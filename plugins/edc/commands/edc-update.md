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
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/hooks/lib/runtime-bootstrap.mjs" ]; then
  bootstrap="$CLAUDE_PLUGIN_ROOT/hooks/lib/runtime-bootstrap.mjs"
elif [ -f "$HOME/.edc/hooks/lib/runtime-bootstrap.mjs" ]; then
  bootstrap="$HOME/.edc/hooks/lib/runtime-bootstrap.mjs"
else
  echo "SCRIPT_MISSING: trusted EDC runtime bootstrap is unavailable; reinstall EDC"
  exit 1
fi
node "$bootstrap" edc-update.sh "$@"
```

If the script exits non-zero, surface its error message verbatim and stop.
Do not retry. Do not attempt the work inline — you cannot, you only have Bash.
