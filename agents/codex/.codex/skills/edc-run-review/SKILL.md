---
name: edc-run-review
description: Performs differential review of code changes using codebase context
---

# Differential Review

Use the arguments provided in the skill invocation.

Common forms:
- `--base main`
- `<commit-sha> --base <ref>`
- `<pr-url>`

The orchestrator script runs the full pipeline self-driven: it spawns fresh
`codex exec` sessions for context build/update, per-module review, and
consolidation. Your only job is to invoke it and surface its output. Do not
attempt the review work inline.

Run this flow as a single shell invocation so `EDC_AGENT_CLI` and the script
call live in the same shell (splitting the export onto a separate tool call
loses the env var):

```bash
export EDC_AGENT_CLI=codex
set -- <arguments>
if [ -f ".edc/scripts/edc-review.sh" ]; then
  bash .edc/scripts/edc-review.sh "$@"
elif [ -f "$HOME/.edc/scripts/edc-review.sh" ]; then
  bash "$HOME/.edc/scripts/edc-review.sh" "$@"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first (run agents/codex/install.sh from the EDC repo)"
  exit 1
fi
```

If the script exits non-zero, surface its error message verbatim and stop. Do
not retry. Do not attempt the work inline.

On success, the script prints `Consolidated: <path>` and `Verified: <path>`.
Tell the user the path of the final review file.
