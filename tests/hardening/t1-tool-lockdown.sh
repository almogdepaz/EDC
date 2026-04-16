#!/usr/bin/env bash
# Task 1 smoke test: verify --allowed-tools "Skill,Bash" appears in all claude -p calls
# Run from repo root: bash tests/hardening/t1-tool-lockdown.sh
set -euo pipefail

SCRIPT="scripts/edc-review.sh"

echo "=== T1: Subprocess tool lockdown ==="

# Count actual claude -p invocations (not comments/echo lines)
total=$(grep -E '^\s+claude -p' "$SCRIPT" | grep -v '^#' | wc -l | tr -d ' ')
locked=$(grep -E '^\s+claude -p' "$SCRIPT" | grep -v '^#' | grep -c -- '--allowed-tools "Skill,Bash"')

echo "claude -p actual invocations in script: $total"
echo "claude -p invocations with --allowed-tools \"Skill,Bash\": $locked"

if [ "$total" -ne "$locked" ]; then
  echo "FAIL: $((total - locked)) claude -p invocation(s) missing --allowed-tools lockdown"
  exit 1
fi

echo "PASS: all $locked claude -p invocation(s) are locked to Skill,Bash"
