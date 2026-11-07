#!/usr/bin/env python3
"""Clean benchmark harness (plan 041 p1).

One run = one arm x one ground-truth entry x one repetition:
  1. build an isolated one-commit snapshot of the vulnerable tree
     (clean_snapshot.py; the audited agent never sees later commits);
  2. run the arm against it with a staged copy of clean-bin/ first on PATH
     (call logging and, for enemy, the `agent` shim); no path into this repo
     reaches the arm's PATH, argv, cwd or env. What the arm writes through
     env paths (call logs, EDC_RESULT_FILE) or its stdout/stderr goes to an opaque
     <work>/io/<id>/ dir, so the env names neither the entry, the arm nor
     the results tree. The harness, an ancestor of the agent, re-execs
     itself (reexec) so its own argv, env and cwd carry none of its inputs;
  3. score the report (judge_report: score.py's judge without its keyword
     gate; plants are judged at file:line), detect blocked runs from the
     structured call logs (clean_blocked.py) and scan them for tool access
     outside the run's roots and for answer markers in tool results
     (clean_access.py; `contaminated` outcome; the
     results tree, the results-file dir and other runs' snap/flat/io dirs
     are forbidden), then move the io dir into the out dir and delete the
     snapshot and flat copy;
  4. write one row to an isolated TSV ($EDC_RESULTS_FILE, else
     <out-dir>/record.tsv), replacing an earlier row of the same run_id; an
     exception after the entry is resolved still writes an `error` row.
     Legacy benchmark/results*.tsv paths are refused.

Usage: benchmark/clean.sh --arm <arm> --project <p> --entry <id> [options]
"""

import argparse
import csv
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

BENCHMARK_DIR = Path(__file__).resolve().parent
REPO_ROOT = BENCHMARK_DIR.parent
# What the arm executes from this repo (clean-bin/), staged under the work
# dir by stage_bin. clean-bin/agent runs ../clean_stream_text.py.
STAGED_BIN_FILES = ("clean-bin/claude", "clean-bin/agent", "clean_stream_text.py")
PLUGIN_DIR = REPO_ROOT / "plugins" / "edc"
DEFAULT_MODEL = "claude-opus-5-5"
DEFAULT_GT_ROOT = BENCHMARK_DIR / "clean"
OUT_MARKER = ".clean-harness-run"

sys.path.insert(0, str(BENCHMARK_DIR))
import clean_gt  # noqa: E402
import clean_snapshot  # noqa: E402
from clean_access import scan_access, summarize  # noqa: E402
from clean_blocked import detect_blocked, result_text  # noqa: E402

ARMS = ("edc-module", "edc-review-skill", "edc-security", "enemy-3", "edc-deep")
# Per-phase wall-clock caps (seconds). edc-review-skill keeps autoresearch.sh's 600s.
DEFAULT_TIMEOUTS = {"edc-module": 1800, "edc-review-skill": 600, "edc-security": 3600, "enemy-3": 7200}
ENEMY_MAX_PASSES = "3"
# Web tools are disallowed in every arm the harness controls; the legacy
# allowed-tool sets are otherwise unchanged.
DISALLOWED_TOOLS = "WebFetch WebSearch"
# Setting sources for every audited `claude -p` call. clean-bin/claude
# injects them together with --strict-mcp-config; both are recorded as
# `isolation`. The judge (score.py) runs outside the wrapper, unaffected.
SETTING_SOURCES = "project,local"
ISOLATION = f"setting-sources={SETTING_SOURCES};strict-mcp-config"

RECORD_FIELDS = [
    "timestamp", "run_id", "arm", "project", "entry", "kind", "run", "model", "outcome", "verdict",
    "confidence", "duration_s", "build_duration_s", "model_calls", "build_model_calls", "passes_run",
    "loop_end", "arm_exit", "blocked", "blocked_signal", "cve_ids_named", "build_scope",
    "isolation", "outside_access", "snapshot_commit", "report", "out_dir", "notes",
]

# --- prompts (verbatim from the legacy runners) -------------------------------

# benchmark/run.sh (the `\`-newline continuations there join with a space).
EDC_MODULE_PROMPT = """Apply the EDC module-context methodology on ONLY these files: {file_list}

This is a security-focused analysis. Perform ultra-granular line-by-line analysis \
looking for all vulnerabilities including memory safety issues, state machine logic \
errors, flag/boolean corruption, protocol injection, and data flow problems.

Write the complete scoped analysis to edc-context/modules/security-benchmark.md

Then create edc-context/reports/issues.md listing ALL security issues you find, with:
- issue title
- severity (critical/high/medium/low)
- category (buffer overflow, use-after-free, logic error, etc.)
- affected file:line
- description of the bug
- evidence (the specific code pattern)

Be thorough. Do not skip any function."""

