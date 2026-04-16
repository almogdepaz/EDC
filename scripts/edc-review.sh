#!/usr/bin/env bash
# edc-review orchestrator
# All deterministic control flow for edc-review lives here.
#
# Usage:
#   edc-review.sh <target> [--baseline <ref>]         build mode (default — emit TASK lines)
#   edc-review.sh --auto <target> [--baseline <ref>]  self-driving mode (claude code only — spawns claude -p)
#   edc-review.sh --check-context                     assert .context/.meta.json fresh (no diff, no task gen)
#   edc-review.sh --consolidate                       merge per-module reports into final review file
#   edc-review.sh --verify                            assert context fresh + reports + final file exist
#
# Build mode exit codes:
#   0 — review-tasks/ written, TASK lines on stdout, proceed with skill
#   1 — context not ready (CONTEXT_MISSING or CONTEXT_STALE), see stdout
#   2 — bad arguments or environment error
#
# Consolidate / verify exit codes:
#   0 — all assertions pass
#   1 — assertion failed (missing report, missing final file, stale context)
#   2 — bad arguments or environment error

set -euo pipefail

# ── dependency check ─────────────────────────────────────────────────────────

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required (brew install jq / apt install jq)" >&2
  exit 2
fi

META=".context/.meta.json"

# ── helpers ──────────────────────────────────────────────────────────────────

# stream_filter: read NDJSON from claude -p --output-format stream-json --verbose
# and print human-readable progress lines.
stream_filter() {
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # type=assistant with text content
    text=$(printf '%s' "$line" | jq -r 'if .type == "assistant" then (.message.content // []) | map(select(.type == "text") | .text) | join("") else empty end' 2>/dev/null)
    if [ -n "$text" ]; then
      printf '%s\n' "$text"
      continue
    fi
    # type=tool_use — show tool name + first arg truncated
    tool_info=$(printf '%s' "$line" | jq -r 'if .type == "assistant" then (.message.content // []) | map(select(.type == "tool_use") | "→ \(.name)(\((.input | to_entries | first | .value // "") | tostring | .[0:80]))") | .[] else empty end' 2>/dev/null)
    if [ -n "$tool_info" ]; then
      printf '%s\n' "$tool_info"
      continue
    fi
    # type=result with is_error=true
    err=$(printf '%s' "$line" | jq -r 'if .type == "result" and .is_error == true then "ERROR (subprocess): \(.result // "unknown error")" else empty end' 2>/dev/null)
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
    fi
  done
}

final_review_filename() {
  # derive consolidated review filename from a target string
  local target="$1"
  echo "review-$(echo "$target" | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-40).md"
}

