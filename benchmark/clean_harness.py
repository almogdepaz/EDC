#!/usr/bin/env python3
"""Clean benchmark harness (plan 041 p1).

One run = one arm x one ground-truth entry x one repetition:
  1. build an isolated one-commit snapshot of the vulnerable tree
     (clean_snapshot.py; the audited agent never sees later commits);
  2. run the arm against it with clean-bin/ first on PATH (call logging and,
     for enemy, the `agent` shim);
  3. score the report with score.score_cve and detect blocked runs from the
     structured call logs (clean_blocked.py);
  4. append one row to an isolated TSV ($EDC_RESULTS_FILE, else
     <out-dir>/record.tsv). Legacy benchmark/results*.tsv paths are refused.

Usage: benchmark/clean.sh --arm <arm> --project <p> --entry <id> [options]
"""

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BENCHMARK_DIR = Path(__file__).resolve().parent
REPO_ROOT = BENCHMARK_DIR.parent
CLEAN_BIN = BENCHMARK_DIR / "clean-bin"
PLUGIN_DIR = REPO_ROOT / "plugins" / "edc"
DEFAULT_EDC_BIN = PLUGIN_DIR / "scripts" / "edc"
DEFAULT_MODEL = "claude-opus-5-5"
DEFAULT_GT_ROOT = BENCHMARK_DIR / "clean"
OUT_MARKER = ".clean-harness-run"

sys.path.insert(0, str(BENCHMARK_DIR))
import clean_gt  # noqa: E402
import clean_snapshot  # noqa: E402
from clean_blocked import detect_blocked, result_text  # noqa: E402

ARMS = ("edc-module", "edc-review-skill", "edc-security", "enemy-3", "edc-deep")
# Per-phase wall-clock caps (seconds). edc-review-skill keeps autoresearch.sh's 600s.
DEFAULT_TIMEOUTS = {"edc-module": 1800, "edc-review-skill": 600, "edc-security": 3600, "enemy-3": 7200}
ENEMY_MAX_PASSES = "3"
# Web tools are disallowed in every arm the harness controls; the legacy
# allowed-tool sets are otherwise unchanged.
DISALLOWED_TOOLS = "WebFetch WebSearch"

