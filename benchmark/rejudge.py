#!/usr/bin/env python3
"""
Interactive re-judge tool for `judge_error` rows.

The scorer (`score.py`) emits `judge_error` whenever the LLM judge refuses,
times out, or returns unparseable output. No retries, no silent fallback —
those rows are surfaced here for a human to resolve.

Usage:
    benchmark/rejudge.py <results.tsv> [--issues-root <dir>]
    benchmark/rejudge.py <results.tsv> --list      # just print the worklist
    benchmark/rejudge.py <results.tsv> --dry-run   # walk rows but don't write

For each `judge_error` row:
  1. Locate the analysis text (issues.md from cache, or transcript jsonl).
  2. Print CVE info + analysis content (paged via $PAGER if available).
  3. Prompt for: exact / partial / missed / skip / quit.
  4. Write the corrected verdict back to the TSV in place. The notes field
     gets `manual=1; reason=<reason>; original_notes=<original>` so the
     audit trail survives.

Backups: every TSV gets a `.bak.<timestamp>` copy before any rewrite.
"""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from transcript_utils import (
    find_issues_for_row,
    find_transcript_for_row,
    extract_review_text_from_transcript,
)

VALID_VERDICTS = {"exact", "partial", "missed"}
SKIP_VERDICT = "skip"
QUIT_VERDICT = "quit"
PROMPT = "verdict [exact/partial/missed/skip/quit/view]: "


def backup_tsv(path: Path) -> Path:
    ts = datetime.now().strftime("%Y%m%dT%H%M%S")
    backup = path.with_suffix(path.suffix + f".bak.{ts}")
    shutil.copy2(path, backup)
    return backup


def load_rows(path: Path) -> tuple[list[str], list[dict]]:
    with path.open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        return list(reader.fieldnames or []), list(reader)


