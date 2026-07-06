#!/usr/bin/env bash
# edc-review orchestrator
# All deterministic control flow for edc-review lives here.
#
# Usage:
#   edc-review.sh [--agent <cli>] [--model <slug>] <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
#                                                     full review pipeline (default - spawns agent subprocesses via EDC_AGENT_CLI)
#   edc-review.sh --base <ref>                         shorthand for: HEAD --base <ref>
#   edc-review.sh --pr <number-or-url> [extras...]      shorthand for: pr:<number-or-url> [extras...]
#   edc-review.sh --build <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
#                                                     task-generation only (emit TASK lines, no subprocess spawning)
#   edc-review.sh --build --pr <number-or-url> [extras...]
#                                                     task-generation for a PR without a full URL
#   edc-review.sh --check-context                      assert <EDC_CONTEXT_DIR>/manifest.json fresh (no diff, no task gen)
#   edc-review.sh --consolidate                        merge per-module reports into final review file
#   edc-review.sh --verify                             assert context fresh + reports + final file exist
#
# --build exit codes:
#   0 - $EDC_REVIEW_TASKS_DIR/ written, TASK lines on stdout, proceed with skill
#   1 - context not ready (CONTEXT_MISSING or CONTEXT_STALE), see stdout
#   2 - bad arguments or environment error
#
# Consolidate / verify exit codes:
#   0 - all assertions pass
#   1 - assertion failed (missing report, missing final file, stale context)
#   2 - bad arguments or environment error

set -euo pipefail

# ── dependency check ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
SCRIPT_DIR="$EDC_SCRIPTS_DIR"
MANIFEST="$EDC_MANIFEST"
CLEAN_SLATE_SH="$SCRIPT_DIR/edc-clean-slate.sh"
CLASSIFY_CLI="$SCRIPT_DIR/../hooks/lib/classify-cli.mjs"

# ── agent CLI configuration ──────────────────────────────────────────────────
#
# EDC_AGENT_CLI selects which CLI spawns subprocess agents for the review pipeline.
#   "claude"  → claude -p  (default, backward-compatible)
#   "cursor"  → cursor agent -p
#   "codex"   → codex exec

EDC_AGENT_CLI="${EDC_AGENT_CLI:-claude}"
CODEX_EXEC_HOME=""
CODEX_EXEC_HOME_OWNED=0

final_review_filename() {
  # derive consolidated review filename from a target string
  local target="$1"
  echo "review-$(echo "$target" | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-40).md"
}

tracked_dirty_files() {
  {
    git diff --name-only
    git diff --cached --name-only
  } | sed '/^$/d' | sort -u
}

append_current_head_dirty_files() {
  local target="$1" files="$2"
  local target_sha head_sha dirty_files
  target_sha=$(git rev-parse --verify "$target^{commit}" 2>/dev/null || true)
  head_sha=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
  if [ -z "$target_sha" ] || [ -z "$head_sha" ] || [ "$target_sha" != "$head_sha" ]; then
    printf '%s\n' "$files" | sed '/^$/d'
    return 0
  fi

  dirty_files=$(tracked_dirty_files)
  if [ -z "$dirty_files" ]; then
    printf '%s\n' "$files" | sed '/^$/d'
    return 0
  fi

  printf '%s\n%s\n' "$files" "$dirty_files" | sed '/^$/d' | sort -u
}

EDC_REVIEW_RESULT_ACTIVE=0
EDC_REVIEW_RESULT_WRITTEN=0
EDC_REVIEW_RESULT_STARTED_HEAD=""

edc_review_result_path() {
  if [ -n "${EDC_RESULT_FILE:-}" ]; then
    echo "$EDC_RESULT_FILE"
  else
    echo "$EDC_BUILD_DIR/last-run.json"
  fi
}

edc_write_review_result() {
  [ "${EDC_REVIEW_RESULT_ACTIVE:-0}" = "1" ] || return 0
  local exit_code="$1" reason_code="$2" failure_reason="${3:-}" failure_hint="${4:-}" failed_module="${5:-}" final_review="${6:-}"
  local result_file finished_head
  result_file=$(edc_review_result_path)
  finished_head=$(git rev-parse HEAD 2>/dev/null || true)
  if ! node "$EDC_JSON_CLI" result-write "$result_file" review "$exit_code" "$reason_code" "$failure_reason" "$failure_hint" "$failed_module" "$final_review" "$EDC_REVIEW_RESULT_STARTED_HEAD" "$finished_head"; then
    echo "WARNING: failed to write EDC result file: $result_file" >&2
  fi
  EDC_REVIEW_RESULT_WRITTEN=1
}

edc_review_result_on_exit() {
  local rc=$?
  if [ "${EDC_REVIEW_RESULT_ACTIVE:-0}" = "1" ] && [ "${EDC_REVIEW_RESULT_WRITTEN:-0}" != "1" ] && [ "$rc" -ne 0 ]; then
    edc_write_review_result "$rc" "review-pipeline-failed" "review pipeline failed" "inspect the log for the subprocess error and rerun after fixing it" "" ""
  fi
  return "$rc"
}
trap edc_review_result_on_exit EXIT

