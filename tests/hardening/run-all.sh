#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BASH_BIN="${BASH_BIN:-bash}"

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$TEST_HOME/.edc/skills"
cp -R "$ROOT/plugins/edc/prompt-bundles/"* "$TEST_HOME/.edc/skills/"
cp -R "$ROOT/plugins/edc/skills/"* "$TEST_HOME/.edc/skills/"

export HOME="$TEST_HOME"

for t in "$ROOT"/tests/hardening/t*.sh; do
  "$BASH_BIN" "$t" || exit 1
done
