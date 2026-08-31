---
name: edc:edc-doctor
description: Validate the v2 context tree, manifest schema, and routing coverage
allowed-tools:
  - Bash
---

# Doctor

The orchestrator-style doctor script runs all layout/manifest/routing
checks deterministically. Your only job is to invoke it and surface its
output.

```bash
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/hooks/lib/runtime-bootstrap.mjs" ]; then
  bootstrap="$CLAUDE_PLUGIN_ROOT/hooks/lib/runtime-bootstrap.mjs"
elif [ -f "$HOME/.edc/hooks/lib/runtime-bootstrap.mjs" ]; then
  bootstrap="$HOME/.edc/hooks/lib/runtime-bootstrap.mjs"
else
  echo "SCRIPT_MISSING: trusted EDC runtime bootstrap is unavailable; reinstall EDC"
  exit 1
fi
node "$bootstrap" edc-doctor.sh
```

If it fails, surface the stderr report verbatim and stop.
