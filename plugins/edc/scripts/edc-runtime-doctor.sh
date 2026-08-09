#!/usr/bin/env bash
# Validate project-local .edc runtime before context recovery/model work.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_CLI="$SCRIPT_DIR/../hooks/lib/runtime-manifest.mjs"

if [ ! -f "$RUNTIME_CLI" ]; then
  echo '{"schemaVersion":1,"status":"failed","reasonCode":"runtime-install-incomplete","message":"runtime doctor helper is missing","hint":"rerun the EDC installer to repair project-local .edc","details":{"missingPath":".edc/hooks/lib/runtime-manifest.mjs"},"exitCode":1}'
  exit 1
fi

node "$RUNTIME_CLI" preflight "${1:-.}" "${2:-}" ${3:+"$3"}
