#!/usr/bin/env python3
"""
Scorer audit tool. Phase 0.1 + 0.3 of BUILD_VALUE_PLAN.md.

For every row in `benchmark/regression/results/**/review-results.tsv`:
  1. classify the recorded verdict's failure mode if any
  2. cross-check against the transcript-written analysis
  3. flag rows where the verdict is `missed` but the transcript contains
     the CVE ID or an affected file (likely a judge refusal masquerading
     as a miss)

Output: benchmark/judge-audit.md with per-mismatch table and aggregate
counts per failure class.

Usage:
    benchmark/audit.py                            # full sweep, write report
    benchmark/audit.py --tsv path/to/results.tsv  # single file
    benchmark/audit.py --json                     # machine-readable
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from dataclasses import dataclass, asdict, field
from pathlib import Path

from transcript_utils import (
    find_issues_for_row,
    find_transcript_for_row,
    extract_review_text_from_transcript,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RESULTS_DIR = REPO_ROOT / "benchmark" / "regression" / "results"
DEFAULT_REPORT = REPO_ROOT / "benchmark" / "judge-audit.md"


@dataclass
class RowVerdict:
    tsv: str
    cve: str
    recorded: str           # exact / partial / missed / judge_error
    notes: str
    failure_class: str      # ok / refusal / parse / keyword-prefilter / actual-miss / unknown
    transcript_has_cve: bool
    transcript_has_file: bool
    transcript_chars: int
    issues_source: str      # "issues.md" / "transcript" / "none"


REFUSAL_RE = re.compile(
    r"(I can'?t (help|assist|provide|do that)|I cannot (help|assist|provide)"
    r"|policy|safety|harmful|malicious)",
    re.IGNORECASE,
)


def classify(row: dict, transcript_text: str, affected_files: list[str],
             cve: str) -> tuple[str, bool, bool]:
    """Return (failure_class, transcript_has_cve, transcript_has_file)."""
    verdict = row.get("found", "")
    notes = row.get("notes", "")
    cve_id_short = cve.replace("CVE-", "")
    has_cve = bool(transcript_text) and (
        cve.lower() in transcript_text.lower()
        or cve_id_short in transcript_text
    )
    has_file = bool(transcript_text) and any(
        f and (f.lower() in transcript_text.lower())
        for f in affected_files
    )

    if verdict in ("exact", "partial"):
        return "ok", has_cve, has_file
    if verdict == "judge_error":
        # Categorize within judge_error using the notes
        if "refusal" in notes.lower() or REFUSAL_RE.search(notes):
            return "refusal", has_cve, has_file
        if "parse_fail" in notes or "json_decode" in notes:
            return "parse", has_cve, has_file
        if "timeout" in notes.lower():
            return "parse", has_cve, has_file
        return "unknown", has_cve, has_file
    if verdict == "missed":
        if notes.startswith("keyword_filter"):
            # Legitimately killed by the keyword pre-filter. But if the
            # transcript contains the CVE id or affected file, the
            # pre-filter killed a real finding — flag it.
            if has_cve or has_file:
                return "keyword-prefilter", has_cve, has_file
            return "actual-miss", has_cve, has_file
        if "judge_error" in notes or "fallback" in notes:
            # Old scorer collapsed judge failure into missed via fallback.
            # If transcript has the answer, this is what the plan calls out.
            if REFUSAL_RE.search(notes):
                return "refusal", has_cve, has_file
            if "parse" in notes or "could not parse" in notes:
                return "parse", has_cve, has_file
            return "unknown", has_cve, has_file
        if has_cve or has_file:
            # Judge ran cleanly but said missed; transcript suggests otherwise.
            # Could be judge hallucination (file present but judge said NOT_FOUND).
            return "unknown", has_cve, has_file
        return "actual-miss", has_cve, has_file
    return "unknown", has_cve, has_file


def load_ground_truth(repo: str) -> dict[str, list[str]]:
    """Return {cve: [affected_files...]} parsed via the benchmark's own parser."""
    gt = REPO_ROOT / "benchmark" / repo / "ground-truth.md"
    if not gt.exists():
        return {}
    out: dict[str, list[str]] = {}
    import subprocess
    res = subprocess.run(
        ["python3", str(REPO_ROOT / "benchmark" / "parse_gt.py"), str(gt)],
        capture_output=True, text=True,
    )
    for line in res.stdout.splitlines():
        parts = line.split("|")
        if len(parts) < 3:
            continue
        cve = parts[0]
        files = [f.strip() for f in parts[2].split(",") if f.strip()]
        out[cve] = files
    return out


