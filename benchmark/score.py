#!/usr/bin/env python3
"""
EDC Benchmark Scorer

Two-phase scoring:
1. Fast keyword pre-filter (cheap, catches obvious misses)
2. LLM-as-judge for exact match verification (accurate, only runs on candidates)

Usage:
    python3 score.py --issues edc-context/reports/issues.md --cve CVE-2023-38545 \
        --bug-pattern "hostname length check bypassed" --category heap-buffer-overflow \
        --severity critical --affected-files lib/socks.c \
        --description "SOCKS5 heap buffer overflow when hostname too long for remote resolve"

    python3 score.py --summary  # Print summary of all results
    python3 score.py --rescore  # Re-run LLM judge on all existing results
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

RESULTS_FILE = Path(os.environ.get("EDC_RESULTS_FILE", Path(__file__).parent / "results.tsv"))
KEYWORD_THRESHOLD = 0.3  # minimum keyword score to trigger LLM judge

# Patterns indicating the judge refused or returned safety boilerplate instead
# of a verdict. When matched, the verdict is `judge_error` with reason
# `refusal`. We do NOT retry and do NOT fall back to keyword-only — the row
# is surfaced for human re-judging via `rejudge.py` after the run.
REFUSAL_PATTERNS = [
    r"\bI can'?t (?:help|assist|provide|do that|with this)\b",
    r"\bI cannot (?:help|assist|provide|comply)\b",
    r"\bI'?m (?:not able|unable) to (?:help|assist|provide)\b",
    r"\bI (?:will|won'?t) not (?:help|assist|provide)\b",
    r"\b(?:against|violates) (?:my|the) (?:safety|content|usage) (?:policy|policies|guidelines)\b",
    r"\b(?:harmful|malicious) (?:content|request|activity)\b",
    r"\bI apologize, but\b.*\b(?:cannot|can'?t|unable)\b",
    # Anthropic API server-side policy block (returned with rc!=0 and the
    # "is_error":true envelope; we treat it as a first-class refusal).
    r"unable to respond to this request, which appears to violate our Usage Policy",
    r"\bAPI Error: Claude Code is unable to respond\b",
]
REFUSAL_RE = re.compile("|".join(REFUSAL_PATTERNS), re.IGNORECASE)

# Verdict strings. `judge_error` is first-class — it means the automated
# scorer could not produce a verdict and a human must resolve it via
# `rejudge.py`. It is NOT counted as `missed` and NOT counted as a hit.
VALID_VERDICTS = ("exact", "partial", "missed", "judge_error")
# Default judge: opus. Sonnet was the prior default but exhibited substantial
# verdict variance and outright hallucinations (“no mention of <affected_file>”
# when the file was clearly present in the analysis output). Opus is slower and
# costlier per call but more consistent. Override with EDC_JUDGE_MODEL=sonnet
# (or any slug) when running large sweeps where cost dominates.
LLM_JUDGE_MODEL = os.environ.get("EDC_JUDGE_MODEL", "opus")

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
        "double free", "double-free", "freed twice"
    ],
    "out-of-bounds-read": [
        "out of bounds read", "oob read", "buffer over-read", "overread",
        "read past", "read beyond", "buffer read"
    ],
    "out-of-bounds-write": [
        "out of bounds write", "oob write", "integer overflow",
        "write past", "write beyond"
    ],
    "credential-leak": [
        "credential", "leak", "auth", "token", "password", "bearer", "cookie"
    ],
    "protocol-injection": [
        "inject", "starttls", "pipeline", "mitm", "man in the middle"
    ],
    "local-file-overwrite": [
        "overwrite", "local file", "path traversal", "directory traversal"
    ],
    "stack-overflow": [
        "stack overflow", "recursion", "unbounded recursion", "infinite recursion",
        "recursive", "stack exhaustion"
    ],
    "validation-bypass": [
        "bypass", "validation", "psl", "public suffix"
    ],
}

# Explicit regular expressions complement literal category keywords. Keeping
# them separate prevents regex-looking prose from being treated as a literal.
CATEGORY_REGEX = {
    "double-free": [r"\bfree\b.*\bfree\b"],
    "out-of-bounds-write": [r"overflow.*write"],
    "credential-leak": [r"redirect.*auth", r"auth.*redirect"],
    "protocol-injection": [r"response.*before.*tls", r"tls.*upgrade"],
    "local-file-overwrite": [r"file.*overwrite"],
    "validation-bypass": [r"check.*skip", r"skip.*check", r"case.*insensitive"],
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
    files = [f.strip() for f in affected_files.split(",") if f.strip()]
    if any(os.path.basename(f).lower() in issues_lower for f in files):
        score += 0.15
        notes.append("file_mentioned")

    # Check category keywords
    cat_keywords = []
    cat_regexes = []
    for subcat in category.split(","):
        subcat = subcat.strip()
        cat_keywords.extend(CATEGORY_KEYWORDS.get(subcat, []))
        cat_regexes.extend(CATEGORY_REGEX.get(subcat, []))
    cat_keywords = list(set(cat_keywords))
    cat_regexes = list(set(cat_regexes))

    literal_matches = sum(1 for keyword in cat_keywords if keyword in issues_lower)
    regex_matches = sum(1 for pattern in cat_regexes if re.search(pattern, issues_lower))
    cat_matches = literal_matches + regex_matches
    cat_pattern_count = len(cat_keywords) + len(cat_regexes)
    if cat_matches > 0:
        score += min(cat_matches / max(cat_pattern_count, 1) * 0.25, 0.25)
        notes.append(f"cat={cat_matches}/{cat_pattern_count}")

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

    The prompt is evidence-first: the judge must locate any text mentioning the
    affected files, quote it verbatim, then reason about whether the quoted
    text describes the same root cause as the known bug. This drastically
    reduces hallucinations of the form “the analysis never mentions X” when
    X is clearly present.
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
<<<ANALYSIS_START>>>
{issues_text}
<<<ANALYSIS_END>>>

EVIDENCE-FIRST METHODOLOGY (mandatory):

Step 1 — LOCATE. Search the analysis between <<<ANALYSIS_START>>> and <<<ANALYSIS_END>>> for any mention of these files: {affected_files}. Look for the bare filename, full path, or basename (e.g. for `lib/socks.c` also check `socks.c`).

Step 2 — QUOTE. For each match found, copy the relevant 1-3 sentences VERBATIM into your reasoning. Do not paraphrase. If NO match exists at all, write `NOT_FOUND` and skip to step 4 with verdict "missed".

Step 3 — COMPARE. Given the quoted text:
  - Does it describe the SAME root cause as the bug pattern above? → "exact"
  - Does it describe a DIFFERENT bug in the SAME code area? → "partial"
  - Does it merely mention the file/function without describing the bug? → "missed"

A "different root cause in the same area" example: bug pattern says "state variable corrupted during slow handshake bypasses 255-byte check"; analysis says "the cast `(char)hostname_len` truncates silently". Same file, same line area, but a different mechanism — that is "partial", not "missed".

Step 4 — VERDICT. Output the final JSON.

RESPONSE FORMAT (strict):
```
LOCATE: <one line: "found N matches" or "NOT_FOUND">
QUOTE: <verbatim 1-3 sentences from the analysis, or "NOT_FOUND">
COMPARE: <one sentence explaining the relationship between the quoted text and the bug pattern>
VERDICT_JSON: {{"verdict": "exact"|"partial"|"missed", "confidence": 0.0-1.0, "explanation": "one sentence why"}}
```

IMPORTANT: VERDICT_JSON must be a single JSON object on one line. The `explanation` field should reference what you quoted (e.g. "quoted text describes X, which matches the bug pattern's Y"), not make general claims about what the analysis did or didn't contain."""

    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--model", LLM_JUDGE_MODEL, "--output-format", "json"],
            capture_output=True, text=True, timeout=180,
            stdin=subprocess.DEVNULL
        )

        if result.returncode != 0:
            err = (result.stderr or "").strip() or (result.stdout or "").strip()
            # Anthropic returns usage-policy refusals with rc!=0 and the
            # refusal text inside the stdout JSON envelope. Detect that
            # before falling back to generic process_fail.
            if REFUSAL_RE.search(err):
                return ("judge_error", 0.0,
                        f"reason=refusal; rc={result.returncode}; out={err[:300]}")
            return ("judge_error", 0.0,
                    f"reason=process_fail; rc={result.returncode}; out={err[:300]}")

        output = result.stdout.strip()

        # Try to parse JSON from output
        # claude --output-format json wraps in {"type":"result","result":"..."}
        try:
            wrapper = json.loads(output)
            if isinstance(wrapper, dict) and "result" in wrapper:
                output = wrapper["result"]
        except json.JSONDecodeError:
            pass

        # Refusal detection. If the judge returned safety boilerplate instead
        # of a verdict, that's a `judge_error` with reason=refusal. Human
        # resolves via `rejudge.py` after the run — no silent retry, no
        # silent fallback.
        if REFUSAL_RE.search(output):
            return "judge_error", 0.0, f"reason=refusal; output={output[:300]}"

        # Extract VERDICT_JSON from the structured response. The new prompt
        # asks the judge to emit a labeled section, so look for that first;
        # fall back to any verdict-shaped JSON for back-compat with older runs.
        verdict_match = re.search(r'VERDICT_JSON:\s*(\{[^{}]*"verdict"[^{}]*\})', output)
        json_match = verdict_match or re.search(r'\{[^{}]*"verdict"[^{}]*\}', output)
        if not json_match:
            return "judge_error", 0.0, f"reason=parse_fail; output={output[:300]}"

        try:
            parsed = json.loads(json_match.group(1) if verdict_match else json_match.group())
        except json.JSONDecodeError as e:
            return "judge_error", 0.0, f"reason=json_decode; err={e}; output={output[:300]}"

        verdict = parsed.get("verdict", "")
        if verdict not in ("exact", "partial", "missed"):
            return "judge_error", 0.0, f"reason=bad_verdict; verdict={verdict!r}; output={output[:300]}"

        # The plan requires a verbatim QUOTE from the analysis (or explicit
        # NOT_FOUND). Verdicts without one are not trustworthy.
        extracted = _extract_judge_steps(output)
        if "quote=" not in extracted:
            return "judge_error", 0.0, f"reason=missing_quote; output={output[:300]}"

        explanation = parsed.get("explanation", "no explanation")
        return (
            verdict,
            float(parsed.get("confidence", 0.0)),
            f"{explanation} | {extracted}",
        )

    except subprocess.TimeoutExpired:
        return "judge_error", 0.0, "reason=timeout"
    except Exception as e:
        return "judge_error", 0.0, f"reason=exception; err={str(e)[:200]}"


