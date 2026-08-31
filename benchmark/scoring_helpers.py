"""Small benchmark scoring helpers shared by benchmark consumers."""

import math

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

COMBINED_SCORE_MATRIX = {
    ("exact", "exact"): 0.5,
    ("exact", "partial"): 0.5,
    ("exact", "missed"): 0.5,
    ("partial", "exact"): 0.75,
    ("partial", "partial"): 0.4,
    ("partial", "missed"): 0.25,
    ("missed", "exact"): 1.0,
    ("missed", "partial"): 0.5,
    ("missed", "missed"): 0.0,
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


def combine_scores(build_verdict: str, review_value: str, *, context: str = "combined score") -> float:
    """Derive a resolved single- or dual-phase score."""
    review = (review_value or "").strip()
    build = (build_verdict or "").strip()
    if "judge_error" in (build, review):
        return -1.0
    review_score = verdict_to_score(review, context=f"{context} review phase")
    if not build:
        return review_score
    verdict_to_score(build, context=f"{context} build phase")
    return COMBINED_SCORE_MATRIX.get((build, review), review_score)


def result_row_score(row, *, context: str) -> float:
    """Validate a persisted result row and return its canonical score."""
    build_verdict = (row.get("build_verdict") or "").strip()
    review_value = review_verdict(row)
    verdict_to_score(review_value, context=f"{context} review phase")
    if build_verdict:
        verdict_to_score(build_verdict, context=f"{context} build phase")
    derived_score = combine_scores(build_verdict, review_value, context=context)
    stored_score = (row.get("combined_score") or "").strip()
    if not stored_score:
        return derived_score
    try:
        parsed_score = float(stored_score)
    except ValueError as error:
        raise UnresolvedVerdictError(f"invalid combined score {stored_score!r} in {context}") from error
    if not math.isfinite(parsed_score) or parsed_score < 0:
        raise UnresolvedVerdictError(f"invalid combined score {stored_score!r} in {context}")
    if not math.isclose(parsed_score, derived_score, rel_tol=0.0, abs_tol=1e-9):
        raise UnresolvedVerdictError(
            f"stale combined score {stored_score!r} in {context}; expected {derived_score}"
        )
    return parsed_score
