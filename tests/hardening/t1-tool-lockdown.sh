#!/usr/bin/env bash
# Task 1 smoke test: verify --allowed-tools "Skill,Bash" appears in all claude -p calls
# Run from repo root: bash tests/hardening/t1-tool-lockdown.sh
set -euo pipefail

SCRIPT="scripts/edc-review.sh"

echo "=== T1: Subprocess tool lockdown ==="

# Count actual claude -p invocations (continuation lines — in pipelines after run_with_timeout)
total=$(grep -E '^\s+claude -p' "$SCRIPT" | wc -l | tr -d ' ')

# Count --allowed-tools "Skill,Bash" lines in non-comment context
# Each claude -p invocation must have exactly one --allowed-tools line nearby
locked=$(grep -v '^#' "$SCRIPT" | grep -c -- '--allowed-tools "Skill,Bash"')

echo "claude -p actual invocations in script: $total"
echo "--allowed-tools \"Skill,Bash\" occurrences (non-comment): $locked"

if [ "$total" -ne 3 ]; then
  echo "FAIL: expected 3 claude -p invocations, found $total"
  exit 1
fi

if [ "$locked" -ne 3 ]; then
  echo "FAIL: expected 3 --allowed-tools lockdowns, found $locked"
  exit 1
fi

echo "PASS: all 3 claude -p invocations have --allowed-tools \"Skill,Bash\" lockdown"
