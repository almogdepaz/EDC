#!/usr/bin/env python3
"""Exercise the authored update recipe and real generator in an owned repository."""
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from contextlib import contextmanager

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "plugins/edc/scripts"
PROMPT = ROOT / "plugins/edc/prompt-bundles/edc-update-impl/SKILL.md"
BLOCKS = re.findall(r"```bash\n([\s\S]*?)\n```", PROMPT.read_text())
PREPARATION = next(block for block in BLOCKS if block.startswith("mkdir -p edc-context/.manifest-inputs"))
PROMOTION = next(block for block in BLOCKS if block.startswith("MANIFEST=edc-context/manifest.json"))
ARGV_PREFIX = "CLI ARGUMENTS (JSON argv): "
PROCESS_TIMEOUT = 10
CLEANUP_TIMEOUT = 3
READY = b"ready"


def assert_group_absent(pid):
    deadline = time.monotonic() + CLEANUP_TIMEOUT
    while True:
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            return
        if time.monotonic() >= deadline:
            raise AssertionError(f"owned process group {pid} remains after cleanup")
        select.select([], [], [], 0.01)


@contextmanager
def owned_process(command, cwd, **kwargs):
    process = subprocess.Popen(
        command, cwd=cwd, start_new_session=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs,
    )
    try:
        yield process
    finally:
        try:
            # Reap an already-exited leader before addressing its remaining group.
            process.poll()
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=CLEANUP_TIMEOUT)
            assert_group_absent(process.pid)
        finally:
            process.stdout.close()
            process.stderr.close()


def capture(command, cwd, **kwargs):
    with owned_process(command, cwd, **kwargs) as process:
        stdout, stderr = process.communicate(timeout=PROCESS_TIMEOUT)
        if process.returncode:
            raise AssertionError(f"command exited {process.returncode}: {stderr}")
        return stdout


def await_ready(pipe):
    if not select.select([pipe], [], [], 1)[0]:
        raise TimeoutError("owned helper did not become ready")
    if os.read(pipe.fileno(), len(READY)) != READY:
        raise RuntimeError("owned helper exited before readiness")


class ManifestPromotionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="edc-t35-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.manifest = self.repo / "edc-context/manifest.json"
        self.manifest.parent.mkdir()
        self.manifest.write_bytes(b"original-manifest")
        for relative in ("src/keep.py", "paths with spaces/skip.py", "$(touch sentinel)/skip.py"):
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# fixture\n")
        capture(["git", "init", "-q"], self.repo)
        capture(["git", "add", "src", "paths with spaces", "$(touch sentinel)"], self.repo)
        capture([
            "git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "-qm", "fixture",
        ], self.repo)
        self.partial = {
            "schemaVersion": 2, "edcVersion": "2.0.0",
            "repoContextFile": "edc-context/index.md", "reports": {}, "build": {},
            "policy": {"defaultMode": "advisory", "unmatchedPathPolicy": "warn-allow"},
            "modules": [{"name": "fixture", "doc": "edc-context/modules/fixture.md",
                         "summary": "fixture", "priority": 100, "match": {"globs": ["**"]}}],
            "unmapped": {"allowedGlobs": []},
        }

    @contextmanager
    def prepared_input(self, content=None):
        relative = capture(["bash", "-c", PREPARATION], self.repo).strip()
        path = self.repo / relative
        self.assertEqual(path.parent, self.repo / "edc-context/.manifest-inputs")
        try:
            path.write_text(json.dumps(self.partial) if content is None else content)
            yield path
        finally:
            path.unlink(missing_ok=True)

    def assembled_argv(self, arguments, action="update"):
        prompt = capture([
            "bash", "-c", '. "$1"; shift; resolve_prompt "$@"', "fixture",
            str(SCRIPTS / "edc-lib.sh"), action, *arguments,
        ], self.repo, env={**os.environ, "EDC_AGENT_CLI": "claude"})
        lines = [line for line in prompt.splitlines() if line.startswith(ARGV_PREFIX)]
        if not arguments:
            self.assertEqual(lines, [])
            return []
        self.assertEqual(len(lines), 1)
        return json.loads(lines[0][len(ARGV_PREFIX):])

    def promotion_command(self, partial, arguments=()):
        # Fill only the two documented worker inputs; execute the authored body.
        block = PROMOTION.replace("<exact-prepared-partial-path>", shlex.quote(str(partial)))
        block = block.replace("manifest_ignore_args=()", "manifest_ignore_args=(" + shlex.join(arguments) + ")")
        return ["bash", "-c", block]

    def assert_staging_clean(self):
        self.assertEqual(list(self.manifest.parent.glob(".manifest-update.*")), [])

    def test_preparation_creates_distinct_owned_inputs(self):
        with self.prepared_input() as first, self.prepared_input() as second:
            self.assertNotEqual(first, second)
            self.assertTrue(first.is_file() and second.is_file())
        self.assertFalse(first.exists() or second.exists())

    def test_real_argv_and_generator_preserve_scope(self):
        for arguments in ([], ["--ignore", "paths with spaces/**", "--ignore", "$(touch sentinel)/**"]):
            with self.subTest(arguments=arguments):
                received = self.assembled_argv(arguments)
                self.assertEqual(received, arguments)
                self.assertEqual(self.assembled_argv(arguments, action="build"), arguments)
                with self.prepared_input() as partial:
                    capture(self.promotion_command(partial, received), self.repo,
                            env={**os.environ, "EDC_SCRIPTS_DIR": str(SCRIPTS)})
                manifest = json.loads(self.manifest.read_text())
                self.assertEqual(manifest["coverage"]["ignoreGlobs"], arguments[1::2])
                self.assertEqual(manifest["coverage"]["ignoredFileCount"], len(arguments) // 2)
                self.assertEqual(manifest["coverage"]["contextMappedFileCount"], 3 - len(arguments) // 2)
                self.assertEqual(manifest["policy"], self.partial["policy"])
                self.assertFalse((self.repo / "sentinel").exists())
                self.assert_staging_clean()

    def test_invalid_input_preserves_manifest(self):
        with self.prepared_input("{invalid") as partial:
            with owned_process(self.promotion_command(partial), self.repo,
                               env={**os.environ, "EDC_SCRIPTS_DIR": str(SCRIPTS)}) as process:
                process.communicate(timeout=PROCESS_TIMEOUT)
                self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.manifest.read_bytes(), b"original-manifest")
        self.assert_staging_clean()

    def test_signal_and_failed_readiness_clean_owned_resources(self):
        scripts = self.repo / "owned-helper"
        scripts.mkdir()
        for mode in ("ready", "silent", "early-exit"):
            with self.subTest(mode=mode), self.prepared_input() as partial:
                helper = scripts / "edc-manifest.sh"
                helper.write_text(
                    '#!/usr/bin/env bash\n'
                    f'bash {shlex.quote(str(SCRIPTS / "edc-manifest.sh"))} "$@" || exit $?\n'
                    + ('exit 17\n' if mode == "early-exit" else
                       ('printf ready >&"$READY_FD"\n' if mode == "ready" else '') + 'exec sleep 60\n')
                )
                read_fd, write_fd = os.pipe()
                with os.fdopen(read_fd, "rb", buffering=0) as reader, os.fdopen(write_fd, "wb", buffering=0) as writer:
                    environment = {**os.environ, "EDC_SCRIPTS_DIR": str(scripts), "READY_FD": str(writer.fileno())}
                    started = time.monotonic()
                    with owned_process(self.promotion_command(partial), self.repo,
                                       env=environment, pass_fds=(writer.fileno(),)) as process:
                        writer.close()
                        if mode == "ready":
                            await_ready(reader)
                            os.killpg(process.pid, signal.SIGTERM)
                            self.assertEqual(process.wait(timeout=PROCESS_TIMEOUT), 143)
                        else:
                            expected = TimeoutError if mode == "silent" else RuntimeError
                            with self.assertRaises(expected):
                                await_ready(reader)
                    self.assertLess(time.monotonic() - started, PROCESS_TIMEOUT)
                self.assertEqual(self.manifest.read_bytes(), b"original-manifest")
                if mode != "silent":
                    self.assert_staging_clean()
                else:
                    # SIGKILL cannot run shell traps; remove only fixture-owned staging.
                    for stage in self.manifest.parent.glob(".manifest-update.*"):
                        shutil.rmtree(stage)
                assert_group_absent(process.pid)
        self.assertEqual(list((self.manifest.parent / ".manifest-inputs").iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
