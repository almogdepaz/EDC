"""Small benchmark scoring helpers shared by benchmark consumers."""

RESOLVED_VERDICT_SCORES = {
    "exact": 1.0,
    "partial": 0.5,
    "missed": 0.0,
    # Legacy infrastructure failure value: keep as a deliberate miss for compatibility.
    "error": 0.0,
}


class UnresolvedVerdictError(ValueError):
    """Raised when a persisted benchmark verdict is not safe to score."""


def verdict_to_score(verdict, *, context: str) -> float:
    normalized = (verdict or "").strip()
    if normalized in RESOLVED_VERDICT_SCORES:
        return RESOLVED_VERDICT_SCORES[normalized]
    label = normalized or "<empty>"
    raise UnresolvedVerdictError(f"unresolved benchmark verdict {label!r} in {context}")
