"""
Shared helpers for locating and reconstructing analysis artifacts from
benchmark runs.

The regression harness writes `issues.md` into a per-CVE worktree under
`/private/tmp/edc-bench-regression/reviews/<sha>/<mode>/<label>/<repo>/<cve>/attempt-<n>/edc-context/reports/issues.md`,
then removes the worktree on success. The same content is also captured in
Claude Code's per-session jsonl transcripts under
`~/.claude/projects/<encoded-cwd>/*.jsonl`.

This module abstracts both lookups so `score.py`, `rejudge.py`, and
`audit.py` can find the analysis text regardless of which one survived.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Iterable

DEFAULT_BENCH_WORKDIR = Path("/private/tmp/edc-bench-regression")
DEFAULT_CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"


def _short_sha_from_tsv_path(tsv_path: Path) -> str | None:
    """Pull the 10-char SHA out of a path like
    benchmark/regression/results/<sha>/<mode>/<label>/<repo>/review-results.tsv.
    """
    parts = tsv_path.resolve().parts
    try:
        idx = parts.index("results")
    except ValueError:
        return None
    if idx + 1 < len(parts):
        candidate = parts[idx + 1]
        if re.fullmatch(r"[0-9a-f]{6,40}", candidate):
            return candidate
    return None


def _path_parts_from_tsv(tsv_path: Path) -> dict[str, str]:
    """Parse <sha>/<mode>/<label>/<repo> out of the canonical layout."""
    parts = tsv_path.resolve().parts
    try:
        idx = parts.index("results")
    except ValueError:
        return {}
    tail = parts[idx + 1:]
    # tail[-1] is the tsv filename. Anything before it is the path layout.
    # Layouts seen in the repo:
    #   <sha>/<mode>/<label>/<repo>/file.tsv      (4-deep)
    #   <sha>/<mode>/<repo>/file.tsv              (3-deep, label collapsed)
    #   <sha>/<repo>/file.tsv                     (2-deep, very old)
    keys = ["sha", "mode", "label", "repo"]
    body = list(tail[:-1])
    if len(body) == 2:
        body = [body[0], "v2", "haiku", body[1]]
    elif len(body) == 3:
        body = [body[0], body[1], body[1], body[2]]
    out: dict[str, str] = {}
    for k, v in zip(keys, body):
        out[k] = v
    return out


def _encode_cwd_for_claude_projects(abs_path: str) -> str:
    """Claude Code encodes the cwd as the project dir name by replacing
    `/` and `_` with `-` and prefixing with `-`. Matches the logic in
    `benchmark/regression/run-regression.sh`'s metrics-recovery helper.
    """
    s = abs_path.lstrip("/")
    s = re.sub(r"[/_]", "-", s)
    return "-" + s


def find_issues_for_row(row: dict, tsv_path: Path,
                        issues_root: Path | None,
                        phase: str) -> list[Path]:
    """Return candidate issues.md paths for a row, in priority order.

    Layout under EDC_REG_WORKDIR for the review phase:
        reviews/<sha>/<mode>/<label>/<repo>/<cve>/attempt-<n>/edc-context/reports/issues.md

    For the build phase:
        cache/<sha>/<mode>/<label>/<repo>/attempt-<n>/edc-context/reports/issues.md
    """
    parts = _path_parts_from_tsv(tsv_path)
    sha = parts.get("sha", "")
    mode = parts.get("mode", "")
    label = parts.get("label", "")
    repo = parts.get("repo", "")
    cve = row.get("cve", "")
    # The TSV has no explicit attempt column for review-results; runs we care
    # about so far are single-attempt. Search attempt-1..attempt-5 in order.
    attempts = [f"attempt-{i}" for i in range(1, 6)]

    base = issues_root if issues_root is not None else DEFAULT_BENCH_WORKDIR
    candidates: list[Path] = []
    if phase == "review":
        for attempt in attempts:
            candidates.append(
                base / "reviews" / sha / mode / label / repo / cve / attempt
                / "edc-context" / "reports" / "issues.md"
            )
            # Some older layouts placed it at edc-context/issues.md
            candidates.append(
                base / "reviews" / sha / mode / label / repo / cve / attempt
                / "edc-context" / "issues.md"
            )
    elif phase == "build":
        for attempt in attempts:
            candidates.append(
                base / "cache" / sha / mode / label / repo / attempt
                / "edc-context" / "reports" / "issues.md"
            )
    return candidates


def find_transcript_for_row(row: dict, tsv_path: Path,
                            projects_root: Path | None = None) -> Path | None:
    """Locate the Claude Code session jsonl for the review run that produced
    this row. Returns the project directory (which contains the jsonl files).
    """
    parts = _path_parts_from_tsv(tsv_path)
    sha = parts.get("sha", "")
    mode = parts.get("mode", "")
    label = parts.get("label", "")
    repo = parts.get("repo", "")
    cve = row.get("cve", "")

    root = projects_root if projects_root is not None else DEFAULT_CLAUDE_PROJECTS
    for attempt in [f"attempt-{i}" for i in range(1, 6)]:
        cwd = f"/private/tmp/edc-bench-regression/reviews/{sha}/{mode}/{label}/{repo}/{cve}/{attempt}"
        encoded = _encode_cwd_for_claude_projects(cwd)
        proj_dir = root / encoded
        if proj_dir.is_dir() and any(proj_dir.glob("*.jsonl")):
            return proj_dir
    return None


def _iter_jsonl(path: Path) -> Iterable[dict]:
    try:
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


def extract_review_text_from_transcript(project_dir: Path,
                                         mode: str = "issues_only") -> str:
    """Reconstruct the review's written analysis from a Claude transcript.

    Modes:
      - `issues_only` (default, RECOMMENDED for scoring): reconstruct just
        the final `issues.md` content by replaying Write/Edit tool calls
        in order. This is what the review actually wrote to disk, with
        none of the surrounding chatter that pushes substantive findings
        past the judge's truncation limit.
      - `full`: superset including assistant reasoning text and the final
        `result` payload. Useful for `rejudge.py` interactive review
        where context helps; bad for `score.py` because chatter buries
        the actual findings.
    """
    if mode == "issues_only":
        return _reconstruct_issues_md(project_dir)

    chunks: list[str] = []
    for jsonl in sorted(project_dir.glob("*.jsonl")):
        for obj in _iter_jsonl(jsonl):
            # final result envelope
            if obj.get("type") == "result" and isinstance(obj.get("result"), str):
                chunks.append(obj["result"])
                continue
            msg = obj.get("message") or {}
            content = msg.get("content")
            if isinstance(content, str):
                chunks.append(content)
            elif isinstance(content, list):
                for item in content:
                    if not isinstance(item, dict):
                        continue
                    t = item.get("type")
                    if t == "text":
                        chunks.append(item.get("text", ""))
                    elif t == "tool_use":
                        inp = item.get("input") or {}
                        tool = item.get("name", "")
                        target = str(inp.get("file_path") or inp.get("path") or "")
                        if "issues.md" in target or "reports/issues" in target:
                            for k in ("content", "new_string", "old_string"):
                                v = inp.get(k)
                                if isinstance(v, str):
                                    chunks.append(f"[{tool} {target} :: {k}]\n{v}")
    return "\n".join(chunks)


def _reconstruct_issues_md(project_dir: Path) -> str:
    """Replay Write/Edit tool calls targeting `issues.md` to reconstruct the
    final file content as it existed at the end of the run.

    Algorithm:
      - iterate jsonl events in timestamp order
      - on `Write` with content: replace current buffer
      - on `Edit` with old_string/new_string: apply in-place replacement
        (best-effort; if old_string not found, append a marker so the
        judge still sees the new content)
      - on `MultiEdit`: apply each edit in sequence
      - heredoc `cat > issues.md << EOF … EOF` Bash commands are also
        captured if present

    Returns the final reconstructed buffer. If nothing was ever written,
    returns the empty string.
    """
    buf = ""
    events: list[tuple] = []
    for jsonl in sorted(project_dir.glob("*.jsonl")):
        for obj in _iter_jsonl(jsonl):
            ts = obj.get("timestamp") or ""
            msg = obj.get("message") or {}
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get("type") != "tool_use":
                    continue
                inp = item.get("input") or {}
                tool = item.get("name", "")
                target = str(inp.get("file_path") or inp.get("path") or "")
                # Bash heredoc detection
                if tool == "Bash":
                    cmd = str(inp.get("command", ""))
                    if "issues.md" in cmd and ("<<" in cmd or "<<-" in cmd):
                        events.append((ts, "bash_heredoc", cmd))
                    continue
                if "issues.md" not in target and "reports/issues" not in target:
                    continue
                if tool == "Write":
                    events.append((ts, "write", str(inp.get("content", ""))))
                elif tool == "Edit":
                    events.append((
                        ts, "edit",
                        (str(inp.get("old_string", "")),
                         str(inp.get("new_string", "")),
                         bool(inp.get("replace_all", False))),
                    ))
                elif tool == "MultiEdit":
                    edits = inp.get("edits") or []
                    seq = []
                    for e in edits:
                        if isinstance(e, dict):
                            seq.append((
                                str(e.get("old_string", "")),
                                str(e.get("new_string", "")),
                                bool(e.get("replace_all", False)),
                            ))
                    events.append((ts, "multiedit", seq))
    events.sort(key=lambda e: e[0])
    for _, kind, payload in events:
        if kind == "write":
            buf = payload
        elif kind == "edit":
            old, new, replace_all = payload
            if not old:
                buf = buf + new
                continue
            if replace_all:
                buf = buf.replace(old, new)
            else:
                idx = buf.find(old)
                if idx >= 0:
                    buf = buf[:idx] + new + buf[idx + len(old):]
                else:
                    # old_string didn't match (maybe Edit ran before our
                    # snapshot of Write); append the new_string so the
                    # finding text still reaches the judge.
                    buf = buf + "\n" + new
        elif kind == "multiedit":
            for old, new, replace_all in payload:
                if not old:
                    buf = buf + new
                    continue
                if replace_all:
                    buf = buf.replace(old, new)
                else:
                    idx = buf.find(old)
                    if idx >= 0:
                        buf = buf[:idx] + new + buf[idx + len(old):]
                    else:
                        buf = buf + "\n" + new
        elif kind == "bash_heredoc":
            # Extract body between `<<EOF` (or similar) and the matching EOF.
            cmd = payload
            m = re.search(r"<<-?\s*[\"']?(\w+)[\"']?\s*\n(.*?)\n\1\b",
                          cmd, re.DOTALL)
            if m:
                body = m.group(2)
                if "> " in cmd.split("<<")[0] or ">>" in cmd.split("<<")[0]:
                    if ">>" in cmd.split("<<")[0]:
                        buf = buf + body
                    else:
                        buf = body
    return buf
