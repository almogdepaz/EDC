---
name: edc:edc-audit
description: Identifies overengineering, code bloat, and duplication by comparing context expectations to actual code
argument-hint: "[--ignore <glob>]..."
allowed-tools:
  - Bash
---

# Audit Complexity

**Arguments:** $ARGUMENTS

The orchestrator script runs the full pipeline self-driven: it gates on
context freshness, auto-recovers (build/update) if stale, then spawns one
audit subprocess via `EDC_AGENT_CLI` and validates the resulting reports.
Your only job is to invoke it and surface its output. You have no other
tools.

```bash
set -- $ARGUMENTS
if [ -f ".edc/scripts/edc-audit.sh" ]; then
  bash .edc/scripts/edc-audit.sh "$@"
elif [ -f "$HOME/.edc/scripts/edc-audit.sh" ]; then
  bash "$HOME/.edc/scripts/edc-audit.sh" "$@"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first"
  exit 1
fi
```

If the script exits non-zero, surface its error message verbatim and stop.
Do not retry. Do not attempt the work inline — you cannot, you only have Bash.

The script prints the report paths on success. Tell the user where to find
`.context/reports/complexity.md` and `.context/reports/issues.md`.
