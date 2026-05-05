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

# ── 4b: every agent phase (build/update/review) wrapped with run_with_timeout ─
# Matches both literal seconds (`run_with_timeout 60`) and env-default form
# (`run_with_timeout "${EDC_*_TIMEOUT:-N}"`).
wrapped=$(grep -cE '^\s+run_with_timeout ("\$\{EDC_[A-Z_]+_TIMEOUT:-[0-9]+\}"|[0-9]+)' "$SCRIPT")
if [ "$wrapped" -ge 3 ]; then
  echo "PASS: agent phases wrapped with run_with_timeout ($wrapped)"
else
  echo "FAIL: expected >=3 wrapped calls (build/update/review), found $wrapped"
  exit 1
fi

# ── 4c: per-phase timeouts configurable via env vars with defaults ────────────
missing=""
for var in EDC_BUILD_TIMEOUT EDC_UPDATE_TIMEOUT EDC_REVIEW_TIMEOUT; do
  if ! grep -qE "run_with_timeout \"\\\$\\{$var:-[0-9]+\\}\"" "$SCRIPT"; then
    missing="$missing $var"
  fi
done
if [ -z "$missing" ]; then
  echo "PASS: EDC_{BUILD,UPDATE,REVIEW}_TIMEOUT env overrides with defaults present"
else
  echo "FAIL: missing env-override timeouts:$missing"
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
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
git init -q
git config user.email "test@test.com"
git config user.name "Test"
git config commit.gpgsign false
touch dummy.txt && git add dummy.txt && git commit -q -m "init"

mkdir -p .context
# Write malformed manifest.json (no sourceCommit field)
printf '{"schemaVersion":2,"modules":[]}' > .context/manifest.json

ORIG_DIR="$(cd - > /dev/null && pwd)"
result=0
bash "$ORIG_DIR/$SCRIPT" --check-context 2>/tmp/t4-pipe-err.txt || result=$?
if [ "$result" -ne 0 ] && grep -qi 'sourcecommit\|sourceCommit\|context' /tmp/t4-pipe-err.txt; then
  echo "PASS: malformed manifest.json causes clear error (not silent empty-string comparison)"
else
  echo "FAIL: expected error on malformed manifest.json, got exit $result"
  cat /tmp/t4-pipe-err.txt
  exit 1
fi

echo ""
echo "All T4 checks passed."