def _extract_judge_steps(output: str) -> str:
    """Pull the LOCATE/QUOTE/COMPARE lines out of the judge response for
    inclusion in the result notes. Best-effort; returns ‘’ if nothing matches."""
    parts = []
    for label in ("LOCATE", "QUOTE", "COMPARE"):
        m = re.search(rf'{label}:\s*(.+?)(?:\n[A-Z_]+:|\Z)', output, re.DOTALL)
        if m:
            txt = m.group(1).strip().replace("\n", " ")
            # Cap each section so the TSV stays readable.
            if len(txt) > 200:
                txt = txt[:200] + "…"
            parts.append(f"{label.lower()}={txt}")
    return " | ".join(parts)


def score_cve(issues_text: str, cve_id: str, bug_pattern: str,
              category: str, description: str, affected_files: str,
              skip_judge: bool = False) -> tuple[str, float, str]:
    """
    Full two-phase scoring.

    Returns: (verdict, confidence, notes) where verdict is one of
    `exact`, `partial`, `missed`, `judge_error`.

    Failure modes are NEVER silently coerced into `missed`. If the judge
    refuses, times out, or returns unparseable output, the verdict is
    `judge_error` with a `reason=<class>` tag in `notes`. A human resolves
    `judge_error` rows post-run via `rejudge.py`.
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

    # Phase 2: LLM judge. Any failure surfaces as judge_error — no fallback,
    # no retry. The plan explicitly forbids silent coercion.
    verdict, confidence, explanation = llm_judge(
        issues_text, cve_id, bug_pattern, category, description, affected_files
    )

    if verdict == "judge_error":
        return "judge_error", 0.0, f"judge_error({explanation}); keywords({kw_notes})"

    return verdict, confidence, f"judge: {explanation}; keywords({kw_notes})"


def append_result(cve_id: str, category: str, severity: str,
                  verdict: str, confidence: float, duration: int, notes: str,
                  build_verdict: str = "", build_confidence: float = 0.0,
                  combined_score: float = -1.0, build_notes: str = ""):
    """Append a result to the TSV file.

    The trailing four arguments form the dual-phase scoring extension. When a
    build-phase verdict is supplied the row records both phases plus the
    combined-score weighting; legacy single-phase callers leave them empty and
    the row preserves the original 8-column layout for back-compat readers.
    """
    timestamp = datetime.now().isoformat(timespec="seconds")

    # Header. Always write the extended 12-column header for new files.
    # Old TSVs created before this change will keep their 8-column layout; the
    # new columns are appended cleanly when older rows are mixed with newer.
    if not RESULTS_FILE.exists() or RESULTS_FILE.stat().st_size == 0:
        with open(RESULTS_FILE, "w") as f:
            f.write(
                "timestamp\tcve\tcategory\tseverity\t"
                "verdict\tconfidence\tduration\tnotes\t"
                "build_verdict\tbuild_confidence\tcombined_score\tbuild_notes\n"
            )

    # combined_score = -1 sentinel means "single-phase row, use verdict mapping".
    # judge_error is excluded from aggregates and gets a sentinel score of -1.0
    # so downstream readers can filter it out.
    if combined_score < 0:
        if verdict == "judge_error":
            combined_score = -1.0
        else:
            combined_score = {"exact": 1.0, "partial": 0.5, "missed": 0.0}.get(verdict, 0.0)

    line = (
        f"{timestamp}\t{cve_id}\t{category}\t{severity}\t"
        f"{verdict}\t{confidence}\t{duration}\t{notes}\t"
        f"{build_verdict}\t{build_confidence}\t{combined_score}\t{build_notes}\n"
    )
    with open(RESULTS_FILE, "a") as f:
        f.write(line)

    icon = {"exact": "HIT", "partial": "PARTIAL", "missed": "MISS",
            "judge_error": "JUDGE_ERR"}.get(verdict, "???")
    if build_verdict:
        print(f"    [{icon}] {cve_id} review={verdict} build={build_verdict} combined={combined_score:.2f} — {notes}")
    else:
        print(f"    [{icon}] {cve_id} ({verdict}, confidence={confidence}) — {notes}")


def print_summary():
    """Print summary of all results."""
    if not RESULTS_FILE.exists():
        print("No results yet.")
        return

    with open(RESULTS_FILE, newline="") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if not rows:
        print("No results yet.")
        return

    total = len(rows)
    verdicts = [(row.get("verdict") or row.get("found") or "") for row in rows]
    exact = sum(1 for verdict in verdicts if verdict == "exact")
    partial = sum(1 for verdict in verdicts if verdict == "partial")
    missed = sum(1 for verdict in verdicts if verdict == "missed")
    judge_errors = sum(1 for verdict in verdicts if verdict == "judge_error")
    other = total - exact - partial - missed - judge_errors

    # judge_error rows are excluded from recall — they need human resolution.
    scored = exact + partial + missed

    print(f"\n=== EDC Benchmark Summary ===")
    print(f"Total CVEs tested: {total}")
    print(f"Scored (auto):     {scored}/{total}")
    print(f"Exact match:  {exact}")
    print(f"Partial:      {partial}")
    print(f"Missed:       {missed}")
    if judge_errors:
        print(f"Judge error:  {judge_errors}  ← run `rejudge.py` to resolve")
    if other:
        print(f"Other:        {other}")
    if scored > 0:
        print(f"Recall (exact, scored only):         {exact/scored:.1%}")
        print(f"Recall (exact+partial, scored only): {(exact+partial)/scored:.1%}")

    # Per-category
    categories: dict[str, dict] = {}
    for row, verdict in zip(rows, verdicts):
        cat = row.get("category")
        if cat:
            if cat not in categories:
                categories[cat] = {"exact": 0, "partial": 0, "missed": 0, "total": 0}
            categories[cat]["total"] += 1
            if verdict in ("exact", "partial", "missed"):
                categories[cat][verdict] += 1

    if categories:
        print(f"\nPer-category:")
        for cat, s in sorted(categories.items()):
            print(f"  {cat}: {s['exact']}e/{s['partial']}p/{s['missed']}m (total {s['total']})")


# Dual-phase scoring matrix. Detects when the build phase pre-identifies a CVE
# and weights the row accordingly so a leak from build into review's reading
# context doesn't masquerade as a review win. See: combine_scores().
# Source-of-truth: discussed and agreed in STATUS.md → "dual-phase scoring".
COMBINED_MATRIX = {
    ("exact",   "exact"):   0.5,   # build leaked the answer, review echoed
    ("exact",   "partial"): 0.5,
    ("exact",   "missed"):  0.5,   # build saw it, review didn't pick up
    ("partial", "exact"):   0.75,  # build hinted at area, review nailed it
    ("partial", "partial"): 0.4,
    ("partial", "missed"):  0.25,
    ("missed",  "exact"):   1.0,   # pure review win, strongest signal
    ("missed",  "partial"): 0.5,
    ("missed",  "missed"):  0.0,
}


def combine_scores(build_verdict: str, review_verdict: str) -> float:
    """Apply the dual-phase scoring matrix. Returns -1.0 sentinel when either
    phase is `judge_error` so the row can be filtered out of aggregates.
    Falls back to the review-only mapping when build_verdict is empty."""
    if "judge_error" in (build_verdict, review_verdict):
        return -1.0
    if not build_verdict:
        return {"exact": 1.0, "partial": 0.5, "missed": 0.0}.get(review_verdict, 0.0)
    key = (build_verdict, review_verdict)
    if key in COMBINED_MATRIX:
        return COMBINED_MATRIX[key]
    return {"exact": 1.0, "partial": 0.5, "missed": 0.0}.get(review_verdict, 0.0)


def main():
    parser = argparse.ArgumentParser(description="EDC Benchmark Scorer")
    parser.add_argument("--issues", help="Path to issues.md file (review phase output)")
    parser.add_argument("--build-issues",
                        help="Optional path to build-phase issues.md snapshot. When supplied, "
                             "the scorer judges both phases and writes a combined row.")
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

    build_verdict = ""
    build_confidence = 0.0
    build_notes = ""
    combined = -1.0

    if args.build_issues:
        build_text = load_issues(args.build_issues)
        if build_text:
            build_verdict, build_confidence, build_notes = score_cve(
                build_text, args.cve, args.bug_pattern,
                args.category, args.description or args.bug_pattern,
                args.affected_files or "",
                skip_judge=args.skip_judge,
            )
        else:
            # Build snapshot missing or empty — treat as build_verdict=missed
            # rather than erroring. Empty notes signal "no build report present".
            build_verdict = "missed"
            build_confidence = 0.0
            build_notes = "build snapshot empty or missing"
        combined = combine_scores(build_verdict, verdict)

    append_result(
        args.cve, args.category, args.severity or "unknown",
        verdict, confidence, args.duration, notes,
        build_verdict=build_verdict,
        build_confidence=build_confidence,
        combined_score=combined,
        build_notes=build_notes,
    )


if __name__ == "__main__":
    main()
