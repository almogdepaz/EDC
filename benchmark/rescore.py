#!/usr/bin/env python3
"""
Re-score an existing review-results.tsv against the hardened scorer.

The old scorer silently coerced judge refusals / parse failures into `missed`
verdicts. As a result, existing TSVs under `benchmark/regression/results/**`
have zero `judge_error` rows even when the underlying transcripts show the
review wrote the correct answer.

This tool walks an existing TSV row-by-row:
  1. locate the analysis text (cached issues.md, falling back to the Claude
     transcript reconstructed via transcript_utils)
  2. re-invoke the LLM judge via score.score_cve
  3. write a NEW TSV at <input>.rescored.tsv with the same schema plus an
     `original_<verdict-field>` column so old vs new can be diffed

Costs money: each row spawns one `claude -p` (default model = $EDC_JUDGE_MODEL).
Use `--dry-run` to print the worklist without paying. Use `--cve` to scope to
one or more CVEs.

Usage:
    benchmark/rescore.py <results.tsv>
    benchmark/rescore.py <results.tsv> --dry-run
    benchmark/rescore.py <results.tsv> --cve CVE-2023-38545,CVE-2018-0500
"""

from __future__ import annotations

import argparse
import csv
import shutil
import sys
from datetime import datetime
from pathlib import Path

from scoring_helpers import combine_scores, review_verdict, review_verdict_field
from transcript_utils import (
    find_issues_for_row,
    find_transcript_for_row,
    extract_review_text_from_transcript,
)
from score import score_cve, load_issues  # noqa: F401  (load_issues kept for future re-use)
import subprocess

REPO_ROOT = Path(__file__).resolve().parent.parent


def load_ground_truth(repo: str) -> dict[str, dict]:
    gt = REPO_ROOT / "benchmark" / repo / "ground-truth.md"
    if not gt.exists():
        return {}
    out: dict[str, dict] = {}
    res = subprocess.run(
        ["python3", str(REPO_ROOT / "benchmark" / "parse_gt.py"), str(gt)],
        capture_output=True, text=True,
    )
    for line in res.stdout.splitlines():
        parts = line.split("|")
        if len(parts) < 7:
            continue
        cve, fix_commit, files, category, severity, bug_pattern, description = parts[:7]
        out[cve] = {
            "fix_commit": fix_commit,
            "affected_files": files,
            "category": category,
            "severity": severity,
            "bug_pattern": bug_pattern,
            "description": description,
        }
    return out


def repo_from_tsv(tsv_path: Path) -> str:
    parts = tsv_path.resolve().parts
    try:
        idx = parts.index("results")
    except ValueError:
        return ""
    # results/<sha>/<mode>/<label>/<repo>/file.tsv → repo is parts[idx+4]
    body = parts[idx + 1:-1]
    if len(body) >= 4:
        return body[3]
    if len(body) == 3:
        return body[2]
    if len(body) == 2:
        return body[1]
    return ""


def find_analysis(row: dict, tsv_path: Path) -> tuple[str, str]:
    for cand in find_issues_for_row(row, tsv_path, None, "review"):
        if cand.exists() and cand.stat().st_size > 0:
            return cand.read_text(encoding="utf-8", errors="replace"), str(cand)
    tx = find_transcript_for_row(row, tsv_path)
    if tx is not None:
        # Reconstruct just the issues.md the review wrote, not the
        # surrounding chatter — chatter buries the finding past the
        # judge's 8000-char truncation window.
        text = extract_review_text_from_transcript(tx, mode="issues_only")
        if text:
            return text, f"{tx} (transcript)"
    return "", ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tsv", type=Path)
    ap.add_argument("--cve", default="", help="comma-separated list of CVEs to rescore (default: all)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--out", type=Path, default=None,
                    help="output tsv path (default: <input>.rescored.tsv)")
    args = ap.parse_args()

    if not args.tsv.exists():
        print(f"error: {args.tsv} not found", file=sys.stderr)
        return 2

    cve_filter = {c.strip() for c in args.cve.split(",") if c.strip()}
    repo = repo_from_tsv(args.tsv)
    gt = load_ground_truth(repo)
    if not gt:
        print(f"warning: no ground truth for repo={repo!r}; continuing", file=sys.stderr)

    with args.tsv.open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        fieldnames = list(reader.fieldnames or [])
        rows = list(reader)

    verdict_field = review_verdict_field(fieldnames)
    original_verdict_field = f"original_{verdict_field}"
    if original_verdict_field not in fieldnames:
        fieldnames.insert(fieldnames.index(verdict_field) + 1, original_verdict_field)
    if "rescored_at" not in fieldnames:
        fieldnames.append("rescored_at")

    out_path = args.out or args.tsv.with_suffix(".rescored.tsv")

    worklist = []
    for row in rows:
        cve = row.get("cve", "")
        if cve_filter and cve not in cve_filter:
            continue
        worklist.append(row)

    print(f"input:      {args.tsv}")
    print(f"output:     {out_path}")
    print(f"rows:       {len(worklist)}/{len(rows)} (filtered={bool(cve_filter)})")
    print(f"repo:       {repo}")
    print(f"dry-run:    {args.dry_run}")
    print()

    new_rows = []
    for i, row in enumerate(rows, 1):
        cve = row.get("cve", "")
        if cve_filter and cve not in cve_filter:
            new_rows.append(row)
            continue

        info = gt.get(cve)
        if not info:
            print(f"[{i}/{len(rows)}] {cve}: no ground truth — skipping")
            new_rows.append(row)
            continue

        text, source = find_analysis(row, args.tsv)
        if not text:
            print(f"[{i}/{len(rows)}] {cve}: no analysis text found — skipping")
            new_rows.append(row)
            continue

        print(f"[{i}/{len(rows)}] {cve}: {len(text)} chars from {source}")
        if args.dry_run:
            print(f"             (dry-run) original={review_verdict(row)}")
            new_rows.append(row)
            continue

        verdict, confidence, notes = score_cve(
            text, cve, info["bug_pattern"], info["category"],
            info["description"], info["affected_files"],
        )
        print(f"             rescored: {review_verdict(row)} → {verdict} ({confidence})")

        new_row = dict(row)
        new_row[original_verdict_field] = review_verdict(row)
        new_row[verdict_field] = verdict
        if "combined_score" in new_row:
            new_row["combined_score"] = str(
                combine_scores(new_row.get("build_verdict", ""), verdict, context=f"{cve} rescore")
            )
        new_row["confidence"] = str(confidence)
        new_row["notes"] = notes
        new_row["rescored_at"] = datetime.now().isoformat(timespec="seconds")
        new_rows.append(new_row)

    if args.dry_run:
        print("\n(dry-run; no writes)")
        return 0

    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter="\t",
                                lineterminator="\n", extrasaction="ignore")
        writer.writeheader()
        for r in new_rows:
            writer.writerow(r)
    print(f"\nwrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
