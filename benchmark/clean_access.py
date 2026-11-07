#!/usr/bin/env python3
"""Outside-access and contamination detection for the clean benchmark (plan 041).

The legacy arms keep `--dangerously-skip-permissions`, so the tool layer does
not stop an audited agent from reading absolute paths. Instead of new
enforcement, each run's stream-json call logs (written by `clean-bin/claude`)
are scanned afterwards for tool access outside the run's allowed roots (the
snapshot, the staged plugin, and the run's scratch dir):

- file tools: `file_path` / `path` / `notebook_path`, and Glob's `pattern`;
- Bash: path-like tokens in the command (absolute under an existing top-level
  dir, `~`, `$HOME`, or anything containing `/`); URLs and `/dev/*` are
  ignored.

Relative paths resolve against the call's init `cwd`, so `../..` escapes count.
Subagent tool calls appear in the same stream and are scanned too.

Attempts count, including ones the permission layer denied (the enemy shim
denies outside paths); a denied attempt exposed nothing and never contaminates.
An outside access is *contaminating* when its path can expose the answer:
ground-truth files, a `benchmark/` or `.plans/` dir, an edc checkout
(`~/Dev/edc*`), Claude Code transcripts of edc sessions
(`~/.claude/projects/<-home->-Dev-edc*`), or a forbidden root (the harness
passes its full-history clone cache, the results tree and results-file dir,
and the snap/flat/io dirs of other runs). Listing `~/Dev` itself is outside access but not
contamination; reading into an edc checkout is.

The Bash scan is lexical: `cd` chains, variables other than `$HOME`, globs,
command substitution and computed paths can hide an access. It is a detector,
not enforcement.

How p3 treats the result: a run with outcome `contaminated` is excluded from
recall (numerator and denominator), counted per arm, and listed in the p3
report with its `outside_access` paths. `outside_access` > 0 without
contamination is reported per arm but does not exclude the run.
"""

import os
import re
from pathlib import Path

from clean_blocked import _events  # same stream-json reader as blocked detection

FILE_KEYS = ("file_path", "path", "notebook_path")
TOKEN_SPLIT_RE = re.compile(r"[\s;|&()<>`'\"=,]+")
URL_RE = re.compile(r"^[A-Za-z][\w+.-]*://")
IGNORED_PREFIXES = ("/dev/",)
SUMMARY_PATHS = 3


def _bash_paths(command: str):
    for token in TOKEN_SPLIT_RE.split(command):
        if not token or URL_RE.match(token):
            continue
        token = token.replace("${HOME}", "~").replace("$HOME", "~")
        if token.startswith("/"):
            # awk/sed regexes and heredoc bodies (`/CONNECT_/`, `/* ... */`) are not paths; a real
            # absolute path starts at an existing top-level dir. Heredocs are still scanned since a
            # `python3 - <<EOF` body can open files.
            top = token.split("/")[1]
            if top and os.path.isdir("/" + top):
                yield token
        elif token.startswith("~") or "/" in token or token == "..":
            yield token


def _tool_paths(name: str, inp: dict):
    if name == "Bash":
        yield from _bash_paths(str(inp.get("command") or ""))
        return
    keys = FILE_KEYS + (("pattern",) if name == "Glob" else ())
    for key in keys:
        value = inp.get(key)
        if isinstance(value, str) and value:
            yield value


def _resolve(raw: str, cwd: str):
    path = os.path.expanduser(raw)
    if not os.path.isabs(path):
        if not cwd:
            return None
        path = os.path.join(cwd, path)
    return os.path.normpath(path)


def _forms(path: str) -> set:
    return {path, os.path.realpath(path)}


def _within(path: str, roots: list) -> bool:
    return any(form == root or form.startswith(root + os.sep) for form in _forms(path) for root in roots)


def _root_forms(roots) -> list:
    return sorted({form for root in roots for form in _forms(os.path.normpath(str(root)))})


def _contaminating(path: str, home: str, forbidden: list) -> bool:
    edc_checkout = re.compile(rf"^{re.escape(home)}/Dev/edc[^/]*(?:/|$)")
    edc_transcripts = f"/.claude/projects/{home.replace('/', '-')}-Dev-edc"
    for form in _forms(path):
        slashed = form + "/"
        if ("ground-truth" in form or "/benchmark/" in slashed or "/.plans/" in slashed
                or edc_checkout.match(form) or edc_transcripts in form):
            return True
    return _within(path, forbidden)


def _denied_ids(log: Path) -> set:
    return {str(d.get("tool_use_id")) for event in _events(log) if event.get("type") == "result"
            for d in event.get("permission_denials") or [] if isinstance(d, dict)}


def scan_access(call_logs, allowed, forbidden=(), home=None) -> tuple[list, list]:
    """Returns (outside, contaminated): (tool, path) per attempted tool access,
    in log order. Uses the permission layer denied (result `permission_denials`)
    count as outside but exposed nothing, so they do not contaminate."""
    home = os.path.normpath(home or str(Path.home()))
    allowed, forbidden = _root_forms(allowed), _root_forms(forbidden)
    outside, contaminated = [], []
    for log in map(Path, call_logs):
        cwd, denied = "", _denied_ids(log)
        for event in _events(log):
            if event.get("type") == "system" and event.get("subtype") == "init":
                cwd = str(event.get("cwd") or "")
            if event.get("type") != "assistant":
                continue
            for block in (event.get("message") or {}).get("content") or []:
                if not (isinstance(block, dict) and block.get("type") == "tool_use"):
                    continue
                name, inp = str(block.get("name") or ""), block.get("input") or {}
                for raw in _tool_paths(name, inp):
                    path = _resolve(raw, cwd)
                    if path is None or path.startswith(IGNORED_PREFIXES) or _within(path, allowed):
                        continue
                    outside.append((name, path))
                    if str(block.get("id")) not in denied and _contaminating(path, home, forbidden):
                        contaminated.append((name, path))
    return outside, contaminated


def summarize(outside, contaminated) -> str:
    """`N: tool path, ...` (contaminating paths first, distinct, at most SUMMARY_PATHS)."""
    if not outside:
        return "0"
    distinct = list(dict.fromkeys([*contaminated, *outside]))
    shown = ", ".join(f"{tool} {path}" for tool, path in distinct[:SUMMARY_PATHS])
    more = len(distinct) - SUMMARY_PATHS
    return f"{len(outside)}: {shown}" + (f" (+{more} more)" if more > 0 else "")
