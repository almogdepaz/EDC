---
name: edc:edc-update
description: Incrementally updates edc-context/ files based on branch changes
argument-hint: "[--base <ref>] [--ignore <glob>]..."
allowed-tools:
  - Bash
---

# Update Context

**Arguments:** $ARGUMENTS

The orchestrator script runs the full pipeline self-driven: it gates on
`edc-context/` health (refusing to update partial/v1/missing layouts with a
copy-pasteable hint), spawns the update subprocess via `EDC_AGENT_CLI`,
and validates the result with `edc-doctor.sh`. Your only job is to
invoke it and surface its output. You have no other tools.

```bash
set -- $ARGUMENTS
if [ -f ".edc/scripts/edc-update.sh" ]; then
  bash .edc/scripts/edc-update.sh "$@"
elif [ -f "$HOME/.edc/scripts/edc-update.sh" ]; then
  bash "$HOME/.edc/scripts/edc-update.sh" "$@"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first"
  exit 1
fi
```

If the script exits non-zero, surface its error message verbatim and stop.
Do not retry. Do not attempt the work inline — you cannot, you only have Bash.
