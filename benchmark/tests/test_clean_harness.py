"""Tests for the clean benchmark harness (plan 041 p1).

No real model calls: fake `claude`, `enemy` and `edc` live in
tests/fixtures/clean-fakes and are put on PATH (or passed by env override).
"""

import csv
import hashlib
import importlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import unittest.mock
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCHMARK_DIR = REPO_ROOT / "benchmark"
FIXTURES = BENCHMARK_DIR / "tests" / "fixtures"
FAKES = FIXTURES / "clean-fakes"
BLOCKED = FIXTURES / "clean-blocked"
CLEAN_SH = BENCHMARK_DIR / "clean.sh"
sys.path.insert(0, str(BENCHMARK_DIR))

clean_gt = importlib.import_module("clean_gt")
clean_snapshot = importlib.import_module("clean_snapshot")
clean_blocked = importlib.import_module("clean_blocked")
clean_harness = importlib.import_module("clean_harness")
clean_access = importlib.import_module("clean_access")

GIT_ENV = {
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@localhost",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@localhost",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
}

VULN_A = "int main(void) {\n  char buf[8];\n  copy(buf, host, len); /* vulnerable */\n  return 0;\n}\n"
FIXED_A = VULN_A.replace("copy(buf, host, len); /* vulnerable */", "if (len < 8) copy(buf, host, len);")
LATER_A = FIXED_A + "/* later */\n"
PLANT_DIFF = """--- a/b.c
+++ b/b.c
@@ -1,3 +1,3 @@
 int helper(int n) {
-  return n > 0 ? n : 0;
+  return n >= 0 ? n : 0; /* planted */
 }
"""


def git(cwd, *args, check=True):
    env = {**os.environ, **GIT_ENV}
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=check,
                          capture_output=True, text=True)


def build_source_repo(root: Path):
    """Three commits: A (vulnerable), B (fix), C (later). Returns shas."""
    src = root / "src"
    (src / "lib").mkdir(parents=True)
    git(src, "init", "-q", "-b", "main")
    (src / "a.c").write_text(VULN_A)
    (src / "b.c").write_text("int helper(int n) {\n  return n > 0 ? n : 0;\n}\n")
    (src / "lib" / "c.c").write_text("int c;\n")
    (src / "README").write_text("readme\n")
    git(src, "add", "-A")
    git(src, "commit", "-qm", "A vulnerable")
    a = git(src, "rev-parse", "HEAD").stdout.strip()
    (src / "a.c").write_text(FIXED_A)
    git(src, "commit", "-qam", "B fix CVE-2099-0001")
    b = git(src, "rev-parse", "HEAD").stdout.strip()
    (src / "a.c").write_text(LATER_A)
    git(src, "commit", "-qam", "C later")
    c = git(src, "rev-parse", "HEAD").stdout.strip()
    return src, a, b, c


def build_gt_root(root: Path, src: Path, fix: str, base: str) -> Path:
    gt_root = root / "gt"
    proj = gt_root / "proj"
    (proj / "plants").mkdir(parents=True)
    (proj / "repo.conf").write_text(f"repo_url=file://{src}\n")
    (proj / "plants" / "PLANT-proj-01.diff").write_text(PLANT_DIFF)
    (proj / "ground-truth.md").write_text(f"""# proj ground truth

### CVE-2099-0001
- **category:** heap-buffer-overflow
- **severity:** critical
- **description:** heap buffer overflow when the hostname
  length check is bypassed.
- **fix_commit:** `{fix}`
- **affected_file:** a.c
- **bug_pattern:** hostname length check bypassed, overflow on copy
- **disclosed:** 2099-01-02
- **source:** https://example.invalid/CVE-2099-0001

### PLANT-proj-01
- **category:** off-by-one
- **severity:** medium
- **description:** helper accepts zero
- **base_commit:** `{base}`
- **affected_file:** b.c
- **line:** 2
- **bug_pattern:** boundary comparison accepts zero
- **patch:** plants/PLANT-proj-01.diff
""")
    return gt_root


class Fixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()
        self.src, self.a, self.b, self.c = build_source_repo(self.root)
        self.gt_root = build_gt_root(self.root, self.src, self.b, self.a)
        self.work = self.root / "work"

    def tearDown(self):
        self._tmp.cleanup()


class GroundTruthTests(Fixture):
    def test_parses_cve_and_planted_entries(self):
        entries = {e["id"]: e for e in clean_gt.parse_entries(self.gt_root / "proj" / "ground-truth.md")}
        cve = entries["CVE-2099-0001"]
        self.assertEqual(cve["kind"], "cve")
        self.assertEqual(cve["fix_commit"], self.b)
        self.assertEqual(cve["affected_files"], ["a.c"])
        self.assertIn("length check is bypassed", cve["description"])
        plant = entries["PLANT-proj-01"]
        self.assertEqual(plant["kind"], "planted")
        self.assertEqual(plant["base_commit"], self.a)
        self.assertEqual(plant["patch"], "plants/PLANT-proj-01.diff")
        self.assertEqual(plant["line"], "2")
        self.assertEqual(clean_gt.read_repo_url(self.gt_root / "proj"), f"file://{self.src}")

    def test_multi_file_affected_list(self):
        gt = self.root / "multi.md"
        gt.write_text("### CVE-1-2\n- **category:** x\n- **fix_commit:** abc\n- **affected_file:** lib/a.c, lib/b.h\n")
        (entry,) = clean_gt.parse_entries(gt)
        self.assertEqual(entry["affected_files"], ["lib/a.c", "lib/b.h"])


