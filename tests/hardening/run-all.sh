#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BASH_BIN="${BASH_BIN:-bash}"

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$TEST_HOME/.edc/skills"
cp -R "$ROOT/plugins/edc/prompt-bundles/"* "$TEST_HOME/.edc/skills/"
cp -R "$ROOT/plugins/edc/skills/"* "$TEST_HOME/.edc/skills/"
git -C "$ROOT" status --porcelain=v1 --untracked-files=all | LC_ALL=C sort >"$TEST_HOME/status-before"

export HOME="$TEST_HOME"

for t in "$ROOT"/tests/hardening/t*.sh; do
  "$BASH_BIN" "$t" || exit 1
done

git -C "$ROOT" status --porcelain=v1 --untracked-files=all | LC_ALL=C sort >"$TEST_HOME/status-after"
if ! diff -u "$TEST_HOME/status-before" "$TEST_HOME/status-after"; then
  echo "FAIL: hardening suite changed the repository checkout" >&2
  exit 1
fi
echo "PASS: hardening suite left repository status unchanged"
