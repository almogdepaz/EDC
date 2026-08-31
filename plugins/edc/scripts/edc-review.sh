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

review_output_path() {
  local target="$1"
  if [ -n "${EDC_REVIEW_FINAL_OUTPUT:-}" ]; then
    echo "$EDC_REVIEW_FINAL_OUTPUT"
  else
    final_review_filename "$target"
  fi
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

EDC_REVIEW_DEPENDENCIES_LOADED=0
edc_load_review_dependencies() {
  [ "$EDC_REVIEW_DEPENDENCIES_LOADED" = "1" ] && return 0
  # These managed helpers must not execute until runtime integrity passes.
  # shellcheck source=edc-assert-fresh.sh
  . "$SCRIPT_DIR/edc-assert-fresh.sh"
  # shellcheck source=edc-recover-context.sh
  . "$SCRIPT_DIR/edc-recover-context.sh"
  # shellcheck source=edc-review-candidate.sh
  . "$SCRIPT_DIR/edc-review-candidate.sh"
  # shellcheck source=edc-review-plan.sh
  . "$SCRIPT_DIR/edc-review-plan.sh"
  EDC_REVIEW_DEPENDENCIES_LOADED=1
}

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

manifest_module_policy() {
  local module="$1"
  node "$EDC_JSON_CLI" review-module-policy "$EDC_REVIEW_TASKS_MANIFEST" "$module" 2>/dev/null || true
}

assert_promotion_check_result_valid() {
  local module="$1"
  local report="$EDC_REVIEW_TASKS_DIR/report-${module}.md"
  local result="$EDC_REVIEW_TASKS_DIR/result-${module}.json"
  if [ ! -f "$report" ]; then
    echo "ERROR: missing $report - promotion-check subprocess did not produce a human report for module '$module'" >&2
    return 1
  fi
  if [ ! -f "$result" ]; then
    echo "ERROR: missing $result - promotion-check subprocess did not produce structured result for module '$module'" >&2
    echo "HINT: promotion-check success is validated from JSON, not markdown headings." >&2
    return 1
  fi
  node "$EDC_JSON_CLI" review-promotion-result-valid "$result" "$report" || return 1
}

# Intermediate LLM reports are prose inputs to deterministic consolidation.
# Promotion checks keep their structured sidecar contract.
assert_intermediate_report_valid() {
  local module="$1"
  local report="$EDC_REVIEW_TASKS_DIR/report-${module}.md"
  if [ "$(manifest_module_policy "$module")" = "promotion-check" ]; then
    assert_promotion_check_result_valid "$module"
    return $?
  fi
  if ! edc_file_has_substantive_content "$report"; then
    echo "ERROR: $report has no substantive content (module: $module)" >&2
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
  final=$(review_output_path "$target")
  modules=$(manifest_modules)

  if [ -z "$modules" ]; then
    echo "ERROR: no modules in manifest.json" >&2
    exit 1
  fi

  # verify every expected report is present and non-trivial before writing final file
  while IFS= read -r module; do
    [ -z "$module" ] && continue
    assert_intermediate_report_valid "$module" || missing=1
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
  final=$(review_output_path "$target")
  modules=$(manifest_modules)

  while IFS= read -r module; do
    [ -z "$module" ] && continue
    assert_intermediate_report_valid "$module" || missing=1
  done <<< "$modules"

  if [ ! -s "$final" ]; then
    echo "ERROR: missing or empty final review file ($final)" >&2
    missing=1
  elif ! grep -q '^# Review: ' "$final"; then
    echo "ERROR: final review missing canonical title ($final)" >&2
    missing=1
  else
    while IFS= read -r module; do
      [ -z "$module" ] && continue
      if ! grep -Fqx "## Module: \`$module\`" "$final"; then
        echo "ERROR: final review missing module section: $module" >&2
        missing=1
      fi
    done <<< "$modules"
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
  edc_runtime_preflight_or_exit
  edc_load_review_dependencies

  local target="$1"; shift
  local raw_args=("$@") extra_args=()
  local -a build_args=() update_args=()
  local no_context_refresh=0 ignore_context=0 full_scope=0 policy="" base="" idx=0
  while [ "$idx" -lt "${#raw_args[@]}" ]; do
    case "${raw_args[$idx]}" in
      --base)
        [ $((idx + 1)) -lt "${#raw_args[@]}" ] || { echo "ERROR: --base requires a ref" >&2; exit 2; }
        base="${raw_args[$((idx + 1))]}"
        # Review scope never controls context update lineage.
        extra_args+=("${raw_args[$idx]}" "$base")
        idx=$((idx + 2))
        ;;
      --ignore)
        [ $((idx + 1)) -lt "${#raw_args[@]}" ] || { echo "ERROR: --ignore requires a glob pattern" >&2; exit 2; }
        build_args+=("${raw_args[$idx]}" "${raw_args[$((idx + 1))]}")
        update_args+=("${raw_args[$idx]}" "${raw_args[$((idx + 1))]}")
        extra_args+=("${raw_args[$idx]}" "${raw_args[$((idx + 1))]}")
        idx=$((idx + 2))
        ;;
      --context-mode)
        [ $((idx + 1)) -lt "${#raw_args[@]}" ] || { echo "ERROR: --context-mode requires a value" >&2; exit 2; }
        extra_args+=("${raw_args[$idx]}" "${raw_args[$((idx + 1))]}")
        idx=$((idx + 2))
        ;;
      --include-working-tree)
        [ -z "$policy" ] || { echo "ERROR: choose only one dirty-state policy" >&2; exit 2; }
        policy=include-working-tree
        idx=$((idx + 1))
        ;;
      --committed-only)
        [ -z "$policy" ] || { echo "ERROR: choose only one dirty-state policy" >&2; exit 2; }
        policy=committed-only
        idx=$((idx + 1))
        ;;
      --no-context-refresh)
        no_context_refresh=1
        extra_args+=("${raw_args[$idx]}")
        idx=$((idx + 1))
        ;;
      --ignore-context)
        ignore_context=1
        extra_args+=("${raw_args[$idx]}")
        idx=$((idx + 1))
        ;;
      --full)
        full_scope=1
        extra_args+=("${raw_args[$idx]}")
        idx=$((idx + 1))
        ;;
      *)
        echo "ERROR: unknown security review argument: ${raw_args[$idx]}" >&2
        exit 2
        ;;
    esac
  done

  if [[ "$target" != https://* ]] && [[ "$target" != pr:* ]] && [ ! -f "$target" ] && [ "$full_scope" -ne 1 ]; then
    local candidate_file
    candidate_file=$(mktemp "${TMPDIR:-/tmp}/edc-security-candidate-$$.XXXXXX") || exit 1
    edc_candidate_resolve "$target" "$base" "$policy" > "$candidate_file" || { local rc=$?; rm -f "$candidate_file"; exit "$rc"; }
    target=$(cat "$candidate_file")
    rm -f "$candidate_file"
  elif [ "$full_scope" -ne 1 ]; then
    edc_candidate_resolve_external "$target" "$base" "$policy" || exit $?
  else
    edc_result_scope_from_args "$target" ${extra_args[@]+"${extra_args[@]}"}
  fi

  edc_octocode_capability_init

  # Gate on freshness; recover (build/update + force-retry) unless the caller
  # explicitly requested a no-refresh run. --no-context-refresh may still use
  # existing context; it just refuses to create/update it. --ignore-context is
  # the stronger pure-baseline mode.
  if [ "$no_context_refresh" -ne 1 ] && [ "$ignore_context" -ne 1 ]; then
    if [ "${EDC_REVIEW_CONTEXT_PREPARED:-0}" != 1 ]; then
      recover_context_if_needed ${build_args[@]+"${build_args[@]}"} -- ${update_args[@]+"${update_args[@]}"} \
        || { edc_write_review_result 1 "context-recovery-failed" "context recovery failed before security review" "inspect the log above, then rerun edc update --agent $EDC_AGENT_CLI or edc build --agent $EDC_AGENT_CLI --force" "" ""; exit 1; }
    else
      assert_context_fresh \
        || { edc_write_review_result 1 "context-not-fresh" "review-all prepared context is no longer fresh" "rerun review-all so context recovery completes before workers start" "" ""; exit 1; }
    fi
  fi

  # All worker IPC and the pre-promotion consolidated report live under git
  # state. Only a fully validated consolidated report is promoted to the root.
  local run_dir run_id
  edc_create_worker_run "security" run_dir run_id || exit $?
  local EDC_REVIEW_TASKS_DIR="$run_dir/staged/review-tasks"
  local EDC_REVIEW_TASKS_MANIFEST="$EDC_REVIEW_TASKS_DIR/manifest.json"
  local canonical_review promotion_review staged_review
  canonical_review=$(final_review_filename "${EDC_REVIEW_DISPLAY_TARGET:-${EDC_CANDIDATE_TARGET:-$target}}")
  promotion_review="${EDC_REVIEW_PROMOTION_OUTPUT:-$canonical_review}"
  staged_review="$run_dir/staged/$(basename "$canonical_review")"
  local EDC_REVIEW_FINAL_OUTPUT="$staged_review"

  # Build review tasks now that context is fresh. Run the function in-process
  # instead of shelling out to `$0 --build`; command substitution confines its
  # exits while preserving outputs under the git-private task directory.
  local out build_rc=0
  out=$(build_mode_resolved "$target" ${extra_args[@]+"${extra_args[@]}"} 2>&1) || build_rc=$?

  if [ "$build_rc" -ne 0 ] || [ ! -f "$EDC_REVIEW_TASKS_MANIFEST" ]; then
    echo "ERROR: script did not produce review tasks. Output:" >&2
    echo "$out" >&2
    local failure_reason="review task generation failed"
    local failure_hint="inspect the log for task-generation output and rerun after fixing it"
    if grep -q 'ERROR: no changed files found for target:' <<< "$out"; then
      failure_reason="no changed files found for review"
      failure_hint="the resolved candidate has no changes against this base; run 'edc review full --agent <agent>' for a full repo review, or choose another base"
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
  local had_warning=0

  if [ -n "$tasks" ]; then
    local prompts_dir="$run_dir/prompts" tasks_jsonl="$run_dir/review-tasks.jsonl" worker_manifest="$run_dir/review-manifest.json"
    : > "$tasks_jsonl"
    local -a review_modules=() review_task_ids=()
    local task_path module prompt_path allowed_report allowed_result task_id
    local task_count=0
    while IFS= read -r task_path; do
      [ -z "$task_path" ] && continue
      task_count=$((task_count + 1))
      module=$(basename "$task_path" .md)
      task_id="review-module-$task_count"
      prompt_path="$prompts_dir/$task_id.md"
      allowed_report="$EDC_REVIEW_TASKS_DIR/report-${module}.md"
      allowed_result="$EDC_REVIEW_TASKS_DIR/result-${module}.json"
      echo "→ planning review module: $module"
      resolve_prompt review "$task_path" > "$prompt_path" || exit 1
      if [ "$(manifest_module_policy "$module")" = "promotion-check" ]; then
        edc_worker_task_append "$tasks_jsonl" "$task_id" "edc-review/$module" "$module" "$prompt_path" "${EDC_REVIEW_TIMEOUT:-1800}" continue "$allowed_report" "$allowed_result" || exit 1
      else
        edc_worker_task_append "$tasks_jsonl" "$task_id" "edc-review/$module" "$module" "$prompt_path" "${EDC_REVIEW_TIMEOUT:-1800}" continue "$allowed_report" || exit 1
      fi
      review_modules+=("$module")
      review_task_ids+=("$task_id")
    done <<< "$tasks"

    edc_worker_manifest_write "$worker_manifest" "$run_id" "$run_dir" "$tasks_jsonl" || exit 1
    local pool_rc=0 before_snapshot after_snapshot changed_forbidden
    before_snapshot=$(mktemp)
    after_snapshot=$(mktemp)
    edc_snapshot_review_forbidden_paths "$before_snapshot"
    edc_worker_pool_run "$worker_manifest" || pool_rc=$?
    edc_snapshot_review_forbidden_paths "$after_snapshot"
    changed_forbidden=$(edc_diff_review_forbidden_paths "$before_snapshot" "$after_snapshot" || true)
    rm -f "$before_snapshot" "$after_snapshot"
    if [ -n "$changed_forbidden" ]; then
      echo "ERROR: forbidden paths changed during the security worker stage:" >&2
      echo "$changed_forbidden" | sed 's/^/  /' >&2
      edc_write_review_result 1 "review-write-containment" "forbidden paths changed during the security worker stage" "inspect $run_dir for the writer; rerun in a disposable checkout if reviewing untrusted input" "" ""
      exit 1
    fi

    local task_index=0 worker_status report
    while [ "$task_index" -lt "$task_count" ]; do
      module="${review_modules[$task_index]}"
      worker_status=$(node -e 'const j=require(process.argv[1]); const task=j.tasks.find((entry)=>entry.id===process.argv[2]); process.stdout.write(task?.status || "missing")' "$run_dir/stage-result.json" "${review_task_ids[$task_index]}")
      report="$EDC_REVIEW_TASKS_DIR/report-${module}.md"
      if [ "$(manifest_module_policy "$module")" != "promotion-check" ] \
        && ! edc_file_has_substantive_content "$report"; then
        edc_write_coverage_gap_report "$report" "Security Review Coverage Gap" \
          "Security review unavailable for module \`$module\`; its reviewer finished with status \`$worker_status\` without substantive output."
        had_warning=1
        echo "EDC review completed with warning: module $module produced no substantive report." >&2
      fi
      assert_intermediate_report_valid "$module" \
        || { echo "ERROR: report validation failed for module $module" >&2; edc_write_review_result 1 "report-validation" "review report validation failed for module $module" "inspect the staged reviewer output under $run_dir" "$module" ""; exit 1; }
      if [ "$worker_status" != "success" ]; then
        had_warning=1
        echo "EDC review completed with warning: review subprocess for module $module reported status $worker_status." >&2
        echo "HINT: preserving its substantive report or explicit unavailable marker; inspect $run_dir for diagnostics." >&2
      fi
      task_index=$((task_index + 1))
    done
    if [ "$pool_rc" -ne 0 ] && [ "$had_warning" -eq 0 ]; then
      echo "ERROR: security worker pool failed without a failed task result" >&2
      exit 1
    fi
  fi

  # Consolidation validates worker and deterministic prewritten reports.
  consolidate_mode || { echo "ERROR: consolidation failed" >&2; edc_write_review_result 1 "consolidation-failed" "review consolidation failed" "inspect staged reports under $run_dir" "" ""; exit 1; }
  verify_mode || { echo "ERROR: verification failed" >&2; edc_write_review_result 1 "verification-failed" "review verification failed" "inspect staged artifacts under $run_dir" "" ""; exit 1; }
  edc_promote_file "$staged_review" "$promotion_review" || { edc_write_review_result 1 "promotion-failed" "review promotion failed" "inspect filesystem permissions and staged output under $run_dir" "" ""; exit 1; }

  if [ "${EDC_KEEP_REVIEW_TASKS:-0}" != "1" ]; then
    rm -rf "$EDC_REVIEW_TASKS_DIR"
  fi

  if [ "$had_warning" -ne 0 ]; then
    edc_write_review_result 0 "success-with-warning" "review completed with one or more module coverage warnings" "inspect the agent log for transport/provider diagnostics" "" "$canonical_review"
  else
    edc_write_review_result 0 "success" "" "" "" "$canonical_review"
  fi

  # Explicit exit so any late-arriving subprocess output can't poison our
  # exit code after the pipeline succeeded.
  exit 0
}

# ── build mode ───────────────────────────────────────────────────────────────

review_usage() {
  cat <<EOF
Usage: edc-review.sh [--agent <cli>] [--model <slug>] <target> [--base <ref>] [--include-working-tree|--committed-only] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
                                                     differential security review pipeline
       edc-review.sh [--agent <cli>] [--model <slug>] --full [--ignore <glob>]... [--context-mode advisory|inject]
                                                     full current-repo security review pipeline
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
      edc_runtime_preflight_or_exit
      edc_load_review_dependencies
      build_mode "pr:$pr_target" "$@"
      exit $?
    fi
    if [ "${1:-}" = "--full" ]; then
      edc_runtime_preflight_or_exit
      edc_load_review_dependencies
      build_mode HEAD --full "${@:2}"
      exit $?
    fi
    if [ -z "${1:-}" ]; then
      echo "ERROR: --build requires a target" >&2
      exit 2
    fi
    edc_runtime_preflight_or_exit
    edc_load_review_dependencies
    build_mode "$@"
    ;;
  --full)
    auto_mode HEAD --full "${@:2}"
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
    edc_runtime_preflight_or_exit
    edc_load_review_dependencies
    check_context_mode
    ;;
  --consolidate)
    edc_runtime_preflight_or_exit
    edc_load_review_dependencies
    consolidate_mode
    ;;
  --verify)
    edc_runtime_preflight_or_exit
    edc_load_review_dependencies
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