read_meta_last_commit() {
  grep -o '"lastCommit"[[:space:]]*:[[:space:]]*"[^"]*"' "$META" \
    | head -1 \
    | sed 's/.*"lastCommit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

manifest_target() {
  grep -o '"target"[[:space:]]*:[[:space:]]*"[^"]*"' review-tasks/manifest.json \
    | head -1 \
    | sed 's/.*"target"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

manifest_modules() {
  # one module name per line
  grep -o '"module"[[:space:]]*:[[:space:]]*"[^"]*"' review-tasks/manifest.json \
    | sed 's/.*"module"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

assert_context_fresh() {
  if [ ! -f "$META" ]; then
    echo "ERROR: context missing ($META not found)" >&2
    return 1
  fi
  local head last_commit
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "ERROR: not a git repo" >&2; return 1; }
  last_commit=$(read_meta_last_commit)
  if [ "$last_commit" != "$head" ]; then
    echo "ERROR: context stale (built at: $last_commit, HEAD: $head)" >&2
    return 1
  fi
  # content validation: context.md must be non-trivial (≥500 bytes, has ## heading)
  local ctx=".context/context.md"
  if [ ! -f "$ctx" ]; then
    echo "ERROR: context file missing ($ctx)" >&2
    return 1
  fi
  local ctx_size
  ctx_size=$(wc -c < "$ctx")
  if [ "$ctx_size" -lt 500 ]; then
    echo "ERROR: $ctx is too small ($ctx_size bytes < 500) — likely a stub" >&2
    return 1
  fi
  if ! grep -q '^##' "$ctx"; then
    echo "ERROR: $ctx has no ## headings — likely a stub" >&2
    return 1
  fi
}

# assert_report_valid <module>: require report ≥200 bytes with at least one ## heading
assert_report_valid() {
  local module="$1"
  local report="review-tasks/report-${module}.md"
  if [ ! -f "$report" ]; then
    echo "ERROR: missing $report" >&2
    return 1
  fi
  local size
  size=$(wc -c < "$report")
  if [ "$size" -lt 200 ]; then
    echo "ERROR: $report is too small ($size bytes < 200) — likely a stub (module: $module)" >&2
    return 1
  fi
  if ! grep -q '^##' "$report"; then
    echo "ERROR: $report has no ## headings — likely a stub (module: $module)" >&2
    return 1
  fi
}

# ── check-context mode ───────────────────────────────────────────────────────

check_context_mode() {
  assert_context_fresh || exit 1
  echo "OK"
}

# ── consolidate mode ─────────────────────────────────────────────────────────

consolidate_mode() {
  if [ ! -f review-tasks/manifest.json ]; then
    echo "ERROR: review-tasks/manifest.json missing — run build mode first" >&2
    exit 1
  fi

  local target final modules missing=0
  target=$(manifest_target)
  final=$(final_review_filename "$target")
  modules=$(manifest_modules)

  if [ -z "$modules" ]; then
    echo "ERROR: no modules in manifest.json" >&2
    exit 1
  fi

  # verify every expected report is present and non-trivial before writing final file
  while IFS= read -r module; do
    [ -z "$module" ] && continue
    assert_report_valid "$module" || missing=1
  done <<< "$modules"

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi

  # write final file
  {
    echo "# Review: ${target}"
    echo ""
    echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "**HEAD:** $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "**Modules reviewed:** $(echo "$modules" | tr '\n' ' ')"
    echo ""
    echo "---"
    echo ""
    while IFS= read -r module; do
      [ -z "$module" ] && continue
      echo "## Module: \`${module}\`"
      echo ""
      cat "review-tasks/report-${module}.md"
      echo ""
      echo "---"
      echo ""
    done <<< "$modules"
  } > "$final"

  echo "Consolidated: $final"
}

# ── verify mode ──────────────────────────────────────────────────────────────

verify_mode() {
  assert_context_fresh || exit 1

  if [ ! -f review-tasks/manifest.json ]; then
    echo "ERROR: review-tasks/manifest.json missing" >&2
    exit 1
  fi

  local target final modules missing=0
  target=$(manifest_target)
  final=$(final_review_filename "$target")
  modules=$(manifest_modules)

  while IFS= read -r module; do
    [ -z "$module" ] && continue
    if [ ! -f "review-tasks/report-${module}.md" ]; then
      echo "ERROR: missing review-tasks/report-${module}.md" >&2
      missing=1
    fi
  done <<< "$modules"

  if [ ! -f "$final" ]; then
    echo "ERROR: missing final review file ($final)" >&2
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi

  echo "Verified: $final"
}

# ── auto mode (claude code only) ─────────────────────────────────────────────
#
# Self-driving pipeline: detect context state, spawn `claude -p` for each phase,
# verify outputs, consolidate, verify. The orchestrator script owns every decision;
# the spawned agents have one job each. Requires `claude` on PATH.

auto_mode() {
  if ! command -v claude > /dev/null 2>&1; then
    echo "ERROR: --auto mode requires 'claude' CLI on PATH" >&2
    exit 2
  fi

  local target="$1"; shift
  local extra_args=("$@")

  # Attempt 1: try to build review tasks
  local out
  out=$(bash "$0" "$target" "${extra_args[@]}" 2>&1) || true
  local first_line
  first_line=$(echo "$out" | head -1)

  # Recover from missing/stale context (one shot)
  case "$first_line" in
    CONTEXT_MISSING)
      echo "→ context missing, spawning claude -p for edc-build..."
      claude -p --output-format stream-json --verbose \
        --allowed-tools "Skill,Bash" \
        "Invoke the edc:edc-build skill. Do not perform any other task." \
        | stream_filter \
        || { echo "ERROR: edc-build invocation failed" >&2; exit 1; }
      ;;
    CONTEXT_STALE)
      echo "→ context stale, spawning claude -p for edc-update..."
      claude -p --output-format stream-json --verbose \
        --allowed-tools "Skill,Bash" \
        "Invoke the edc:edc-update skill. Do not perform any other task." \
        | stream_filter \
        || { echo "ERROR: edc-update invocation failed" >&2; exit 1; }
      ;;
  esac

  if [ "$first_line" = "CONTEXT_MISSING" ] || [ "$first_line" = "CONTEXT_STALE" ]; then
    bash "$0" --check-context > /dev/null \
      || { echo "ERROR: context still not ready after recovery" >&2; exit 1; }
    # Attempt 2: build tasks now that context is ready
    out=$(bash "$0" "$target" "${extra_args[@]}" 2>&1) || true
  fi

  if ! echo "$out" | grep -q "^Review tasks ready"; then
    echo "ERROR: script did not produce review tasks. Output:" >&2
    echo "$out" >&2
    exit 1
  fi

  # Parse TASK lines
  local tasks
  tasks=$(echo "$out" | grep '^TASK ' | sed 's/^TASK //')
  if [ -z "$tasks" ]; then
    echo "ERROR: no TASK lines in script output" >&2
    exit 1
  fi

  # Spawn one claude -p per module
  while IFS= read -r task_path; do
    [ -z "$task_path" ] && continue
    local module
    module=$(basename "$task_path" .md)
    echo "→ reviewing module: $module"
    claude -p --output-format stream-json --verbose \
      --allowed-tools "Skill,Bash" \
      "Invoke the edc:edc-review skill with arguments: --task-file $task_path. Do not perform any other task." \
      | stream_filter \
      || { echo "ERROR: review invocation failed for module $module" >&2; exit 1; }
    assert_report_valid "$module" \
      || { echo "ERROR: report validation failed for module $module" >&2; exit 1; }
  done <<< "$tasks"

  # Consolidate + verify
  bash "$0" --consolidate || { echo "ERROR: consolidation failed" >&2; exit 1; }
  bash "$0" --verify     || { echo "ERROR: verification failed" >&2; exit 1; }
}

