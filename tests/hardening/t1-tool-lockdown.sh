#!/usr/bin/env bash
# Task 1 smoke test: verify claude -p invocations are locked down via --allowed-tools
# Run from repo root: bash tests/hardening/t1-tool-lockdown.sh
set -euo pipefail

# All agent-CLI spawns now live in the shared helper edc-lib.sh (SPAWN section), sourced by
# every orchestrator. The lockdown contract pins claude -p invocations there.
SCRIPT="plugins/edc/scripts/edc-lib.sh"
LEGACY_TOOLS='--allowed-tools "Skill,Bash,Read,Write,Edit,Grep,Glob"'
PROMPT_FILE_TOOLS='--allowed-tools "Read,Write,Bash,Grep,Glob"'

echo "=== T1: Subprocess tool lockdown ==="

# Current edc-lib.sh builds the claude invocation as an argv array. Count the
# actual array seed, not old multi-line shell text that started with `claude -p`.
total=$(grep -cF 'local -a cmd=(claude -p' "$SCRIPT" || true)
legacy_locked=$(grep -v '^#' "$SCRIPT" | grep -cF -- "$LEGACY_TOOLS" || true)
prompt_file_locked=$(grep -v '^#' "$SCRIPT" | grep -cF -- "$PROMPT_FILE_TOOLS" || true)
all_lockdowns=$(grep -v '^#' "$SCRIPT" | grep -cF -- '--allowed-tools "' || true)

echo "claude argv-array invocations in script: $total"
echo "$LEGACY_TOOLS occurrences (non-comment): $legacy_locked"
echo "$PROMPT_FILE_TOOLS occurrences (non-comment): $prompt_file_locked"

if [ "$total" -ne 1 ]; then
  echo "FAIL: expected exactly 1 claude argv-array invocation, found $total"
  exit 1
fi

if [ "$legacy_locked" -ne 1 ]; then
  echo "FAIL: legacy prompt mode must have exactly one $LEGACY_TOOLS lockdown (found $legacy_locked)"
  exit 1
fi

if [ "$prompt_file_locked" -ne 1 ]; then
  echo "FAIL: prompt-file mode must have exactly one $PROMPT_FILE_TOOLS lockdown (found $prompt_file_locked)"
  exit 1
fi

if [ "$all_lockdowns" -ne 2 ]; then
  echo "FAIL: expected exactly 2 non-comment --allowed-tools entries, found $all_lockdowns"
  exit 1
fi

echo "PASS: claude spawn has lockdowns for legacy and prompt-file modes"