# benchmark/autoresearch.sh run_cve(); no pre-built context in this arm.
REVIEW_SKILL_CTX_NOTE = "No pre-built context available — analyze from source only."
REVIEW_SKILL_PROMPT = """{ctx_note}

Perform a full security review of these source files:{file_list}

Use the edc-review methodology. This is a FULL-FILE review — analyze the entire source for vulnerabilities.
Ignore any diff/PR-specific instructions in the skill.

Write ALL findings to edc-context/reports/issues.md with:
- issue title
- severity (critical/high/medium/low)
- category (buffer overflow, use-after-free, logic error, etc.)
- affected file:line
- description of the bug
- evidence (the specific code pattern)"""

REVIEW_SKILL_REPORTS = ("edc-context/reports/issues.md", "edc-context/issues.md", "issues.md")
PASS_FILE_RE = re.compile(r"^(?:feynman|state)-pass(\d+)\.md$")
CVE_ID_RE = re.compile(r"CVE-\d{4}-\d{4,}")


class HarnessError(RuntimeError):
    pass


# --- helpers ------------------------------------------------------------------

def opaque_id(*parts) -> str:
    """Directory name the audited agent sees; must not reveal the entry."""
    return hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()[:16]


def check_results_path(path: Path) -> Path:
    resolved = Path(path).resolve()
    if resolved.name.startswith("results") and BENCHMARK_DIR in resolved.parents:
        raise HarnessError(f"refusing to write legacy results file {resolved}; point EDC_RESULTS_FILE elsewhere")
    return resolved


def _glob_escape(path: str) -> str:
    # edc_path_matches_ignore treats patterns as bash globs.
    return re.sub(r"([*?\[\]\\])", r"\\\1", path)


def ignore_complement(tracked, keep) -> list[str]:
    """edc --ignore patterns that leave exactly `keep` out of `tracked`.

    At every directory on the path to a kept file, ignore each sibling entry
    (`dir/` prefix for directories, the exact path for files)."""
    keep = set(keep)
    kept_dirs = {""}
    for path in keep:
        parts = path.split("/")
        kept_dirs.update("/".join(parts[:i]) for i in range(1, len(parts)))
    patterns = set()
    for path in tracked:
        parts = path.split("/")
        for depth in range(1, len(parts) + 1):
            parent, entry = "/".join(parts[:depth - 1]), "/".join(parts[:depth])
            if parent not in kept_dirs:
                break
            is_dir = depth < len(parts)
            if is_dir and entry in kept_dirs:
                continue
            if not is_dir and entry in keep:
                break
            patterns.add((entry.count("/"), _glob_escape(entry) + ("/" if is_dir else "")))
            break
    return [p for _, p in sorted(patterns)]


def _stage(work: Path, kind: str, leaf: str, src_root: Path, files, copy) -> Path:
    """Content-addressed copy under <work>/<kind>/<digest>/<leaf>; copy(dest)
    fills a fresh directory. Arms must not get paths into this repo: they
    lead to benchmark/*/ground-truth.md."""
    digest = hashlib.sha256()
    for path in sorted(files):
        digest.update(str(path.relative_to(src_root)).encode() + b"\0" + path.read_bytes() + b"\0")
    dest = work / kind / digest.hexdigest()[:16] / leaf
    if not dest.is_dir():
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.parent / f".tmp-{os.getpid()}"
        copy(tmp)
        try:
            os.replace(tmp, dest)
        except OSError:  # a concurrent run staged the same content first
            shutil.rmtree(tmp)
    return dest


def stage_plugin(work: Path) -> Path:
    """plugins/edc for --plugin-dir (audited agents follow that path)."""
    files = [p for p in PLUGIN_DIR.rglob("*") if p.is_file()]
    return _stage(work, "plugin", "edc", PLUGIN_DIR, files,
                  lambda dest: shutil.copytree(PLUGIN_DIR, dest, symlinks=True))


