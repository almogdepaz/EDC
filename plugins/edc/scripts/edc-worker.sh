#!/usr/bin/env bash
# Execute one validated worker-pool task through the shared backend boundary.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "ERROR: edc-worker.sh requires one task JSON path" >&2
  exit 2
fi

task_file="$1"
if [ ! -f "$task_file" ]; then
  echo "ERROR: worker task file not found: $task_file" >&2
  exit 2
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"

read_task_field() {
  local field="$1"
  node -e '
    const fs = require("fs");
    const task = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const value = task[process.argv[2]];
    if ((typeof value !== "string" && typeof value !== "number") || String(value).length === 0) process.exit(2);
    process.stdout.write(String(value));
  ' "$task_file" "$field"
}

run_id=$(read_task_field runId) || { echo "ERROR: invalid worker task runId" >&2; exit 2; }
task_id=$(read_task_field id) || { echo "ERROR: invalid worker task id" >&2; exit 2; }
phase=$(read_task_field phase) || { echo "ERROR: invalid worker task phase" >&2; exit 2; }
timeout_secs=$(read_task_field timeoutSeconds) || { echo "ERROR: invalid worker task timeoutSeconds" >&2; exit 2; }
prompt_file=$(read_task_field promptFile) || { echo "ERROR: invalid worker task promptFile" >&2; exit 2; }

if [ "${EDC_RUN_ID:-}" != "$run_id" ] || [ "${EDC_TASK_ID:-}" != "$task_id" ] || [ "${EDC_TASK_PHASE:-}" != "$phase" ]; then
  echo "ERROR: worker task provenance does not match coordinator environment" >&2
  exit 2
fi

edc_require_agent_cli
edc_spawn "$phase" "$timeout_secs" --prompt-file "$prompt_file"
