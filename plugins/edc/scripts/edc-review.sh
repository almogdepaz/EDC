#!/usr/bin/env bash
# bash >= 4 required: uses declare -A (assoc arrays) and set -u with empty arrays
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
# edc-review orchestrator
# All deterministic control flow for edc-review lives here.
#
# Usage:
#   edc-review.sh <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject]
#                                                     full review pipeline (default — spawns agent subprocesses via EDC_AGENT_CLI)
#   edc-review.sh --base <ref>                         shorthand for: HEAD --base <ref>
#   edc-review.sh --build <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject]
#                                                     task-generation only (emit TASK lines, no subprocess spawning)
#   edc-review.sh --check-context                      assert .context/manifest.json fresh (no diff, no task gen)
#   edc-review.sh --consolidate                        merge per-module reports into final review file
#   edc-review.sh --verify                             assert context fresh + reports + final file exist
#
# --build exit codes:
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

MANIFEST=".context/manifest.json"
# Resolve SCRIPT_DIR through symlinks so sibling helpers (edc-assert-fresh.sh,
# edc-clean-slate.sh) are found relative to the real script location, not the
# invocation path. scripts/edc-review.sh is a symlink to
# plugins/edc/scripts/edc-review.sh; without symlink resolution the helpers
# would be looked up under scripts/, where they don't exist.
_edc_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_edc_resolve_script_dir)"
CLEAN_SLATE_SH="$SCRIPT_DIR/edc-clean-slate.sh"

# ── agent CLI configuration ──────────────────────────────────────────────────
#
# EDC_AGENT_CLI selects which CLI spawns subprocess agents for the review pipeline.
#   "claude"  → claude -p  (default, backward-compatible)
#   "cursor"  → cursor agent -p
#   "codex"   → codex exec

EDC_AGENT_CLI="${EDC_AGENT_CLI:-claude}"
CODEX_EXEC_HOME=""
CODEX_EXEC_HOME_OWNED=0

# Shared subprocess runtime (TIMEOUT_BIN, run_with_timeout, stream_filter,
# codex home helpers). Sourced by every orchestrator to avoid drift.
# shellcheck source=edc-runtime.sh
. "$SCRIPT_DIR/edc-runtime.sh"

final_review_filename() {
  # derive consolidated review filename from a target string
  local target="$1"
  echo "review-$(echo "$target" | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-40).md"
}

# read_manifest_source_commit + assert_context_fresh come from the shared
# helper. Sourced (not exec'd) so the functions run in this shell.
# shellcheck source=edc-assert-fresh.sh
. "$SCRIPT_DIR/edc-assert-fresh.sh"
# edc_spawn (per-CLI subprocess dispatch with timeout + stream filter) lives
# in a shared helper used by every orchestrator.
# shellcheck source=edc-spawn.sh
. "$SCRIPT_DIR/edc-spawn.sh"
# recover_context_if_needed (freshness gate + spawn build/update + force-retry).
# shellcheck source=edc-recover-context.sh
. "$SCRIPT_DIR/edc-recover-context.sh"

manifest_target() {
  local val
  val=$(grep -o '"target"[[:space:]]*:[[:space:]]*"[^"]*"' review-tasks/manifest.json \
    | head -1 \
    | sed 's/.*"target"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
  if [ -z "$val" ]; then
    echo "ERROR: could not read target from review-tasks/manifest.json" >&2
    return 1
  fi
  echo "$val"
}

manifest_modules() {
  # one module name per line
  local val
  val=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' review-tasks/manifest.json \
    | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
  if [ -z "$val" ]; then
    echo "ERROR: could not read modules from review-tasks/manifest.json" >&2
    return 1
  fi
  echo "$val"
}

load_ignore_patterns() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
    return 0
  fi

  if [ ! -f ".edcignore" ]; then
    return 0
  fi

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac
    printf '%s\n' "$line"
  done < ".edcignore"
}

path_matches_ignore() {
  local path="$1" pattern="$2"
  if [[ "$pattern" == */ ]]; then
    [[ "$path" == ${pattern}* ]]
    return
  fi

  [[ "$path" == "$pattern" ]] \
    || [[ "$path" == "$pattern/"* ]] \
    || [[ "$path" == $pattern ]]
}

filter_ignored_files() {
  local files="$1"
  shift
  local patterns
  patterns=$(load_ignore_patterns "$@")
  if [ -z "$patterns" ]; then
    printf '%s' "$files"
    return 0
  fi

  local filtered=""
  local file pattern ignored
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    ignored=0
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if path_matches_ignore "$file" "$pattern"; then
        ignored=1
        break
      fi
    done <<< "$patterns"
    [ "$ignored" -eq 1 ] && continue
    filtered+="${file}"$'\n'
  done <<< "$files"

  printf '%s' "$filtered"
}

