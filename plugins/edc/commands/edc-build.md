---
name: edc:edc-build
description: Builds or updates deep architectural context for any codebase
argument-hint: "[--force] [--focus <module>] [--ignore <glob>]..."
allowed-tools:
  - Bash
---

# Build Context

**Arguments:** $ARGUMENTS

The orchestrator script runs the full pipeline self-driven: it decides
build-vs-update routing in shell (via `edc-clean-slate.sh`), spawns the
right subprocess via `EDC_AGENT_CLI`, and validates the output with
`edc-doctor.sh`. Your only job is to invoke it and surface its output.
You have no other tools.

```bash
set -- $ARGUMENTS
if [ -f ".edc/scripts/edc-build.sh" ]; then
  bash .edc/scripts/edc-build.sh "$@"
elif [ -f "$HOME/.edc/scripts/edc-build.sh" ]; then
  bash "$HOME/.edc/scripts/edc-build.sh" "$@"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first"
  exit 1
fi
```

If the script exits non-zero, surface its error message verbatim and stop.
Do not retry. Do not attempt the work inline — you cannot, you only have Bash.
