#!/usr/bin/env bash
# Task 1 smoke test: verify claude -p invocations are locked down via --allowed-tools
# Run from repo root: bash tests/hardening/t1-tool-lockdown.sh
set -euo pipefail

SCRIPT="scripts/edc-review.sh"
EXPECTED_TOOLS='--allowed-tools "Skill,Bash,Read,Write,Edit,Grep,Glob"'

echo "=== T1: Subprocess tool lockdown ==="

total=$(grep -cE '^\s+claude -p' "$SCRIPT")
locked=$(grep -v '^#' "$SCRIPT" | grep -cF -- "$EXPECTED_TOOLS")

echo "claude -p actual invocations in script: $total"
echo "$EXPECTED_TOOLS occurrences (non-comment): $locked"

if [ "$total" -lt 1 ]; then
  echo "FAIL: expected >=1 claude -p invocation, found $total"
  exit 1
fi

if [ "$locked" -ne "$total" ]; then
  echo "FAIL: every claude -p must have $EXPECTED_TOOLS (invocations=$total, lockdowns=$locked)"
  exit 1
fi

echo "PASS: all $total claude -p invocation(s) have $EXPECTED_TOOLS lockdown"
