#!/usr/bin/env bash
# Run a Cursor-backed PR review benchmark in two modes:
#   1. ignore-context: no EDC build/update, no manifest/routing, pure baseline task
#   2. context: normal EDC context-backed review with auto build/update recovery
#
# Output: artifacts + spend telemetry under benchmark/pr-review/results/<run-id>/

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  run-cursor-pr-benchmark.sh --repo <path> --target <target> [--base <ref>] [options]

Options:
  --repo <path>              repository to review (default: current directory)
  --target <target>          PR URL, commit/ref, HEAD, or diff file (default: HEAD)
  --base <ref>               base ref for git target diffs (forwarded to edc-review.sh)
  --mode both|ignore-context|no-refresh|context
                            which benchmark cells to run (default: both)
  --out <dir>                output directory (default: benchmark/pr-review/results/<timestamp>-<repo>-<target>)
  --force-build-context      run edc-build.sh --force before the context review
  --ignore <glob>            forwarded to edc-review.sh (repeatable)
  --review-timeout <secs>    EDC_REVIEW_TIMEOUT for each review subprocess
  --build-timeout <secs>     EDC_BUILD_TIMEOUT for context recovery/build
  -h, --help                 show this help

Examples:
  bash /path/to/edc/benchmark/pr-review/run-cursor-pr-benchmark.sh \
    --repo ~/Dev/chia-blockchain \
    --target HEAD \
    --base main

  bash /path/to/edc/benchmark/pr-review/run-cursor-pr-benchmark.sh \
    --repo ~/Dev/chia-blockchain \
    --target https://github.com/Chia-Network/chia-blockchain/pull/12345 \
    --force-build-context
EOF
}

resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"
EDC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_SH="$EDC_ROOT/plugins/edc/scripts/edc-review.sh"
BUILD_SH="$EDC_ROOT/plugins/edc/scripts/edc-build.sh"

repo="$(pwd)"
target="HEAD"
base=""
mode="both"
out_dir=""
force_build_context=0
review_timeout=""
build_timeout=""
ignore_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --out) out_dir="$2"; shift 2 ;;
    --force-build-context) force_build_context=1; shift ;;
    --ignore)
      [ "$#" -ge 2 ] || { echo "ERROR: --ignore requires a glob" >&2; exit 2; }
      ignore_args+=(--ignore "$2")
      shift 2
      ;;
    --review-timeout) review_timeout="$2"; shift 2 ;;
    --build-timeout) build_timeout="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

case "$mode" in
  both|ignore-context|no-refresh|context) ;;
  *) echo "ERROR: --mode must be one of: both, ignore-context, no-refresh, context" >&2; exit 2 ;;
esac

