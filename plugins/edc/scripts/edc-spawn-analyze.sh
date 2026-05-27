#!/usr/bin/env bash
# edc-spawn-analyze: summarize spawn-log + preserved transcripts.
#
# Usage:
#   edc-spawn-analyze.sh [--transcript-dir <dir>] [--spawn-log <path>]
#                        [--claude-projects <dir>] [--format text|json]
#
# Defaults:
#   --transcript-dir   $EDC_TRANSCRIPT_DIR, else edc-context/build/transcripts
#   --spawn-log        $EDC_SPAWN_LOG, else edc-context/build/spawn-log.jsonl
#   --claude-projects  ~/.claude/projects (claude code per-session jsonl + Task subagent transcripts)
#   --format           text
#
# What this analyzes:
#   1. spawn-log.jsonl: each line is one edc_spawn invocation (outer summary).
#   2. transcripts/ (preserved when EDC_PRESERVE_TRANSCRIPTS=1): the stream-json
#      output of each edc_spawn call. This is the INNER claude session that
#      edc_spawn launched, not its Task subagents.
#   3. claude-projects: claude code writes per-session jsonl files under
#      ~/.claude/projects/<repo-path>/<session-id>.jsonl plus
#      <session-id>/subagents/agent-*.jsonl for each Task subagent it spawned.
#      We walk these to find Task subagents linked to the inner sessions.
#
# Output: per-spawn summary, per-Task-subagent breakdown, drift detection.
#
# Requires jq, python3.

set -euo pipefail

TRANSCRIPT_DIR=""
SPAWN_LOG=""
CLAUDE_PROJECTS=""
FORMAT="text"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --transcript-dir)  TRANSCRIPT_DIR="$2"; shift 2 ;;
    --spawn-log)       SPAWN_LOG="$2"; shift 2 ;;
    --claude-projects) CLAUDE_PROJECTS="$2"; shift 2 ;;
    --format)          FORMAT="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

TRANSCRIPT_DIR="${TRANSCRIPT_DIR:-${EDC_TRANSCRIPT_DIR:-edc-context/build/transcripts}}"
SPAWN_LOG="${SPAWN_LOG:-${EDC_SPAWN_LOG:-edc-context/build/spawn-log.jsonl}}"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 2; }

if [ ! -d "$TRANSCRIPT_DIR" ]; then
  echo "WARN: transcript dir not found: $TRANSCRIPT_DIR" >&2
  echo "WARN: re-run with EDC_PRESERVE_TRANSCRIPTS=1 to capture future spawns" >&2
fi
if [ ! -f "$SPAWN_LOG" ]; then
  echo "WARN: spawn-log not found: $SPAWN_LOG" >&2
fi

python3 - "$SPAWN_LOG" "$TRANSCRIPT_DIR" "$CLAUDE_PROJECTS" "$FORMAT" <<'PY'
import json, os, sys, glob
from pathlib import Path
from collections import Counter, defaultdict

spawn_log = Path(sys.argv[1])
transcript_dir = Path(sys.argv[2])
claude_projects = Path(sys.argv[3])
fmt = sys.argv[4]

# ── Load spawn-log records (outer spawns) ────────────────────────────────────
outer_records = []
if spawn_log.is_file():
    for line in spawn_log.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            outer_records.append(json.loads(line))
        except json.JSONDecodeError:
            pass

# ── Walk transcript dir, parse each transcript for inner subagents ───────────
def parse_transcript(path):
    """Yield (kind, record) tuples for every event of interest.

    Top-level events come from `claude -p` stream-json. Inner Task subagent
    events appear as `{"isSidechain": true, ...}` lines with their own
    `sessionId` (parent) and unique `agentId`.
    """
    try:
        for line in path.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            yield d
    except Exception:
        return

def summarize_transcript(path):
    """Return {
        outer: {model, turns, in, out, cache_r, cache_w, cost, tools, reads},
        subagents: [ {agent_id, prompt_head, model, turns, in, out, cache_r,
                      cache_w, cost, tools, reads, files_read} ... ]
    }
    """
    outer = dict(model=None, turns=0, in_=0, out=0, cache_r=0, cache_w=0,
                 cost=None, tools=Counter(), reads=[], errors=[])
    # subagents keyed by agentId
    subs = defaultdict(lambda: dict(prompt_head="", model=None, turns=0, in_=0,
                                    out=0, cache_r=0, cache_w=0, cost=None,
                                    tools=Counter(), reads=[], errors=[]))

    for d in parse_transcript(path):
        t = d.get("type", "")
        agent_id = d.get("agentId", "") or ""
        is_side = d.get("isSidechain", False)
        target = subs[agent_id] if (is_side and agent_id) else outer

        if t == "system" and d.get("subtype") == "init":
            target["model"] = target.get("model") or d.get("model")

        elif t == "assistant":
            msg = d.get("message", {}) or {}
            m = msg.get("model")
            if m:
                target["model"] = target.get("model") or m
            usage = msg.get("usage", {}) or {}
            target["in_"]    += usage.get("input_tokens", 0)
            target["out"]    += usage.get("output_tokens", 0)
            target["cache_r"] += usage.get("cache_read_input_tokens", 0)
            target["cache_w"] += usage.get("cache_creation_input_tokens", 0)
            for c in msg.get("content", []) or []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use":
                    tn = c.get("name", "")
                    target["tools"][tn] += 1
                    if tn == "Read":
                        fp = (c.get("input", {}) or {}).get("file_path", "")
                        if fp:
                            target["reads"].append(fp)

        elif t == "user":
            msg = d.get("message", {}) or {}
            content = msg.get("content", "")
            if is_side and agent_id and not target["prompt_head"]:
                # first user message of this subagent — capture prompt head
                if isinstance(content, str):
                    target["prompt_head"] = content[:240]
                elif isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            target["prompt_head"] = c.get("text", "")[:240]
                            break

        elif t == "result":
            target["cost"] = d.get("total_cost_usd")
            target["turns"] = d.get("num_turns", target.get("turns", 0))

        elif t == "error" or (t == "result" and d.get("is_error")):
            err = d.get("result") or d.get("message") or "error"
            target["errors"].append(str(err)[:120])

    # subagent count their own turns from message count if not on a result line
    for ag, rec in subs.items():
        if not rec["turns"]:
            # heuristic: count of assistant messages
            pass
    return outer, subs

