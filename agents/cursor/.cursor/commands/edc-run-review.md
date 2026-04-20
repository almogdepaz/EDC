---
description: Performs differential review of code changes using codebase context
---

# Differential Review

**Arguments:** passed from command input

Common forms:
- `--base main` — review current branch against main
- `<commit-sha> --base <ref>` — review a specific target against a base
- `<pr-url>` — review a GitHub PR

The orchestrator script runs the full pipeline self-driven: it spawns fresh `cursor agent -p`
sessions for context build/update, per-module review, and consolidation. Your only job
is to invoke it and surface its output. Do not attempt the review work inline.

```bash
export EDC_AGENT_CLI=cursor
set -- <arguments>
if [ -f ".edc/scripts/edc-review.sh" ]; then
  bash .edc/scripts/edc-review.sh "$@"
elif [ -f "$HOME/.edc/scripts/edc-review.sh" ]; then
  bash "$HOME/.edc/scripts/edc-review.sh" "$@"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first (run agents/cursor/install.sh from the EDC repo)"
  exit 1
fi
```

If the script exits non-zero, surface its error message verbatim and stop. Do not retry.
Do not attempt the work inline — let the orchestrator handle subprocess spawning.

The script prints `Consolidated: <path>` and `Verified: <path>` on success. Tell the
user the path of the final review file.
