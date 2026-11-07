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
  ignored. The command line is split into simple commands (`&&`, `||`, `;`,
  `|`, `&`, newline): `cd`/`pushd`/`popd` move the cwd that later relative
  paths resolve against, and plain `VAR=value` assignments expand in later
  `$VAR`s;
- Task/Agent tool calls: path-like tokens in the subagent's brief. Subagent
  tool calls (`parent_tool_use_id`) appear in the same stream and are scanned
  like any other.

Relative paths resolve against the call's init `cwd` (reset for every Bash
call), so `../..` escapes count.

Attempts count, including ones the permission layer denied (the enemy shim
denies outside paths); a denied attempt exposed nothing and never contaminates.
An outside access is *contaminating* when its path can expose the answer:
ground-truth files, a `benchmark/` or `.plans/` dir, an edc checkout
(`~/Dev/edc*`), Claude Code transcripts of edc sessions
(`~/.claude/projects/<-home->-Dev-edc*`), or a forbidden root (the harness
passes its full-history clone cache, the results tree and results-file dir,
and the snap/flat/io dirs of other runs). Listing `~/Dev` itself is outside
access but not contamination; reading into an edc checkout is. A recursive
search (find/rg/fd/ag/ack, `grep -r`, the Grep tool, a Glob with `**`) is
contaminating when its root is one of those dirs or an ancestor of one
(`/`, `~`, `~/Dev`, the work dir).

Tool results are scanned for answer markers (the harness passes the gt entry
format `**bug_pattern:**`, `PLANT-<project>-`, `ground-truth.md`,
`/benchmark/clean/` and the entry id): a marker in a result that no agent of
the run wrote earlier (assistant text or tool input, any call log before it)
is contaminating, so reads the path scan misses still count when they return
ground truth. A result of a denied call is ignored.

The scan is lexical: variables other than plain assignments and `$HOME`,
globs, command substitution, subshell scoping (`(cd x; ...)` is followed past
the parenthesis), code in heredocs (`os.walk("/")`) and computed paths can hide
an access; a marker check only sees ground truth that is quoted verbatim. It
is a detector, not enforcement.