def stage_bin(work: Path) -> Path:
    """clean-bin/ (+ clean_stream_text.py) at the same relative layout; returns
    the staged clean-bin dir that goes first on the arm's PATH."""
    files = [BENCHMARK_DIR / rel for rel in STAGED_BIN_FILES]

    def copy(dest: Path):
        for rel in STAGED_BIN_FILES:
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(BENCHMARK_DIR / rel, dest / rel)

    return _stage(work, "bin", "harness", BENCHMARK_DIR, files, copy) / "clean-bin"


def run_logged(cmd, cwd, env, timeout, stdout_path, stderr_path) -> tuple[int, float, bool]:
    """Run cmd in its own process group; returns (exit, seconds, timed_out).
    On timeout: SIGTERM the group, SIGKILL 5s later (autoresearch.sh's watchdog)."""
    start = time.monotonic()
    with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                start_new_session=True)
        timed_out = False
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                rc = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                rc = proc.wait()
    return rc, time.monotonic() - start, timed_out


def call_logs(log_dir: Path) -> list[Path]:
    return sorted(log_dir.glob("call-*.jsonl")) if log_dir.is_dir() else []


def call_count(log_dir: Path) -> int:
    return len(list(log_dir.glob("call-*.argv"))) if log_dir.is_dir() else 0


def read_text(path) -> str:
    try:
        return Path(path).read_text(errors="replace")
    except OSError:
        return ""


def save_report(src: Path, out: Path, name=None) -> Path:
    dest = out / (name or src.name)
    shutil.copyfile(src, dest)
    return dest


# --- arms ---------------------------------------------------------------------

