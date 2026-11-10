#!/usr/bin/env bash
# Task 2 smoke test: verify stream_filter visibility without jq
# Run from repo root: bash tests/hardening/t2-stream-filter.sh
set -euo pipefail

SCRIPT="plugins/edc/scripts/edc-review.sh"
# Stream filtering lives in edc-lib; backend argv construction is extracted.
RUNTIME="plugins/edc/scripts/edc-lib.sh"
SPAWN="plugins/edc/scripts/edc-agent-backends.sh"
TMPDIR_T2=$(mktemp -d "${TMPDIR:-/tmp}/edc-test.XXXXXX")
trap 'rm -rf "$TMPDIR_T2"' EXIT
T2_FILTER_ERR="$TMPDIR_T2/filter-err.txt"

echo "=== T2: Stream-json visibility ==="

# 1. runtime has no jq fail-fast dependency; stream_filter delegates to node.
if ! grep -q 'command -v jq\|jq is required' "$SCRIPT" && grep -q 'stream-filter.mjs' "$RUNTIME"; then
  echo "PASS: stream filtering no longer requires jq"
else
  echo "FAIL: stream filtering still references jq dependency"
  exit 1
fi

# 2. stream_filter: source the function and feed synthetic NDJSON
source_and_test() {
  # Source only the stream_filter function from the runtime helper.
  eval "$(awk '/^stream_filter\(\)/{found=1} found{print} /^}$/{if(found){exit}}' "$RUNTIME")"
  EDC_STREAM_FILTER_CLI="plugins/edc/hooks/lib/stream-filter.mjs"

  local output errors

  # assistant text event
  output=$(printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hello world"}]}}\n' | stream_filter 2>"$T2_FILTER_ERR")
  if [ "$output" = "hello world" ]; then
    echo "PASS: assistant text event rendered"
  else
    echo "FAIL: assistant text expected 'hello world', got: '$output'"
    exit 1
  fi

  # tool_use event
  output=$(printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/some/path/to/file.md"}}]}}\n' | stream_filter 2>"$T2_FILTER_ERR")
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

# 2b. Model-rejection classification must not stop a healthy worker.
FILTER_CLI="plugins/edc/hooks/lib/stream-filter.mjs"
run_filter() {
  rc=0
  printf "%s\n" "$@" | STREAM_FILTER_MODEL="" STREAM_FILTER_CAPTURE="" node "$FILTER_CLI" >/dev/null 2>"$T2_FILTER_ERR" || rc=$?
}

run_filter '{"type":"tool_execution_end","isError":true,"result":{"error":"path src/models/x.ts not found"}}'
if [ "$rc" -eq 0 ] && grep -q 'ERROR (subprocess): path src/models/x.ts not found' "$T2_FILTER_ERR"; then
  echo "PASS: tool error with a models path is not a model rejection"
else
  echo "FAIL: tool error was classified as a model rejection (exit=$rc)"; cat "$T2_FILTER_ERR"; exit 1
fi

run_filter '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' 'warning: model cache not found'
if [ "$rc" -eq 0 ]; then
  echo "PASS: plain line after a structured event is not a model rejection"
else
  echo "FAIL: plain line after a structured event stopped the run (exit=$rc)"; cat "$T2_FILTER_ERR"; exit 1
fi

run_filter 'Error: Model "bad-model" not found.'
if [ "$rc" -eq 87 ]; then
  echo "PASS: plain startup model rejection still exits 87"
else
  echo "FAIL: plain startup model rejection must exit 87 (exit=$rc)"; exit 1
fi

run_filter '{"type":"result","is_error":true,"result":"model_not_found: bad-model"}'
if [ "$rc" -eq 87 ]; then
  echo "PASS: structured provider model rejection still exits 87"
else
  echo "FAIL: structured provider model rejection must exit 87 (exit=$rc)"; exit 1
fi

# 3. Verify the claude argv-array seed uses --output-format stream-json --verbose.
# Spawns live in the backend module and are built as arrays.
total=$(grep -cF 'local -a cmd=(claude -p' "$SPAWN" || true)
locked=$(grep -v '^#' "$SPAWN" | grep -cF -- 'local -a cmd=(claude -p --output-format stream-json --verbose' || true)
echo "claude argv-array invocations: $total; with stream-json: $locked"
if [ "$total" -ne 1 ] || [ "$locked" -ne "$total" ]; then
  echo "FAIL: every claude argv-array spawn must use --output-format stream-json --verbose (invocations=$total, matched=$locked)"
  exit 1
fi
echo "PASS: claude argv-array spawn uses stream-json"
