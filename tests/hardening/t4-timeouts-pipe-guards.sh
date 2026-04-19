#!/usr/bin/env bash
# Task 4 smoke test: timeouts + pipe guards
# Run from repo root: bash tests/hardening/t4-timeouts-pipe-guards.sh
set -euo pipefail

SCRIPT="scripts/edc-review.sh"

echo "=== T4: Timeouts + pipe guards ==="

# ── 4a: TIMEOUT_BIN detection logic present ───────────────────────────────────
if grep -q 'TIMEOUT_BIN' "$SCRIPT" && grep -q 'run_with_timeout' "$SCRIPT"; then
  echo "PASS: TIMEOUT_BIN detection and run_with_timeout present"
else
  echo "FAIL: timeout infrastructure missing from script"
  exit 1
fi

# ── 4b: all 3 claude -p calls wrapped with run_with_timeout ──────────────────
# Count only actual invocations (lines starting with spaces/tabs then run_with_timeout,
# not the function definition line or comments)
wrapped=$(grep -E '^\s+run_with_timeout [0-9]' "$SCRIPT" | wc -l | tr -d ' ')
if [ "$wrapped" -eq 3 ]; then
  echo "PASS: all 3 claude -p calls wrapped with run_with_timeout ($wrapped)"
else
  echo "FAIL: expected 3 wrapped calls, found $wrapped"
  exit 1
fi

# ── 4c: timeout limits match spec (1200/600/900) ──────────────────────────────
if grep -q 'run_with_timeout 1200' "$SCRIPT" && \
   grep -q 'run_with_timeout 600'  "$SCRIPT" && \
   grep -q 'run_with_timeout 900'  "$SCRIPT"; then
  echo "PASS: timeout limits 1200/600/900 present"
else
  echo "FAIL: expected timeout limits 1200, 600, 900 in script"
  exit 1
fi

# ── 4d: run_with_timeout actually works (non-timeout path) ───────────────────
# Set TIMEOUT_BIN explicitly (mirrors what the script detects) then source function
if command -v timeout > /dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  TIMEOUT_BIN=""
fi
eval "$(awk '/^run_with_timeout\(\)/{found=1} found{print} /^\}$/{if(found){exit}}' "$SCRIPT")"

result=$(run_with_timeout 5 "test-phase" echo "hello from timeout")
if [ "$result" = "hello from timeout" ]; then
  echo "PASS: run_with_timeout runs fast commands correctly"
else
  echo "FAIL: run_with_timeout failed fast command, got: '$result'"
  exit 1
fi

# ── 4e: run_with_timeout fires on exceeded time ───────────────────────────────
timeout_fired=0
run_with_timeout 1 "slow-test" sleep 5 2>/tmp/t4-timeout-err.txt || timeout_fired=1
if [ "$timeout_fired" -eq 1 ] && grep -q 'timed out' /tmp/t4-timeout-err.txt; then
  echo "PASS: run_with_timeout fires on exceeded time"
else
  echo "FAIL: run_with_timeout did not fire on slow command (exit: $timeout_fired)"
  cat /tmp/t4-timeout-err.txt
  exit 1
fi

# ── 4f: pipe guards — null-check on read_meta_last_commit ────────────────────
TMPDIR_T4=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T4"' EXIT

cd "$TMPDIR_T4"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
touch dummy.txt && git add dummy.txt && git commit -q -m "init"

mkdir -p .context
# Write malformed meta.json (no lastCommit field)
printf '{"modules":[]}' > .context/.meta.json

ORIG_DIR="$(cd - > /dev/null && pwd)"
result=0
bash "$ORIG_DIR/$SCRIPT" --check-context 2>/tmp/t4-pipe-err.txt || result=$?
if [ "$result" -ne 0 ] && grep -qi 'lastcommit\|lastCommit\|context' /tmp/t4-pipe-err.txt; then
  echo "PASS: malformed meta.json causes clear error (not silent empty-string comparison)"
else
  echo "FAIL: expected error on malformed meta.json, got exit $result"
  cat /tmp/t4-pipe-err.txt
  exit 1
fi

echo ""
echo "All T4 checks passed."
