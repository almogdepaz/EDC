#!/usr/bin/env python3
"""
EDC Benchmark Scorer

Two-phase scoring:
1. Fast keyword pre-filter (cheap, catches obvious misses)
2. LLM-as-judge for exact match verification (accurate, only runs on candidates)

Usage:
    python3 score.py --issues .context/issues.md --cve CVE-2023-38545 \
        --bug-pattern "hostname length check bypassed" --category heap-buffer-overflow \
        --severity critical --affected-files lib/socks.c \
        --description "SOCKS5 heap buffer overflow when hostname too long for remote resolve"

    python3 score.py --summary  # Print summary of all results
    python3 score.py --rescore  # Re-run LLM judge on all existing results
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

RESULTS_FILE = Path(os.environ.get("EDC_RESULTS_FILE", Path(__file__).parent / "results.tsv"))
KEYWORD_THRESHOLD = 0.3  # minimum keyword score to trigger LLM judge
LLM_JUDGE_MODEL = os.environ.get("EDC_JUDGE_MODEL", "sonnet")

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
    return path.read_text(encoding="utf-8", errors="replace")


def extract_bug_keywords(bug_pattern: str) -> list[str]:
    """Extract meaningful keywords from the bug pattern description."""
    stop_words = {
        "the", "a", "an", "in", "on", "at", "to", "for", "of", "with",
        "is", "are", "was", "were", "be", "been", "being", "not", "no",
        "and", "or", "but", "when", "during", "after", "before", "via",
        "that", "this", "from", "by"
    }
    words = re.split(r'[,\s]+', bug_pattern.lower())
    return [w for w in words if len(w) > 2 and w not in stop_words]


def keyword_score(issues_text: str, bug_pattern: str,
                  category: str, affected_files: str) -> tuple[float, str]:
    """
    Phase 1: Fast keyword pre-filter.
    Returns (score 0-1, notes string).
    """
    issues_lower = issues_text.lower()
    notes = []
    score = 0.0

    # Check affected file mentioned
    files = [f.strip() for f in affected_files.split(",")]
    if any(os.path.basename(f).lower() in issues_lower for f in files):
        score += 0.15
        notes.append("file_mentioned")

    # Check category keywords
    cat_keywords = []
    for subcat in category.split(","):
        subcat = subcat.strip()
        cat_keywords.extend(CATEGORY_KEYWORDS.get(subcat, []))
    cat_keywords = list(set(cat_keywords))

    cat_matches = sum(1 for kw in cat_keywords if kw in issues_lower)
    if cat_matches > 0:
        score += min(cat_matches / max(len(cat_keywords), 1) * 0.25, 0.25)
        notes.append(f"cat={cat_matches}/{len(cat_keywords)}")

    # Check bug pattern keywords
    pattern_keywords = extract_bug_keywords(bug_pattern)
    pattern_matches = sum(1 for kw in pattern_keywords if kw in issues_lower)
    if pattern_matches > 0:
        score += min(pattern_matches / max(len(pattern_keywords), 1) * 0.35, 0.35)
        notes.append(f"pat={pattern_matches}/{len(pattern_keywords)}")

    return round(score, 3), "; ".join(notes)


def llm_judge(issues_text: str, cve_id: str, bug_pattern: str,
              category: str, description: str, affected_files: str) -> tuple[str, float, str]:
    """
    Phase 2: LLM-as-judge for exact match verification.

    Returns: (verdict: "exact"|"partial"|"missed", confidence: 0-1, explanation: str)
    """
    # Truncate issues to avoid token limits
    max_chars = 8000
    if len(issues_text) > max_chars:
        issues_text = issues_text[:max_chars] + "\n... (truncated)"

    prompt = f"""You are a security vulnerability matching judge. Your job is to determine if an automated code analysis found a SPECIFIC known vulnerability.

KNOWN VULNERABILITY:
- CVE: {cve_id}
- Category: {category}
- Affected files: {affected_files}
- Description: {description}
- Bug pattern: {bug_pattern}

ANALYSIS OUTPUT (findings from automated tool):
{issues_text}

TASK: Did the analysis find the SPECIFIC vulnerability described above?

Rules:
- "exact" = the analysis describes the same root cause bug, even if using different words
- "partial" = the analysis found a related issue in the same code area but NOT the specific root cause
- "missed" = the analysis did not find this vulnerability or anything closely related

