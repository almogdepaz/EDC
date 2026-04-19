# edc-review: Deterministic Flow Plan

## Scope

This PR locks down the **claude code** flow only. cursor/codex/gemini wrappers do NOT
have a `Skill` tool and need a different orchestration model — handled in follow-up PRs,
one per agent. wrapper files in `agents/` are out of scope here.

## Architecture (final)

The script is the orchestrator. The user's claude session is a thin shell that just
runs bash. Each phase (build, update, per-module review) runs in a fresh `claude -p`
subprocess spawned by the script.

```
user types /edc:edc-review <target>
  └─ command (allowed-tools: [Bash])
     └─ bash edc-review.sh --auto <target>
        ├─ try build mode → if CONTEXT_MISSING/STALE:
        │    └─ claude -p "Invoke edc:edc-build skill"  (or edc-update)
        │       └─ check-context → fail-fast if not ready
        │    └─ retry build mode
        ├─ for each TASK line:
        │    └─ claude -p "Invoke edc:edc-review skill --task-file X"
        │       └─ verify report-{module}.md exists or HARD FAIL
        ├─ --consolidate → merge reports → write final review file
        └─ --verify → assert context fresh + reports + final file
```

The user's session never invokes a skill itself. Each spawned `claude -p` gets a fresh
context with a single instruction. Maximum determinism, zero possibility of orchestrator
freelancing.

## Problem (observed in session 3fea410b)

When `/edc:edc-review` runs today:
1. **Context build fails silently** — API overload during edc-context → agent abandons the
   skill, does inline file reads, writes .meta.json manually. Context is incomplete.
2. **Agent skips re-verification** — after manually building context, agent decides to
   "proceed directly" instead of re-running the orchestrator script.
3. **Agent ignores task files** — review-tasks/{module}.md files are created by the script
   but the agent never reads them. It fetches the PR diff itself and does its own analysis.
4. **No hard failures** — every failure mode has an implicit "work around it" fallback.

Root cause: the top command has Read, Grep, Write, Glob available. The agent can always
fall back to inline analysis when skills fail. Removing that option removes the fallback.

---

## Desired Behavior

### Full flow (no existing context)

```
/edc:edc-review <target>
  │
  ├─ run orchestrator script
  │    └─ exits: CONTEXT_MISSING
  │
  ├─ invoke edc-build skill (Skill tool)
  │    └─ skill completes (or fails → HARD STOP)
  │
  ├─ re-run orchestrator script
  │    └─ exits: CONTEXT_STALE or CONTEXT_MISSING → HARD STOP
  │    └─ exits: "Review tasks ready" → continue
  │
  ├─ for each TASK line from script output:
  │    └─ invoke edc-review skill with --task-file <path>
  │         skill reads task file
  │         skill loads context.md + issues.md + {module}.md
  │         skill reviews the listed files
  │         skill writes review-tasks/report-{module}.md
  │         if report not written → HARD STOP
  │
  └─ run script --consolidate
       merges reports → review-{target}.md
       exits non-zero if any report missing → HARD STOP
```

### Incremental flow (fresh context)

```
/edc:edc-review <target>
  ├─ run orchestrator script → "Review tasks ready"
  ├─ invoke edc-review skill per task file
  └─ run script --consolidate
```

### Stale context flow

```
/edc:edc-review <target>
  ├─ run orchestrator script → CONTEXT_STALE
  ├─ invoke edc-update skill → re-run script → verify
  ├─ invoke edc-review skill per task file
  └─ run script --consolidate
```

---

## Rules

1. **Script is the sole router.** All branching (build/update/skip, module list) comes from
   the bash script. The agent never makes routing decisions.

2. **Hard fail on any deviation.** Non-zero script exit after a skill = stop. No retry with
   inline logic. No workarounds. Surface the error message.

3. **Top command: Bash + Skill only.** No Read, Grep, Write, Glob at the command level.
   The agent physically cannot do inline analysis or write files.

4. **Skills retain full tools.** edc-build, edc-update, edc-review each declare their own
   allowed-tools. They do all analysis and file writing.

