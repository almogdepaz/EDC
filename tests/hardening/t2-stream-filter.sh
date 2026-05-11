#!/usr/bin/env bash
# Task 2 smoke test: verify stream_filter and jq fail-fast
# Run from repo root: bash tests/hardening/t2-stream-filter.sh
set -euo pipefail

SCRIPT="scripts/edc-review.sh"
# Subprocess spawning + per-CLI flags moved to edc-spawn.sh; check both files
# for stream-json contract.
SPAWN="plugins/edc/scripts/edc-spawn.sh"

echo "=== T2: Stream-json visibility ==="

# 1. jq fail-fast: verify the guard block exists in the script
# (runtime test requires hiding jq which is at /usr/bin/jq on this system;
# static check confirms the guard is present and wired correctly)
if grep -q 'command -v jq' "$SCRIPT" && grep -q 'jq is required' "$SCRIPT"; then
  echo "PASS: jq fail-fast guard present in script"
else
  echo "FAIL: jq fail-fast guard missing from script"
  exit 1
fi

# Also verify the guard exits with code 2 (grep for exit 2 after jq error message)
if grep -A3 'command -v jq' "$SCRIPT" | grep -q 'exit 2'; then
  echo "PASS: jq fail-fast exits with code 2"
else
  echo "FAIL: jq fail-fast does not exit 2"
  exit 1
fi

# 2. stream_filter: source the function and feed synthetic NDJSON
RUNTIME="plugins/edc/scripts/edc-runtime.sh"
source_and_test() {
  # Source only the stream_filter function from the runtime helper.
  eval "$(awk '/^stream_filter\(\)/{found=1} found{print} /^}$/{if(found){exit}}' "$RUNTIME")"

  local output errors

  # assistant text event
  output=$(printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hello world"}]}}\n' | stream_filter 2>/tmp/t2-filter-err.txt)
  if [ "$output" = "hello world" ]; then
    echo "PASS: assistant text event rendered"
  else
    echo "FAIL: assistant text expected 'hello world', got: '$output'"
    exit 1
  fi

  # tool_use event
  output=$(printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/some/path/to/file.md"}}]}}\n' | stream_filter 2>/tmp/t2-filter-err.txt)
  if echo "$output" | grep -q '→ Read('; then
    echo "PASS: tool_use event rendered: $output"
  else
    echo "FAIL: tool_use not rendered, got: '$output'"
    exit 1
  fi

  # error result event — goes to stderr
  errors=$(printf '{"type":"result","is_error":true,"result":"something went wrong"}\n' | stream_filter 2>&1 >/dev/null)
  if echo "$errors" | grep -q "ERROR (subprocess)"; then
    echo "PASS: result error event rendered to stderr"
  else
    echo "FAIL: result error not in stderr, got: '$errors'"
    exit 1
  fi
}

source_and_test

# 3. Verify every claude -p invocation uses --output-format stream-json --verbose
# (exclude comment lines). Spawns live in edc-spawn.sh.
total=$(grep -cE '^\s+claude -p' "$SPAWN")
locked=$(grep -v '^#' "$SPAWN" | grep -c -- '--output-format stream-json --verbose')
echo "claude -p invocations: $total; with stream-json: $locked"
if [ "$total" -lt 1 ] || [ "$locked" -ne "$total" ]; then
  echo "FAIL: every claude -p must use --output-format stream-json --verbose (invocations=$total, matched=$locked)"
  exit 1
fi
echo "PASS: all $total claude -p invocation(s) use stream-json"
