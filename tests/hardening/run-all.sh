#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

resolve_bash4() {
  local candidate version
  for candidate in "${EDC_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)" /bin/bash; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    version=$("$candidate" -lc 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null || true)
    [ "${version:-0}" -ge 4 ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

BASH_BIN=$(resolve_bash4) || { echo "FAIL: bash >=4 not found"; exit 1; }
export EDC_BASH="$BASH_BIN"
export PATH="$(dirname "$BASH_BIN"):$PATH"

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$TEST_HOME/.edc/skills"
cp -R "$ROOT/plugins/edc/prompt-bundles/"* "$TEST_HOME/.edc/skills/"
cp -R "$ROOT/plugins/edc/skills/"* "$TEST_HOME/.edc/skills/"

export HOME="$TEST_HOME"

for t in "$ROOT"/tests/hardening/t*.sh; do
  "$BASH_BIN" "$t" || exit 1
done