class Run:
    def __init__(self, args, entry, model, snap, out, work, env, bin_dir, io):
        self.args, self.entry, self.model = args, entry, model
        self.snap, self.out, self.work, self.env, self.bin = snap, out, work, env, bin_dir
        # paths the arm can learn (env, its stdio fds via lsof) live here: opaque, moved into out after the run
        self.io = io
        self.files = entry["affected_files"]
        self.calls = io / "calls"
        self.plugin = stage_plugin(work)
        self.scratch = []  # run-owned dirs the agent may use besides snap and plugin
        self.result = {"report_text": "", "report": "", "arm_exit": "", "ok": False, "timed_out": False,
                       "duration": 0.0, "build_duration": None, "build_calls": None, "passes_run": "",
                       "loop_end": "", "call_dirs": [self.calls], "text_logs": [], "notes": []}

    def timeout(self, arm):
        return self.args.timeout or DEFAULT_TIMEOUTS[arm]

    def arm_env(self, call_dir: Path, **extra):
        env = dict(self.env)
        env["EDC_BENCH_CALL_LOG_DIR"] = str(call_dir)
        env.update(extra)
        return env

    def single_call(self, arm, cmd, cwd, report_candidates):
        r = self.result
        stdout, stderr = self.io / "arm-stdout.jsonl", self.io / "arm-stderr.log"
        rc, r["duration"], r["timed_out"] = run_logged(cmd, cwd, self.arm_env(self.calls), self.timeout(arm),
                                                       stdout, stderr)
        r["arm_exit"], r["text_logs"] = rc, [stderr]
        for rel in report_candidates:
            path = cwd / rel
            if path.is_file():
                r["report"] = str(save_report(path, self.out))
                r["report_text"], r["ok"] = read_text(path), True
                return
        # legacy fallback: the result text of the stream is the report
        text = result_text(stdout)
        if text:
            dest = self.out / "result-text.md"
            dest.write_text(text)
            r["report"], r["report_text"] = str(dest), text
        r["ok"] = rc == 0 and bool(text) and not r["timed_out"]

    def edc_module(self):
        file_list = "".join(f" {f}" for f in self.files)
        cmd = [str(self.bin / "claude"), "-p", EDC_MODULE_PROMPT.format(file_list=file_list),
               "--plugin-dir", str(self.plugin),
               "--allowedTools", "Read Grep Glob Write Bash Skill",
               "--disallowedTools", DISALLOWED_TOOLS,
               "--max-turns", "50", "--output-format", "stream-json", "--verbose",
               "--model", self.model, "--dangerously-skip-permissions"]
        self.single_call("edc-module", cmd, self.snap, ["edc-context/reports/issues.md"])

    def edc_review_skill(self):
        # autoresearch.sh reviews a flat dir holding only the affected files.
        flat = self.work / "flat" / opaque_id("flat", self.args.arm, self.args.project, self.entry["id"],
                                              self.args.run)
        if flat.exists():
            shutil.rmtree(flat)
        flat.mkdir(parents=True)
        self.scratch.append(flat)
        names = [Path(f).name for f in self.files]
        if len(set(names)) != len(names):
            raise HarnessError(f"affected files share a basename; flat copy would collide: {self.files}")
        for f in self.files:
            shutil.copyfile(self.snap / f, flat / Path(f).name)
        file_list = "".join(f" {n}" for n in names)
        prompt = REVIEW_SKILL_PROMPT.format(ctx_note=REVIEW_SKILL_CTX_NOTE, file_list=file_list)
        cmd = [str(self.bin / "claude"), "-p", prompt,
               "--plugin-dir", str(self.plugin),
               "--allowedTools", "Read Glob Grep Write Skill",
               "--disallowedTools", DISALLOWED_TOOLS,
               "--max-turns", "20", "--model", self.model,
               "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions"]
        self.single_call("edc-review-skill", cmd, flat, REVIEW_SKILL_REPORTS)

    def edc_security(self):
        r = self.result
        edc = os.environ.get("EDC_BENCH_EDC_BIN") or str(self.plugin / "scripts" / "edc")
        tracked = subprocess.run(["git", "ls-files"], cwd=self.snap, capture_output=True, text=True,
                                 check=True).stdout.splitlines()
        ignores = []
        for pattern in ignore_complement(tracked, self.files):
            ignores += ["--ignore", pattern]
        build_calls = self.io / "calls-build"
        r["call_dirs"] = [build_calls, self.calls]
        build_cmd = [edc, "--model", self.model, "build", "--agent", "claude", str(self.snap)]
        if self.args.build_scope == "affected":
            build_cmd += ignores
        rc, r["build_duration"], timed_out = run_logged(
            build_cmd, self.snap, self.arm_env(build_calls), self.timeout("edc-security"),
            self.io / "build-stdout.log", self.io / "build-stderr.log")
        r["build_calls"] = call_count(build_calls)
        r["text_logs"] = [self.io / "build-stdout.log", self.io / "build-stderr.log"]
        if rc != 0 or timed_out:
            r["arm_exit"], r["timed_out"] = f"build:{rc}", timed_out
            r["notes"].append("edc build failed; review skipped")
            return
        result_file = self.io / "edc-result.json"
        review_cmd = [edc, "--model", self.model, "security-review", "--agent", "claude", "--full",
                      "--no-context-refresh", *ignores]
        rc, r["duration"], r["timed_out"] = run_logged(
            review_cmd, self.snap, self.arm_env(self.calls, EDC_RESULT_FILE=str(result_file)),
            self.timeout("edc-security"), self.io / "review-stdout.log", self.io / "review-stderr.log")
        r["arm_exit"] = rc
        r["text_logs"] += [self.io / "review-stdout.log", self.io / "review-stderr.log"]
        report = None
        try:
            final = json.loads(result_file.read_text()).get("finalReview")
            if final and (self.snap / final).is_file():
                report = self.snap / final
        except (OSError, ValueError):
            r["notes"].append("edc result json missing or unreadable")
        if report is None:
            found = sorted(self.snap.glob("review-*.md"))
            report = found[0] if found else None
        if report is not None:
            r["report"] = str(save_report(report, self.out))
            r["report_text"] = read_text(report)
        r["ok"] = rc == 0 and report is not None and not r["timed_out"]

    def enemy_3(self):
        r = self.result
        enemy = enemy_bin()
        cmd = [enemy, "audit", self.files[0], "--repo", str(self.snap), "--max-passes", ENEMY_MAX_PASSES]
        if len(self.files) > 1:
            # enemy audit takes a single positional target.
            cmd += ["--instructions",
                    "Also audit these files as part of the primary scope: " + ", ".join(self.files[1:])]
        stdout, stderr = self.io / "enemy-stdout.log", self.io / "enemy-stderr.log"
        rc, r["duration"], r["timed_out"] = run_logged(cmd, self.snap, self.arm_env(self.calls),
                                                       self.timeout("enemy-3"), stdout, stderr)
        r["arm_exit"], r["text_logs"] = rc, [stdout, stderr]
        r["loop_end"] = {0: "converged", 4: "capped"}.get(rc, "incomplete")
        findings = self.snap / ".audit" / "findings"
        saved = self.out / "findings"
        passes = []
        if findings.is_dir():
            shutil.copytree(findings, saved, dirs_exist_ok=True)
            passes = sorted((p for p in saved.iterdir() if PASS_FILE_RE.match(p.name)),
                            key=lambda p: int(PASS_FILE_RE.match(p.name).group(1)))
        r["passes_run"] = len(passes)
        for name in ("nemesis-verified.md", "nemesis-raw.md"):
            if (saved / name).is_file():
                r["report"], r["report_text"] = str(saved / name), read_text(saved / name)
                break
        else:
            if passes:
                # blocked/incomplete runs still score what the completed passes wrote
                combined = self.out / "passes-combined.md"
                combined.write_text("\n\n".join(read_text(p) for p in passes))
                r["report"], r["report_text"] = str(combined), read_text(combined)
                r["notes"].append("scored pass artifacts (no final report)")
        r["ok"] = rc in (0, 4) and not r["timed_out"]


