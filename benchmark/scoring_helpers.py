"""Small benchmark scoring helpers shared by benchmark consumers."""

CANONICAL_REVIEW_VERDICT_FIELD = "verdict"
LEGACY_REVIEW_VERDICT_FIELD = "found"
CANONICAL_RESULT_FIELDS = (
    "timestamp",
    "cve",
    "category",
    "severity",
    CANONICAL_REVIEW_VERDICT_FIELD,
    "confidence",
    "duration",
    "notes",
    "build_verdict",
    "build_confidence",
    "combined_score",
    "build_notes",
)

RESOLVED_VERDICT_SCORES = {
    "exact": 1.0,
    "partial": 0.5,
    "missed": 0.0,
    # Legacy infrastructure failure value: keep as a deliberate miss for compatibility.
    "error": 0.0,
}


class UnresolvedVerdictError(ValueError):
    """Raised when a persisted benchmark verdict is not safe to score."""


def review_verdict(row) -> str:
    """Read the canonical review verdict with legacy `found` fallback."""
    return row.get(CANONICAL_REVIEW_VERDICT_FIELD) or row.get(LEGACY_REVIEW_VERDICT_FIELD) or ""


def review_verdict_field(fieldnames) -> str:
    """Select the existing review-verdict field without changing its schema."""
    fields = set(fieldnames)
    if CANONICAL_REVIEW_VERDICT_FIELD in fields:
        return CANONICAL_REVIEW_VERDICT_FIELD
    if LEGACY_REVIEW_VERDICT_FIELD in fields:
        return LEGACY_REVIEW_VERDICT_FIELD
    raise ValueError("result schema has no review verdict field ('verdict' or legacy 'found')")


def verdict_to_score(verdict, *, context: str) -> float:
    normalized = (verdict or "").strip()
    if normalized in RESOLVED_VERDICT_SCORES:
        return RESOLVED_VERDICT_SCORES[normalized]
    label = normalized or "<empty>"
    raise UnresolvedVerdictError(f"unresolved benchmark verdict {label!r} in {context}")
