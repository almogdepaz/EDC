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

# Run every test: shell tests first, then Python tests. The default stops at
# the first failure. EDC_TEST_KEEP_GOING=1 runs all tests and lists every failure.
failed=()
for t in "$ROOT"/tests/hardening/t*.sh "$ROOT"/tests/hardening/t*.py; do
  [ -e "$t" ] || continue
  start=$SECONDS
  rc=0
  case "$t" in
    *.py) python3 "$t" || rc=$? ;;
    *) "$BASH_BIN" "$t" || rc=$? ;;
  esac
  printf '%s %s (%ss)\n' "$([ "$rc" -eq 0 ] && echo ok || echo FAILED)" "$(basename "$t")" "$((SECONDS - start))" >&2
  if [ "$rc" -ne 0 ]; then
    failed+=("$(basename "$t")")
    [ "${EDC_TEST_KEEP_GOING:-0}" = 1 ] || break
  fi
done
if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAIL: ${failed[*]}" >&2
  exit 1
fi

git -C "$ROOT" status --porcelain=v1 --untracked-files=all | LC_ALL=C sort >"$TEST_HOME/status-after"
if ! diff -u "$TEST_HOME/status-before" "$TEST_HOME/status-after"; then
  echo "FAIL: hardening suite changed the repository checkout" >&2
  exit 1
fi
echo "PASS: hardening suite left repository status unchanged"