def enemy_bin() -> str:
    enemy = os.environ.get("ENEMY_BIN") or shutil.which("enemy")
    if not enemy:
        raise HarnessError("enemy not found: set ENEMY_BIN or put enemy on PATH")
    return enemy


def preflight_enemy() -> None:
    enemy = enemy_bin()
    proc = subprocess.run([enemy, "audit", "--help"], capture_output=True, text=True)
    if "--max-passes" not in proc.stdout + proc.stderr:
        raise HarnessError(f"{enemy} has no `audit --max-passes`; build enemy with --max-passes support "
                           "and point ENEMY_BIN at it")


# --- scoring ------------------------------------------------------------------

def judge_report(report_text: str, entry: dict, skip_judge: bool) -> tuple[str, float, str]:
    """score.score_cve for the clean harness: every non-empty report goes to
    the judge. score_cve's keyword gate (score.py KEYWORD_THRESHOLD) drops
    correct findings whose category has no CATEGORY_KEYWORDS entry (most p2
    entries), so the keyword score is only recorded in notes. --skip-judge
    keeps score_cve's keyword-only scoring. A plant's `line` goes to the judge
    with the bug pattern (not into affected files: the judge's LOCATE step
    searches the report for those names)."""
    import score  # judge uses the harness env (real claude, not the call logger)
    files = ", ".join(entry["affected_files"])
    bug_pattern, category = entry.get("bug_pattern", ""), entry.get("category", "")
    if not report_text.strip():
        return "missed", 0.0, "no issues file"
    if skip_judge:
        return score.score_cve(report_text, entry["id"], bug_pattern, category, entry.get("description", ""),
                               files, skip_judge=True)
    _, kw_notes = score.keyword_score(report_text, bug_pattern, category, files)
    judged_pattern = bug_pattern
    if entry.get("line"):
        judged_pattern += (f" (planted at {entry['affected_files'][0]}:{entry['line']}; "
                           "line numbers refer to the reviewed tree)")
    verdict, confidence, explanation = score.llm_judge(report_text, entry["id"], judged_pattern, category,
                                                       entry.get("description", ""), files)
    if verdict == "judge_error":  # same notes shape as score_cve
        return "judge_error", 0.0, f"judge_error({explanation}); keywords({kw_notes})"
    return verdict, confidence, f"judge: {explanation}; keywords({kw_notes})"


# --- record -------------------------------------------------------------------

def check_record_header(path: Path) -> None:
    if path.exists() and path.stat().st_size > 0:
        with path.open(newline="") as fh:
            header = fh.readline().rstrip("\r\n").split("\t")
        if header != RECORD_FIELDS:
            raise HarnessError(f"{path} has a different header; use a fresh EDC_RESULTS_FILE")