# read_manifest_source_commit + assert_context_fresh come from edc-assert-fresh.sh.
# recover_context_if_needed (freshness gate + spawn build/update + force-retry)
# comes from edc-recover-context.sh. Both sourced (not exec'd) so functions
# run in this shell. edc_spawn, run_with_timeout, stream_filter,
# resolve_prompt, and the EDC_* path vars come from edc-lib.sh, sourced above.
# shellcheck source=edc-assert-fresh.sh
. "$SCRIPT_DIR/edc-assert-fresh.sh"
# shellcheck source=edc-recover-context.sh
. "$SCRIPT_DIR/edc-recover-context.sh"

manifest_target() {
  local val
  val=$(node "$EDC_JSON_CLI" review-target "$EDC_REVIEW_TASKS_MANIFEST" 2>/dev/null || true)
  if [ -z "$val" ]; then
    echo "ERROR: could not read target from $EDC_REVIEW_TASKS_MANIFEST" >&2
    return 1
  fi
  echo "$val"
}

manifest_modules() {
  # one module name per line
  local val
  val=$(node "$EDC_JSON_CLI" review-modules "$EDC_REVIEW_TASKS_MANIFEST" 2>/dev/null || true)
  if [ -z "$val" ]; then
    echo "ERROR: could not read modules from $EDC_REVIEW_TASKS_MANIFEST" >&2
    return 1
  fi
  echo "$val"
}

manifest_context_mode() {
  node "$EDC_JSON_CLI" review-context-mode "$EDC_REVIEW_TASKS_MANIFEST" 2>/dev/null || echo "context"
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

  # shellcheck disable=SC2053 # intentional glob match for .edcignore patterns
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

normalize_review_report_headings() {
  local report="$1"
  if grep -q '^## Findings\b' "$report" || ! grep -q '^## Critical Findings\b' "$report"; then
    return 0
  fi

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/edc-report-normalize-$$.XXXXXX") || return 1
  awk '{ if ($0 == "## Critical Findings" || $0 ~ /^## Critical Findings[[:space:]]/) print "## Findings"; else print }' "$report" > "$tmp" \
    && cat "$tmp" > "$report"
  rm -f "$tmp"
}

# assert_report_valid <module>: require the reporting contract's Findings section.
# (edc-review skill always emits ## What Changed, ## Findings, etc. per reporting.md)
assert_report_valid() {
  local module="$1"
  local report="$EDC_REVIEW_TASKS_DIR/report-${module}.md"
  if [ ! -f "$report" ]; then
    echo "ERROR: missing $report - edc-review skill did not produce output for module '$module'" >&2
    return 1
  fi
  if ! grep -q '^##' "$report"; then
    echo "ERROR: $report has no '## ' headings (module: $module) - expected sections like ## What Changed, ## Findings" >&2
    echo "HINT: this usually means the edc-review skill was bypassed or wrote a stub. check the subprocess output above." >&2
    return 1
  fi
  normalize_review_report_headings "$report"
  if ! grep -q '^## Findings\b' "$report"; then
    echo "ERROR: $report missing required section: ## Findings (module: $module)" >&2
    echo "HINT: this usually means the edc-review skill wrote an incomplete report. check the subprocess output above." >&2
    return 1
  fi
}

write_allowed_unmapped_report() {
  local files="$1"
  local report="$EDC_REVIEW_TASKS_DIR/report-allowed-unmapped.md"

  {
    echo "# Differential Review Report: allowed-unmapped"
    echo ""
    echo "## What Changed"
    echo ""
    echo "The following changed paths match \`$MANIFEST\` legacy \`unmapped.allowedGlobs\` and are intentionally outside module ownership:"
    echo ""
    echo "$files" | grep -v '^$' | sed 's/^/- `/' | sed 's/$/`/'
    echo ""
    echo "## Findings"
    echo ""
    echo "No module review was spawned for these paths. They are explicit account-only contextless coverage, so they are intentionally skipped but still accounted for in the final review."
    echo ""
    echo "## Coverage Notes"
    echo ""
    echo "Unexpected uncovered source files are still routed through the synthetic \`unmapped\` review task according to \`policy.unmatchedPathPolicy\`."
  } > "$report"
}

write_contextless_account_report() {
  local module="$1"
  local contextless_id="$2"
  local files="$3"
  local report="$EDC_REVIEW_TASKS_DIR/report-${module}.md"

  {
    echo "# Differential Review Report: ${module}"
    echo ""
    echo "## What Changed"
    echo ""
    echo "The following changed paths match \`$MANIFEST\` \`contextless.entries[]\` id \`${contextless_id}\` with \`reviewPolicy=account-only\`:"
    echo ""
    echo "$files" | grep -v '^$' | sed 's/^/- `/' | sed 's/$/`/'
    echo ""
    echo "## Findings"
    echo ""
    echo "No module review was spawned for these paths. They are intentionally contextless and accounted only."
    echo ""
    echo "## Coverage Notes"
    echo ""
    echo "If a future diff reveals durable agent context here, run update to promote the path into a real context module."
  } > "$report"
}

# ── check-context mode ───────────────────────────────────────────────────────

check_context_mode() {
  assert_context_fresh || exit 1
  echo "OK"
}

# ── consolidate mode ─────────────────────────────────────────────────────────

consolidate_mode() {
  if [ ! -f "$EDC_REVIEW_TASKS_MANIFEST" ]; then
    echo "ERROR: $EDC_REVIEW_TASKS_MANIFEST missing - run build mode first" >&2
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
      cat "$EDC_REVIEW_TASKS_DIR/report-${module}.md"
      echo ""
      echo "---"
      echo ""
    done <<< "$modules"
  } > "$final"

  echo "Consolidated: $final"
}