# ── Locate Task subagent transcripts ────────────────────────────────────────
# For each session_id we find in the transcripts (claude code's `system/init`
# block tells us the sessionId), look for matching subagent jsonl files in
# the claude code project dir tree.
def find_subagent_files(session_id):
    """Search ~/.claude/projects/**/<session_id>/subagents/agent-*.jsonl."""
    if not session_id or not claude_projects.is_dir():
        return []
    matches = []
    for proj in claude_projects.iterdir():
        if not proj.is_dir():
            continue
        sub_dir = proj / session_id / "subagents"
        if sub_dir.is_dir():
            matches.extend(sorted(sub_dir.glob("agent-*.jsonl")))
    return matches

def parse_subagent_file(path):
    """Parse a single Task subagent jsonl. Returns same shape as inner subs entry."""
    rec = dict(prompt_head="", model=None, turns=0, in_=0, out=0, cache_r=0,
               cache_w=0, cost=None, tools=Counter(), reads=[], errors=[])
    try:
        for line in path.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = d.get("type", "")
            if t == "user" and not rec["prompt_head"]:
                c = d.get("message", {}).get("content", "")
                if isinstance(c, str):
                    rec["prompt_head"] = c[:240]
                elif isinstance(c, list):
                    for x in c:
                        if isinstance(x, dict) and x.get("type") == "text":
                            rec["prompt_head"] = x.get("text", "")[:240]
                            break
            elif t == "assistant":
                msg = d.get("message", {}) or {}
                rec["model"] = rec["model"] or msg.get("model")
                usage = msg.get("usage", {}) or {}
                rec["in_"]    += usage.get("input_tokens", 0)
                rec["out"]    += usage.get("output_tokens", 0)
                rec["cache_r"] += usage.get("cache_read_input_tokens", 0)
                rec["cache_w"] += usage.get("cache_creation_input_tokens", 0)
                rec["turns"] += 1
                for c in msg.get("content", []) or []:
                    if isinstance(c, dict) and c.get("type") == "tool_use":
                        tn = c.get("name", "")
                        rec["tools"][tn] += 1
                        if tn == "Read":
                            fp = (c.get("input", {}) or {}).get("file_path", "")
                            if fp:
                                rec["reads"].append(fp)
    except Exception:
        pass
    return rec

# ── Aggregate ────────────────────────────────────────────────────────────────
transcripts = sorted(transcript_dir.glob("*.jsonl")) if transcript_dir.is_dir() else []

per_transcript = []
totals = dict(in_=0, out=0, cache_r=0, cache_w=0, cost=0.0, subagents=0, outer_spawns=0)

# Extract session_id from a transcript. Two cases:
#   - stream-json from `claude -p`: first line is system/init with .session_id
#   - claude code project-dir jsonl: every line has .sessionId (camelCase)
def session_id_of(path):
    try:
        for line in path.read_text(errors="replace").splitlines()[:200]:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            # stream-json init block (most reliable when present)
            if d.get("type") == "system" and d.get("subtype") == "init":
                sid = d.get("session_id") or d.get("sessionId")
                if sid:
                    return sid
            # claude-projects line — any entry with sessionId works
            sid = d.get("sessionId") or d.get("session_id")
            if sid:
                return sid
    except Exception:
        pass
    return ""

for tpath in transcripts:
    outer, subs = summarize_transcript(tpath)
    # Also pull in Task subagents from claude code's project dir if available.
    sid = session_id_of(tpath)
    if sid:
        for sub_path in find_subagent_files(sid):
            agent_id = sub_path.stem.replace("agent-", "")
            if agent_id not in subs:
                subs[agent_id] = parse_subagent_file(sub_path)
    per_transcript.append((tpath.name, outer, subs))
    totals["outer_spawns"] += 1
    totals["in_"]    += outer["in_"]
    totals["out"]    += outer["out"]
    totals["cache_r"] += outer["cache_r"]
    totals["cache_w"] += outer["cache_w"]
    if outer["cost"]: totals["cost"] += outer["cost"] or 0
    totals["subagents"] += len(subs)
    for sub in subs.values():
        totals["in_"]    += sub["in_"]
        totals["out"]    += sub["out"]
        totals["cache_r"] += sub["cache_r"]
        totals["cache_w"] += sub["cache_w"]