# ── build mode ───────────────────────────────────────────────────────────────

build_mode() {
  local target="$1"; shift
  local baseline=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --baseline) baseline="$2"; shift 2 ;;
      *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
  done

  # Step 1: context gate
  local head
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "ERROR: not a git repo" >&2; exit 2; }

  if [ ! -f "$META" ]; then
    echo "CONTEXT_MISSING"
    echo "No .context/.meta.json found. Run edc-build before reviewing."
    exit 1
  fi

  local last_commit
  last_commit=$(read_meta_last_commit)
  if [ "$last_commit" != "$head" ]; then
    echo "CONTEXT_STALE"
    echo "Context is stale (built at: $last_commit, HEAD: $head). Run edc-update before reviewing."
    exit 1
  fi

  # Step 2: get changed files
  local files
  if [[ "$target" == https://* ]]; then
    files=$(gh pr diff "$target" --name-only 2>/dev/null)
  elif [ -f "$target" ]; then
    files=$(grep '^+++ b/' "$target" | sed 's|^+++ b/||')
  else
    local base="${baseline:-${target}^}"
    files=$(git diff "${base}..${target}" --name-only)
  fi

  if [ -z "$files" ]; then
    echo "ERROR: no changed files found for target: $target" >&2
    exit 2
  fi

  # Step 3: group by top-level dir
  declare -A MODULE_FILES
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local dir
    dir=$(dirname "$file" | cut -d'/' -f1)
    [ "$dir" = "." ] && dir="root"
    MODULE_FILES["$dir"]+="${file}"$'\n'
  done <<< "$files"

  # Step 4: write review-tasks/
  rm -rf review-tasks
  mkdir -p review-tasks

  local sorted_modules
  sorted_modules=$(printf '%s\n' "${!MODULE_FILES[@]}" | sort)

  # manifest.json (script-internal source of truth for consolidate/verify)
  {
    echo "{"
    echo "  \"target\": \"$target\","
    echo "  \"baseline\": \"$baseline\","
    echo "  \"head\": \"$head\","
    echo "  \"modules\": ["
    local first=1
    while IFS= read -r module; do
      [ "$first" -eq 0 ] && echo "    ,"
      echo -n "    { \"module\": \"$module\", \"files\": ["
      local file_json
      file_json=$(echo "${MODULE_FILES[$module]}" \
        | grep -v '^$' \
        | sed 's/^/"/;s/$/"/' \
        | tr '\n' ',' \
        | sed 's/,$//')
      echo -n "$file_json"
      echo -n "] }"
      first=0
    done <<< "$sorted_modules"
    echo ""
    echo "  ]"
    echo "}"
  } > review-tasks/manifest.json

  # per-module task files
  while IFS= read -r module; do
    local file_list baseline_line
    file_list=$(echo "${MODULE_FILES[$module]}" | grep -v '^$' | sed 's/^/- /')
    baseline_line=""
    [ -n "$baseline" ] && baseline_line=$'\n'"## Baseline"$'\n'"${baseline}"

    cat > "review-tasks/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${target}${baseline_line}

## Files to review
${file_list}

## Instructions

1. Read \`.context/context.md\` — module map, invariants, trust boundaries
2. Read \`.context/issues.md\` if it exists — cross-reference known issues against the files above
3. Read \`.context/${module}.md\` if it exists — deep per-module context, invariants, call graphs
4. Use the edc-review skill to perform the full review on the files listed above
5. Write your report to \`review-tasks/report-${module}.md\`

DO NOT write your own review methodology.
DO NOT skip reading the context files.
USE the edc-review skill.
TASK
  done <<< "$sorted_modules"

  # Done — emit TASK lines for the agent to iterate
  echo ""
  echo "Review tasks ready."
  echo ""
  while IFS= read -r module; do
    echo "TASK review-tasks/${module}.md"
  done <<< "$sorted_modules"
}

# ── dispatch ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  --auto)
    shift
    if [ -z "${1:-}" ]; then
      echo "ERROR: --auto requires a target" >&2
      exit 2
    fi
    auto_mode "$@"
    ;;
  --check-context)
    check_context_mode
    ;;
  --consolidate)
    consolidate_mode
    ;;
  --verify)
    verify_mode
    ;;
  "")
    echo "ERROR: target required (PR URL, commit SHA, or diff path)" >&2
    echo "Usage: edc-review.sh <target> [--baseline <ref>]" >&2
    echo "       edc-review.sh --auto <target> [--baseline <ref>]" >&2
    echo "       edc-review.sh --check-context" >&2
    echo "       edc-review.sh --consolidate" >&2
    echo "       edc-review.sh --verify" >&2
    exit 2
    ;;
  *)
    build_mode "$@"
    ;;
esac