# assert_report_valid <module>: require report with at least one ## heading
# (edc-review skill always emits ## What Changed, ## Findings, etc. per reporting.md)
assert_report_valid() {
  local module="$1"
  local report="review-tasks/report-${module}.md"
  if [ ! -f "$report" ]; then
    echo "ERROR: missing $report — edc-review skill did not produce output for module '$module'" >&2
    return 1
  fi
  if ! grep -q '^##' "$report"; then
    echo "ERROR: $report has no '## ' headings (module: $module) — expected sections like ## What Changed, ## Findings" >&2
    echo "HINT: this usually means the edc-review skill was bypassed or wrote a stub. check the subprocess output above." >&2
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

# ── auto mode ────────────────────────────────────────────────────────────────
#
# Self-driving pipeline: detect context state, spawn agent subprocesses for each
# phase, verify outputs, consolidate, verify. The orchestrator script owns every
# decision; the spawned agents have one job each.
# Set EDC_AGENT_CLI=claude|cursor|codex before invoking.

auto_mode() {
  case "$EDC_AGENT_CLI" in
    claude)
      command -v claude > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=claude but 'claude' not found on PATH" >&2; exit 2; }
      ;;
    cursor)
      command -v cursor > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=cursor but 'cursor' not found on PATH" >&2; exit 2; }
      ;;
    codex)
      command -v codex > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=codex but 'codex' not found on PATH" >&2; exit 2; }
      ensure_codex_exec_home || exit 1
      ;;
    *)
      echo "ERROR: EDC_AGENT_CLI must be 'claude', 'cursor', or 'codex'" >&2
      exit 2
      ;;
  esac

  local target="$1"; shift
  local extra_args=("$@")
  local -a build_args=() update_args=()
  local idx=0
  while [ "$idx" -lt "${#extra_args[@]}" ]; do
    case "${extra_args[$idx]}" in
      --base)
        [ $((idx + 1)) -lt "${#extra_args[@]}" ] || { echo "ERROR: --base requires a ref" >&2; exit 2; }
        update_args+=("${extra_args[$idx]}" "${extra_args[$((idx + 1))]}")
        idx=$((idx + 2))
        ;;
      --ignore)
        [ $((idx + 1)) -lt "${#extra_args[@]}" ] || { echo "ERROR: --ignore requires a glob pattern" >&2; exit 2; }
        build_args+=("${extra_args[$idx]}" "${extra_args[$((idx + 1))]}")
        update_args+=("${extra_args[$idx]}" "${extra_args[$((idx + 1))]}")
        idx=$((idx + 2))
        ;;
      --context-mode)
        [ $((idx + 1)) -lt "${#extra_args[@]}" ] || { echo "ERROR: --context-mode requires a value" >&2; exit 2; }
        idx=$((idx + 2))
        ;;
      *)
        idx=$((idx + 1))
        ;;
    esac
  done

  # Gate on freshness; recover (build/update + force-retry) if needed. After
  # this returns, .context/manifest.json is fresh or we've exited non-zero.
  recover_context_if_needed "${build_args[@]}" -- "${update_args[@]}" \
    || exit 1

  # Build review tasks now that context is fresh.
  local out
  out=$(bash "$0" --build "$target" "${extra_args[@]}" 2>&1) || true

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

  # Spawn one agent subprocess per module.
  # The here-string on each spawn provides the prompt via stdin, overriding
  # the loop's <<< "$tasks" so it doesn't leak into the subprocess.
  while IFS= read -r task_path; do
    [ -z "$task_path" ] && continue
    local module
    module=$(basename "$task_path" .md)
    echo "→ reviewing module: $module"
    local review_prompt
    review_prompt=$(resolve_prompt review "$task_path") || exit 1
    edc_spawn "edc-review/$module" "${EDC_REVIEW_TIMEOUT:-1800}" "$review_prompt" \
      || { echo "ERROR: review invocation failed for module $module" >&2; exit 1; }
    assert_report_valid "$module" \
      || { echo "ERROR: report validation failed for module $module" >&2; exit 1; }
  done <<< "$tasks"

  # Consolidate + verify
  bash "$0" --consolidate || { echo "ERROR: consolidation failed" >&2; exit 1; }
  bash "$0" --verify     || { echo "ERROR: verification failed" >&2; exit 1; }
  # Explicit exit so any late-arriving subprocess output can't poison our
  # exit code after the pipeline succeeded.
  exit 0
}