def audit_tsv(tsv_path: Path) -> list[RowVerdict]:
    out: list[RowVerdict] = []
    with tsv_path.open(newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    if not rows:
        return out
    # Determine repo from path: results/<sha>/<mode>/<label>/<repo>/file.tsv
    parts = tsv_path.resolve().parts
    try:
        idx = parts.index("results")
        repo = parts[idx + 4] if len(parts) > idx + 4 else parts[idx + 2]
    except (ValueError, IndexError):
        repo = ""
    gt = load_ground_truth(repo) if repo else {}

    for row in rows:
        cve = row.get("cve", "")
        affected = gt.get(cve, [])
        issues_text = ""
        source = "none"
        for cand in find_issues_for_row(row, tsv_path, None, "review"):
            if cand.exists() and cand.stat().st_size > 0:
                issues_text = cand.read_text(encoding="utf-8", errors="replace")
                source = "issues.md"
                break
        if not issues_text:
            tx = find_transcript_for_row(row, tsv_path)
            if tx is not None:
                # Focused issues.md reconstruction; lets the audit see what
                # the review actually wrote, not interleaved chatter.
                issues_text = extract_review_text_from_transcript(tx, mode="issues_only")
                if issues_text:
                    source = "transcript"
        cls, has_cve, has_file = classify(row, issues_text, affected, cve)
        out.append(RowVerdict(
            tsv=str(tsv_path.relative_to(REPO_ROOT)),
            cve=cve,
            recorded=row.get("found", ""),
            notes=(row.get("notes", "") or "")[:240],
            failure_class=cls,
            transcript_has_cve=has_cve,
            transcript_has_file=has_file,
            transcript_chars=len(issues_text),
            issues_source=source,
        ))
    return out


def find_all_tsvs(root: Path) -> list[Path]:
    return sorted(root.glob("**/review-results.tsv"))


def render_markdown(rows: list[RowVerdict]) -> str:
    by_class: dict[str, int] = {}
    for r in rows:
        by_class[r.failure_class] = by_class.get(r.failure_class, 0) + 1
    lines = [
        "# Judge audit",
        "",
        f"Total rows audited: **{len(rows)}**",
        "",
        "## Failure class counts",
        "",
        "| Class | Count |",
        "|-------|-------|",
    ]
    for cls in ("ok", "refusal", "parse", "keyword-prefilter",
                "actual-miss", "unknown"):
        lines.append(f"| {cls} | {by_class.get(cls, 0)} |")

    suspect = [r for r in rows
               if r.failure_class in ("refusal", "parse", "keyword-prefilter",
                                       "unknown")
               and (r.transcript_has_cve or r.transcript_has_file)]
    lines += [
        "",
        f"## Suspect rows: recorded as miss/error but transcript has evidence ({len(suspect)})",
        "",
        "These are the rows where the scorer most likely undercounted a real",
        "finding. Run `rejudge.py` on the corresponding TSV.",
        "",
        "| TSV | CVE | recorded | class | has_cve | has_file | chars | source |",
        "|-----|-----|----------|-------|---------|----------|-------|--------|",
    ]
    for r in suspect:
        lines.append(
            f"| `{r.tsv}` | {r.cve} | {r.recorded} | {r.failure_class} "
            f"| {r.transcript_has_cve} | {r.transcript_has_file} "
            f"| {r.transcript_chars} | {r.issues_source} |"
        )

    lines += ["", "## All rows", "",
              "| TSV | CVE | recorded | class | has_cve | has_file | chars | source |",
              "|-----|-----|----------|-------|---------|----------|-------|--------|"]
    for r in rows:
        lines.append(
            f"| `{r.tsv}` | {r.cve} | {r.recorded} | {r.failure_class} "
            f"| {r.transcript_has_cve} | {r.transcript_has_file} "
            f"| {r.transcript_chars} | {r.issues_source} |"
        )

    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tsv", type=Path, help="audit a single tsv")
    ap.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS_DIR,
                    help="root directory containing benchmark results")
    ap.add_argument("--out", type=Path, default=DEFAULT_REPORT,
                    help="output markdown report path")
    ap.add_argument("--json", action="store_true",
                    help="print rows as JSON to stdout instead of writing a report")
    args = ap.parse_args()

    if args.tsv:
        tsvs = [args.tsv]
    else:
        tsvs = find_all_tsvs(args.results_dir)
    if not tsvs:
        print(f"no review-results.tsv files under {args.results_dir}", file=sys.stderr)
        return 1

    all_rows: list[RowVerdict] = []
    for t in tsvs:
        all_rows.extend(audit_tsv(t))

    if args.json:
        print(json.dumps([asdict(r) for r in all_rows], indent=2))
        return 0

    args.out.write_text(render_markdown(all_rows))
    print(f"wrote {args.out} ({len(all_rows)} rows from {len(tsvs)} tsv(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