How p3 treats the result: a run with outcome `contaminated` is excluded from
recall (numerator and denominator), counted per arm, and listed in the p3
report with its `outside_access` paths. `outside_access` > 0 without
contamination is reported per arm but does not exclude the run.
"""

import json
import os
import re
import shlex
from pathlib import Path

from clean_blocked import _events  # same stream-json reader as blocked detection

FILE_KEYS = ("file_path", "path", "notebook_path")
TOKEN_SPLIT_RE = re.compile(r"[\s;|&()<>`'\"=,]+")
SEGMENT_SPLIT_RE = re.compile(r"&&|\|\||[;|&\n]")  # simple commands of a Bash command line (lexically)
VAR_RE = re.compile(r"\$(?:\{(\w+)\}|(\w+))")
ASSIGN_RE = re.compile(r"^(\w+)=(.*)$", re.S)
URL_RE = re.compile(r"^[A-Za-z][\w+.-]*://")
IGNORED_PREFIXES = ("/dev/",)
COMMAND_PREFIXES = {"sudo", "env", "command", "exec", "nohup", "nice", "time", "xargs", "export", "local"}
SEARCH_COMMANDS = {"find", "rg", "fd", "ag", "ack"}  # recursive by default
GREP_COMMANDS = {"grep", "egrep", "fgrep"}  # recursive with -r/-R
RECURSIVE_FLAG_RE = re.compile(r"^(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive|--dereference-recursive)$")
PATTERN_OPTIONS = ("-e", "-f", "--regexp", "--file", "--files")  # operands are then all paths
TASK_TOOLS = ("Task", "Agent")
TASK_TEXT_KEYS = ("description", "prompt")
SUMMARY_PATHS = 3


def _path_tokens(text: str):
    for token in TOKEN_SPLIT_RE.split(text):
        if not token or URL_RE.match(token):
            continue
        token = token.replace("${HOME}", "~").replace("$HOME", "~")
        if token.startswith("/"):
            # awk/sed regexes and heredoc bodies (`/CONNECT_/`, `/* ... */`) are not paths; a real
            # absolute path starts at an existing top-level dir. Heredocs are still scanned since a
            # `python3 - <<EOF` body can open files. A bare `/` only counts as a search root.
            top = token.split("/")[1]
            if top and os.path.isdir("/" + top):
                yield token
        elif token.startswith("~") or "/" in token or token == "..":
            yield token


def _words(segment: str) -> list:
    try:
        return shlex.split(segment)
    except ValueError:  # unbalanced quotes: awk programs and heredoc bodies split across segments
        return segment.split()


def _search_roots(command: str, args: list) -> list:
    """Operands a recursive search starts from (default: the cwd)."""
    if command == "find":
        while args and args[0] in ("-H", "-L", "-P"):
            args = args[1:]
        roots = []
        for arg in args:
            if arg.startswith(("-", "(", "!")):
                break
            roots.append(arg)
    else:
        operands = [a for a in args if not a.startswith("-")]
        explicit = any(a.split("=")[0] in PATTERN_OPTIONS for a in args)
        roots = operands if explicit else operands[1:]  # the first operand is the pattern
    return roots or ["."]


def _bash_accesses(command: str, cwd: str):
    """(path, recursive) per accessed path. Splits the command line into simple
    commands; `cd`/`pushd`/`popd` move the cwd later relative paths resolve
    against, plain `VAR=value` assignments expand in later `$VAR`s, and a
    recursive search (find/rg/fd/ag/ack, grep -r) yields its roots."""
    variables, stack = {"HOME": "~"}, []
    for segment in SEGMENT_SPLIT_RE.split(command):
        segment = VAR_RE.sub(lambda m: variables.get(m.group(1) or m.group(2), m.group(0)), segment)
        for token in _path_tokens(segment):
            yield _resolve(token, cwd), False
        words = _words(segment)
        while words and (os.path.basename(words[0]) in COMMAND_PREFIXES or ASSIGN_RE.match(words[0])):
            match = ASSIGN_RE.match(words.pop(0))
            if match:
                variables[match.group(1)] = match.group(2)
        if not words:
            continue
        name, args = os.path.basename(words[0]), words[1:]
        if name in ("cd", "pushd"):
            targets = [a for a in args if not a.startswith("-")]
            if "-" in args and not targets:
                continue  # `cd -`: the previous dir is unknown here
            target = _resolve(targets[0] if targets else "~", cwd)
            if target:
                yield target, False
                if name == "pushd":
                    stack.append(cwd)
                cwd = target
        elif name == "popd" and stack:
            cwd = stack.pop()
        elif name in SEARCH_COMMANDS or (name in GREP_COMMANDS and any(map(RECURSIVE_FLAG_RE.match, args))):
            for root in _search_roots(name, args):
                yield _resolve(root, cwd), True


def _glob_root(pattern: str, path: str) -> str:
    if pattern.startswith(("/", "~")):
        return os.path.dirname(re.split(r"[*?\[{]", pattern, 1)[0] + "x")
    return path or "."


def _tool_accesses(name: str, inp: dict, cwd: str):
    """(path, recursive) per path a tool call accesses; paths resolved."""
    if name == "Bash":
        yield from _bash_accesses(str(inp.get("command") or ""), cwd)
        return
    if name in TASK_TOOLS:  # a subagent's own tool calls are in the stream too; its brief may name paths
        for key in TASK_TEXT_KEYS:
            for token in _path_tokens(str(inp.get(key) or "")):
                yield _resolve(token, cwd), False
        return
    if name == "Grep":  # always recursive, from `path` or the cwd
        yield _resolve(str(inp.get("path") or "."), cwd), True
        return
    for key in FILE_KEYS + (("pattern",) if name == "Glob" else ()):
        value = inp.get(key)
        if isinstance(value, str) and value:
            yield _resolve(value, cwd), False
    pattern = str(inp.get("pattern") or "")
    if name == "Glob" and "**" in pattern:
        yield _resolve(_glob_root(pattern, str(inp.get("path") or "")), cwd), True


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


def _covers(path: str, targets: list) -> bool:
    """path is one of targets or an ancestor of one."""
    return any(t == form or t.startswith(form.rstrip(os.sep) + os.sep) for form in _forms(path) for t in targets)


def _denied_ids(log: Path) -> set:
    return {str(d.get("tool_use_id")) for event in _events(log) if event.get("type") == "result"
            for d in event.get("permission_denials") or [] if isinstance(d, dict)}


def _blocks(event: dict) -> list:
    content = (event.get("message") or {}).get("content")
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def _result_text(content) -> str:
    if isinstance(content, list):
        return "\n".join(str(b.get("text") or "") for b in content if isinstance(b, dict))
    return str(content or "")


def scan_access(call_logs, allowed, forbidden=(), home=None, markers=()) -> tuple[list, list]:
    """Returns (outside, contaminated): (tool, path) per attempted tool access,
    in log order. Uses the permission layer denied (result `permission_denials`)
    count as outside but exposed nothing, so they do not contaminate. A
    recursive search whose root is an edc checkout's ancestor (/, ~, ~/Dev),
    the edc transcripts dir's, or a forbidden root's (or one of those) is
    contaminating. A tool result containing one of `markers` that no agent of
    the run wrote earlier is recorded as (tool, "result contains '<marker>'")
    in both lists."""
    home = os.path.normpath(home or str(Path.home()))
    allowed, forbidden = _root_forms(allowed), _root_forms(forbidden)
    sensitive = _root_forms([os.path.join(home, "Dev", "edc"), os.path.join(home, ".claude", "projects"),
                             *forbidden])
    outside, contaminated, authored = [], [], []  # authored: text the run's agents wrote, in log order
    for log in map(Path, call_logs):
        cwd, denied, tool_names = "", _denied_ids(log), {}
        for event in _events(log):
            kind = event.get("type")
            if kind == "system" and event.get("subtype") == "init":
                cwd = str(event.get("cwd") or "")
            elif kind == "assistant":
                for block in _blocks(event):
                    if block.get("type") == "text":
                        authored.append(str(block.get("text") or ""))
                    if block.get("type") != "tool_use":
                        continue
                    tid, name = str(block.get("id")), str(block.get("name") or "")
                    inp = block.get("input") if isinstance(block.get("input"), dict) else {}
                    tool_names[tid] = name
                    authored.append(json.dumps(inp, ensure_ascii=False))
                    accesses = {}  # one entry per path and call; recursive if any use of it is
                    for path, recursive in _tool_accesses(name, inp, cwd):
                        accesses[path] = accesses.get(path, False) or recursive
                    for path, recursive in accesses.items():
                        if path is None or path.startswith(IGNORED_PREFIXES) or _within(path, allowed):
                            continue
                        outside.append((name, path))
                        if tid not in denied and (_contaminating(path, home, forbidden)
                                                  or (recursive and _covers(path, sensitive))):
                            contaminated.append((name, path))
            elif kind == "user" and markers:
                for block in _blocks(event):
                    tid = str(block.get("tool_use_id"))
                    if block.get("type") != "tool_result" or tid in denied:
                        continue
                    text = _result_text(block.get("content"))
                    for marker in markers:
                        if marker in text and not any(marker in a for a in authored):
                            hit = (tool_names.get(tid, "tool_result"), f"result contains {marker!r}")
                            outside.append(hit)
                            contaminated.append(hit)
    return outside, contaminated


def summarize(outside, contaminated) -> str:
    """`N: tool path, ...` (contaminating paths first, distinct, at most SUMMARY_PATHS)."""
    if not outside:
        return "0"
    distinct = list(dict.fromkeys([*contaminated, *outside]))
    shown = ", ".join(f"{tool} {path}" for tool, path in distinct[:SUMMARY_PATHS])
    more = len(distinct) - SUMMARY_PATHS
    return f"{len(outside)}: {shown}" + (f" (+{more} more)" if more > 0 else "")
