#!/usr/bin/env python3
"""Blocked-run detection for the clean benchmark (plan 041).

Structured first: `claude -p --output-format stream-json` call logs captured
by `clean-bin/claude`. A call is blocked when an assistant message or the
result event has stop_reason "refusal", or the result event carries a
safeguard/policy block text (api error or the soft "safety classifier
stopped the response" shape). The generic passive phrase ("blocked by the
safety system") also counts, but only in an `is_error` result: reports use
the same words for the code's own checks. Text logs (arm stdout/stderr, which
carry report prose) are matched against the exact block texts only; score.py's broad
REFUSAL_RE (which also matches ordinary security prose such as "malicious
request") is consulted only when no structured call log exists.
"""

import json
import re
from pathlib import Path

# Block texts observed from the API / Claude Code, not model prose about bugs.
BLOCK_PATTERNS = [
    r"safeguards flagged",
    r"real-time-cyber-safeguards",
    r"Details:\s*`?\[cyber\]",
    r"violates? (?:our|the) Usage Policy",
    r"API Error: Claude Code is unable to respond",
    r"safety classifier (?:stopped|blocked|flagged|interrupted)",
]
BLOCK_RE = re.compile("|".join(BLOCK_PATTERNS), re.IGNORECASE)
# Matches report prose ("stopped by the safety check at line 672"): error results only.
ERROR_BLOCK_RE = re.compile("|".join(
    [*BLOCK_PATTERNS, r"(?:blocked|stopped|flagged) by (?:a |the )?safety (?:classifier|check|system|filter)"]),
    re.IGNORECASE)


def _events(path: Path):
    try:
        lines = Path(path).read_text(errors="replace").splitlines()
    except OSError:
        return
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            yield event


def _structured_signal(path: Path) -> str:
    for event in _events(path):
        kind = event.get("type")
        if kind == "assistant":
            message = event.get("message") or {}
            if message.get("stop_reason") == "refusal":
                return "json:assistant_stop_reason=refusal"
        elif kind == "result":
            if event.get("stop_reason") == "refusal":
                return "json:result_stop_reason=refusal"
            text = str(event.get("result") or "")
            match = (ERROR_BLOCK_RE if event.get("is_error") else BLOCK_RE).search(text)
            if match:
                prefix = "result_error" if event.get("is_error") else "result_text"
                return f"json:{prefix}={match.group(0)}"
    return ""


def result_text(path: Path) -> str:
    """Text of the last result event in a stream-json log ('' if none)."""
    text = ""
    for event in _events(path):
        if event.get("type") == "result":
            text = str(event.get("result") or "")
    return text


def detect_blocked(call_logs, text_logs) -> tuple[bool, str]:
    call_logs = [Path(p) for p in call_logs]
    for path in call_logs:
        signal = _structured_signal(path)
        if signal:
            return True, signal
    texts = []
    for path in text_logs:
        try:
            texts.append(Path(path).read_text(errors="replace"))
        except OSError:
            continue
    for text in texts:
        match = BLOCK_RE.search(text)
        if match:
            return True, f"text:{match.group(0)}"
    if not call_logs:
        from score import REFUSAL_RE  # fallback only; broad on purpose
        for text in texts:
            match = REFUSAL_RE.search(text)
            if match:
                return True, f"text:refusal_re={match.group(0)}"
    return False, ""
