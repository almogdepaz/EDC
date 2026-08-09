#!/usr/bin/env bash
# edc-audit orchestrator.
# Deterministic control plane for terminal/orchestrated edc audit runs.
#
# Flow:
#   1. dependency check (git/node via helpers)
#   2. parse args (optional target/--base diff scope, --ignore, --context-mode)
#   3. freshness gate via assert_context_fresh; auto-recover (build/update +
#      force-retry) if stale or missing — same recovery path review uses
#   4. spawn one scoped audit subprocess per manifest module
#   5. spawn one synthesis subprocess to write canonical reports
#   6. validate output: <reports-dir>/{complexity,issues}.md must exist
#      and contain at least one ## heading
#   7. exit 0 with paths printed, non-zero with reason
#
# Usage:
#   EDC_AGENT_CLI=claude|cursor|codex|pi bash edc-audit.sh [target --base <ref>] [--ignore <glob>]... [--context-mode advisory|inject]

set -euo pipefail

# ── dependency check ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
SCRIPT_DIR="$EDC_SCRIPTS_DIR"
MANIFEST="$EDC_MANIFEST"
CLEAN_SLATE_SH="$SCRIPT_DIR/edc-clean-slate.sh"

# ── agent CLI selection ──────────────────────────────────────────────────────

EDC_AGENT_CLI="${EDC_AGENT_CLI:-claude}"
CODEX_EXEC_HOME=""
CODEX_EXEC_HOME_OWNED=0

# ── shared helpers ───────────────────────────────────────────────────────────

EDC_AUDIT_DEPENDENCIES_LOADED=0
edc_load_audit_dependencies() {
  [ "$EDC_AUDIT_DEPENDENCIES_LOADED" = "1" ] && return 0
  # Managed helpers execute only after runtime integrity passes.
  # shellcheck source=edc-assert-fresh.sh
  . "$SCRIPT_DIR/edc-assert-fresh.sh"
  # shellcheck source=edc-recover-context.sh
  . "$SCRIPT_DIR/edc-recover-context.sh"
  # shellcheck source=edc-review-candidate.sh
  . "$SCRIPT_DIR/edc-review-candidate.sh"
  EDC_AUDIT_DEPENDENCIES_LOADED=1
}

# ── audit task helpers ───────────────────────────────────────────────────────

AUDIT_TASKS_DIR="$EDC_CONTEXT_DIR/audit-tasks"

safe_audit_name() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

manifest_audit_modules() {
  node "$EDC_JSON_CLI" audit-modules "$MANIFEST"
}

changed_files_for_audit_scope() {
  local target="$1" base="$2"
  git diff --name-only --diff-filter=ACDMRTUXB "$base...$target" 2>/dev/null | sed '/^$/d'
}

manifest_audit_modules_for_files() {
  node "$EDC_JSON_CLI" audit-modules-for-files "$MANIFEST"
}

assert_markdown_report_valid() {
  local f="$1" label="$2"
  if [ ! -f "$f" ]; then
    echo "ERROR: audit report missing: $f ($label)" >&2
    return 1
  fi
  if ! grep -q '^##' "$f"; then
    echo "ERROR: $f has no '## ' headings — expected sections like ## Summary" >&2
    echo "HINT: subprocess produced a stub. check the agent output above." >&2
    return 1
  fi
}

assert_audit_report_pair_valid() {
  local complexity_path="$1" issues_path="$2" rc=0
  assert_markdown_report_valid "$complexity_path" "complexity" || rc=1
  assert_markdown_report_valid "$issues_path" "issues" || rc=1
  return $rc
}

assert_audit_reports_valid() {
  assert_audit_report_pair_valid "$EDC_COMPLEXITY" "$EDC_ISSUES"
}

build_audit_worker_prompt() {
  local module="$1" module_doc="$2" report_path="$3"
  local candidate_contract="Full audit: inspect the repository source directly."
  if [ -n "${target:-}" ]; then
    candidate_contract="The immutable candidate commit is \`$target\`. Treat \`git diff ${base}...${target}\` and blobs read with \`git show ${target}:<path>\` as the sole source evidence. Do not read changed or adjacent source from the mutable working tree. For a deleted path, inspect its baseline blob. For a changed gitlink, resolve the baseline and candidate gitlink SHAs from the parent commits, inspect bytes with \`git -C <submodule-path> diff <baseline-submodule>...<candidate-submodule>\` and \`git -C <submodule-path> show <candidate-submodule>:<path>\`, and repeat for nested gitlinks; when the baseline has no gitlink, enumerate the candidate with \`git -C <submodule-path> ls-tree -r <candidate-submodule>\`. Never use mutable submodule working-tree source as evidence."
  fi
  cat <<EOF
AUDIT WORKER TASK
AUDIT_MODULE: $module
AUDIT_MODULE_DOC: $module_doc
AUDIT_REPORT_PATH: $report_path

Run a scoped code quality audit for this one module only.

Candidate evidence contract:
$candidate_contract

Rules:
1. Read $EDC_INDEX, $MANIFEST, and $module_doc for this module's documented ownership, invariants, and file scope.
2. Inspect only this module plus the smallest supporting references needed to verify a local code-quality finding.
3. Write exactly one markdown report to $report_path.
4. Do not write $EDC_COMPLEXITY or $EDC_ISSUES; synthesis owns canonical reports.
5. Use the embedded edc-audit skill bundle below.

$(_emit_audit_prompt)
EOF
}