Respond with ONLY a JSON object, no other text:
{{"verdict": "exact"|"partial"|"missed", "confidence": 0.0-1.0, "explanation": "one sentence why"}}"""

    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--model", LLM_JUDGE_MODEL, "--output-format", "json"],
            capture_output=True, text=True, timeout=60
        )

        if result.returncode != 0:
            return "error", 0.0, f"claude failed: {result.stderr[:200]}"

        output = result.stdout.strip()

        # Try to parse JSON from output
        # claude --output-format json wraps in {"type":"result","result":"..."}
        try:
            wrapper = json.loads(output)
            if isinstance(wrapper, dict) and "result" in wrapper:
                output = wrapper["result"]
        except json.JSONDecodeError:
            pass

        # Extract JSON from the response (might have markdown or extra text)
        json_match = re.search(r'\{[^{}]*"verdict"[^{}]*\}', output)
        if json_match:
            parsed = json.loads(json_match.group())
            return (
                parsed.get("verdict", "error"),
                float(parsed.get("confidence", 0.0)),
                parsed.get("explanation", "no explanation")
            )

        return "error", 0.0, f"could not parse judge response: {output[:200]}"

    except subprocess.TimeoutExpired:
        return "error", 0.0, "judge timed out"
    except Exception as e:
        return "error", 0.0, f"judge error: {str(e)[:200]}"


def score_cve(issues_text: str, cve_id: str, bug_pattern: str,
              category: str, description: str, affected_files: str,
              skip_judge: bool = False) -> tuple[str, float, str]:
    """
    Full two-phase scoring.

    Returns: (verdict: "exact"|"partial"|"missed"|"error", confidence: 0-1, notes: str)
    """
    if not issues_text:
        return "missed", 0.0, "no issues file"

    # Phase 1: keyword pre-filter
    kw_score, kw_notes = keyword_score(issues_text, bug_pattern, category, affected_files)

    if kw_score < KEYWORD_THRESHOLD:
        return "missed", kw_score, f"keyword_filter({kw_notes})"

    if skip_judge:
        # Keyword-only mode
        found = kw_score >= 0.4
        verdict = "exact" if found else "missed"
        return verdict, kw_score, f"keyword_only({kw_notes})"

    # Phase 2: LLM judge
    verdict, confidence, explanation = llm_judge(
        issues_text, cve_id, bug_pattern, category, description, affected_files
    )

    if verdict == "error":
        # Fall back to keyword score
        found = kw_score >= 0.4
        fallback_verdict = "exact" if found else "missed"
        return fallback_verdict, kw_score, f"judge_error({explanation}); fallback({kw_notes})"

    return verdict, confidence, f"judge: {explanation}; keywords({kw_notes})"


def append_result(cve_id: str, category: str, severity: str,
                  verdict: str, confidence: float, duration: int, notes: str):
    """Append a result to the TSV file."""
    timestamp = datetime.now().isoformat(timespec="seconds")

    # Write header if file is new
    if not RESULTS_FILE.exists() or RESULTS_FILE.stat().st_size == 0:
        with open(RESULTS_FILE, "w") as f:
            f.write("timestamp\tcve\tcategory\tseverity\tverdict\tconfidence\tduration\tnotes\n")

    line = f"{timestamp}\t{cve_id}\t{category}\t{severity}\t{verdict}\t{confidence}\t{duration}\t{notes}\n"
    with open(RESULTS_FILE, "a") as f:
        f.write(line)

    icon = {"exact": "HIT", "partial": "PARTIAL", "missed": "MISS", "error": "ERR"}.get(verdict, "???")
    print(f"    [{icon}] {cve_id} ({verdict}, confidence={confidence}) — {notes}")


def print_summary():
    """Print summary of all results."""
    if not RESULTS_FILE.exists():
        print("No results yet.")
        return

    lines = RESULTS_FILE.read_text().strip().split("\n")
    if len(lines) <= 1:
        print("No results yet.")
        return

    total = len(lines) - 1
    exact = sum(1 for l in lines[1:] if "\texact\t" in l)
    partial = sum(1 for l in lines[1:] if "\tpartial\t" in l)
    missed = sum(1 for l in lines[1:] if "\tmissed\t" in l)
    errors = total - exact - partial - missed

    print(f"\n=== EDC Benchmark Summary ===")
    print(f"Total CVEs tested: {total}")
    print(f"Exact match:  {exact}")
    print(f"Partial:      {partial}")
    print(f"Missed:       {missed}")
    if errors:
        print(f"Errors:       {errors}")
    print(f"Recall (exact):          {exact/total:.1%}" if total > 0 else "")
    print(f"Recall (exact+partial):  {(exact+partial)/total:.1%}" if total > 0 else "")

    # Per-category
    categories: dict[str, dict] = {}
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) >= 5:
            cat = parts[2]
            v = parts[4]
            if cat not in categories:
                categories[cat] = {"exact": 0, "partial": 0, "missed": 0, "total": 0}
            categories[cat]["total"] += 1
            if v in ("exact", "partial", "missed"):
                categories[cat][v] += 1

    if categories:
        print(f"\nPer-category:")
        for cat, s in sorted(categories.items()):
            print(f"  {cat}: {s['exact']}e/{s['partial']}p/{s['missed']}m (total {s['total']})")


def main():
    parser = argparse.ArgumentParser(description="EDC Benchmark Scorer")
    parser.add_argument("--issues", help="Path to issues.md file")
    parser.add_argument("--cve", help="CVE ID")
    parser.add_argument("--bug-pattern", help="Expected bug pattern description")
    parser.add_argument("--category", help="Bug category")
    parser.add_argument("--severity", help="Bug severity")
    parser.add_argument("--description", help="Full CVE description for LLM judge")
    parser.add_argument("--affected-files", help="Comma-separated affected files")
    parser.add_argument("--duration", type=int, default=0, help="Analysis duration in seconds")
    parser.add_argument("--skip-judge", action="store_true", help="Skip LLM judge, keyword-only")
    parser.add_argument("--summary", action="store_true", help="Print results summary")
    args = parser.parse_args()

    if args.summary:
        print_summary()
        return

    if not all([args.issues, args.cve, args.bug_pattern, args.category]):
        parser.error("--issues, --cve, --bug-pattern, and --category are required")

    issues_text = load_issues(args.issues)
    verdict, confidence, notes = score_cve(
        issues_text, args.cve, args.bug_pattern,
        args.category, args.description or args.bug_pattern,
        args.affected_files or "",
        skip_judge=args.skip_judge
    )

    append_result(
        args.cve, args.category, args.severity or "unknown",
        verdict, confidence, args.duration, notes
    )


if __name__ == "__main__":
    main()
