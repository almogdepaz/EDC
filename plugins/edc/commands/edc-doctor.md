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
if [ -f ".edc/scripts/edc-doctor.sh" ]; then
  bash .edc/scripts/edc-doctor.sh
elif [ -f "$HOME/.edc/scripts/edc-doctor.sh" ]; then
  bash "$HOME/.edc/scripts/edc-doctor.sh"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first"
  exit 1
fi
```

If it fails, surface the stderr report verbatim and stop.
