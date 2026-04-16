# edc-review: Deterministic Flow Plan

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
- [ ] Add `--consolidate` mode: reads all `review-tasks/report-*.md`, merges into
      `review-{target}.md`, exits non-zero if any expected report is missing
- [ ] After writing task files, print one `TASK review-tasks/{module}.md` line per module
      (so the command can iterate without needing Read access)
- [ ] Verify that expected report files exist in `--consolidate` mode

### `plugins/edc/commands/edc-review.md`
- [ ] Strip allowed-tools to `Bash` + `Skill` only
- [ ] Rewrite flow:
  - run script → parse first line
  - CONTEXT_MISSING → invoke edc-build skill → re-run script → if not "Review tasks ready" → HARD FAIL
  - CONTEXT_STALE → invoke edc-update skill → re-run script → if not "Review tasks ready" → HARD FAIL
  - "Review tasks ready" → read TASK lines from script output
  - for each TASK line: invoke edc-review skill with `--task-file <path>`
  - after each: verify `review-tasks/report-{module}.md` exists (bash -f check) → if missing → HARD FAIL
  - run script `--consolidate` → if non-zero → HARD FAIL

### `plugins/edc/skills/edc-review/SKILL.md`
- [ ] Add `--task-file <path>` argument handling at the top:
  - If provided: read the task file first, extract target + file list + context paths
  - Use file list to scope review to those files only
  - Use context paths to load the right module context
  - Write report to `review-tasks/report-{module}.md` (module name from task file name)
  - Otherwise: behave as today

### Agent wrappers
- [ ] `agents/cursor/.cursor/commands/edc-run-review.md` — mirror command changes
- [ ] `agents/codex/AGENTS.md` — mirror flow description
- [ ] `agents/gemini/GEMINI.md` — mirror flow description

---

## Success Criteria

- [ ] Full flow with no context: edc-build runs, context verified, review runs, report written
- [ ] API overload during edc-build: command hard fails, no inline fallback
- [ ] Fresh context: build/update skipped, review runs directly
- [ ] Agent has no Read/Grep/Write → physically cannot do inline review
- [ ] Missing report after skill = hard fail before consolidation
- [ ] Final report contains per-module sections from skill output only
