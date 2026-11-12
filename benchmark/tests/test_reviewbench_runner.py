"""Real production coordinator integration; only the Pi executable is fake.

Temporary git fixture creation is explicit via REVIEWBENCH_TEST_GIT_FIXTURES=1.
No credentials, network, installed Pi, or production files are used/modified.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_reviewbench_adapter import SECURITY, DELIVERY, QUALITY, ISSUES

ROOT = Path(__file__).resolve().parents[2]
ADAPTER_DIR = ROOT / "benchmark/pr-review/reviewbench"
sys.path.insert(0, str(ADAPTER_DIR))
spec = importlib.util.spec_from_file_location("reviewbench_run", ADAPTER_DIR / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def export_runtime(destination):
    """Export pinned blobs with read-only Git commands; no existing Git writes."""
    files = {}
    tree = runner.git(ROOT, "ls-tree", "-rz", runner.EDC_REVISION, "--", "package.json", "pi", "plugins")
    for entry in tree.split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        mode, kind, sha = metadata.split()
        assert kind == b"blob" and mode in (b"100644", b"100755")
        data = runner.git(ROOT, "cat-file", "blob", sha.decode())
        path = destination / name.decode()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if mode == b"100755" else 0o644)
        files[name.decode()] = runner.digest(data)
    manifest = dict(revision=runner.EDC_REVISION, files=files)
    (destination / "runtime-provenance.json").write_bytes(runner.encoded(manifest))
    return manifest


class ExportIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="reviewbench-export-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = export_runtime(self.root)
        self.path = self.root / "runtime-provenance.json"

    def test_exported_runtime_verifies_all_pinned_bytes_without_git(self):
        self.assertFalse((self.root / ".git").exists())
        # Export validation must not accidentally discover an ancestor Git repo.
        with patch.object(runner, "git", side_effect=AssertionError("Git unavailable in export")):
            identity = runner.runtime_identity(self.root)
        self.assertEqual(identity["revision"], runner.EDC_REVISION)
        self.assertEqual(identity["manifest_sha256"], runner.digest(self.path.read_bytes()))
        self.assertEqual(identity["sha256"], runner.digest(runner.encoded(self.manifest["files"])))

    def test_manifest_formatting_changes_identity_not_trusted_inventory(self):
        first = runner.runtime_identity(self.root)
        self.path.write_text(json.dumps(self.manifest))
        second = runner.runtime_identity(self.root)
        self.assertNotEqual(first["manifest_sha256"], second["manifest_sha256"])
        self.assertEqual(first["sha256"], second["sha256"])

    def test_changed_bytes_rejected_even_with_rehashed_manifest_claiming_pin(self):
        path = self.root / "plugins/edc/scripts/edc"
        path.write_text("not the pinned coordinator")
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)
        self.manifest["files"]["plugins/edc/scripts/edc"] = runner.digest(path.read_bytes())
        self.path.write_bytes(runner.encoded(self.manifest))
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)

    def test_missing_and_unlisted_runtime_files_rejected(self):
        path = self.root / "pi/unlisted.mjs"
        path.write_text("unlisted")
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)
        path.unlink()
        (self.root / "pi/index.mjs").unlink()
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)

    def test_unsafe_manifest_paths_and_wrong_revision_rejected(self):
        for path in ("../escape", "/tmp/escape", "pi/../escape", "./package.json", "pi\\escape", "install.sh"):
            manifest = dict(self.manifest, files=dict(self.manifest["files"], **{path: "a" * 64}))
            self.path.write_bytes(runner.encoded(manifest))
            with self.subTest(path=path), self.assertRaises(runner.AdapterError):
                runner.runtime_identity(self.root)
        self.path.write_bytes(runner.encoded(dict(self.manifest, revision="a" * 40)))
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)

    def test_links_and_special_files_are_not_runtime_provenance(self):
        target = self.root / "pi/index.mjs"
        data = target.read_bytes()
        target.unlink()
        target.symlink_to("README.md")
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)
        target.unlink()
        target.write_bytes(data)
        self.path.rename(self.root / "original.json")
        self.path.symlink_to("original.json")
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)

    def test_manifest_cannot_be_a_hard_link_or_fifo(self):
        self.path.rename(self.root / "original.json")
        os.link(self.root / "original.json", self.path)
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)
        self.path.unlink()
        os.mkfifo(self.path)
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)

    def test_symlinked_directory_rejected(self):
        (self.root / "pi").rename(self.root / "original-pi")
        (self.root / "pi").symlink_to("original-pi", target_is_directory=True)
        with self.assertRaises(runner.AdapterError):
            runner.runtime_identity(self.root)


class InputTests(unittest.TestCase):
    def test_exact_two_pr_manifest_and_environment_binding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pr = dict(repo="https://github.com/test/repo", pr_number=1, base="a" * 40, head="b" * 40)
            metadata = dict(pr, nwo="test/repo", title="test", body="test")
            config = dict(pilot=[pr, dict(pr, pr_number=2)], runtime="/opt/edc", model=runner.MODEL,
                          backend_version="fake", isolation_id="offline", runtime_settings={})
            (root / "pr.json").write_text(json.dumps(metadata))
            env = dict(RB_EDC_CONFIG=str(root / "config.json"), RB_PR_JSON=str(root / "pr.json"),
                       RB_HEAD=pr["head"], RB_BASE=pr["base"], RB_PR_NUMBER="1", RB_NWO="test/repo")
            (root / "config.json").write_text(json.dumps(config))
            self.assertEqual(runner.read_inputs(env)[2], pr)
            self.assertEqual(runner.read_inputs(dict(env, EDC_PI_MODEL=runner.MODEL))[2], pr)
            with self.assertRaises(runner.AdapterError):
                runner.read_inputs(dict(env, EDC_PI_MODEL="other-provider/other-model"))
            for pilot in [[pr], [pr, pr], [pr, dict(pr, pr_number=2), dict(pr, pr_number=3)]]:
                (root / "config.json").write_text(json.dumps(dict(config, pilot=pilot)))
                with self.subTest(pilot=pilot), self.assertRaises(runner.AdapterError):
                    runner.read_inputs(env)
            (root / "config.json").write_text(json.dumps(config))
            for key, value in [("RB_HEAD", "c" * 40), ("RB_BASE", "c" * 40), ("RB_PR_NUMBER", "3"), ("RB_NWO", "wrong/repo")]:
                with self.subTest(key=key), self.assertRaises(runner.AdapterError):
                    runner.read_inputs(dict(env, **{key: value}))

    def usage_fixture(self, root, messages, relative="transcripts/trace.jsonl"):
        trace = root / relative
        trace.parent.mkdir(parents=True, exist_ok=True)
        trace.write_text(json.dumps(dict(type="agent_end", messages=messages)) + "\n")

    def test_usage_missing_is_unknown_not_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            self.usage_fixture(path, [])
            with self.assertRaises(runner.AdapterError):
                runner.usage_inventory(path)

    def test_empty_or_wrong_model_usage_does_not_count_as_accounted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            for message in [dict(role="assistant", usage={}),
                            dict(role="assistant", provider="wrong", model="wrong", usage=dict(input=1, output=1, cacheRead=0, cacheWrite=0, totalTokens=2))]:
                self.usage_fixture(path, [message])
                with self.subTest(message=message), self.assertRaises(runner.AdapterError):
                    runner.usage_inventory(path)

    def test_one_accounted_message_does_not_hide_missing_attempt_usage(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            good = dict(role="assistant", provider="openai-codex", model="gpt-6.1-sol", usage=dict(input=1, output=1, cacheRead=0, cacheWrite=0, totalTokens=2))
            self.usage_fixture(path, [dict(role="assistant", stopReason="error"), good])
            with self.assertRaises(runner.AdapterError):
                runner.usage_inventory(path)

    def test_worker_private_usage_is_checked_not_only_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            good = dict(role="assistant", provider="openai-codex", model="gpt-6.1-sol", usage=dict(input=1, output=1, cacheRead=0, cacheWrite=0, totalTokens=2))
            self.usage_fixture(path, [good])
            self.usage_fixture(path, [good], "worker-state/runs/security/transcripts/worker.jsonl")
            self.assertEqual(len(runner.usage_inventory(path)), 2)
            self.usage_fixture(path, [dict(role="assistant")], "worker-state/runs/security/transcripts/worker.jsonl")
            with self.assertRaises(runner.AdapterError):
                runner.usage_inventory(path)

    def test_head_bounds_use_lf_lines_and_exclude_git_symlinks(self):
        tree = b"100644 blob abc\tsrc/main.py\x00120000 blob def\tlink.py\x00"
        with patch.object(runner, "git", side_effect=[tree, b"a\rb\n"]):
            bounds = runner.HeadBounds(Path("unused"), "a" * 40)
            self.assertNotIn("link.py", bounds)
            self.assertEqual(bounds["src/main.py"], 1)

    def test_unsafe_symlink_artifact_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "escape").symlink_to("/etc/passwd")
            with self.assertRaises(runner.AdapterError):
                runner.regular_files(root)


@unittest.skipUnless(os.environ.get("REVIEWBENCH_TEST_GIT_FIXTURES") == "1", "temporary git writes require explicit test-fixture permission")
class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="reviewbench-offline-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {"PATH": str(self.bin) + os.pathsep + os.environ["PATH"], "HOME": str(self.home),
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "LC_ALL": "C"}
        self.git("init", "-q")
        self.git("config", "user.name", "Offline fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "src").mkdir()
        (self.repo / "src/main.py").write_text("one\ntwo\nthree\nfour\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        base = self.git("rev-parse", "HEAD").strip()
        (self.repo / "src/main.py").write_text("one\nchanged\nthree\nfour\n")
        self.git("add", ".")
        self.git("commit", "-qm", "head")
        head = self.git("rev-parse", "HEAD").strip()
        self.pr = dict(repo="https://github.com/offline/fixture", pr_number=1, base=base, head=head)
        metadata = dict(self.pr, nwo="offline/fixture", title="test", body="test PR")
        (self.root / "pr.json").write_text(json.dumps(metadata))
        (self.root / "diff.patch").write_text(self.git("diff", base + "..." + head))
        # The harness HEAD advances independently of the frozen review runtime.
        # Clone locally into this disposable fixture, then check out the pin.
        runtime = self.root / "runtime-git"
        subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(ROOT), str(runtime)],
                       env=self.env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subprocess.run(["git", "-C", str(runtime), "checkout", "--quiet", "--detach", runner.EDC_REVISION],
                       env=self.env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        config = dict(pilot=[self.pr, dict(self.pr, pr_number=2)], runtime=str(runtime), model=runner.MODEL,
                      backend_version="fake-pi-offline", isolation_id="offline-no-network-fake-provider", runtime_settings={})
        (self.root / "config.json").write_text(json.dumps(config))
        self.env.update(RB_EDC_CONFIG=str(self.root / "config.json"), RB_PR_JSON=str(self.root / "pr.json"),
                        RB_HEAD=head, RB_BASE=base, RB_PR_NUMBER="1", RB_NWO="offline/fixture", RB_AGENT="edc-offline",
                        RB_REPO=str(self.repo), RB_OUT=str(self.root / "findings.json"),
                        RB_ARTIFACT_DIR=str(self.root / "artifacts"), RB_DIFF=str(self.root / "diff.patch"))
        fixtures = dict(security=SECURITY, delivery=DELIVERY, complexity=QUALITY, issues=ISSUES)
        (self.root / "reports.json").write_text(json.dumps(fixtures))
        self.env["EDC_PI_MODEL"] = runner.MODEL
        self.env["PI_CODING_AGENT_DIR"] = str(self.home / "isolated-pi")
        self.env["FAKE_REPORTS"] = str(self.root / "reports.json")
        self.env["FAKE_CALLS"] = str(self.root / "calls.jsonl")
        fake = self.bin / "pi"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, re, sys
args = sys.argv[1:]
prompt = pathlib.Path(next(a[1:] for a in args if a.startswith('@'))).read_text()
with open(os.environ['FAKE_CALLS'], 'a') as stream:
    stream.write(json.dumps({'args': args, 'prompt': prompt, 'model_env': os.environ.get('EDC_PI_MODEL'), 'pi_dir': os.environ.get('PI_CODING_AGENT_DIR'), 'tmpdir': os.environ.get('TMPDIR')}) + '\\n')
assert 'CONTEXT_POLICY: ignored' in prompt
assert 'DO NOT build or update EDC context' in prompt
reports = json.loads(pathlib.Path(os.environ['FAKE_REPORTS']).read_text())
if 'AUDIT SYNTHESIS TASK' in prompt:
    outputs = [(p, reports[k.lower()]) for k,p in re.findall(r'^CANONICAL_(COMPLEXITY|ISSUES)_REPORT: (.+)$', prompt, re.M)]
elif 'AUDIT WORKER TASK' in prompt:
    outputs = [(p, reports['complexity']) for p in re.findall(r'^AUDIT_REPORT_PATH: (.+)$', prompt, re.M)]
elif 'DELIVERY REVIEW TASK' in prompt:
    if os.environ.get('FAKE_TOUCH_SOURCE_DELIVERY') == '1':
        pathlib.Path('src/main.py').write_text('forbidden source mutation')
    outputs = [(p, reports['delivery']) for p in re.findall(r'^DELIVERY_REPORT_PATH: (.+)$', prompt, re.M)]
else:
    outputs = [(p, reports['security']) for p in re.findall(r'Write your report to `([^`]+report-[^`]+\\.md)`', prompt)]
if not outputs:
    raise RuntimeError('unexpected prompt: possible context build')
for path, content in outputs:
    p = pathlib.Path(path); p.parent.mkdir(parents=True, exist_ok=True); p.write_text(content)
message = {'role':'assistant', 'model':'gpt-6.1-sol', 'provider':'openai-codex', 'stopReason':'stop', 'content':[{'type':'text','text':'ok'}], 'usage':{'input':10,'output':5,'cacheRead':0,'cacheWrite':0,'totalTokens':15,'cost':{'total':0}}}
print(json.dumps({'type':'agent_end','messages':[message]}))
''')
        fake.chmod(0o755)
        (self.bin / "octocode").write_text("#!/bin/sh\nexit 1\n")
        (self.bin / "octocode").chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], env=self.env, text=True, stderr=subprocess.PIPE)

    def test_production_path_success_and_resume(self):
        self.assert_success_and_resume()

    def test_exported_runtime_production_path_success_and_resume(self):
        runtime = self.root / "runtime"
        export_runtime(runtime)
        config = json.loads((self.root / "config.json").read_text())
        config["runtime"] = str(runtime)
        (self.root / "config.json").write_text(json.dumps(config))
        self.assert_success_and_resume()
        receipt = json.loads((self.root / "artifacts/receipt.json").read_text())
        self.assertEqual(receipt["identity"]["runtime"]["manifest_sha256"], runner.digest((runtime / "runtime-provenance.json").read_bytes()))

    def assert_success_and_resume(self):
        self.assertEqual(runner.execute(self.env), "completed")
        findings = json.loads((self.root / "findings.json").read_text())
        self.assertEqual(len(findings["findings"]), 1)
        calls = (self.root / "calls.jsonl").read_text()
        self.assertEqual(len(calls.splitlines()), 4)
        for line in calls.splitlines():
            call = json.loads(line)
            self.assertIn("--no-extensions", call["args"])
            self.assertIn(runner.MODEL, call["args"])
            self.assertEqual(call["model_env"], self.env["EDC_PI_MODEL"])
            self.assertEqual(call["pi_dir"], self.env["PI_CODING_AGENT_DIR"])
            self.assertEqual(call["tmpdir"], str(self.root / "artifacts/tmp"))
        self.assertFalse((self.repo / "edc-context/manifest.json").exists())
        artifacts = self.root / "artifacts"
        self.assertTrue(list((artifacts / "worker-state").rglob("*.json")))
        self.assertEqual(len(list(artifacts.glob("**/transcripts/*.jsonl"))), 4)
        self.assertEqual(len(json.loads((artifacts / "usage-inventory.json").read_text())), 4)
        self.assertEqual(runner.execute(self.env), "resumed")
        self.assertEqual((self.root / "calls.jsonl").read_text(), calls)
        with self.assertRaises(runner.AdapterError):
            runner.execute(dict(self.env, PI_CODING_AGENT_DIR=str(self.home / "different-config")))
        self.assertEqual((self.root / "calls.jsonl").read_text(), calls)
        (artifacts / "reports/security.md").write_text("corrupt")
        with self.assertRaises(runner.AdapterError):
            runner.execute(self.env)
        self.assertEqual((self.root / "calls.jsonl").read_text(), calls)

    def test_zero_findings_remains_a_valid_complete_review(self):
        reports = json.loads((self.root / "reports.json").read_text())
        reports["security"] = "## Findings\n### No security findings\nChecked validation and scope.\n"
        (self.root / "reports.json").write_text(json.dumps(reports))
        self.assertEqual(runner.execute(self.env), "completed")
        findings = json.loads((self.root / "findings.json").read_text())
        self.assertEqual(findings["findings"], [])
        self.assertEqual(len((self.root / "calls.jsonl").read_text().splitlines()), 4)

    def test_malformed_final_report_is_not_zero_or_rerun(self):
        reports = json.loads((self.root / "reports.json").read_text())
        reports["security"] = SECURITY.replace("src/main.py:2-3", "src/main.py")
        (self.root / "reports.json").write_text(json.dumps(reports))
        with self.assertRaises(runner.AdapterError):
            runner.execute(self.env)
        artifacts = self.root / "artifacts"
        self.assertEqual(json.loads((artifacts / "result.json").read_text())["status"], "success")
        self.assertIn("unsupported or ambiguous head evidence", (artifacts / "failure.json").read_text())
        self.assertIn("- where: `src/main.py`", (artifacts / "reports/security.md").read_text())
        self.assertEqual(len(list(artifacts.glob("**/transcripts/*.jsonl"))), 4)
        self.assertFalse((self.root / "findings.json").exists())
        calls = (self.root / "calls.jsonl").read_text()
        with self.assertRaises(runner.AdapterError):
            runner.execute(self.env)
        self.assertEqual((self.root / "calls.jsonl").read_text(), calls)

    def test_failed_phase_retains_structured_failure_and_unpromoted_report(self):
        self.env["FAKE_TOUCH_SOURCE_DELIVERY"] = "1"
        with self.assertRaises(runner.AdapterError):
            runner.execute(self.env)
        artifacts = self.root / "artifacts"
        result = json.loads((artifacts / "result.json").read_text())
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["failedPhase"], "delivery")
        self.assertEqual(result["reasonCode"], "delivery-write-containment")
        self.assertTrue(list((artifacts / "worker-state").glob("**/staged/delivery.md")))
        self.assertTrue((artifacts / "failure.json").is_file())
        self.assertFalse((self.root / "findings.json").exists())

    def test_coverage_warning_preserves_artifacts_and_blocks_retry(self):
        reports = json.loads((self.root / "reports.json").read_text())
        reports["delivery"] = ""
        (self.root / "reports.json").write_text(json.dumps(reports))
        with self.assertRaises(runner.AdapterError):
            runner.execute(self.env)
        artifacts = self.root / "artifacts"
        self.assertTrue((artifacts / "failure.json").is_file())
        self.assertTrue((artifacts / "result.json").is_file())
        self.assertTrue((artifacts / "reports/security.md").is_file())
        self.assertFalse((self.root / "findings.json").exists())
        calls = (self.root / "calls.jsonl").read_text()
        with self.assertRaises(runner.AdapterError):
            runner.execute(self.env)
        self.assertEqual((self.root / "calls.jsonl").read_text(), calls)

    def test_head_bounds_reject_symlink_and_missing_path(self):
        bounds = runner.HeadBounds(self.repo, self.pr["head"])
        self.assertEqual(bounds["src/main.py"], 4)
        self.assertNotIn("../escape", bounds)
        self.assertNotIn("missing", bounds)


if __name__ == "__main__":
    unittest.main()
