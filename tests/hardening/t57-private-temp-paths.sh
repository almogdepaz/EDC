#!/usr/bin/env bash
# T57: runtime temp state stays out of the shared temp directory (IMP-05)
# Run from repo root: bash tests/hardening/t57-private-temp-paths.sh
set -euo pipefail

echo "=== T57: private temp paths ==="

SCRIPTS=(plugins/edc/scripts/edc plugins/edc/scripts/*.sh)

# 1. No fixed file or directory name in the shared /tmp directory.
if grep -n '/tmp/edc-' "${SCRIPTS[@]}"; then
  echo "FAIL: runtime scripts use a fixed name in /tmp"
  exit 1
else
  echo "PASS: runtime scripts use no fixed name in /tmp"
fi

# 2. The routing hook does not write dedup state directly into the shared temp directory.
if grep -n 'join(tmpdir(), `edc-injected-modules-' plugins/edc/hooks/lib/route.mjs; then
  echo "FAIL: route.mjs writes dedup state directly into the shared temp directory"
  exit 1
else
  echo "PASS: route.mjs keeps dedup state out of the shared temp directory root"
fi

echo ""
echo "All T57 checks passed."