def write_record(path: Path, row: dict) -> None:
    """Write row, replacing any row with the same run_id (a rerun of one run).
    Concurrent runs may share the file: read-modify-replace under a lock."""
    path.parent.mkdir(parents=True, exist_ok=True)
    clean = {k: re.sub(r"[\t\r\n]+", " ", str(row.get(k, ""))) for k in RECORD_FIELDS}
    with open(path.parent / f".{path.name}.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        check_record_header(path)
        rows = []
        if path.exists() and path.stat().st_size > 0:
            with path.open(newline="") as fh:
                rows = [r for r in csv.DictReader(fh, delimiter="\t") if r.get("run_id") != clean["run_id"]]
        tmp = path.parent / f".{path.name}.tmp-{os.getpid()}"
        with tmp.open("w", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=RECORD_FIELDS, delimiter="\t", lineterminator="\n")
            writer.writeheader()
            writer.writerows([*rows, clean])
        os.replace(tmp, path)


def prepare_dir(path: Path) -> None:
    """(Re)create a harness-owned directory; never delete one we did not make."""
    if path.exists():
        if not (path / OUT_MARKER).exists():
            raise HarnessError(f"{path} exists and was not created by the clean harness")
        shutil.rmtree(path)
    path.mkdir(parents=True)
    (path / OUT_MARKER).write_text("")


# --- main ---------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(prog="clean.sh", description=__doc__.split("\n\n")[0])
    p.add_argument("--arm", required=True, choices=ARMS)
    p.add_argument("--project", required=True)
    p.add_argument("--entry", required=True)
    p.add_argument("--gt-root", type=Path, default=DEFAULT_GT_ROOT)
    p.add_argument("--run", type=int, default=1)
    p.add_argument("--work-dir", type=Path)
    p.add_argument("--out-dir", type=Path)
    p.add_argument("--skip-judge", action="store_true", help="keyword-only scoring (no judge call)")
    p.add_argument("--timeout", type=int, help="per-phase wall-clock cap in seconds")
    p.add_argument("--build-scope", choices=("full", "affected"), default="full",
                   help="edc-security: build context for the whole snapshot or only the affected files")
    return p.parse_args(argv)


def in_repo(path) -> bool:
    resolved = Path(path).resolve()
    return resolved == REPO_ROOT or REPO_ROOT in resolved.parents


GIT_CONFIG_PAIR_RE = re.compile(r"^GIT_CONFIG_(?:KEY|VALUE)_\d+$")


def _keep_git_config_pairs(env: dict, dirty) -> None:
    """GIT_CONFIG_COUNT/KEY_n/VALUE_n (claude code's sandbox exports
    safe.directory entries this way) must stay consistent: dropping one
    VALUE_n alone breaks every git call. Drop dirty pairs and renumber."""
    try:
        count = int(os.environ.get("GIT_CONFIG_COUNT", "0"))
    except ValueError:
        count = 0
    pairs = [(os.environ.get(f"GIT_CONFIG_KEY_{i}"), os.environ.get(f"GIT_CONFIG_VALUE_{i}", "")) for i in range(count)]
    for key in [k for k in env if k == "GIT_CONFIG_COUNT" or GIT_CONFIG_PAIR_RE.match(k)]:
        del env[key]
    kept = [(k, v) for k, v in pairs if k is not None and not dirty(k) and not dirty(v)]
    if kept:
        env["GIT_CONFIG_COUNT"] = str(len(kept))
        for i, (k, v) in enumerate(kept):
            env[f"GIT_CONFIG_KEY_{i}"], env[f"GIT_CONFIG_VALUE_{i}"] = k, v


def child_env(model: str, bin_dir: Path) -> dict:
    """The arm's env: no value mentions this repo or any other edc checkout
    (~/Dev/edc*; PWD/OLDPWD/_ of the shell that started clean.sh would), those
    dirs leave PATH, the staged bin leads."""
    repo_forms = {str(REPO_ROOT), os.path.dirname(os.path.dirname(os.path.abspath(__file__))),  # resolved, as invoked
                  os.path.join(str(Path.home()), "Dev", "edc")}  # prefix of every ~/Dev/edc* checkout
    repo_forms |= {form.replace(os.sep, "-") for form in repo_forms}  # claude code per-project dirs (session tmp)
    def dirty(value):
        return any(form in value for form in repo_forms)

    path_dirs = [d for d in os.environ.get("PATH", "").split(os.pathsep) if d and not in_repo(d) and not dirty(d)]
    env = {k: v for k, v in os.environ.items() if not dirty(v)}
    _keep_git_config_pairs(env, dirty)
    for key in ("EDC_RESULTS_FILE", "ENEMY_BIN", "EDC_BENCH_EDC_BIN", "PWD", "OLDPWD"):
        env.pop(key, None)  # harness inputs, or stale for the arm's cwd
    real = shutil.which("claude", path=os.pathsep.join(path_dirs))
    if not real:
        raise HarnessError("claude not found on PATH (outside this repo)")
    env["PATH"] = os.pathsep.join([str(bin_dir), *path_dirs])
    env["EDC_BENCH_REAL_CLAUDE"] = real
    env["EDC_BENCH_SETTING_SOURCES"] = SETTING_SOURCES
    for key in ("EDC_BENCH_MODEL", "EDC_BUILD_MODEL", "EDC_REVIEW_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"):
        env[key] = model
    return env


def run(args) -> dict:
    model = os.environ.get("EDC_BENCH_MODEL") or DEFAULT_MODEL
    work = (args.work_dir or Path(os.environ.get("EDC_BENCH_WORKDIR", "/private/tmp/edc-bench")) / "clean").resolve()
    out = (args.out_dir or work / "results" / args.arm / args.entry / f"run-{args.run}").resolve()
    results_path = check_results_path(Path(os.environ["EDC_RESULTS_FILE"]) if os.environ.get("EDC_RESULTS_FILE")
                                      else out / "record.tsv")
    for path in (work, out):
        if in_repo(path):
            raise HarnessError(f"{path} is inside the repo; audited agents must not get paths into it")
    for root, label in ((out, "--out-dir"), (results_path.parent, "EDC_RESULTS_FILE dir")):
        # audited agents must not read these (forbidden roots); one that contains the work or home dir
        # would turn every snapshot or home read into contamination
        for contained, what in ((work, "the work dir"), (Path.home().resolve(), "the home dir")):
            if root == contained or root in contained.parents:
                raise HarnessError(f"{label} {root} contains {what}; use a dedicated directory "
                                   "(EDC_RESULTS_FILE / --out-dir are forbidden to audited agents)")
    check_record_header(results_path)
    if args.arm == "enemy-3":
        preflight_enemy()
    bin_dir = stage_bin(work)
    env = child_env(model, bin_dir)

    project_dir = args.gt_root.resolve() / args.project
    entry = clean_gt.find_entry(project_dir / "ground-truth.md", args.entry)
    if not entry["affected_files"]:
        raise HarnessError(f"{args.entry} has no affected_file")
    prepare_dir(out)  # refuses a foreign out dir before any snapshot/cache work
    row = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_id": f"{args.arm}:{args.project}:{entry['id']}:{args.run}",
        "arm": args.arm, "project": args.project, "entry": entry["id"], "kind": entry["kind"],
        "run": args.run, "model": model, "outcome": "error",
        "build_scope": args.build_scope if args.arm == "edc-security" else "",
        "isolation": ISOLATION, "out_dir": str(out),
    }
    try:
        row.update(run_entry(args, entry, model, work, out, env, bin_dir, project_dir, results_path))
    except Exception as exc:
        row["notes"] = f"exception={type(exc).__name__}: {exc}"
        write_record(results_path, row)
        raise
    write_record(results_path, row)
    return row