# ── verify mode ──────────────────────────────────────────────────────────────

verify_mode() {
  if [ ! -f "$EDC_REVIEW_TASKS_MANIFEST" ]; then
    echo "ERROR: $EDC_REVIEW_TASKS_MANIFEST missing" >&2
    exit 1
  fi

  if [ "$(manifest_context_mode)" = "context" ]; then
    assert_context_fresh || exit 1
  fi

  local target final modules missing=0
  target=$(manifest_target)
  final=$(final_review_filename "$target")
  modules=$(manifest_modules)

  while IFS= read -r module; do
    [ -z "$module" ] && continue
    if [ ! -f "$EDC_REVIEW_TASKS_DIR/report-${module}.md" ]; then
      echo "ERROR: missing $EDC_REVIEW_TASKS_DIR/report-${module}.md" >&2
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
# Set EDC_AGENT_CLI=claude|cursor|codex|pi before invoking.

auto_mode() {
  edc_require_agent_cli
  EDC_REVIEW_RESULT_ACTIVE=1
  EDC_REVIEW_RESULT_WRITTEN=0
  EDC_REVIEW_RESULT_STARTED_HEAD=$(git rev-parse HEAD 2>/dev/null || true)

  local target="$1"; shift
  local extra_args=("$@")
  local -a build_args=() update_args=()
  local no_context_refresh=0
  local ignore_context=0
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
      --no-context-refresh)
        no_context_refresh=1
        idx=$((idx + 1))
        ;;
      --ignore-context)
        ignore_context=1
        idx=$((idx + 1))
        ;;
      *)
        idx=$((idx + 1))
        ;;
    esac
  done

  # Gate on freshness; recover (build/update + force-retry) unless the caller
  # explicitly requested a no-refresh run. --no-context-refresh may still use
  # existing context; it just refuses to create/update it. --ignore-context is
  # the stronger pure-baseline mode.
  if [ "$no_context_refresh" -ne 1 ] && [ "$ignore_context" -ne 1 ]; then
    recover_context_if_needed ${build_args[@]+"${build_args[@]}"} -- ${update_args[@]+"${update_args[@]}"} \
      || exit 1
  fi

  # Build review tasks now that context is fresh. Run the function in-process
  # instead of shelling out to `$0 --build`; build_mode still exits, but command
  # substitution confines that exit to the subshell while preserving filesystem
  # outputs under $EDC_REVIEW_TASKS_DIR.
  local out build_rc=0
  out=$(build_mode "$target" ${extra_args[@]+"${extra_args[@]}"} 2>&1) || build_rc=$?

  if [ "$build_rc" -ne 0 ] || [ ! -f "$EDC_REVIEW_TASKS_MANIFEST" ]; then
    echo "ERROR: script did not produce review tasks. Output:" >&2
    echo "$out" >&2
    local failure_reason="review task generation failed"
    local failure_hint="inspect the log for task-generation output and rerun after fixing it"
    if grep -q 'ERROR: no changed files found for target:' <<< "$out"; then
      failure_reason="no changed files found for review"
      failure_hint="review uses committed diff plus dirty tracked files; commit changes, modify a tracked file, or choose another target/base"
    elif grep -q 'ERROR: no reviewable files after filtering tool output and ignore rules' <<< "$out"; then
      failure_reason="no reviewable files after filtering"
      failure_hint="changed files are EDC scratch files or matched by --ignore/.edcignore; choose another target/base or adjust ignore rules"
    fi
    edc_write_review_result 1 "review-task-build-failed" "$failure_reason" "$failure_hint" "" ""
    exit 1
  fi

  # allowed-unmapped/account-only paths are satisfied by deterministic
  # prewritten reports and intentionally have no subprocess task file.
  local tasks
  tasks=$(find "$EDC_REVIEW_TASKS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'report-*.md' -print | sort)
  if [ -z "$tasks" ]; then
    local module prewritten_missing=0
    while IFS= read -r module; do
      [ -z "$module" ] && continue
      assert_report_valid "$module" || prewritten_missing=1
    done <<< "$(manifest_modules)"
    if [ "$prewritten_missing" -ne 0 ]; then
      echo "ERROR: no TASK lines in script output and no complete prewritten reports" >&2
      edc_write_review_result 1 "report-validation" "review report validation failed" "inspect the reviewer output in the log; a prewritten report is incomplete" "" ""
      exit 1
    fi
  fi

  # Spawn one agent subprocess per module.
  # The here-string on each spawn provides the prompt via stdin, overriding
  # the loop's <<< "$tasks" so it doesn't leak into the subprocess.
  while IFS= read -r task_path; do
    [ -z "$task_path" ] && continue
    local module
    module=$(basename "$task_path" .md)
    echo "→ reviewing module: $module"
    local review_prompt before_snapshot after_snapshot changed_forbidden allowed_report spawn_rc
    allowed_report="$EDC_REVIEW_TASKS_DIR/report-${module}.md"
    before_snapshot=$(mktemp)
    after_snapshot=$(mktemp)
    edc_snapshot_review_forbidden_paths "$before_snapshot" "$allowed_report"
    review_prompt=$(resolve_prompt review "$task_path") || { rm -f "$before_snapshot" "$after_snapshot"; exit 1; }
    if edc_spawn "edc-review/$module" "${EDC_REVIEW_TIMEOUT:-1800}" "$review_prompt"; then
      spawn_rc=0
    else
      spawn_rc=$?
    fi
    edc_snapshot_review_forbidden_paths "$after_snapshot" "$allowed_report"
    changed_forbidden=$(edc_diff_review_forbidden_paths "$before_snapshot" "$after_snapshot" || true)
    rm -f "$before_snapshot" "$after_snapshot"
    if [ -n "$changed_forbidden" ]; then
      echo "ERROR: review subagent touched forbidden paths for module $module:" >&2
      echo "$changed_forbidden" | sed 's/^/  /' >&2
      edc_write_review_result 1 "review-write-containment" "review subagent touched forbidden paths for module $module" "inspect the log for forbidden paths; rerun in a disposable checkout if reviewing untrusted input" "$module" ""
      exit 1
    fi
    assert_report_valid "$module" \
      || { echo "ERROR: report validation failed for module $module" >&2; edc_write_review_result 1 "report-validation" "review report validation failed for module $module" "inspect the module reviewer output in the log; the reviewer likely wrote an incomplete report" "$module" ""; exit 1; }
    if [ "$spawn_rc" -ne 0 ]; then
      echo "EDC review succeeded with warning: review subprocess for module $module reported failure, but report validation passed." >&2
      echo "HINT: treating the validated report as success; inspect the agent log for transport/provider diagnostics." >&2
    fi
  done <<< "$tasks"

  # Consolidate + verify
  bash "$0" --consolidate || { echo "ERROR: consolidation failed" >&2; edc_write_review_result 1 "consolidation-failed" "review consolidation failed" "inspect the log for report validation errors and rerun after fixing them" "" ""; exit 1; }
  bash "$0" --verify     || { echo "ERROR: verification failed" >&2; edc_write_review_result 1 "verification-failed" "review verification failed" "inspect the log for missing or stale review artifacts" "" ""; exit 1; }

  # Auto-cleanup: review tasks are pure IPC scaffolding; the consolidated
  # review-<target>.md at the repo root is the durable artifact. On success,
  # remove $EDC_REVIEW_TASKS_DIR/ so it doesn't clutter the tree. Failures
  # exit non-zero above and leave the directory in place for inspection.
  # Override with EDC_KEEP_REVIEW_TASKS=1 to keep the dir on success too.
  if [ "${EDC_KEEP_REVIEW_TASKS:-0}" != "1" ]; then
    rm -rf "$EDC_REVIEW_TASKS_DIR"
  fi

  edc_write_review_result 0 "success" "" "" "" "$(final_review_filename "$target")"

  # Explicit exit so any late-arriving subprocess output can't poison our
  # exit code after the pipeline succeeded.
  exit 0
}