[ -f "$REVIEW_SH" ] || { echo "ERROR: missing $REVIEW_SH" >&2; exit 2; }
[ -f "$BUILD_SH" ] || { echo "ERROR: missing $BUILD_SH" >&2; exit 2; }
command -v cursor >/dev/null 2>&1 || { echo "ERROR: cursor not found on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

repo="$(cd "$repo" && pwd)"
repo_name="$(basename "$repo")"
target_slug="$(printf '%s' "$target" | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-40)"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-${repo_name}-${target_slug}"
if [ -z "$out_dir" ]; then
  out_dir="$EDC_ROOT/benchmark/pr-review/results/$run_id"
fi
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

base_args=()
[ -n "$base" ] && base_args+=(--base "$base")
review_args=("$target" "${base_args[@]}" "${ignore_args[@]}")
final_file="review-${target_slug}.md"

sum_metrics() {
  local log_path="$1"
  if [ ! -s "$log_path" ]; then
    jq -n '{spawns:0,total_cost_usd:null,has_null_cost:true,duration_s:0,input_tokens:0,output_tokens:0,cache_read_tokens:0,cache_write_tokens:0,phases:[]}'
    return 0
  fi
  jq -s '
    {
      spawns: length,
      total_cost_usd: (if any(.total_cost_usd == null) then null else (map(.total_cost_usd) | add) end),
      has_null_cost: any(.total_cost_usd == null),
      duration_s: (map(.duration_s // 0) | add),
      input_tokens: (map(.input_tokens // 0) | add),
      output_tokens: (map(.output_tokens // 0) | add),
      cache_read_tokens: (map(.cache_read_tokens // 0) | add),
      cache_write_tokens: (map(.cache_write_tokens // 0) | add),
      phases: map({phase, backend, model_requested, model_observed, duration_s, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_cost_usd})
    }
  ' "$log_path"
}

write_row() {
  local cell="$1" metrics="$2"
  jq -r --arg cell "$cell" '[
    $cell,
    (.spawns|tostring),
    (.total_cost_usd // "null" | tostring),
    (.duration_s|tostring),
    (.input_tokens|tostring),
    (.output_tokens|tostring),
    (.cache_read_tokens|tostring),
    (.cache_write_tokens|tostring),
    (.has_null_cost|tostring)
  ] | @tsv' "$metrics" >> "$out_dir/summary.tsv"
}

run_cell() {
  local cell="$1"
  shift
  local cell_dir="$out_dir/$cell"
  mkdir -p "$cell_dir/transcripts"
  rm -f "$cell_dir/spawn-log.jsonl" "$cell_dir/run.log" "$cell_dir/metrics.json"

  echo "=== running $cell ===" | tee -a "$out_dir/run.log"
  (
    cd "$repo"
    export EDC_AGENT_CLI=cursor
    export EDC_SPAWN_LOG="$cell_dir/spawn-log.jsonl"
    export EDC_TRANSCRIPT_DIR="$cell_dir/transcripts"
    export EDC_PRESERVE_TRANSCRIPTS=1
    [ -n "$review_timeout" ] && export EDC_REVIEW_TIMEOUT="$review_timeout"
    [ -n "$build_timeout" ] && export EDC_BUILD_TIMEOUT="$build_timeout"
    "$@"
  ) 2>&1 | tee "$cell_dir/run.log"

  if [ -f "$repo/$final_file" ]; then
    cp "$repo/$final_file" "$cell_dir/$final_file"
  else
    echo "WARN: final review file not found: $repo/$final_file" | tee -a "$out_dir/run.log"
  fi

  sum_metrics "$cell_dir/spawn-log.jsonl" > "$cell_dir/metrics.json"
  write_row "$cell" "$cell_dir/metrics.json"
}

{
  echo "# Cursor PR review benchmark"
  echo ""
  echo "- run_id: $run_id"
  echo "- repo: $repo"
  echo "- target: $target"
  echo "- base: ${base:-}"
  echo "- mode: $mode"
  echo "- force_build_context: $force_build_context"
  echo "- edc_root: $EDC_ROOT"
  echo "- head: $(cd "$repo" && git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "- started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$out_dir/README.md"

printf 'cell\tspawns\ttotal_cost_usd\tduration_s\tinput_tokens\toutput_tokens\tcache_read_tokens\tcache_write_tokens\thas_null_cost\n' > "$out_dir/summary.tsv"
printf 'mode\tfinding_id\tstatus\tseverity\tfile\tsummary\tnotes\n' > "$out_dir/manual-findings.tsv"

case "$mode" in
  both|ignore-context)
    run_cell "ignore-context" env EDC_CONTEXT_DIR=".edc-bench/ignore-context" bash "$REVIEW_SH" "${review_args[@]}" --ignore-context
    ;;
  no-refresh)
    run_cell "no-refresh" bash "$REVIEW_SH" "${review_args[@]}" --no-context-refresh
    ;;
esac

case "$mode" in
  both|context)
    if [ "$force_build_context" -eq 1 ]; then
      run_cell "context-build" bash "$BUILD_SH" --force
    fi
    run_cell "context-review" bash "$REVIEW_SH" "${review_args[@]}"
    ;;
esac

{
  echo ""
  echo "## Summary"
  echo ""
  echo '```tsv'
  cat "$out_dir/summary.tsv"
  echo '```'
  echo ""
  echo "## Manual findings adjudication"
  echo ""
  echo "Fill manual-findings.tsv after reading each review file:"
  echo ""
  echo "- status: accepted | duplicate | false-positive | unclear"
  echo "- one row per substantive finding"
} >> "$out_dir/README.md"

echo ""
echo "benchmark artifacts: $out_dir"
echo "summary:"
cat "$out_dir/summary.tsv"