def run_entry(args, entry, model, work, out, env, bin_dir, project_dir, results_path) -> dict:
    """Snapshot, arm, detection and scoring for one run; returns its record
    fields. The snapshot and flat copy are deleted and the io dir moved into
    out afterwards, also when the run fails."""
    snap = work / "snap" / opaque_id(args.arm, args.project, args.entry, args.run)
    io = work / "io" / opaque_id("io", args.arm, args.project, args.entry, args.run)
    r = None
    try:
        cache = clean_snapshot.ensure_cache(clean_gt.read_repo_url(project_dir),
                                            work / "cache" / f"{args.project}.git")
        for d in (snap, io):
            if d.exists():
                shutil.rmtree(d)
        io.mkdir(parents=True)
        snapshot_commit = clean_snapshot.make_snapshot(cache, entry, project_dir, snap)
        r = Run(args, entry, model, snap, out, work, env, bin_dir, io)
        getattr(r, args.arm.replace("-", "_"))()
        return score_run(args, entry, r, results_path, snapshot_commit)
    finally:
        for d in [snap, *(r.scratch if r else [])]:
            shutil.rmtree(d, ignore_errors=True)
        if io.is_dir():
            for child in io.iterdir():
                shutil.move(str(child), str(out / child.name))
            io.rmdir()


def answer_markers(project: str, entry: dict) -> tuple:
    """Strings a tool result shows only when it exposes ground truth: the gt
    entry format, gt paths, plant ids of the project, this entry's id."""
    return ("**bug_pattern:**", f"PLANT-{project}-", "ground-truth.md", "/benchmark/clean/", entry["id"])