RECORD_FIELDS = [
    "timestamp", "run_id", "arm", "project", "entry", "kind", "run", "model", "outcome", "verdict",
    "confidence", "duration_s", "build_duration_s", "model_calls", "build_model_calls", "passes_run",
    "loop_end", "arm_exit", "blocked", "blocked_signal", "cve_ids_named", "build_scope",
    "snapshot_commit", "report", "out_dir", "notes",
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
    def __init__(self, args, entry, model, snap, out, work, env):
        self.args, self.entry, self.model = args, entry, model
        self.snap, self.out, self.work, self.env = snap, out, work, env
        self.files = entry["affected_files"]
        self.calls = out / "calls"
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
        stdout, stderr = self.out / "arm-stdout.jsonl", self.out / "arm-stderr.log"
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
        cmd = [str(CLEAN_BIN / "claude"), "-p", EDC_MODULE_PROMPT.format(file_list=file_list),
               "--plugin-dir", str(PLUGIN_DIR),
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
        names = [Path(f).name for f in self.files]
        if len(set(names)) != len(names):
            raise HarnessError(f"affected files share a basename; flat copy would collide: {self.files}")
        for f in self.files:
            shutil.copyfile(self.snap / f, flat / Path(f).name)
        file_list = "".join(f" {n}" for n in names)
        prompt = REVIEW_SKILL_PROMPT.format(ctx_note=REVIEW_SKILL_CTX_NOTE, file_list=file_list)
        cmd = [str(CLEAN_BIN / "claude"), "-p", prompt,
               "--plugin-dir", str(PLUGIN_DIR),
               "--allowedTools", "Read Glob Grep Write Skill",
               "--disallowedTools", DISALLOWED_TOOLS,
               "--max-turns", "20", "--model", self.model,
               "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions"]
        self.single_call("edc-review-skill", cmd, flat, REVIEW_SKILL_REPORTS)

    def edc_security(self):
        r = self.result
        edc = os.environ.get("EDC_BENCH_EDC_BIN") or str(DEFAULT_EDC_BIN)
        tracked = subprocess.run(["git", "ls-files"], cwd=self.snap, capture_output=True, text=True,
                                 check=True).stdout.splitlines()
        ignores = []
        for pattern in ignore_complement(tracked, self.files):
            ignores += ["--ignore", pattern]
        build_calls = self.out / "calls-build"
        r["call_dirs"] = [build_calls, self.calls]
        build_cmd = [edc, "--model", self.model, "build", "--agent", "claude", str(self.snap)]
        if self.args.build_scope == "affected":
            build_cmd += ignores
        rc, r["build_duration"], timed_out = run_logged(
            build_cmd, self.snap, self.arm_env(build_calls), self.timeout("edc-security"),
            self.out / "build-stdout.log", self.out / "build-stderr.log")
        r["build_calls"] = call_count(build_calls)
        r["text_logs"] = [self.out / "build-stdout.log", self.out / "build-stderr.log"]
        if rc != 0 or timed_out:
            r["arm_exit"], r["timed_out"] = f"build:{rc}", timed_out
            r["notes"].append("edc build failed; review skipped")
            return
        result_file = self.out / "edc-result.json"
        review_cmd = [edc, "--model", self.model, "security-review", "--agent", "claude", "--full",
                      "--no-context-refresh", *ignores]
        rc, r["duration"], r["timed_out"] = run_logged(
            review_cmd, self.snap, self.arm_env(self.calls, EDC_RESULT_FILE=str(result_file)),
            self.timeout("edc-security"), self.out / "review-stdout.log", self.out / "review-stderr.log")
        r["arm_exit"] = rc
        r["text_logs"] += [self.out / "review-stdout.log", self.out / "review-stderr.log"]
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
        stdout, stderr = self.out / "enemy-stdout.log", self.out / "enemy-stderr.log"
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


# --- record -------------------------------------------------------------------

def write_record(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    clean = {k: re.sub(r"[\t\r\n]+", " ", str(row.get(k, ""))) for k in RECORD_FIELDS}
    exists = path.exists() and path.stat().st_size > 0
    if exists:
        with path.open(newline="") as fh:
            header = fh.readline().rstrip("\r\n").split("\t")
        if header != RECORD_FIELDS:
            raise HarnessError(f"{path} has a different header; use a fresh EDC_RESULTS_FILE")
    with path.open("a", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=RECORD_FIELDS, delimiter="\t", lineterminator="\n")
        if not exists:
            writer.writeheader()
        writer.writerow(clean)


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


def child_env(model: str) -> dict:
    env = dict(os.environ)
    env.pop("EDC_RESULTS_FILE", None)
    path_dirs = [d for d in env.get("PATH", "").split(os.pathsep)
                 if d and Path(d).resolve() != CLEAN_BIN.resolve()]
    real = shutil.which("claude", path=os.pathsep.join(path_dirs))
    if not real:
        raise HarnessError("claude not found on PATH")
    env["PATH"] = os.pathsep.join([str(CLEAN_BIN), *path_dirs])
    env["EDC_BENCH_REAL_CLAUDE"] = real
    for key in ("EDC_BENCH_MODEL", "EDC_BUILD_MODEL", "EDC_REVIEW_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"):
        env[key] = model
    return env


def run(args) -> dict:
    model = os.environ.get("EDC_BENCH_MODEL") or DEFAULT_MODEL
    work = (args.work_dir or Path(os.environ.get("EDC_BENCH_WORKDIR", "/private/tmp/edc-bench")) / "clean").resolve()
    out = (args.out_dir or work / "results" / args.arm / args.entry / f"run-{args.run}").resolve()
    results_path = check_results_path(Path(os.environ["EDC_RESULTS_FILE"]) if os.environ.get("EDC_RESULTS_FILE")
                                      else out / "record.tsv")
    if args.arm == "enemy-3":
        preflight_enemy()
    env = child_env(model)

    project_dir = args.gt_root.resolve() / args.project
    entry = clean_gt.find_entry(project_dir / "ground-truth.md", args.entry)
    if not entry["affected_files"]:
        raise HarnessError(f"{args.entry} has no affected_file")
    cache = clean_snapshot.ensure_cache(clean_gt.read_repo_url(project_dir), work / "cache" / f"{args.project}.git")
    snap = work / "snap" / opaque_id(args.arm, args.project, args.entry, args.run)
    if snap.exists():
        shutil.rmtree(snap)
    snapshot_commit = clean_snapshot.make_snapshot(cache, entry, project_dir, snap)

    prepare_dir(out)
    r = Run(args, entry, model, snap, out, work, env)
    getattr(r, args.arm.replace("-", "_"))()
    res = r.result

    logs = [p for d in res["call_dirs"] for p in call_logs(d)]
    blocked, signal_ = detect_blocked(logs, res["text_logs"])
    import score  # judge uses the harness env (real claude, not the call logger)
    verdict, confidence, notes = score.score_cve(
        res["report_text"], entry["id"], entry.get("bug_pattern", ""), entry.get("category", ""),
        entry.get("description", ""), ", ".join(entry["affected_files"]), skip_judge=args.skip_judge)
    if blocked:
        outcome = "blocked"
    elif res["timed_out"]:
        outcome = "timeout"
    elif not res["ok"]:
        outcome = "error"
    else:
        outcome = verdict
    named = sorted(set(CVE_ID_RE.findall(res["report_text"])))
    row = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_id": f"{args.arm}:{args.project}:{entry['id']}:{args.run}",
        "arm": args.arm, "project": args.project, "entry": entry["id"], "kind": entry["kind"],
        "run": args.run, "model": model, "outcome": outcome, "verdict": verdict,
        "confidence": f"{confidence:.2f}", "duration_s": f"{res['duration']:.1f}",
        "build_duration_s": "" if res["build_duration"] is None else f"{res['build_duration']:.1f}",
        "model_calls": call_count(r.calls),
        "build_model_calls": "" if res["build_calls"] is None else res["build_calls"],
        "passes_run": res["passes_run"], "loop_end": res["loop_end"], "arm_exit": res["arm_exit"],
        "blocked": "yes" if blocked else "no", "blocked_signal": signal_,
        "cve_ids_named": ",".join(named),
        "build_scope": args.build_scope if args.arm == "edc-security" else "",
        "snapshot_commit": snapshot_commit, "report": res["report"], "out_dir": str(out),
        "notes": "; ".join([*res["notes"], notes]),
    }
    write_record(results_path, row)
    return row


def main(argv=None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
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


if __name__ == "__main__":
    sys.exit(main())