5. **Verified handoffs.** After every skill completes, the script re-runs to confirm the
   expected output exists. Trust nothing implicitly.

6. **Per-module skill invocation.** Script outputs one `TASK review-tasks/{module}.md` line
   per module. Top agent invokes edc-review skill once per line, passing the task file path.
   The skill does the scoped review and writes the report.

7. **No silent fallbacks.** API overload, timeout, skill failure = hard stop with clear error.
   The agent does not attempt the task inline under any circumstances.

---

## Changes Required

### `scripts/edc-review.sh`
- [x] Add `--auto <target>` mode: self-driving pipeline. Spawns `claude -p` for
      edc-build/edc-update, then per-module reviews, then `--consolidate` and
      `--verify`. Requires `claude` on PATH. Bounded recovery (one shot at context
      fix). Each spawned session is a fresh context with one instruction.
- [x] Add `--check-context` mode: thin assertion that `.context/.meta.json` exists and
      `lastCommit` matches HEAD. Used by the command to verify edc-build/edc-update
      actually worked before re-entering build mode.
- [x] Add `--consolidate` mode: reads `review-tasks/manifest.json` to determine expected
      reports, merges all `review-tasks/report-{module}.md` into `review-{target}.md`,
      exits non-zero if any expected report is missing
- [x] After writing task files, print one `TASK review-tasks/{module}.md` line per module
      to stdout (so the command can iterate without needing Read access)
- [x] `manifest.json` is the script's internal source of truth (consumed only by
      `--consolidate` and `--verify`). The agent never reads it. TASK stdout lines are
      the only agent-facing module list.
- [x] Add `--verify` mode: re-asserts meta.json fresh + all expected reports exist +
      final review file written. Used as the closing self-check.
- [x] Note: stale-context recovery — if `edc-update` advances HEAD, re-running the script
      passes because meta.json is updated to the new HEAD. This is correct, but document it
      so the freshness check isn't surprising.

### `plugins/edc/commands/edc-review.md`
- [x] Strip allowed-tools to `Bash` only (no Skill, no Read/Write/Grep/Glob)
- [x] Replace 7-step state machine with single `bash "$SCRIPT" --auto $ARGUMENTS`
      invocation. The script does ALL orchestration including spawning `claude -p`
      sub-sessions for each phase. The user's claude session is a passive shell.

### `plugins/edc/skills/edc-review/SKILL.md`
- [x] Add `Skill` to allowed-tools (so the skill can invoke `edc:edc-context` for Phase 4
      deep context, which the workflow already references)
- [x] Add `--task-file <path>` argument handling at the top of the skill:
  - If provided: parse the task file (format defined by `scripts/edc-review.sh:117-137`):
    extract Target, Baseline, and Files-to-review list
  - Scope review to listed files only — do not expand
  - Load `.context/context.md`, `.context/issues.md`, `.context/{module}.md` (module name
    derived from task file basename)
  - Write report to `review-tasks/report-{module}.md`
  - Otherwise: behave as today (full standalone review)

### Out of scope (follow-up PRs)
- `agents/cursor/.cursor/commands/edc-run-review.md` — needs a non-Skill orchestration
- `agents/codex/AGENTS.md` — same
- `agents/gemini/GEMINI.md` — same

Each wrapper picks its own strategy (script-only, CLI shell-out, manual user step).
Don't try to unify here — would force a worse design on claude code.

---

## Success Criteria (claude code only)

- [ ] Full flow with no context: edc-build runs, context verified, review runs, report written
- [ ] API overload during edc-build: command hard fails, no inline fallback
- [ ] Fresh context: build/update skipped, review runs directly
- [ ] Stale context: edc-update runs, script re-verifies, review proceeds
- [ ] Top command has no Read/Grep/Write/Glob → physically cannot do inline review
- [ ] Missing report after a per-module skill call = hard fail before consolidation
- [ ] `--consolidate` and `--verify` both pass before user sees "done"
- [ ] Final report contains per-module sections from skill output only
- [ ] Wrappers (cursor/codex/gemini) untouched in this PR