# ── Drift detection: in build-context fanout, every module-context subagent
# should have a prompt starting with "Build deep architectural context for
# module `<name>`". Detect any deviation. ─────────────────────────────────────
def detect_drift(subs):
    """Return list of subagent prompts whose first 80 chars look different
    from the most common prefix among all subagents."""
    if len(subs) < 2:
        return []
    prefixes = Counter(s["prompt_head"][:80] for s in subs.values() if s["prompt_head"])
    if not prefixes:
        return []
    common, count = prefixes.most_common(1)[0]
    odd = []
    for ag, s in subs.items():
        head80 = s["prompt_head"][:80]
        if head80 and head80 != common:
            odd.append((ag, head80))
    return odd, common, count

# ── Output ───────────────────────────────────────────────────────────────────
if fmt == "json":
    out = {
        "totals": totals,
        "outer_records": outer_records,
        "transcripts": [
            {
                "file": name,
                "outer": {k: (dict(v) if isinstance(v, Counter) else v) for k, v in outer.items()},
                "subagents": [
                    {"agent_id": ag, **{k: (dict(v) if isinstance(v, Counter) else v) for k, v in sub.items()}}
                    for ag, sub in subs.items()
                ],
            }
            for name, outer, subs in per_transcript
        ],
    }
    json.dump(out, sys.stdout, default=str, indent=2)
    sys.exit(0)

# text format
print(f"## Spawn-log records: {len(outer_records)}")
if outer_records:
    print(f"{'phase':<32} {'model_req':<30} {'observed':<32} {'turns':>5} {'cost$':>8} {'in':>8} {'cr':>10} {'cw':>8} {'dur':>5}")
    for r in outer_records:
        phase = r.get("phase", "?")[:32]
        mr = (r.get("model_requested") or "")[:30]
        mo = (r.get("model_observed") or "")[:32]
        print(f"{phase:<32} {mr:<30} {mo:<32} {r.get('num_turns', '-'):>5} {(r.get('total_cost_usd') or 0):>8.4f} {r.get('input_tokens', 0):>8} {r.get('cache_read_tokens', 0):>10} {r.get('cache_write_tokens', 0):>8} {r.get('duration_s', 0):>5}")

print()
print(f"## Transcripts: {len(transcripts)} (dir: {transcript_dir})")
print(f"## Totals across transcripts:")
print(f"   outer_spawns:  {totals['outer_spawns']}")
print(f"   subagents:     {totals['subagents']}")
print(f"   input tokens:  {totals['in_']:,}")
print(f"   output tokens: {totals['out']:,}")
print(f"   cache_read:    {totals['cache_r']:,}")
print(f"   cache_write:   {totals['cache_w']:,}")
print(f"   total cost:    ${totals['cost']:.4f}")

print()
for name, outer, subs in per_transcript:
    print("=" * 80)
    print(f"### {name}")
    print(f"  outer model:   {outer['model']}")
    print(f"  outer turns:   {outer['turns']}")
    print(f"  outer tokens:  in={outer['in_']:,} out={outer['out']:,} cache_r={outer['cache_r']:,} cache_w={outer['cache_w']:,}")
    print(f"  outer cost:    ${outer['cost'] or 0:.4f}")
    if outer["tools"]:
        print(f"  outer tools:   {dict(outer['tools'])}")
    if outer["errors"]:
        print(f"  outer errors:  {outer['errors'][:3]}")

    if subs:
        print(f"  subagents:     {len(subs)}")
        # drift detection
        drift_res = detect_drift(subs)
        if isinstance(drift_res, tuple):
            odd, common, count = drift_res
            print(f"    common prompt head (n={count}): {common[:80]!r}")
            if odd:
                print(f"    DRIFT detected: {len(odd)} subagent(s) with different prompts:")
                for ag, head in odd[:10]:
                    print(f"      {ag[:10]}: {head!r}")
        print()
        print(f"    {'agent':<14} {'model':<32} {'in':>8} {'out':>6} {'cache_r':>10} {'cache_w':>8} {'reads':>5} {'top_tool':<20} {'prompt_head':<60}")
        for ag, s in sorted(subs.items()):
            top_tool = s["tools"].most_common(1)
            top_tool_str = f"{top_tool[0][0]}×{top_tool[0][1]}" if top_tool else ""
            ph = (s["prompt_head"][:60] or "").replace("\n", " ")
            print(f"    {ag[:14]:<14} {(s['model'] or '')[:32]:<32} {s['in_']:>8} {s['out']:>6} {s['cache_r']:>10} {s['cache_w']:>8} {len(s['reads']):>5} {top_tool_str:<20} {ph:<60}")
            if s["errors"]:
                print(f"      ERRORS: {s['errors'][:2]}")
PY