def write_rows(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter="\t",
                                lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def is_judge_error(row: dict) -> bool:
    # Either phase may be judge_error. We surface both — `found` is the
    # review-phase verdict; `build_verdict` is the build-phase verdict.
    return row.get("found") == "judge_error" or row.get("build_verdict") == "judge_error"


def show_analysis(text: str) -> None:
    """Page the analysis text using $PAGER if available, else print."""
    pager = os.environ.get("PAGER", "less")
    try:
        proc = subprocess.Popen([pager], stdin=subprocess.PIPE)
        if proc.stdin is not None:
            proc.stdin.write(text.encode("utf-8", errors="replace"))
            proc.stdin.close()
        proc.wait()
    except (FileNotFoundError, BrokenPipeError):
        print(text)


def prompt_verdict() -> str:
    while True:
        try:
            ans = input(PROMPT).strip().lower()
        except EOFError:
            return QUIT_VERDICT
        if ans in VALID_VERDICTS or ans in (SKIP_VERDICT, QUIT_VERDICT):
            return ans
        if ans == "view":
            return "view"
        print(f"  invalid; pick one of: {sorted(VALID_VERDICTS)} / skip / quit / view")


def find_analysis_text(row: dict, tsv_path: Path,
                       issues_root: Path | None,
                       phase: str) -> tuple[str | None, str | None]:
    """Return (text, source_label) or (None, None).

    `phase` is either "review" or "build". For review, prefer the cached
    issues.md; fall back to the claude transcript. For build, prefer the
    build snapshot issues.md.
    """
    if phase == "review":
        candidates = find_issues_for_row(row, tsv_path, issues_root, phase="review")
    else:
        candidates = find_issues_for_row(row, tsv_path, issues_root, phase="build")

    for p in candidates:
        if p.exists() and p.stat().st_size > 0:
            return p.read_text(encoding="utf-8", errors="replace"), str(p)

    if phase == "review":
        tx = find_transcript_for_row(row, tsv_path)
        if tx is not None:
            # Default to the focused issues.md reconstruction so the human
            # sees the actual finding text, not interleaved chatter.
            text = extract_review_text_from_transcript(tx, mode="issues_only")
            if text:
                return text, f"{tx} (reconstructed issues.md)"
            text = extract_review_text_from_transcript(tx, mode="full")
            if text:
                return text, f"{tx} (reconstructed full transcript)"

    return None, None


def format_row_header(row: dict, phase: str) -> str:
    verdict_field = "found" if phase == "review" else "build_verdict"
    notes_field = "notes" if phase == "review" else "build_notes"
    return (
        f"\n{'=' * 72}\n"
        f"phase:       {phase}\n"
        f"cve:         {row.get('cve', '?')}\n"
        f"category:    {row.get('category', '?')}\n"
        f"severity:    {row.get('severity', '?')}\n"
        f"current:     {row.get(verdict_field, '?')}\n"
        f"notes:       {row.get(notes_field, '')[:400]}\n"
        f"timestamp:   {row.get('timestamp', '?')}\n"
        f"{'=' * 72}"
    )


def rejudge_phase(row: dict, phase: str, tsv_path: Path,
                  issues_root: Path | None, dry_run: bool) -> bool:
    """Re-judge a single (row, phase). Returns False on quit."""
    verdict_field = "found" if phase == "review" else "build_verdict"
    confidence_field = "confidence" if phase == "review" else "build_confidence"
    notes_field = "notes" if phase == "review" else "build_notes"

    if row.get(verdict_field) != "judge_error":
        return True

    print(format_row_header(row, phase))

    text, source = find_analysis_text(row, tsv_path, issues_root, phase)
    if text is None:
        print(f"  ! no analysis text found for this row ({phase} phase). marking skip.")
        return True
    print(f"  source: {source} ({len(text)} chars)")

    print(f"  type 'view' to page the analysis, or verdict directly.")
    while True:
        ans = prompt_verdict()
        if ans == QUIT_VERDICT:
            return False
        if ans == SKIP_VERDICT:
            print(f"  skipped {row.get('cve')} ({phase})")
            return True
        if ans == "view":
            show_analysis(text)
            continue
        # valid verdict
        original_notes = row.get(notes_field, "")
        row[verdict_field] = ans
        row[confidence_field] = "1.0"
        row[notes_field] = (
            f"manual=1; reason=judge_error_resolved; "
            f"original={original_notes[:300]}"
        )
        # Recompute combined_score if both phases now have non-error verdicts.
        bv = row.get("build_verdict", "")
        rv = row.get("found", "")
        if rv and rv != "judge_error" and bv and bv != "judge_error":
            from score import combine_scores
            row["combined_score"] = f"{combine_scores(bv, rv)}"
        elif rv and rv != "judge_error" and not bv:
            row["combined_score"] = str(
                {"exact": 1.0, "partial": 0.5, "missed": 0.0}.get(rv, 0.0)
            )
        action = "would write" if dry_run else "wrote"
        print(f"  {action} verdict={ans} for {row.get('cve')} ({phase})")
        return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tsv", type=Path, help="path to review-results.tsv")
    ap.add_argument("--issues-root", type=Path, default=None,
                    help="root directory to search for issues.md "
                         "(defaults to standard /private/tmp/edc-bench-regression cache)")
    ap.add_argument("--list", action="store_true",
                    help="just print the worklist of judge_error rows and exit")
    ap.add_argument("--dry-run", action="store_true",
                    help="walk and prompt but do not write back")
    args = ap.parse_args()

    if not args.tsv.exists():
        print(f"error: {args.tsv} not found", file=sys.stderr)
        return 2

    fieldnames, rows = load_rows(args.tsv)
    if not rows:
        print("no rows in tsv")
        return 0

    err_rows = [r for r in rows if is_judge_error(r)]
    if not err_rows:
        print(f"no judge_error rows in {args.tsv}")
        return 0

    print(f"found {len(err_rows)} judge_error row(s) in {args.tsv}")
    for r in err_rows:
        which = []
        if r.get("found") == "judge_error":
            which.append("review")
        if r.get("build_verdict") == "judge_error":
            which.append("build")
        print(f"  - {r.get('cve')} [{','.join(which)}]")

    if args.list:
        return 0

    if not args.dry_run:
        bkp = backup_tsv(args.tsv)
        print(f"backup written: {bkp}")

    sys.stdout.flush()
    keep_going = True
    for row in err_rows:
        if not keep_going:
            break
        for phase in ("review", "build"):
            if row.get("found" if phase == "review" else "build_verdict") != "judge_error":
                continue
            keep_going = rejudge_phase(row, phase, args.tsv, args.issues_root,
                                       args.dry_run)
            if not keep_going:
                print("quitting; partial progress saved.")
                break

    if not args.dry_run:
        write_rows(args.tsv, fieldnames, rows)
        print(f"\nwrote updates to {args.tsv}")
    else:
        print("\n(dry-run; no writes performed)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