# ── build mode ───────────────────────────────────────────────────────────────

build_mode() {
  local target="$1"; shift
  local baseline=""
  local -a ignore_patterns=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) baseline="$2"; shift 2 ;;
      --ignore)
        [ $# -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; exit 2; }
        ignore_patterns+=("$2")
        shift 2
        ;;
      --context-mode)
        [ $# -ge 2 ] || { echo "ERROR: --context-mode requires a value" >&2; exit 2; }
        shift 2
        ;;
      *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
  done

  # Step 1: context gate
  local head
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "ERROR: not a git repo" >&2; exit 2; }

  if [ ! -f "$MANIFEST" ]; then
    echo "CONTEXT_MISSING"
    echo "No .context/manifest.json found. Run edc-build before reviewing."
    exit 1
  fi

  # Structural check: index.md must exist and contain ## headings. Absent or
  # stubbed index.md means edc-build never finished (or wrote junk) — treat as
  # missing so auto_mode's recovery re-runs edc-build to overwrite the stub.
  local ctx=".context/index.md"
  if [ ! -f "$ctx" ] || ! grep -q '^##' "$ctx"; then
    echo "CONTEXT_MISSING"
    echo "$ctx is missing or has no '## ' headings (stub). Run edc-build before reviewing."
    exit 1
  fi

  local source_commit
  source_commit=$(read_manifest_source_commit)
  if [ "$source_commit" != "$head" ]; then
    echo "CONTEXT_STALE"
    echo "Context is stale (built at: $source_commit, HEAD: $head). Run edc-update before reviewing."
    exit 1
  fi

  # Step 2: get changed files
  local files
  if [[ "$target" == https://* ]]; then
    files=$(gh pr diff "$target" --name-only 2>/dev/null)
  elif [ -f "$target" ]; then
    files=$(grep '^+++ b/' "$target" | sed 's|^+++ b/||' || true)
    if [ -z "$files" ]; then
      echo "ERROR: no '+++ b/' lines found in diff file: $target" >&2
      exit 2
    fi
  else
    local base="${baseline:-${target}^}"
    files=$(git diff "${base}..${target}" --name-only)
  fi

  if [ -z "$files" ]; then
    echo "ERROR: no changed files found for target: $target" >&2
    exit 2
  fi

  # Filter out tool-internal paths. These are edc scratch state — reviewing
  # them would make the tool eat its own tail (review .context/, review-tasks/,
  # or prior review-*.md files as if they were source).
  files=$(echo "$files" | grep -Ev '^(\.context/|review-tasks/|review-[^/]+\.md$)' || true)
  files=$(filter_ignored_files "$files" "${ignore_patterns[@]}")

  if [ -z "$files" ]; then
    echo "ERROR: no reviewable files after filtering tool output and ignore rules" >&2
    echo "HINT: target may contain only edc scratch files or files matched by --ignore/.edcignore." >&2
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
      echo -n "    { \"name\": \"$module\", \"doc\": \".context/modules/${module}.md\", \"files\": ["
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

1. Read \`.context/index.md\` — module map, invariants, trust boundaries
2. Read \`.context/reports/issues.md\` if it exists — cross-reference known issues against the files above
3. Read \`.context/modules/${module}.md\` if it exists — deep per-module context, invariants, call graphs
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
  --build)
    shift
    if [ -z "${1:-}" ]; then
      echo "ERROR: --build requires a target" >&2
      exit 2
    fi
    build_mode "$@"
    ;;
  --base)
    # Shorthand: --base <ref> [extras...] → HEAD --base <ref> [extras...]
    if [ -z "${2:-}" ]; then
      echo "ERROR: --base requires a ref (e.g. --base main)" >&2
      exit 2
    fi
    auto_mode HEAD --base "$2" "${@:3}"
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
    echo "Usage: edc-review.sh <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject]" >&2
    echo "                                                     full review pipeline (default)" >&2
    echo "       edc-review.sh --base <ref>                         shorthand for HEAD --base <ref>" >&2
    echo "       edc-review.sh --build <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject]" >&2
    echo "                                                     generate review-tasks/ only (no subprocess spawning)" >&2
    echo "       edc-review.sh --check-context" >&2
    echo "       edc-review.sh --consolidate" >&2
    echo "       edc-review.sh --verify" >&2
    exit 2
    ;;
  --*)
    echo "ERROR: unknown flag: $1" >&2
    echo "Run 'edc-review.sh' with no args for usage." >&2
    exit 2
    ;;
  *)
    auto_mode "$@"
    ;;
esac
