#!/usr/bin/env python3
"""
EDC Benchmark Scorer

Compares EDC analysis output against known CVE ground truth.
Uses fuzzy matching on bug patterns to determine if the CVE was found.

Usage:
    python3 score.py --issues .context/issues.md --cve CVE-2023-38545 \
        --bug-pattern "hostname length check bypassed" --category heap-buffer-overflow \
        --severity critical --affected-files lib/socks.c

    python3 score.py --summary  # Print summary of all results
"""

import argparse
import os
import re
import sys
from datetime import datetime
from pathlib import Path

RESULTS_FILE = Path(__file__).parent / "results.tsv"

# Keywords that indicate a match for each bug category
CATEGORY_KEYWORDS = {
    "heap-buffer-overflow": [
        "heap", "buffer overflow", "overflow", "overwrite", "out of bounds write",
        "oob write", "buffer overrun", "heap corruption"
    ],
    "stack-buffer-overflow": [
        "stack", "buffer overflow", "overflow", "stack overwrite",
        "stack corruption", "stack smash"
    ],
    "use-after-free": [
        "use after free", "uaf", "dangling pointer", "freed memory",
        "use-after-free", "stale pointer"
    ],
    "double-free": [
        "double free", "double-free", "freed twice", "free.*free"
    ],
    "out-of-bounds-read": [
        "out of bounds read", "oob read", "buffer over-read", "overread",
        "read past", "read beyond", "buffer read"
    ],
    "out-of-bounds-write": [
        "out of bounds write", "oob write", "integer overflow", "overflow.*write",
        "write past", "write beyond"
    ],
    "credential-leak": [
        "credential", "leak", "auth", "token", "password", "bearer",
        "cookie", "redirect.*auth", "auth.*redirect"
    ],
    "protocol-injection": [
        "inject", "starttls", "pipeline", "mitm", "man in the middle",
        "response.*before.*tls", "tls.*upgrade"
    ],
    "local-file-overwrite": [
        "overwrite", "local file", "file.*overwrite", "path traversal",
        "directory traversal"
    ],
    "stack-overflow": [
        "stack overflow", "recursion", "unbounded recursion", "infinite recursion",
        "recursive", "stack exhaustion"
    ],
    "validation-bypass": [
        "bypass", "validation", "check.*skip", "skip.*check", "case.*insensitive",
        "psl", "public suffix"
    ],
}


def load_issues(issues_path: str) -> str:
    """Load the issues file content."""
    path = Path(issues_path)
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace").lower()


def extract_bug_keywords(bug_pattern: str) -> list[str]:
    """Extract meaningful keywords from the bug pattern description."""
    # Split on common delimiters and filter short/stop words
    stop_words = {
        "the", "a", "an", "in", "on", "at", "to", "for", "of", "with",
        "is", "are", "was", "were", "be", "been", "being", "not", "no",
        "and", "or", "but", "when", "during", "after", "before", "via",
        "that", "this", "from", "by"
    }
    words = re.split(r'[,\s]+', bug_pattern.lower())
    keywords = [w for w in words if len(w) > 2 and w not in stop_words]
    return keywords


