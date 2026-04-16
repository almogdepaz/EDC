#!/usr/bin/env bash
# edc-review orchestrator
# All deterministic control flow for edc-review lives here.
#
# Usage:
#   edc-review.sh <target> [--baseline <ref>]   build mode (default)
#   edc-review.sh --check-context               assert .context/.meta.json fresh (no diff, no task gen)
#   edc-review.sh --consolidate                 merge per-module reports into final review file
#   edc-review.sh --verify                      assert context fresh + reports + final file exist
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

META=".context/.meta.json"

# ── helpers ──────────────────────────────────────────────────────────────────

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

  # verify every expected report exists before writing final file
  while IFS= read -r module; do
    [ -z "$module" ] && continue
    if [ ! -f "review-tasks/report-${module}.md" ]; then
      echo "ERROR: missing review-tasks/report-${module}.md" >&2
      missing=1
    fi
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
    echo "       edc-review.sh --check-context" >&2
    echo "       edc-review.sh --consolidate" >&2
    echo "       edc-review.sh --verify" >&2
    exit 2
    ;;
  *)
    build_mode "$@"
    ;;
esac