# ── build mode ───────────────────────────────────────────────────────────────

build_mode() {
  local target="$1"; shift
  local baseline=""
  local no_context_refresh=0
  local ignore_context=0
  local context_available=1
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
      --no-context-refresh)
        no_context_refresh=1
        shift
        ;;
      --ignore-context)
        ignore_context=1
        shift
        ;;
      *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
  done

  # Step 1: context gate
  local head
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "ERROR: not a git repo" >&2; exit 2; }

  if [ "$ignore_context" -ne 1 ]; then
    if [ ! -f "$MANIFEST" ]; then
      if [ "$no_context_refresh" -eq 1 ]; then
        context_available=0
      else
        echo "CONTEXT_MISSING"
        echo "No $MANIFEST found. Run edc-build before reviewing."
        exit 1
      fi
    fi

    # Structural check: index.md must exist and contain ## headings. Absent or
    # stubbed index.md means edc-build never finished (or wrote junk). In
    # --no-context-refresh mode, do not recover; fall back to a direct review
    # task instead.
    local ctx="$EDC_INDEX"
    if [ "$context_available" -eq 1 ] && { [ ! -f "$ctx" ] || ! grep -q '^##' "$ctx"; }; then
      if [ "$no_context_refresh" -eq 1 ]; then
        context_available=0
      else
        echo "CONTEXT_MISSING"
        echo "$ctx is missing or has no '## ' headings (stub). Run edc-build before reviewing."
        exit 1
      fi
    fi

    local source_commit=""
    if [ "$context_available" -eq 1 ]; then
      source_commit=$(read_manifest_source_commit)
      if [ "$source_commit" != "$head" ] && [ "$no_context_refresh" -ne 1 ]; then
        echo "CONTEXT_STALE"
        echo "Context is stale (built at: $source_commit, HEAD: $head). Run edc-update before reviewing."
        exit 1
      fi
      if [ "$source_commit" != "$head" ] && [ "$no_context_refresh" -eq 1 ]; then
        echo "WARNING: context is stale (built at: $source_commit, HEAD: $head); using it because --no-context-refresh was requested" >&2
      fi
    fi
  fi

  # Step 2: get changed files
  local files
  if [[ "$target" == https://* ]]; then
    local gh_err
    gh_err=$(mktemp "${TMPDIR:-/tmp}/edc-gh-pr-diff-$$.XXXXXX") || exit 1
    if ! files=$(gh pr diff "$target" --name-only 2>"$gh_err"); then
      echo "ERROR: gh pr diff failed for target: $target" >&2
      sed 's/^/gh: /' "$gh_err" >&2
      rm -f "$gh_err"
      exit 2
    fi
    rm -f "$gh_err"
  elif [[ "$target" == pr:* ]]; then
    local gh_err
    gh_err=$(mktemp "${TMPDIR:-/tmp}/edc-gh-pr-diff-$$.XXXXXX") || exit 1
    if ! files=$(gh pr diff "${target#pr:}" --name-only 2>"$gh_err"); then
      echo "ERROR: gh pr diff failed for target: $target" >&2
      sed 's/^/gh: /' "$gh_err" >&2
      rm -f "$gh_err"
      exit 2
    fi
    rm -f "$gh_err"
  elif [ -f "$target" ]; then
    files=$(grep '^+++ b/' "$target" | sed 's|^+++ b/||' || true)
    if [ -z "$files" ]; then
      echo "ERROR: no '+++ b/' lines found in diff file: $target" >&2
      exit 2
    fi
  else
    local base="${baseline:-${target}^}"
    files=$(git diff -z "${base}...${target}" --name-only | tr '\0' '\n')
    files=$(append_current_head_dirty_files "$target" "$files")
  fi

  if [ -z "$files" ]; then
    echo "ERROR: no changed files found for target: $target" >&2
    echo "HINT: review uses committed diff plus dirty tracked files; commit changes, modify a tracked file, or choose another target/base." >&2
    exit 2
  fi

  # Filter out tool-internal paths. These are edc scratch state - reviewing
  # them would make the tool eat its own tail (review the context dir,
  # $EDC_REVIEW_TASKS_DIR/ - itself under $EDC_CONTEXT_DIR/ - or prior
  # review-*.md files as if they were source).
  files=$(echo "$files" | grep -Ev "^(${EDC_CONTEXT_DIR}/|review-[^/]+\.md$)" || true)
  files=$(filter_ignored_files "$files" ${ignore_patterns[@]+"${ignore_patterns[@]}"})

  if [ -z "$files" ]; then
    echo "ERROR: no reviewable files after filtering tool output and ignore rules" >&2
    echo "HINT: target may contain only edc scratch files or files matched by --ignore/.edcignore." >&2
    exit 2
  fi

  if [ "$ignore_context" -eq 1 ] || [ "$context_available" -eq 0 ]; then
    rm -rf "$EDC_REVIEW_TASKS_DIR"
    mkdir -p "$EDC_REVIEW_TASKS_DIR"

    local file_list context_mode direct_module instruction_1 extra_instruction
    file_list=$(echo "$files" | grep -v '^$' | sed 's/^/- /')

    if [ "$ignore_context" -eq 1 ]; then
      context_mode="ignored"
      direct_module="ignore-context"
      instruction_1="Do not read \`${EDC_INDEX}\`, \`${EDC_ISSUES}\`, or any \`${EDC_CONTEXT_DIR}/\` module docs."
      extra_instruction=$'DO NOT use prebuilt EDC context, even if it exists in this repository.'
    else
      context_mode="no-refresh"
      direct_module="no-context-refresh"
      instruction_1="No usable EDC context was available without building/updating. Review the changed files directly."
      extra_instruction=""
    fi

    printf '%s\n' "$files" | grep -v '^$' | node "$EDC_JSON_CLI" review-direct-manifest "$target" "$baseline" "$head" "$context_mode" "$direct_module" \
      > "$EDC_REVIEW_TASKS_MANIFEST"

    cat > "$EDC_REVIEW_TASKS_DIR/${direct_module}.md" <<TASK
# Review Task: \`${direct_module}\`

## Target
${target}

## Files to review
${file_list}

## Instructions

1. ${instruction_1}
2. Review only the changed files listed above and whatever adjacent source files are necessary to understand the diff.
3. Use the embedded edc-review methodology to perform the full review on the files listed above.
4. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${direct_module}.md\`

DO NOT build or update EDC context.
${extra_instruction}
TASK

    echo "routing summary: context=$context_mode files=$(echo "$files" | grep -cve '^$') modules=1" >&2
    echo ""
    echo "Review tasks ready."
    echo ""
    echo "TASK $EDC_REVIEW_TASKS_DIR/${direct_module}.md"
    return 0
  fi

  # Step 3: classify changed files through the shared batch coverage classifier.
  # Real modules get normal module-review tasks. Contextless paths follow their
  # deterministic reviewPolicy and never load fake module docs.
  if [ ! -f "$CLASSIFY_CLI" ]; then
    echo "ERROR: classify-cli.mjs not found at $CLASSIFY_CLI" >&2
    exit 2
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: node is required for review path classification" >&2
    exit 2
  fi

  local unmatched_policy
  unmatched_policy=$(node "$EDC_JSON_CLI" unmatched-policy "$MANIFEST")
  case "$unmatched_policy" in
    warn-allow|allow|fail) ;;
    *)
      echo "ERROR: invalid policy.unmatchedPathPolicy in $MANIFEST: '$unmatched_policy'" >&2
      echo "HINT: must be one of: warn-allow, allow, fail" >&2
      exit 2
      ;;
  esac

  local ambiguous_count=0 uncovered_count=0 mapped_count=0 contextless_count=0 allowed_unmapped_count=0
  local -a unmapped_unexpected=()
  local -a ambiguous_lines=()
  local -a module_names=()
  local -a module_files=()
  local -a module_types=()
  local -a module_policies=()
  local -a module_contextless_ids=()

  local module_index_result=""

  _module_index() {
    local needle="$1" i
    i=0
    while [ "$i" -lt "${#module_names[@]}" ]; do
      if [ "${module_names[$i]}" = "$needle" ]; then
        module_index_result="$i"
        return 0
      fi
      i=$((i + 1))
    done
    module_index_result=""
    return 1
  }

  _ensure_module() {
    local module="$1" type="${2:-module}" policy="${3:-}" contextless_id="${4:-}" idx
    if _module_index "$module"; then
      idx="$module_index_result"
      module_types[$idx]="$type"
      module_policies[$idx]="$policy"
      module_contextless_ids[$idx]="$contextless_id"
    else
      idx=${#module_names[@]}
      module_names[$idx]="$module"
      module_files[$idx]=""
      module_types[$idx]="$type"
      module_policies[$idx]="$policy"
      module_contextless_ids[$idx]="$contextless_id"
    fi
    module_index_result="$idx"
  }

  _append_module_file() {
    local module="$1" file="$2" type="${3:-module}" policy="${4:-}" contextless_id="${5:-}" idx
    _ensure_module "$module" "$type" "$policy" "$contextless_id"
    idx="$module_index_result"
    module_files[$idx]="${module_files[$idx]}${file}"$'\n'
  }

  _record_contextless() {
    local id="$1" policy="$2" file="$3" module contextless_id
    contextless_id="$id"
    case "$policy" in
      account-only)
        if [ "$id" = "legacy-unmapped" ]; then
          module="allowed-unmapped"
          allowed_unmapped_count=$((allowed_unmapped_count + 1))
        else
          module="contextless-${id}"
        fi
        ;;
      promotion-check)
        module="contextless-promotion-check"
        contextless_id="promotion-check"
        ;;
      no-context-review)
        module="contextless-${id}"
        ;;
      *)
        echo "ERROR: invalid contextless reviewPolicy from classifier: $policy" >&2
        exit 2
        ;;
    esac
    _append_module_file "$module" "$file" "contextless" "$policy" "$contextless_id"
  }

  local classifications
  classifications=$(printf '%s\n' "$files" | node "$CLASSIFY_CLI" "$MANIFEST") || {
    echo "ERROR: classify-cli.mjs failed" >&2
    exit 2
  }

  while IFS=$'\t' read -r file state; do
    [ -z "$file" ] && continue

    case "$state" in
      context-module:*)
        module="${state#context-module:}"
        _append_module_file "$module" "$file" "module"
        mapped_count=$((mapped_count + 1))
        ;;
      contextless:*)
        rest="${state#contextless:}"
        contextless_id="${rest%:*}"
        review_policy="${rest##*:}"
        _record_contextless "$contextless_id" "$review_policy" "$file"
        contextless_count=$((contextless_count + 1))
        ;;
      uncovered)
        uncovered_count=$((uncovered_count + 1))
        _append_module_file "unmapped" "$file" "unmapped"
        unmapped_unexpected+=("$file")
        ;;
      ambiguous)
        ambiguous_count=$((ambiguous_count + 1))
        ambiguous_lines+=("$file")
        ;;
      ignored)
        ;;
      *)
        echo "ERROR: invalid classifier state for $file: $state" >&2
        exit 2
        ;;
    esac
  done <<< "$classifications"

  if [ "$ambiguous_count" -gt 0 ]; then
    echo "ERROR: $ambiguous_count file(s) match multiple modules or contextless entries:" >&2
    local line
    for line in ${ambiguous_lines[@]+"${ambiguous_lines[@]}"}; do
      echo "  $line" >&2
    done
    echo "HINT: edit $MANIFEST - bump priority, tighten match rules, or remove overlapping contextless globs" >&2
    exit 2
  fi

  if [ "${#unmapped_unexpected[@]}" -gt 0 ]; then
    case "$unmatched_policy" in
      fail)
        echo "ERROR: ${#unmapped_unexpected[@]} changed file(s) not mapped to any module or contextless entry (policy=fail):" >&2
        local f
        for f in ${unmapped_unexpected[@]+"${unmapped_unexpected[@]}"}; do
          echo "  $f" >&2
        done
        echo "HINT: add a module rule or contextless.entries coverage in $MANIFEST, then re-run." >&2
        exit 2
        ;;
      warn-allow)
        echo "WARNING: ${#unmapped_unexpected[@]} changed file(s) not mapped to any module or contextless entry (will review under 'unmapped'):" >&2
        local f
        for f in ${unmapped_unexpected[@]+"${unmapped_unexpected[@]}"}; do
          echo "  $f" >&2
        done
        ;;
      allow)
        :
        ;;
    esac
  fi

  echo "routing summary: mapped=$mapped_count contextless=$contextless_count uncovered=$uncovered_count allowed-unmapped=$allowed_unmapped_count modules=${#module_names[@]}" >&2

  # Step 4: write $EDC_REVIEW_TASKS_DIR/
  rm -rf "$EDC_REVIEW_TASKS_DIR"
  mkdir -p "$EDC_REVIEW_TASKS_DIR"

  local sorted_modules
  sorted_modules=$(printf '%s\n' ${module_names[@]+"${module_names[@]}"} | sort)

  # manifest.json (script-internal source of truth for consolidate/verify)
  local context_mode
  if [ "$no_context_refresh" -eq 1 ]; then
    context_mode="no-refresh"
  else
    context_mode="context"
  fi

  local manifest_meta_dir manifest_meta
  manifest_meta_dir="$EDC_REVIEW_TASKS_DIR/.manifest-files"
  manifest_meta="$manifest_meta_dir/modules.tsv"
  mkdir -p "$manifest_meta_dir"
  : > "$manifest_meta"

  while IFS= read -r module; do
    local module_doc="${EDC_MODULES_DIR}/${module}.md"
    local module_idx module_type module_policy module_contextless_id module_file_blob
    _module_index "$module"
    module_idx="$module_index_result"
    module_type="${module_types[$module_idx]:-module}"
    module_policy="${module_policies[$module_idx]:-}"
    module_contextless_id="${module_contextless_ids[$module_idx]:-}"
    module_file_blob="${module_files[$module_idx]}"
    if [ "$module_type" != "module" ]; then
      module_doc=""
    fi
    printf '%s' "$module_file_blob" > "$manifest_meta_dir/$module_idx.files"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$module_idx" "$module" "$module_type" "$module_policy" "$module_contextless_id" "$module_doc" >> "$manifest_meta"
  done <<< "$sorted_modules"

  node "$EDC_JSON_CLI" review-routed-manifest "$target" "$baseline" "$head" "$context_mode" "$manifest_meta" "$manifest_meta_dir" \
    > "$EDC_REVIEW_TASKS_MANIFEST"
  rm -rf "$manifest_meta_dir"

  # per-module task files
  while IFS= read -r module; do
    local file_list baseline_line module_context_line module_idx module_type module_policy module_contextless_id module_file_blob
    _module_index "$module"
    module_idx="$module_index_result"
    module_type="${module_types[$module_idx]:-module}"
    module_policy="${module_policies[$module_idx]:-}"
    module_contextless_id="${module_contextless_ids[$module_idx]:-}"
    module_file_blob="${module_files[$module_idx]}"
    file_list=$(echo "$module_file_blob" | grep -v '^$' | sed 's/^/- /')

    if [ "$module" = "allowed-unmapped" ]; then
      write_allowed_unmapped_report "$module_file_blob"
      continue
    fi

    if [ "$module_type" = "contextless" ] && [ "$module_policy" = "account-only" ]; then
      write_contextless_account_report "$module" "$module_contextless_id" "$module_file_blob"
      continue
    fi

    baseline_line=""
    [ -n "$baseline" ] && baseline_line=$'\n'"## Baseline"$'\n'"${baseline}"

    if [ "$module_type" = "contextless" ] && [ "$module_policy" = "promotion-check" ]; then
      cat > "$EDC_REVIEW_TASKS_DIR/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${target}${baseline_line}

## Files to review
${file_list}

## Instructions

1. This is a promotion check only, not a full module review.
2. Do not read generated module docs; these paths are intentionally contextless.
3. Inspect only the listed diff and the smallest adjacent source needed to decide whether durable agent context now exists.
4. Report whether update should promote these paths into a real context module, and why.
5. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${module}.md\`

DO NOT edit \`edc-context/manifest.json\`, \`edc-context/index.md\`, or \`edc-context/modules/*.md\`.
DO NOT perform a full module review.
TASK
      continue
    fi

    if [ "$module_type" = "contextless" ] && [ "$module_policy" = "no-context-review" ]; then
      cat > "$EDC_REVIEW_TASKS_DIR/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${target}${baseline_line}

## Files to review
${file_list}

## Instructions

1. These files are intentionally contextless but risk-bearing.
2. Do not read generated module docs; there is no module context for these paths.
3. Review only the changed files listed above and the smallest adjacent source needed to understand the diff.
4. Use the edc-review skill to perform the full review on the files listed above.
5. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${module}.md\`

DO NOT build or update EDC context.
DO NOT edit \`edc-context/manifest.json\`, \`edc-context/index.md\`, or \`edc-context/modules/*.md\`.
TASK
      continue
    fi

    if [ "$module" = "unmapped" ]; then
      module_context_line="3. NOTE: these files are not matched by the current ${EDC_MANIFEST} routing or contextless coverage. Use only \`${EDC_INDEX}\` for repo-level context; there is no per-module deep context for these paths. State this limitation clearly in the report."
    else
      module_context_line="3. Read \`${EDC_MODULES_DIR}/${module}.md\` if it exists - deep per-module context, invariants, call graphs"
    fi

    cat > "$EDC_REVIEW_TASKS_DIR/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${target}${baseline_line}

## Files to review
${file_list}

## Instructions

1. Read \`${EDC_INDEX}\` - module map, invariants, trust boundaries
2. Read \`${EDC_ISSUES}\` if it exists - cross-reference known issues against the files above
${module_context_line}
4. Use the edc-review skill to perform the full review on the files listed above
5. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${module}.md\`

DO NOT write your own review methodology.
DO NOT skip reading the context files.
USE the edc-review skill.
TASK
  done <<< "$sorted_modules"

  # Done - emit TASK lines for the agent to iterate. Deterministic skipped
  # reports are already complete and must not spawn an agent subprocess.
  echo ""
  echo "Review tasks ready."
  echo ""
  while IFS= read -r module; do
    local module_idx module_type module_policy
    _module_index "$module"
    module_idx="$module_index_result"
    module_type="${module_types[$module_idx]:-module}"
    module_policy="${module_policies[$module_idx]:-}"
    if [ "$module_type" = "contextless" ] && [ "$module_policy" = "account-only" ]; then
      continue
    fi
    echo "TASK $EDC_REVIEW_TASKS_DIR/${module}.md"
  done <<< "$sorted_modules"
}

review_usage() {
  cat <<EOF
Usage: edc-review.sh [--agent <cli>] [--model <slug>] <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
                                                     full review pipeline (default)
       edc-review.sh --base <ref> [--no-context-refresh|--ignore-context]
                                                     shorthand for HEAD --base <ref>
       edc-review.sh --pr <number-or-url> [--base <ref>] [--no-context-refresh|--ignore-context]
                                                     shorthand for PR review without full URL
       edc-review.sh --no-context-refresh [--base <ref>]  shorthand for HEAD --no-context-refresh
       edc-review.sh --ignore-context [--base <ref>]      shorthand for HEAD --ignore-context
       edc-review.sh --build <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
                                                     generate $EDC_REVIEW_TASKS_DIR/ only (no subprocess spawning)
       edc-review.sh --build --pr <number-or-url> [--ignore-context|--no-context-refresh]
                                                     generate PR review tasks without full URL
       edc-review.sh --check-context
       edc-review.sh --consolidate
       edc-review.sh --verify
EOF
}

# ── dispatch ─────────────────────────────────────────────────────────────────

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --agent requires an agent cli" >&2
        exit 2
      fi
      EDC_AGENT_CLI="$2"
      export EDC_AGENT_CLI
      shift 2
      ;;
    --agent=*)
      EDC_AGENT_CLI="${1#--agent=}"
      export EDC_AGENT_CLI
      shift
      ;;
    --model)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --model requires a model slug" >&2
        exit 2
      fi
      export EDC_BUILD_MODEL="$2"
      export EDC_REVIEW_MODEL="$2"
      shift 2
      ;;
    --model=*)
      export EDC_BUILD_MODEL="${1#--model=}"
      export EDC_REVIEW_MODEL="${1#--model=}"
      shift
      ;;
    *)
      break
      ;;
  esac
done
case "${1:-}" in
  --build)
    shift
    if [ "${1:-}" = "--pr" ]; then
      if [ -z "${2:-}" ]; then
        echo "ERROR: --build --pr requires a PR number or URL (e.g. --build --pr 147)" >&2
        exit 2
      fi
      pr_target="$2"
      shift 2
      build_mode "pr:$pr_target" "$@"
      exit $?
    fi
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
  --pr)
    # Shorthand: --pr <number-or-url> [extras...] → pr:<number-or-url> [extras...]
    if [ -z "${2:-}" ]; then
      echo "ERROR: --pr requires a PR number or URL (e.g. --pr 147)" >&2
      exit 2
    fi
    auto_mode "pr:$2" "${@:3}"
    ;;
  pr|PR)
    # Shorthand: pr <number-or-url> [extras...] → pr:<number-or-url> [extras...]
    if [ -z "${2:-}" ]; then
      echo "ERROR: pr requires a PR number or URL (e.g. pr 147)" >&2
      exit 2
    fi
    auto_mode "pr:$2" "${@:3}"
    ;;
  --no-context-refresh)
    # Shorthand: --no-context-refresh [extras...] → HEAD --no-context-refresh [extras...]
    auto_mode HEAD --no-context-refresh "${@:2}"
    ;;
  --ignore-context)
    # Shorthand: --ignore-context [extras...] → HEAD --ignore-context [extras...]
    auto_mode HEAD --ignore-context "${@:2}"
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
  -h|--help)
    review_usage
    exit 0
    ;;
  "")
    echo "ERROR: target required (PR URL, commit SHA, or diff path)" >&2
    review_usage >&2
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