def score_issues(issues_text: str, cve_id: str, bug_pattern: str,
                 category: str, affected_files: str) -> tuple[bool, float, str]:
    """
    Score whether the issues text contains the CVE finding.

    Returns: (found: bool, confidence: float 0-1, notes: str)
    """
    if not issues_text:
        return False, 0.0, "no issues file"

    notes = []
    score = 0.0

    # 1. Check if the affected file is mentioned
    files = [f.strip() for f in affected_files.split(",")]
    file_mentioned = any(
        os.path.basename(f).lower() in issues_text for f in files
    )
    if file_mentioned:
        score += 0.2
        notes.append("file_mentioned")

    # 2. Check category keywords
    cat_keywords = CATEGORY_KEYWORDS.get(category, [])
    # Also check sub-categories (e.g. "use-after-free, double-free")
    for subcat in category.split(","):
        subcat = subcat.strip()
        cat_keywords.extend(CATEGORY_KEYWORDS.get(subcat, []))

    cat_matches = sum(1 for kw in cat_keywords if kw in issues_text)
    if cat_matches > 0:
        cat_score = min(cat_matches / max(len(cat_keywords), 1) * 0.3, 0.3)
        score += cat_score
        notes.append(f"cat_keywords={cat_matches}/{len(cat_keywords)}")

    # 3. Check bug pattern keywords
    pattern_keywords = extract_bug_keywords(bug_pattern)
    pattern_matches = sum(1 for kw in pattern_keywords if kw in issues_text)
    if pattern_matches > 0:
        pattern_score = min(pattern_matches / max(len(pattern_keywords), 1) * 0.5, 0.5)
        score += pattern_score
        notes.append(f"pattern_keywords={pattern_matches}/{len(pattern_keywords)}")

    # Threshold: found if confidence >= 0.4
    found = score >= 0.4

    return found, round(score, 3), "; ".join(notes)


def append_result(cve_id: str, category: str, severity: str,
                  found: bool, confidence: float, duration: int, notes: str):
    """Append a result to the TSV file."""
    timestamp = datetime.now().isoformat(timespec="seconds")
    line = f"{timestamp}\t{cve_id}\t{category}\t{severity}\t{'YES' if found else 'NO'}\t{confidence}\t{duration}\t{notes}\n"

    with open(RESULTS_FILE, "a") as f:
        f.write(line)

    # Also print
    status = "FOUND" if found else "MISSED"
    print(f"    [{status}] {cve_id} (confidence={confidence}) — {notes}")


def print_summary():
    """Print summary of all results."""
    if not RESULTS_FILE.exists():
        print("No results yet.")
        return

    lines = RESULTS_FILE.read_text().strip().split("\n")
    if len(lines) <= 1:
        print("No results yet.")
        return

    total = len(lines) - 1  # minus header
    found = sum(1 for l in lines[1:] if "\tYES\t" in l)
    missed = total - found

    print(f"\n=== EDC Benchmark Summary ===")
    print(f"Total CVEs tested: {total}")
    print(f"Found: {found}")
    print(f"Missed: {missed}")
    print(f"Recall: {found/total:.1%}" if total > 0 else "Recall: N/A")

    # Per-category breakdown
    categories = {}
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) >= 5:
            cat = parts[2]
            was_found = parts[4] == "YES"
            if cat not in categories:
                categories[cat] = {"found": 0, "total": 0}
            categories[cat]["total"] += 1
            if was_found:
                categories[cat]["found"] += 1

    if categories:
        print(f"\nPer-category:")
        for cat, stats in sorted(categories.items()):
            print(f"  {cat}: {stats['found']}/{stats['total']}")


def main():
    parser = argparse.ArgumentParser(description="EDC Benchmark Scorer")
    parser.add_argument("--issues", help="Path to issues.md file")
    parser.add_argument("--cve", help="CVE ID")
    parser.add_argument("--bug-pattern", help="Expected bug pattern description")
    parser.add_argument("--category", help="Bug category")
    parser.add_argument("--severity", help="Bug severity")
    parser.add_argument("--affected-files", help="Comma-separated affected files")
    parser.add_argument("--duration", type=int, default=0, help="Analysis duration in seconds")
    parser.add_argument("--summary", action="store_true", help="Print results summary")
    args = parser.parse_args()

    if args.summary:
        print_summary()
        return

    if not all([args.issues, args.cve, args.bug_pattern, args.category]):
        parser.error("--issues, --cve, --bug-pattern, and --category are required")

    issues_text = load_issues(args.issues)
    found, confidence, notes = score_issues(
        issues_text, args.cve, args.bug_pattern,
        args.category, args.affected_files or ""
    )

    append_result(
        args.cve, args.category, args.severity or "unknown",
        found, confidence, args.duration, notes
    )


if __name__ == "__main__":
    main()
