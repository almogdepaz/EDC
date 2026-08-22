---
name: edc:edc-run-review
description: Performs combined security, delivery, and quality review of code changes, with optional EDC context
argument-hint: "--full | <target> --base <ref> [--ignore <glob>]... [--context-mode advisory|inject]"
allowed-tools:
  - Bash
---

# Combined Review

**Arguments:** $ARGUMENTS

Run the EDC review orchestrator with Bash only. Do not review inline.

If EDC context is missing or stale, the orchestrator may build/update it before
reviewing. Warn the user this can take several minutes.

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

echo "WARNING: if EDC context is missing or stale, review may first build/update context and can take several minutes."
node "$bootstrap" edc-review-all.sh "$@"
```

If the script exits non-zero, surface its error message verbatim and stop. Do not retry.

The script writes security, delivery, and quality outputs on success. Tell the user
the reported output paths.