class SnapshotTests(Fixture):
    def snapshot(self, entry_id):
        entries = {e["id"]: e for e in clean_gt.parse_entries(self.gt_root / "proj" / "ground-truth.md")}
        cache = clean_snapshot.ensure_cache(f"file://{self.src}", self.work / "cache" / "proj.git")
        dest = self.work / "snap" / "opaque"
        clean_snapshot.make_snapshot(cache, entries[entry_id], self.gt_root / "proj", dest)
        return dest

    def test_cve_snapshot_is_single_commit_without_fix_history(self):
        snap = self.snapshot("CVE-2099-0001")
        self.assertEqual(git(snap, "rev-list", "--all").stdout.split(), [git(snap, "rev-parse", "HEAD").stdout.strip()])
        self.assertEqual(git(snap, "rev-parse", "HEAD^{tree}").stdout.strip(),
                         git(self.src, "rev-parse", f"{self.a}^{{tree}}").stdout.strip())
        for later in (self.b, self.c):
            self.assertNotEqual(git(snap, "cat-file", "-e", later, check=False).returncode, 0)
        self.assertNotEqual(git(snap, "cat-file", "-e", f"{self.b}^{{tree}}", check=False).returncode, 0)
        self.assertEqual(git(snap, "remote").stdout.strip(), "")
        self.assertFalse((snap / ".git" / "objects" / "info" / "alternates").exists())
        self.assertEqual((snap / "a.c").read_text(), VULN_A)
        log = git(snap, "log", "--format=%s%n%an%n%ae").stdout
        self.assertNotIn("CVE", log)
        self.assertEqual(git(snap, "status", "--porcelain").stdout, "")

    def test_planted_snapshot_applies_patch_in_single_commit(self):
        snap = self.snapshot("PLANT-proj-01")
        self.assertIn("/* planted */", (snap / "b.c").read_text())
        self.assertEqual(len(git(snap, "rev-list", "--all").stdout.split()), 1)
        tracked = git(snap, "ls-files").stdout.split()
        self.assertNotIn("plants/PLANT-proj-01.diff", tracked)
        self.assertFalse(any(p.endswith(".diff") for p in tracked))
        self.assertEqual(git(snap, "status", "--porcelain").stdout, "")
        for later in (self.b, self.c):
            self.assertNotEqual(git(snap, "cat-file", "-e", later, check=False).returncode, 0)

    def assert_uniform_mtimes(self, snap):
        """No file or dir outside .git stands out by mtime (`ls -lt` / `find -newer`)."""
        paths = [snap] + [p for p in snap.rglob("*") if ".git" not in p.relative_to(snap).parts]
        self.assertGreater(len(paths), 5)
        mtimes = {p.lstat().st_mtime_ns for p in paths}
        self.assertEqual(len(mtimes), 1, sorted((p.lstat().st_mtime_ns, str(p.relative_to(snap))) for p in paths))

    def test_snapshots_have_uniform_mtimes(self):
        for entry_id in ("CVE-2099-0001", "PLANT-proj-01"):
            with self.subTest(entry=entry_id):
                shutil.rmtree(self.work / "snap", ignore_errors=True)
                snap = self.snapshot(entry_id)
                self.assert_uniform_mtimes(snap)
                self.assertEqual(git(snap, "status", "--porcelain").stdout, "")
                self.assertEqual(len(git(snap, "rev-list", "--all").stdout.split()), 1)

    def test_planted_snapshot_is_patched_tree(self):
        """The plant is part of the extracted tree: the snapshot tree is base + patch."""
        snap = self.snapshot("PLANT-proj-01")
        self.assertIn("/* planted */", (snap / "b.c").read_text())
        expected = self.root / "expected"
        git(self.root, "clone", "-q", str(self.src), str(expected))
        git(expected, "checkout", "-q", self.a)
        git(expected, "apply", str(self.gt_root / "proj" / "plants" / "PLANT-proj-01.diff"))
        git(expected, "add", "-A")
        self.assertEqual(git(snap, "rev-parse", "HEAD^{tree}").stdout.strip(),
                         git(expected, "write-tree").stdout.strip())

    def test_concurrent_cache_creation_is_atomic(self):
        cache = self.work / "cache" / "proj.git"
        errors = []

        def fetch():
            try:
                clean_snapshot.ensure_cache(f"file://{self.src}", cache)
            except Exception as exc:  # noqa: BLE001 - collected for the assertion
                errors.append(exc)

        threads = [threading.Thread(target=fetch) for _ in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        self.assertEqual(git(cache, "rev-parse", self.c).returncode, 0)
        leftovers = [p.name for p in cache.parent.iterdir() if p.name != "proj.git" and not p.name.endswith(".lock")]
        self.assertEqual(leftovers, [])

    def test_cache_dir_without_head_is_refused(self):
        cache = self.work / "cache" / "proj.git"
        cache.mkdir(parents=True)
        (cache / "partial").write_text("")
        with self.assertRaises(clean_snapshot.SnapshotError):
            clean_snapshot.ensure_cache(f"file://{self.src}", cache)

    def test_planted_patch_that_does_not_apply_fails(self):
        (self.gt_root / "proj" / "plants" / "PLANT-proj-01.diff").write_text(PLANT_DIFF.replace("n > 0", "n > 9"))
        with self.assertRaises(clean_snapshot.SnapshotError):
            self.snapshot("PLANT-proj-01")

    def test_missing_affected_file_fails(self):
        gt = self.gt_root / "proj" / "ground-truth.md"
        gt.write_text(gt.read_text().replace("- **affected_file:** a.c", "- **affected_file:** nope.c"))
        with self.assertRaises(clean_snapshot.SnapshotError):
            self.snapshot("CVE-2099-0001")


class IgnoreComplementTests(unittest.TestCase):
    TRACKED = ["README", "a.c", "b.c", "lib/c.c", "lib/d.c", "lib/sub/e.c", "lib/sub/f.c", "docs/x.md"]

    def filter_with_edc_lib(self, patterns):
        """Run edc's own ignore filter over the tracked list."""
        script = ('. "$1/plugins/edc/scripts/edc-lib.sh"; shift; files=$(cat); '
                  'edc_filter_ignored_files "$files" "$@"')
        out = subprocess.run(["bash", "-c", script, "bash", str(REPO_ROOT), *patterns],
                             input="\n".join(self.TRACKED) + "\n", capture_output=True, text=True, check=True)
        return [line for line in out.stdout.splitlines() if line]

    def test_complement_keeps_only_affected_files(self):
        for keep in (["a.c"], ["lib/sub/e.c"], ["lib/c.c", "lib/sub/f.c"]):
            with self.subTest(keep=keep):
                patterns = clean_harness.ignore_complement(self.TRACKED, keep)
                self.assertEqual(sorted(self.filter_with_edc_lib(patterns)), sorted(keep))


class BlockedDetectionTests(unittest.TestCase):
    def detect(self, call_logs=(), text_logs=()):
        return clean_blocked.detect_blocked([BLOCKED / p for p in call_logs], [BLOCKED / p for p in text_logs])

    def test_api_policy_error_is_blocked(self):
        blocked, signal = self.detect(["api-block.jsonl"])
        self.assertTrue(blocked)
        self.assertTrue(signal.startswith("json:"), signal)

    def test_refusal_stop_reason_is_blocked(self):
        blocked, signal = self.detect(["refusal-stop.jsonl"])
        self.assertTrue(blocked)
        self.assertIn("refusal", signal)

    def test_soft_block_text_in_result_is_blocked(self):
        blocked, signal = self.detect(["soft-block.jsonl"])
        self.assertTrue(blocked)
        self.assertTrue(signal.startswith("json:"), signal)

    def test_clean_run_is_not_blocked_even_with_security_prose(self):
        self.assertEqual(self.detect(["clean.jsonl"], ["clean-text.log"]), (False, ""))

    # report prose about a missing/bypassed check (041 review P5)
    PROSE = ["The length is stopped by the safety check at line 672 only when the flag is set.",
             "Oversized names are flagged by the safety filter but still copied.",
             "The request is blocked by a safety check that the slow path skips.",
             "Input is blocked by the safety system unless the state is reset."]

    def test_security_prose_about_safety_checks_is_not_blocked(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        for sentence in self.PROSE:
            with self.subTest(sentence=sentence):
                log, text = tmp / "call.jsonl", tmp / "out.log"
                log.write_text(json.dumps({"type": "result", "is_error": False, "stop_reason": "end_turn",
                                           "result": f"# issues\n\n{sentence}\n"}) + "\n")
                text.write_text(f"pass 1 report:\n{sentence}\n")
                self.assertEqual(clean_blocked.detect_blocked([log], [text]), (False, ""))
                self.assertEqual(clean_blocked.detect_blocked([], [text])[0], False)

    def test_generic_safety_phrase_counts_in_error_results(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        log = tmp / "call.jsonl"
        log.write_text(json.dumps({"type": "result", "is_error": True, "result": "Request blocked by the safety system."}))
        blocked, signal = clean_blocked.detect_blocked([log], [])
        self.assertTrue(blocked)
        self.assertTrue(signal.startswith("json:result_error="), signal)

    def test_text_fallback_detects_api_block_without_call_logs(self):
        blocked, signal = self.detect([], ["api-block-text.log"])
        self.assertTrue(blocked)
        self.assertTrue(signal.startswith("text:"), signal)

    def test_refusal_re_used_only_as_fallback(self):
        blocked, signal = self.detect([], ["refusal-text.log"])
        self.assertTrue(blocked)
        self.assertTrue(signal.startswith("text:refusal_re"), signal)
        # with structured call logs present, the prose regex is not consulted
        self.assertEqual(self.detect(["clean.jsonl"], ["refusal-text.log"]), (False, ""))


class ArmDispatchTests(Fixture):
    def setUp(self):
        super().setUp()
        # the harness strips repo paths from the arm's PATH and env, so the fakes live outside the repo
        self.fakes = self.root / "fakes"
        shutil.copytree(FAKES, self.fakes)

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("EDC_", "FAKE_"))}
        env.update(GIT_ENV)
        env["PATH"] = f"{self.fakes}:{env['PATH']}"
        env["EDC_BENCH_WORKDIR"] = str(self.work)
        env["FAKE_CLAUDE_ARGV_LOG"] = str(self.root / "claude-argv.jsonl")
        env["FAKE_ENEMY_ARGV_LOG"] = str(self.root / "enemy-argv.log")
        env["FAKE_EDC_ARGV_LOG"] = str(self.root / "edc-argv.log")
        env["ENEMY_BIN"] = str(self.fakes / "enemy")
        env["EDC_BENCH_EDC_BIN"] = str(self.fakes / "edc")
        env.update(extra)
        return env

    def run_arm(self, arm, entry="CVE-2099-0001", env=None, check=True, judge=False, extra=()):
        cmd = ["bash", str(CLEAN_SH), "--arm", arm, "--gt-root", str(self.gt_root), "--project", "proj",
               "--entry", entry, *([] if judge else ["--skip-judge"]), *extra]
        proc = subprocess.run(cmd, env=env or self.env(), capture_output=True, text=True)
        if check:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def record(self, arm, entry="CVE-2099-0001", run=1):
        path = self.work / "clean" / "results" / arm / entry / f"run-{run}" / "record.tsv"
        with path.open(newline="") as fh:
            rows = list(csv.DictReader(fh, delimiter="\t"))
        self.assertEqual(len(rows), 1)
        return rows[0]

    def claude_calls(self):
        path = self.root / "claude-argv.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_opaque(self, cwd):
        self.assertNotIn("CVE-2099-0001", cwd)
        self.assertNotIn("PLANT", cwd)

    def test_edc_module_arm(self):
        self.run_arm("edc-module")
        (call,) = self.claude_calls()
        argv = call["argv"]
        self.assertEqual(argv[argv.index("--model") + 1], "claude-opus-5-5")
        self.assertEqual(argv[argv.index("--max-turns") + 1], "50")
        self.assertEqual(argv[argv.index("--allowedTools") + 1], "Read Grep Glob Write Bash Skill")
        plugin = Path(argv[argv.index("--plugin-dir") + 1])
        self.assertNotIn(REPO_ROOT, plugin.parents)  # no path back to ground truth
        self.assertIn(self.work.resolve(), plugin.parents)
        self.assertTrue((plugin / "skills" / "edc-review" / "SKILL.md").is_file())
        self.assertTrue(os.access(plugin / "scripts" / "edc", os.X_OK))
        prompt = argv[argv.index("-p") + 1]
        self.assertIn("Apply the EDC module-context methodology on ONLY these files:  a.c", prompt)
        self.assert_opaque(call["cwd"])
        self.assertEqual(call["commits"], 1)
        row = self.record("edc-module")
        self.assertEqual((row["arm"], row["outcome"], row["verdict"], row["model_calls"], row["blocked"]),
                         ("edc-module", "exact", "exact", "1", "no"))
        self.assertEqual(row["model"], "claude-opus-5-5")

    def test_edc_review_skill_arm_uses_flat_copy(self):
        self.run_arm("edc-review-skill")
        (call,) = self.claude_calls()
        argv = call["argv"]
        self.assertEqual(argv[argv.index("--max-turns") + 1], "20")
        self.assertEqual(argv[argv.index("--allowedTools") + 1], "Read Glob Grep Write Skill")
        prompt = argv[argv.index("-p") + 1]
        self.assertIn("Use the edc-review methodology. This is a FULL-FILE review", prompt)
        self.assertIn("No pre-built context available", prompt)
        self.assert_opaque(call["cwd"])
        self.assertEqual(sorted(call["files"]), ["a.c"])
        self.assertEqual(self.record("edc-review-skill")["outcome"], "exact")

    def test_edc_security_arm(self):
        self.run_arm("edc-security", env=self.env(EDC_BENCH_MODEL="fake-model"))
        build, review = (self.root / "edc-argv.log").read_text().splitlines()
        self.assertEqual(build.split()[:4], ["--model", "fake-model", "build", "--agent"])
        rv = review.split()
        self.assertEqual(rv[:5], ["--model", "fake-model", "security-review", "--agent", "claude"])
        self.assertIn("--full", rv)
        self.assertIn("--no-context-refresh", rv)
        ignores = [rv[i + 1] for i, a in enumerate(rv) if a == "--ignore"]
        self.assertIn("b.c", ignores)
        self.assertNotIn("a.c", ignores)
        row = self.record("edc-security")
        self.assertEqual((row["outcome"], row["model_calls"], row["build_model_calls"], row["model"]),
                         ("exact", "1", "1", "fake-model"))
        self.assertNotEqual(row["build_duration_s"], "")
        self.assertTrue(row["report"].endswith("review-HEAD.md"))

    def test_enemy_arm_through_shim(self):
        self.run_arm("enemy-3", env=self.env(EDC_BENCH_MODEL="fake-model"))
        argv = (self.root / "enemy-argv.log").read_text().split()
        self.assertEqual(argv[:2], ["audit", "a.c"])
        self.assertEqual(argv[argv.index("--max-passes") + 1], "3")
        snap = argv[argv.index("--repo") + 1]
        self.assert_opaque(snap)
        (call,) = self.claude_calls()
        cargv = call["argv"]
        self.assertEqual(cargv[cargv.index("--model") + 1], "fake-model")
        self.assertIn("stream-json", cargv)
        # only ls/wc are pre-approved; unscoped Read/Write/Edit rules would allow absolute paths outside
        # the workspace, so file tools rely on the default working-directory confinement (acceptEdits)
        self.assertEqual(cargv[cargv.index("--allowedTools") + 1:], ["Bash(ls:*)", "Bash(wc:*)"])
        self.assertEqual(cargv[cargv.index("--permission-mode") + 1], "acceptEdits")
        self.assertEqual(cargv[cargv.index("--disallowedTools") + 1], "WebFetch WebSearch Bash(git:*)")
        self.assertEqual(cargv[cargv.index("--tools") + 1], "Read,Grep,Glob,Write,Edit,Bash")
        self.assertIn("--strict-mcp-config", cargv)
        self.assertEqual(call["stdin"].strip(), "pass 2 prompt")
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(snap))
        row = self.record("enemy-3")
        self.assertEqual((row["outcome"], row["verdict"], row["passes_run"], row["loop_end"], row["arm_exit"],
                          row["model_calls"]), ("exact", "exact", "3", "capped", "4", "1"))

    def test_enemy_blocked_still_scores_completed_passes(self):
        proc = self.run_arm("enemy-3", env=self.env(FAKE_CLAUDE_MODE="blocked_api"))
        row = self.record("enemy-3")
        self.assertEqual((row["outcome"], row["verdict"], row["passes_run"], row["arm_exit"], row["blocked"]),
                         ("blocked", "exact", "1", "3", "yes"), proc.stdout + proc.stderr)
        self.assertTrue(row["blocked_signal"].startswith("json:"))

    def test_single_call_arm_blocked(self):
        self.run_arm("edc-module", env=self.env(FAKE_CLAUDE_MODE="blocked_api"))
        row = self.record("edc-module")
        self.assertEqual((row["outcome"], row["blocked"]), ("blocked", "yes"))

    def test_planted_entry_runs(self):
        self.run_arm("edc-module", entry="PLANT-proj-01")
        (call,) = self.claude_calls()
        self.assert_opaque(call["cwd"])
        self.assertIn("/* planted */", call["files"]["b.c"])
        self.assertEqual(self.record("edc-module", entry="PLANT-proj-01")["kind"], "planted")

    def test_edc_deep_is_reserved(self):
        proc = self.run_arm("edc-deep", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not implemented until p4", proc.stderr)
        self.assertEqual(self.claude_calls(), [])

    def test_unknown_arm_rejected(self):
        proc = self.run_arm("nope", check=False)
        self.assertNotEqual(proc.returncode, 0)

    def test_enemy_without_max_passes_is_rejected(self):
        old = self.root / "old-enemy"
        old.write_text("#!/bin/sh\necho 'Usage: enemy audit [OPTIONS] [target]'\n")
        old.chmod(0o755)
        proc = self.run_arm("enemy-3", env=self.env(ENEMY_BIN=str(old)), check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--max-passes", proc.stderr)


class ResultsIsolationTests(ArmDispatchTests):
    def test_custom_results_file_and_legacy_untouched(self):
        legacy = BENCHMARK_DIR / "results.tsv"
        before = hashlib.sha256(legacy.read_bytes()).hexdigest()
        results = self.root / "iso" / "arm.tsv"
        self.run_arm("edc-module", env=self.env(EDC_RESULTS_FILE=str(results)))
        self.run_arm("edc-module", env=self.env(EDC_RESULTS_FILE=str(results)), extra=["--run", "2"])
        self.assertEqual([r["run"] for r in self.rows(results)], ["1", "2"])
        self.assertEqual(hashlib.sha256(legacy.read_bytes()).hexdigest(), before)

    def rows(self, path):
        with path.open(newline="") as fh:
            return list(csv.DictReader(fh, delimiter="\t"))

    def test_rerun_of_same_run_replaces_its_row(self):
        results = self.root / "iso" / "arm.tsv"
        env = self.env(EDC_RESULTS_FILE=str(results))
        self.run_arm("edc-module", env=env)
        self.run_arm("edc-module", env=env, extra=["--run", "2"])
        self.run_arm("edc-module", env=self.env(EDC_RESULTS_FILE=str(results), FAKE_CLAUDE_MODE="blocked_api"))
        rows = self.rows(results)
        self.assertEqual([(r["run"], r["outcome"]) for r in rows], [("2", "exact"), ("1", "blocked")])

    def test_exception_writes_error_row(self):
        gt = self.gt_root / "proj" / "ground-truth.md"
        gt.write_text(gt.read_text().replace("- **affected_file:** a.c", "- **affected_file:** nope.c"))
        proc = self.run_arm("edc-module", check=False)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        row = self.record("edc-module")
        self.assertEqual((row["outcome"], row["entry"], row["kind"]), ("error", "CVE-2099-0001", "cve"))
        self.assertIn("exception=SnapshotError", row["notes"])
        self.assertEqual(self.claude_calls(), [])

    def test_foreign_out_dir_is_refused_before_snapshot(self):
        out = self.work / "clean" / "results" / "edc-module" / "CVE-2099-0001" / "run-1"
        out.mkdir(parents=True)
        (out / "mine.txt").write_text("keep")
        proc = self.run_arm("edc-module", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not created by the clean harness", proc.stderr)
        self.assertEqual((out / "mine.txt").read_text(), "keep")
        self.assertFalse((self.work / "clean" / "snap").exists())
        self.assertFalse((self.work / "clean" / "cache").exists())

    def test_legacy_results_path_is_refused(self):
        for name in ("results.tsv", "results-iter-7.tsv", "curl/results-baseline.tsv"):
            with self.subTest(name=name):
                proc = self.run_arm("edc-module", env=self.env(EDC_RESULTS_FILE=str(BENCHMARK_DIR / name)),
                                    check=False)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("legacy", proc.stderr)
                self.assertEqual(self.claude_calls(), [])


ISOLATION_FLAG = ["--setting-sources", "project,local"]


class SettingSourcesTests(ArmDispatchTests):
    """Every audited `claude -p` call loads only project/local settings; the judge is not audited."""

    def assert_isolated_calls(self, calls, expected):
        self.assertEqual(len(calls), expected, calls)
        for call in calls:
            self.assertEqual(call["argv"][:2], ISOLATION_FLAG, call["argv"])
            self.assertEqual(call["argv"].count("--setting-sources"), 1, call["argv"])
            # account-level claude.ai MCP connectors survive --setting-sources
            self.assertEqual(call["argv"].count("--strict-mcp-config"), 1, call["argv"])

    def test_flag_reaches_every_audited_call(self):
        # edc-security: the build call and the review call are both made by edc itself
        for arm, expected in (("edc-module", 1), ("edc-review-skill", 1), ("edc-security", 2), ("enemy-3", 1)):
            with self.subTest(arm=arm):
                (self.root / "claude-argv.jsonl").unlink(missing_ok=True)
                self.run_arm(arm)
                self.assert_isolated_calls(self.claude_calls(), expected)
                self.assertEqual(self.record(arm)["isolation"], "setting-sources=project,local;strict-mcp-config")

    def test_judge_call_is_not_isolated(self):
        self.run_arm("edc-module", judge=True)
        calls = self.claude_calls()
        judge = [c for c in calls if "--output-format" in c["argv"]
                 and c["argv"][c["argv"].index("--output-format") + 1] == "json"]
        self.assertEqual(len(judge), 1, calls)
        self.assertNotIn("--setting-sources", judge[0]["argv"])
        self.assertNotIn("--strict-mcp-config", judge[0]["argv"])
        self.assert_isolated_calls([c for c in calls if c not in judge], 1)
        self.assertEqual(self.record("edc-module")["verdict"], "exact")

    def wrapper(self, *args, **env):
        full = {**os.environ, "EDC_BENCH_REAL_CLAUDE": str(FAKES / "claude"),
                "FAKE_CLAUDE_ARGV_LOG": str(self.root / "claude-argv.jsonl"), **env}
        full.pop("EDC_BENCH_CALL_LOG_DIR", None)
        return subprocess.run([str(BENCHMARK_DIR / "clean-bin" / "claude"), *args], env=full,
                              capture_output=True, text=True, cwd=self.root)

    def test_wrapper_refuses_print_call_without_isolation_setting(self):
        env = {k: v for k, v in os.environ.items() if k != "EDC_BENCH_SETTING_SOURCES"}
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            proc = self.wrapper("-p", "hi")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.claude_calls(), [])

    def test_wrapper_refuses_caller_setting_sources(self):
        proc = self.wrapper("-p", "--setting-sources", "user", "hi", EDC_BENCH_SETTING_SOURCES="project,local")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--setting-sources", proc.stderr)
        self.assertEqual(self.claude_calls(), [])


class RepoPathTests(ArmDispatchTests):
    """No path into this repo (which holds benchmark/*/ground-truth.md) reaches an audited call."""

    def test_no_repo_path_reaches_audited_calls(self):
        repo = str(REPO_ROOT)
        encoded = repo.replace("/", "-")  # claude code's per-project dir form (~/.claude/projects, session tmp)
        decoys = {"PWD": str(BENCHMARK_DIR), "OLDPWD": repo, "DECOY_REPO_PATH": repo + "/x",
                  "DECOY_ENCODED_PATH": f"/private/tmp/claude-501/{encoded}/session",
                  "PATH": f"{BENCHMARK_DIR / 'clean-bin'}:{self.fakes}:{os.environ['PATH']}"}
        for arm in ("edc-module", "edc-review-skill", "edc-security", "enemy-3"):
            with self.subTest(arm=arm):
                (self.root / "claude-argv.jsonl").unlink(missing_ok=True)
                self.run_arm(arm, env=self.env(**decoys))
                calls = self.claude_calls()
                self.assertTrue(calls)
                for call in calls:
                    self.assertNotIn(repo, json.dumps(call["argv"]))
                    self.assertNotIn(repo, call["cwd"])
                    for key, value in call["env"].items():
                        self.assertNotIn(repo, value, key)
                        self.assertNotIn(encoded, value, key)
                    staged = Path(call["env"]["PATH"].split(os.pathsep)[0])
                    self.assertIn(self.work.resolve(), staged.parents)
                    self.assertEqual(staged.name, "clean-bin")
                    for name in ("claude", "agent"):
                        self.assertTrue(os.access(staged / name, os.X_OK), name)
                        self.assertEqual((staged / name).read_bytes(),
                                         (BENCHMARK_DIR / "clean-bin" / name).read_bytes())
                    # clean-bin/agent runs ../clean_stream_text.py
                    self.assertEqual((staged.parent / "clean_stream_text.py").read_bytes(),
                                     (BENCHMARK_DIR / "clean_stream_text.py").read_bytes())
        for log in ("enemy-argv.log", "edc-argv.log"):
            self.assertNotIn(repo, (self.root / log).read_text(), log)

    def test_other_edc_checkouts_leave_the_arm_env(self):
        home = str(Path.home())
        encoded = home.replace("/", "-") + "-Dev-edc"
        decoys = {"PATH": f"{home}/Dev/edc-other/bin:{home}/Dev/edc/bin:{self.fakes}:{os.environ['PATH']}",
                  "DECOY_OTHER_CHECKOUT": f"{home}/Dev/edc-other/x",
                  "DECOY_OTHER_ENCODED": f"/private/tmp/claude-501/{encoded}-other/session"}
        self.run_arm("edc-module", env=self.env(**decoys))
        (call,) = self.claude_calls()
        for key, value in call["env"].items():
            self.assertNotIn(f"{home}/Dev/edc", value, key)
            self.assertNotIn(encoded, value, key)

    def test_git_config_env_pairs_stay_consistent(self):
        # claude code's sandbox exports safe.directory entries for edc checkouts as GIT_CONFIG_KEY_n/VALUE_n;
        # dropping a VALUE_n alone leaves GIT_CONFIG_COUNT pointing at a missing pair and breaks git in the arm
        home = str(Path.home())
        decoys = {"GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": str(REPO_ROOT),
                  "GIT_CONFIG_KEY_1": "bench.keep", "GIT_CONFIG_VALUE_1": "yes",
                  "GIT_CONFIG_KEY_2": "safe.directory", "GIT_CONFIG_VALUE_2": f"{home}/Dev/edc/.git"}
        self.run_arm("edc-module", env=self.env(**decoys))
        (call,) = self.claude_calls()
        self.assertEqual(call["commits"], 1)
        git_env = {k: v for k, v in call["env"].items() if k.startswith("GIT_CONFIG_") and k != "GIT_CONFIG_PARAMETERS"}
        self.assertEqual({k: v for k, v in git_env.items() if k not in GIT_ENV},
                         {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "bench.keep", "GIT_CONFIG_VALUE_0": "yes"})

    def test_work_dir_inside_repo_is_refused(self):
        inside = REPO_ROOT / ".clean-test-work"
        self.addCleanup(shutil.rmtree, inside, True)  # in case the guard regresses
        proc = self.run_arm("edc-module", env=self.env(EDC_BENCH_WORKDIR=str(inside)), check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("inside the repo", proc.stderr)
        self.assertFalse(inside.exists())
        self.assertEqual(self.claude_calls(), [])


class ContaminationRecordTests(ArmDispatchTests):
    def test_clean_run_has_no_outside_access(self):
        self.run_arm("edc-module")
        row = self.record("edc-module")
        self.assertEqual((row["outcome"], row["outside_access"]), ("exact", "0"))

    def test_ground_truth_read_marks_run_contaminated(self):
        gt = str(Path.home() / "Dev" / "edc" / "benchmark" / "curl" / "ground-truth.md")
        for arm, calls in (("edc-module", 1), ("edc-security", 2)):  # edc-security: build + review logs
            with self.subTest(arm=arm):
                self.run_arm(arm, env=self.env(FAKE_CLAUDE_MODE="outside_read"))
                row = self.record(arm)
                self.assertEqual((row["outcome"], row["verdict"]), ("contaminated", "exact"))
                self.assertTrue(row["outside_access"].startswith(f"{calls}: "), row["outside_access"])
                self.assertIn(f"Read {gt}", row["outside_access"])


class HarnessPathTests(ArmDispatchTests):
    """041 review P1/P4: harness-owned paths neither leak to the agent nor go unflagged."""

    def test_audited_env_has_no_entry_arm_or_results_path(self):
        for arm, entry in (("edc-module", "CVE-2099-0001"), ("edc-security", "PLANT-proj-01"),
                           ("enemy-3", "CVE-2099-0001"), ("edc-review-skill", "PLANT-proj-01")):
            with self.subTest(arm=arm):
                (self.root / "claude-argv.jsonl").unlink(missing_ok=True)
                self.run_arm(arm, entry=entry)
                calls = self.claude_calls()
                self.assertTrue(calls)
                for call in calls:
                    for key, value in call["env"].items():
                        for leak in (entry, arm, "/results/"):
                            self.assertNotIn(leak, value, key)
                    io = Path(call["env"]["EDC_BENCH_CALL_LOG_DIR"])
                    self.assertEqual(io.parent.parent, self.work / "clean" / "io")
                    if "EDC_RESULT_FILE" in call["env"]:
                        self.assertEqual(Path(call["env"]["EDC_RESULT_FILE"]).parent, io.parent)
                out = self.work / "clean" / "results" / arm / entry / "run-1"
                row = self.record(arm, entry)
                self.assertEqual(row["model_calls"], "1")
                self.assertTrue(sorted((out / "calls").glob("call-*.jsonl")))
                if arm == "edc-security":
                    self.assertTrue((out / "calls-build").is_dir())
                    self.assertTrue((out / "edc-result.json").is_file())

    def test_run_dirs_are_removed_after_scoring(self):
        for arm in ("edc-module", "edc-review-skill"):
            with self.subTest(arm=arm):
                self.run_arm(arm)
                for kind in ("snap", "flat", "io"):
                    d = self.work / "clean" / kind
                    self.assertEqual(list(d.iterdir()) if d.exists() else [], [], kind)

    def test_harness_dirs_of_other_runs_are_contaminating(self):
        clean = self.work / "clean"
        results = self.root / "iso" / "arm.tsv"
        cases = {
            "results tree": str(clean / "results" / "enemy-3" / "CVE-2099-0001" / "run-1" / "issues.md"),
            "other snap": str(clean / "snap" / "0123456789abcdef" / ".audit" / "findings" / "nemesis-verified.md"),
            "other flat": str(clean / "flat" / "0123456789abcdef" / "edc-context" / "reports" / "issues.md"),
            "other io": str(clean / "io" / "0123456789abcdef" / "calls" / "call-1.jsonl"),
            "results-file dir": str(results.parent / "other-arm.tsv"),
        }
        for label, path in cases.items():
            with self.subTest(label):
                self.run_arm("edc-module", env=self.env(FAKE_CLAUDE_READ=path, EDC_RESULTS_FILE=str(results)))
                row = [r for r in csv.DictReader(results.open(newline=""), delimiter="\t")][-1]
                self.assertEqual(row["outcome"], "contaminated", row["outside_access"])
                self.assertIn(f"Read {path}", row["outside_access"])

    def test_own_run_dirs_are_not_outside(self):
        self.run_arm("edc-module", env=self.env(FAKE_CLAUDE_READ="$CWD/a.c,$CALLS/call-1.argv"))
        row = self.record("edc-module")
        self.assertEqual((row["outcome"], row["outside_access"]), ("exact", "0"))

    def test_results_dir_containing_work_dir_is_refused(self):
        for results in (self.work / "r.tsv", Path.home() / "r.tsv"):
            with self.subTest(results=str(results)):
                proc = self.run_arm("edc-module", env=self.env(EDC_RESULTS_FILE=str(results)), check=False)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("EDC_RESULTS_FILE", proc.stderr)
                self.assertFalse(results.exists())
                self.assertEqual(self.claude_calls(), [])


class AccessScanTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()
        self.work = self.root / "work"
        self.snap = self.work / "snap" / "s1"
        self.plugin = self.work / "plugin" / "p1" / "edc"
        self.flat = self.work / "flat" / "f1"
        for d in (self.snap, self.plugin, self.flat):
            d.mkdir(parents=True)
        self.home = str(Path.home())
        self.n = 0

    def tearDown(self):
        self._tmp.cleanup()

    def scan(self, *tool_uses, cwd=None, denied=()):
        self.n += 1
        log = self.root / f"call-{self.n}.jsonl"
        lines = [{"type": "system", "subtype": "init", "cwd": str(cwd or self.snap)}]
        for i, (name, inp) in enumerate(tool_uses):
            lines.append({"type": "assistant", "message": {"content": [
                {"type": "text", "text": "reading"}, {"type": "tool_use", "id": f"t{i}", "name": name, "input": inp}]}})
        lines.append({"type": "result", "permission_denials": [
            {"tool_name": tool_uses[i][0], "tool_use_id": f"t{i}", "tool_input": tool_uses[i][1]} for i in denied]})
        log.write_text("\n".join(json.dumps(line) for line in lines) + "\nnot json\n")
        return clean_access.scan_access([log], [self.snap, self.plugin, self.flat],
                                        forbidden=[self.work / "cache"])

    def test_inside_access_and_shell_noise_are_clean(self):
        alias = self.root / "alias"
        alias.symlink_to(self.work)  # /tmp vs /private/tmp
        outside, contaminated = self.scan(
            ("Read", {"file_path": "a.c"}),
            ("Read", {"file_path": str(self.snap / "lib" / "c.c")}),
            ("Grep", {"pattern": "x/y", "path": str(self.plugin / "skills")}),
            ("Glob", {"pattern": "**/*.c"}),
            ("Write", {"file_path": str(self.flat / "edc-context" / "reports" / "issues.md"), "content": "/etc/x"}),
            ("Bash", {"command": "grep -n 'copy(' a.c 2>/dev/null | head -5"}),
            ("Bash", {"command": "sed -n 's/a/b/p' lib/c.c && wc -l ./a.c"}),
            ("Bash", {"command": "curl -s https://example.invalid/x/y"}),
            ("Bash", {"command": f"ls {alias}/snap/s1"}),
            # awk/sed regexes and heredoc bodies are not paths (seen in real smoke transcripts)
            ("Bash", {"command": "awk '/Curl_x/{f=1} f&&/CONNECT_|ret/{print}' lib/socks.c; ls /\n"
                                 "cat > r.md <<'EOF'\n/* note */ rejects `/:#?!@{}[]`\nEOF"}),
            ("Skill", {"skill": "edc:edc-review"}),
        )
        self.assertEqual((outside, contaminated), ([], []))

    def test_outside_access_without_ground_truth_is_not_contaminated(self):
        outside, contaminated = self.scan(
            ("Read", {"file_path": "/etc/hosts"}),
            ("Bash", {"command": "ls ~/Dev"}),
            ("Bash", {"command": "cat " + "../" * 30 + "etc/passwd"}),
        )
        self.assertEqual(outside, [("Read", "/etc/hosts"), ("Bash", f"{self.home}/Dev"), ("Bash", "/etc/passwd")])
        self.assertEqual(contaminated, [])

    def test_ground_truth_access_is_contaminated(self):
        gt = f"{self.home}/Dev/edc/benchmark/curl/ground-truth.md"
        claude_project = self.home.replace("/", "-") + "-Dev-edc-enemy-port-p1"
        cases = {
            "read": ("Read", {"file_path": gt}),
            "grep path": ("Grep", {"pattern": "socks", "path": f"{self.home}/Dev/edc-enemy-port-p1"}),
            "glob pattern": ("Glob", {"pattern": "/somewhere/**/ground-truth.md"}),
            "plans": ("Bash", {"command": f"cd {self.home}/x && cat {self.home}/x/.plans/041-p1-report.md"}),
            "compound": ("Bash", {"command": f"ls ~/Dev; cat {gt} | head"}),
            "home var": ("Bash", {"command": "cat $HOME/Dev/edc-foo/README.md"}),
            "benchmark dir": ("Write", {"file_path": "/elsewhere/benchmark/x.md"}),
            "fix history": ("Read", {"file_path": str(self.work / "cache" / "curl.git" / "HEAD")}),
            "relative escape": ("Bash", {"command": "cat " + "../" * 30 + f"{self.home[1:]}/Dev/edc/README.md"}),
            "edc transcripts": ("Read", {"file_path": f"{self.home}/.claude/projects/{claude_project}/s.jsonl"}),
        }
        for label, use in cases.items():
            with self.subTest(label):
                outside, contaminated = self.scan(use)
                self.assertTrue(contaminated, outside)
                self.assertTrue(set(contaminated) <= set(outside))

    def test_denied_ground_truth_access_is_outside_not_contaminated(self):
        # the enemy shim's permission layer denies outside paths; nothing was exposed
        gt = f"{self.home}/Dev/edc/benchmark/curl/ground-truth.md"
        outside, contaminated = self.scan(("Bash", {"command": f"cat {gt}"}), ("Read", {"file_path": gt}),
                                          denied=[0, 1])
        self.assertEqual((outside, contaminated), ([("Bash", gt), ("Read", gt)], []))

    def test_ls_dev_alone_is_outside_not_contaminated(self):
        outside, contaminated = self.scan(("Bash", {"command": "ls ~/Dev"}))
        self.assertEqual((outside, contaminated), ([("Bash", f"{self.home}/Dev")], []))

    def test_summary(self):
        self.assertEqual(clean_access.summarize([], []), "0")
        out = [("Read", "/a"), ("Bash", "/b"), ("Read", "/c"), ("Read", "/gt"), ("Bash", "/e")]
        self.assertEqual(clean_access.summarize(out, [("Read", "/gt")]),
                         "5: Read /gt, Read /a, Bash /b (+2 more)")


# ArmDispatchTests' tests should not run twice through the subclasses.
for _cls in (ResultsIsolationTests, SettingSourcesTests, RepoPathTests, ContaminationRecordTests, HarnessPathTests):
    for _name in [n for n in dir(ArmDispatchTests) if n.startswith("test_")]:
        if _name not in _cls.__dict__:
            setattr(_cls, _name, None)


if __name__ == "__main__":
    unittest.main()