def score_run(args, entry, r, results_path, snapshot_commit) -> dict:
    res, work = r.result, r.work
    logs = [p for d in res["call_dirs"] for p in call_logs(d)]
    blocked, signal_ = detect_blocked(logs, res["text_logs"])
    # other runs' dirs (and earlier results) can hold this entry's findings; the current run's are allowed
    forbidden = [work / "cache", work / "results", work / "snap", work / "flat", work / "io", r.out,
                 results_path.parent]
    outside, contaminated = scan_access(logs, [r.snap, r.plugin, *r.scratch, r.io], forbidden=forbidden,
                                        markers=answer_markers(args.project, entry))
    verdict, confidence, notes = judge_report(res["report_text"], entry, args.skip_judge)
    if contaminated:  # the agent may have seen the answer; p3 excludes these from recall
        outcome = "contaminated"
    elif blocked:
        outcome = "blocked"
    elif res["timed_out"]:
        outcome = "timeout"
    elif not res["ok"]:
        outcome = "error"
    else:
        outcome = verdict
    named = sorted(set(CVE_ID_RE.findall(res["report_text"])))
    return {
        "outcome": outcome, "verdict": verdict,
        "confidence": f"{confidence:.2f}", "duration_s": f"{res['duration']:.1f}",
        "build_duration_s": "" if res["build_duration"] is None else f"{res['build_duration']:.1f}",
        "model_calls": call_count(r.calls),
        "build_model_calls": "" if res["build_calls"] is None else res["build_calls"],
        "passes_run": res["passes_run"], "loop_end": res["loop_end"], "arm_exit": res["arm_exit"],
        "blocked": "yes" if blocked else "no", "blocked_signal": signal_,
        "cve_ids_named": ",".join(named),
        "outside_access": summarize(outside, contaminated),
        "snapshot_commit": snapshot_commit, "report": res["report"],
        "notes": "; ".join([*res["notes"], notes]),
    }


def main(argv=None) -> int:
    return run_cli(parse_args(sys.argv[1:] if argv is None else argv))


def run_cli(args) -> int:
    if args.arm == "edc-deep":
        print("edc-deep: not implemented until p4", file=sys.stderr)
        return 2
    try:
        row = run(args)
    except (HarnessError, clean_snapshot.SnapshotError, KeyError) as exc:
        print(f"clean.sh: {exc}", file=sys.stderr)
        return 1
    print(f"{row['arm']} {row['entry']} run={row['run']}: outcome={row['outcome']} verdict={row['verdict']} "
          f"calls={row['model_calls']} duration={row['duration_s']}s -> {row['out_dir']}")
    return 0


# The harness is an ancestor of every audited agent, whose `ps -E` / lsof show the harness's exec-time
# argv, env and cwd: the repo path, --gt-root, --entry, EDC_RESULTS_FILE, PWD. So the script entry point
# re-execs itself with those inputs in a private temp file (unlinked on read), a locale-only env and cwd /.
BOOT = ("import json,os,sys;p=sys.argv[1];a=json.load(open(p));os.unlink(p);"
        "sys.path.insert(0,a['dir']);import clean_harness;sys.exit(clean_harness.boot(a))")
EXEC_ENV_KEYS = ("LANG", "LC_ALL", "LC_CTYPE")
PATH_ARGS = ("gt_root", "work_dir", "out_dir")
PATH_ENV_KEYS = ("EDC_RESULTS_FILE", "EDC_BENCH_WORKDIR", "ENEMY_BIN", "EDC_BENCH_EDC_BIN")


def reexec(argv) -> None:
    fd, path = tempfile.mkstemp(prefix=".clean-args-", suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump({"argv": argv, "cwd": os.getcwd(), "env": dict(os.environ), "dir": str(BENCHMARK_DIR)}, fh)
    try:
        os.execve(sys.executable, [sys.executable, "-I", "-c", BOOT, path],
                  {k: os.environ[k] for k in EXEC_ENV_KEYS if k in os.environ})
    except OSError:
        os.unlink(path)
        raise


def boot(saved: dict) -> int:
    """Second stage of reexec: restore the caller's env, make relative path
    inputs absolute against its cwd, then run from /."""
    os.environ.clear()
    os.environ.update(saved["env"])
    os.chdir(saved["cwd"])
    args = parse_args(saved["argv"])
    for key in PATH_ARGS:
        if getattr(args, key) is not None:
            setattr(args, key, getattr(args, key).absolute())
    for key in PATH_ENV_KEYS:
        value = os.environ.get(key)
        if value and os.sep in value:  # a bare ENEMY_BIN name stays a PATH lookup
            os.environ[key] = os.path.abspath(value)
    os.chdir("/")
    return run_cli(args)


if __name__ == "__main__":
    reexec(sys.argv[1:])
