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
    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("EDC_", "FAKE_"))}
        env.update(GIT_ENV)
        env["PATH"] = f"{FAKES}:{env['PATH']}"
        env["EDC_BENCH_WORKDIR"] = str(self.work)
        env["FAKE_CLAUDE_ARGV_LOG"] = str(self.root / "claude-argv.jsonl")
        env["FAKE_ENEMY_ARGV_LOG"] = str(self.root / "enemy-argv.log")
        env["FAKE_EDC_ARGV_LOG"] = str(self.root / "edc-argv.log")
        env["ENEMY_BIN"] = str(FAKES / "enemy")
        env["EDC_BENCH_EDC_BIN"] = str(FAKES / "edc")
        env.update(extra)
        return env

    def run_arm(self, arm, entry="CVE-2099-0001", env=None, check=True, judge=False):
        cmd = ["bash", str(CLEAN_SH), "--arm", arm, "--gt-root", str(self.gt_root), "--project", "proj",
               "--entry", entry, *([] if judge else ["--skip-judge"])]
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
        self.assertEqual(len(git(call["cwd"], "rev-list", "--all").stdout.split()), 1)
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
        flat = sorted(p.name for p in Path(call["cwd"]).iterdir() if p.name != "edc-context")
        self.assertEqual(flat, ["a.c"])
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
        self.assertEqual(cargv[cargv.index("--tools") + 1], "Read,Write,Edit,Bash")
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
        self.assertIn("/* planted */", (Path(call["cwd"]) / "b.c").read_text())
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
        self.run_arm("edc-module", env=self.env(EDC_RESULTS_FILE=str(results)))
        with results.open(newline="") as fh:
            rows = list(csv.DictReader(fh, delimiter="\t"))
        self.assertEqual(len(rows), 2)
        self.assertEqual(hashlib.sha256(legacy.read_bytes()).hexdigest(), before)

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


# ArmDispatchTests' tests should not run twice through the subclasses.
for _cls in (ResultsIsolationTests, SettingSourcesTests):
    for _name in [n for n in dir(ArmDispatchTests) if n.startswith("test_")]:
        if _name not in _cls.__dict__:
            setattr(_cls, _name, None)


if __name__ == "__main__":
    unittest.main()