build_audit_synthesis_prompt() {
  local complexity_output="$1" issues_output="$2"
  cat <<EOF
AUDIT SYNTHESIS TASK
AUDIT_WORKER_REPORTS_DIR: $AUDIT_TASKS_DIR
CANONICAL_COMPLEXITY_REPORT: $complexity_output
CANONICAL_ISSUES_REPORT: $issues_output

Synthesize the scoped module audit reports into the canonical EDC audit reports.

Rules:
1. Read every markdown report under $AUDIT_TASKS_DIR.
2. Do not re-audit source code unless a worker report is ambiguous and a small verification read is necessary.
3. Write $complexity_output for maintainability/code-quality findings.
4. Write $issues_output only for concrete correctness risks surfaced by worker reports.
5. Preserve module names and evidence from worker reports so findings remain traceable.
6. Use the embedded edc-audit reporting contract below.

$(_emit_audit_prompt)
EOF
}

# ── main ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF' >&2
Usage:
  EDC_AGENT_CLI=<claude|cursor|codex|pi> edc-audit.sh [target --base <ref>] [--include-working-tree|--committed-only] [--ignore <glob>]... [--context-mode advisory|inject]
EOF
  exit 2
}

audit_main() {
  edc_result_begin audit
  trap edc_result_on_exit EXIT
  edc_runtime_preflight_or_exit
  edc_load_audit_dependencies
  local target="" base="" policy=""
  local complexity_output="${EDC_AUDIT_COMPLEXITY_OUTPUT:-$EDC_COMPLEXITY}"
  local issues_output="${EDC_AUDIT_ISSUES_OUTPUT:-$EDC_ISSUES}"
  local -a ignore_args=() ignore_patterns=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base)
        [ "$#" -ge 2 ] || { echo "ERROR: --base requires a ref" >&2; usage; }
        base="$2"
        shift 2
        ;;
      --include-working-tree)
        [ -z "$policy" ] || { echo "ERROR: choose only one dirty-state policy" >&2; exit 2; }
        policy=include-working-tree
        shift
        ;;
      --committed-only)
        [ -z "$policy" ] || { echo "ERROR: choose only one dirty-state policy" >&2; exit 2; }
        policy=committed-only
        shift
        ;;
      --ignore)
        [ "$#" -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; usage; }
        ignore_args+=("$1" "$2")
        ignore_patterns+=("$2")
        shift 2
        ;;
      --context-mode)
        [ "$#" -ge 2 ] || { echo "ERROR: --context-mode requires a value" >&2; usage; }
        # accepted but currently advisory-only for audit; passed through to
        # build/update if recovery is needed.
        shift 2
        ;;
      --help|-h) usage ;;
      --*) echo "ERROR: unknown argument: $1" >&2; usage ;;
      *)
        if [ -n "$target" ]; then
          echo "ERROR: audit accepts at most one target" >&2
          usage
        fi
        target="$1"
        shift
        ;;
    esac
  done

  if [ -n "$base" ] && [ -z "$target" ]; then
    target="HEAD"
  fi
  if [ -n "$target" ] && [ -z "$base" ]; then
    echo "ERROR: differential quality review requires --base <ref>" >&2
    usage
  fi
  if [ -n "$policy" ] && [ -z "$target" ]; then
    echo "ERROR: a dirty-state policy requires differential quality review with target --base <ref>" >&2
    usage
  fi
  if [ -n "$target" ]; then
    local candidate_file
    candidate_file=$(mktemp "${TMPDIR:-/tmp}/edc-audit-candidate-$$.XXXXXX") || exit 1
    edc_candidate_resolve "$target" "$base" "$policy" > "$candidate_file" || { local rc=$?; rm -f "$candidate_file"; exit "$rc"; }
    target=$(cat "$candidate_file")
    rm -f "$candidate_file"
  fi

  edc_require_agent_cli

  # Gate on freshness once for standalone review. review-all prepares it before
  # launching all lenses so parallel children must not race recovery.
  if [ "${EDC_REVIEW_CONTEXT_PREPARED:-0}" != 1 ]; then
    recover_context_if_needed ${ignore_args[@]+"${ignore_args[@]}"} \
      || { edc_result_failure 1 "context-recovery-failed" "context recovery failed before quality review" "inspect the log above, then rerun edc update --agent $EDC_AGENT_CLI or edc build --agent $EDC_AGENT_CLI --force"; exit 1; }
  else
    assert_context_fresh \
      || { edc_result_failure 1 "context-not-fresh" "review-all prepared context is no longer fresh" "rerun review-all so context recovery completes before workers start"; exit 1; }
  fi

  # Build a versioned task manifest in git-private run storage. Workers write
  # only staged reports; the coordinator validates before canonical promotion.
  echo "→ running per-module audit via $EDC_AGENT_CLI..."
  local run_dir run_id
  edc_create_worker_run "audit" run_dir run_id || exit $?
  local AUDIT_TASKS_DIR="$run_dir/staged/audit-tasks"
  local prompts_dir="$run_dir/prompts" tasks_jsonl="$run_dir/module-tasks.jsonl" worker_manifest="$run_dir/module-manifest.json"
  mkdir -p "$AUDIT_TASKS_DIR" "$prompts_dir"
  : > "$tasks_jsonl"

  local changed_files=""
  if [ -n "$target" ]; then
    changed_files=$(changed_files_for_audit_scope "$target" "$base")
    changed_files=$(edc_filter_ignored_files "$changed_files" ${ignore_patterns[@]+"${ignore_patterns[@]}"})
    if [ -z "$changed_files" ]; then
      echo "ERROR: no changed files found for quality review target: $target" >&2
      edc_result_failure 1 "no-reviewable-files" "no changed files found for quality review" "choose another target/base or modify a tracked file"
      exit 1
    fi
  fi

  local module module_doc safe report_path prompt_path task_id module_count=0 had_warning=0
  local -a audit_modules=() audit_reports=() audit_task_ids=()
  while IFS=$'\t' read -r module module_doc; do
    [ -n "${module:-}" ] || continue
    module_count=$((module_count + 1))
    if [ -z "${module_doc:-}" ] || [ ! -f "$module_doc" ]; then
      echo "ERROR: manifest module '$module' has missing doc: ${module_doc:-<empty>}" >&2
      exit 1
    fi
    safe=$(safe_audit_name "$module")
    [ -n "$safe" ] || safe="module_$module_count"
    task_id="audit-module-$module_count"
    report_path="$AUDIT_TASKS_DIR/$safe.md"
    prompt_path="$prompts_dir/$task_id.md"
    echo "→ planning audit module: $module"
    build_audit_worker_prompt "$module" "$module_doc" "$report_path" > "$prompt_path" || exit 1
    edc_worker_task_append "$tasks_jsonl" "$task_id" "edc-audit/$safe" "$module" "$prompt_path" "${EDC_AUDIT_TIMEOUT:-1800}" continue "$report_path" || exit 1
    audit_modules+=("$module")
    audit_reports+=("$report_path")
    audit_task_ids+=("$task_id")
  done < <(if [ -n "$target" ]; then printf '%s\n' "$changed_files" | manifest_audit_modules_for_files; else manifest_audit_modules; fi)

  if [ "$module_count" -eq 0 ]; then
    if [ -n "$target" ]; then
      echo "ERROR: no changed files map to auditable modules for quality review" >&2
      edc_result_failure 1 "no-reviewable-files" "no changed files map to auditable modules for quality review" "choose another target/base or run full quality-review without --diff"
    else
      echo "ERROR: no real modules found in $MANIFEST; cannot run per-module audit" >&2
      edc_result_failure 1 "audit-no-modules" "no real modules found in manifest" "run edc doctor, then rebuild edc-context if needed"
    fi
    exit 1
  fi

  edc_worker_manifest_write "$worker_manifest" "$run_id" "$run_dir" "$tasks_jsonl" || exit 1
  local worker_pool_rc=0 before_snapshot after_snapshot changed_forbidden
  before_snapshot=$(mktemp)
  after_snapshot=$(mktemp)
  edc_snapshot_review_forbidden_paths "$before_snapshot"
  edc_worker_pool_run "$worker_manifest" || worker_pool_rc=$?
  edc_snapshot_review_forbidden_paths "$after_snapshot"
  changed_forbidden=$(edc_diff_review_forbidden_paths "$before_snapshot" "$after_snapshot" || true)
  rm -f "$before_snapshot" "$after_snapshot"
  if [ -n "$changed_forbidden" ]; then
    echo "ERROR: forbidden paths changed during the audit worker stage:" >&2
    echo "$changed_forbidden" | sed 's/^/  /' >&2
    edc_result_failure 1 "audit-write-containment" "forbidden paths changed during the audit worker stage" "inspect the run logs for the writer; rerun in a disposable checkout if reviewing untrusted input"
    exit 1
  fi

  local index worker_status
  index=0
  while [ "$index" -lt "$module_count" ]; do
    module="${audit_modules[$index]}"
    report_path="${audit_reports[$index]}"
    assert_markdown_report_valid "$report_path" "module $module" \
      || { echo "ERROR: module audit validation failed for $module" >&2; edc_result_failure 1 "audit-report-validation" "module audit validation failed for $module" "inspect the staged module audit and task stderr under $run_dir" "$module"; exit 1; }
    worker_status=$(node -e 'const j=require(process.argv[1]); const task=j.tasks.find((entry)=>entry.id===process.argv[2]); process.stdout.write(task?.status || "missing")' "$run_dir/stage-result.json" "${audit_task_ids[$index]}")
    if [ "$worker_status" != "success" ]; then
      had_warning=1
      echo "EDC audit succeeded with warning: audit subprocess for module $module reported failure, but report validation passed." >&2
      echo "HINT: treating the validated module audit report as success; inspect $run_dir for transport/provider diagnostics." >&2
    fi
    index=$((index + 1))
  done
  if [ "$worker_pool_rc" -ne 0 ] && [ "$had_warning" -eq 0 ]; then
    echo "ERROR: audit worker pool failed without a failed task result" >&2
    exit 1
  fi

  echo "→ synthesizing audit reports..."
  local staged_complexity="$run_dir/staged/complexity.md" staged_issues="$run_dir/staged/issues.md"
  local synthesis_prompt_path="$prompts_dir/audit-synthesis.md" synthesis_tasks="$run_dir/synthesis-tasks.jsonl" synthesis_manifest="$run_dir/synthesis-manifest.json"
  build_audit_synthesis_prompt "$staged_complexity" "$staged_issues" > "$synthesis_prompt_path" || exit 1
  : > "$synthesis_tasks"
  edc_worker_task_append "$synthesis_tasks" audit-synthesis edc-audit/synthesis "" "$synthesis_prompt_path" "${EDC_AUDIT_TIMEOUT:-1800}" continue "$staged_complexity" "$staged_issues" || exit 1
  edc_worker_manifest_write "$synthesis_manifest" "$run_id" "$run_dir" "$synthesis_tasks" || exit 1

  local synthesis_rc=0
  before_snapshot=$(mktemp)
  after_snapshot=$(mktemp)
  edc_snapshot_review_forbidden_paths "$before_snapshot"
  edc_worker_pool_run "$synthesis_manifest" || synthesis_rc=$?
  edc_snapshot_review_forbidden_paths "$after_snapshot"
  changed_forbidden=$(edc_diff_review_forbidden_paths "$before_snapshot" "$after_snapshot" || true)
  rm -f "$before_snapshot" "$after_snapshot"
  if [ -n "$changed_forbidden" ]; then
    echo "ERROR: forbidden paths changed during audit synthesis:" >&2
    echo "$changed_forbidden" | sed 's/^/  /' >&2
    edc_result_failure 1 "audit-write-containment" "forbidden paths changed during audit synthesis" "inspect the run logs for the writer; rerun in a disposable checkout if reviewing untrusted input"
    exit 1
  fi

  assert_audit_report_pair_valid "$staged_complexity" "$staged_issues" \
    || { edc_result_failure 1 "audit-report-validation" "audit report validation failed" "inspect synthesis output under $run_dir; staged reports are missing or incomplete"; exit 1; }
  if [ "$synthesis_rc" -ne 0 ]; then
    had_warning=1
    echo "EDC audit succeeded with warning: audit synthesis subprocess reported failure, but report validation passed." >&2
    echo "HINT: treating the validated audit reports as success; inspect $run_dir for transport/provider diagnostics." >&2
  fi

  edc_promote_file "$staged_complexity" "$complexity_output" || exit 1
  edc_promote_file "$staged_issues" "$issues_output" || exit 1
  assert_audit_report_pair_valid "$complexity_output" "$issues_output" || { edc_result_failure 1 "audit-report-validation" "promoted audit report validation failed" "inspect canonical report promotion"; exit 1; }

  if [ "${EDC_KEEP_AUDIT_TASKS:-0}" != "1" ]; then
    rm -rf "$AUDIT_TASKS_DIR"
  fi

  if [ "$had_warning" -ne 0 ]; then
    edc_result_success_with_warning "audit validated outputs after one or more subprocess failures" "inspect the agent log for transport/provider diagnostics"
  else
    edc_result_success
  fi
  echo "Audit reports:"
  echo "  $EDC_COMPLEXITY"
  echo "  $EDC_ISSUES"
  exit 0
}

audit_main "$@"
