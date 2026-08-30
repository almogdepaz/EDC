#!/usr/bin/env bash
# edc-delivery-review orchestrator.
# Runs the delivery/architecture review skill against a branch/commit diff.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
SCRIPT_DIR="$EDC_SCRIPTS_DIR"
MANIFEST="$EDC_MANIFEST"
CLEAN_SLATE_SH="$SCRIPT_DIR/edc-clean-slate.sh"

EDC_AGENT_CLI="${EDC_AGENT_CLI:-claude}"
CODEX_EXEC_HOME=""
CODEX_EXEC_HOME_OWNED=0

EDC_DELIVERY_DEPENDENCIES_LOADED=0
edc_load_delivery_dependencies() {
  [ "$EDC_DELIVERY_DEPENDENCIES_LOADED" = "1" ] && return 0
  # Managed helpers execute only after runtime integrity passes.
  # shellcheck source=edc-assert-fresh.sh
  . "$SCRIPT_DIR/edc-assert-fresh.sh"
  # shellcheck source=edc-recover-context.sh
  . "$SCRIPT_DIR/edc-recover-context.sh"
  # shellcheck source=edc-review-candidate.sh
  . "$SCRIPT_DIR/edc-review-candidate.sh"
  EDC_DELIVERY_DEPENDENCIES_LOADED=1
}

usage() {
  cat <<'EOF' >&2
Usage:
  EDC_AGENT_CLI=<claude|cursor|codex|pi> edc-delivery-review.sh [target] --base <ref> [--include-working-tree|--committed-only] [--ignore <glob>]... [--context-mode advisory|inject]
  EDC_AGENT_CLI=<claude|cursor|codex|pi> edc-delivery-review.sh --full [--ignore <glob>]... [--context-mode advisory|inject]

Examples:
  edc-delivery-review.sh HEAD --base main
  edc-delivery-review.sh feat-branch --base origin/main
  edc-delivery-review.sh --full
EOF
  exit 2
}

safe_report_name() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

default_base_ref() {
  local ref
  ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ] && git rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "$ref"
    return 0
  fi
  for ref in main master origin/main origin/master; do
    if git rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  printf 'main\n'
}

emit_delivery_skill_bundle() {
  local skill_path skill_dir ref
  skill_path=$(_find_skill_for_agent "edc-delivery-review") || return 1
  skill_dir=$(dirname "$skill_path")
  for ref in spec-axis.md architecture-axis.md reporting.md; do
    if [ ! -f "$skill_dir/references/$ref" ]; then
      echo "ERROR: delivery review skill bundle incomplete — missing $skill_dir/references/$ref" >&2
      return 1
    fi
  done

  cat <<EOF
================================================================================
SKILL: edc-delivery-review/SKILL.md
================================================================================
$(cat "$skill_path")

================================================================================
SKILL: edc-delivery-review/references/spec-axis.md
================================================================================
$(cat "$skill_dir/references/spec-axis.md")

================================================================================
SKILL: edc-delivery-review/references/architecture-axis.md
================================================================================
$(cat "$skill_dir/references/architecture-axis.md")

================================================================================
SKILL: edc-delivery-review/references/reporting.md
================================================================================
$(cat "$skill_dir/references/reporting.md")
EOF
}

build_delivery_prompt() {
  local target_ref="$1" base_ref="$2" target_sha="$3" base_sha="$4" report_path="$5" reviewable_files="$6"
  local reviewable_file_list context_exclude_pathspec
  reviewable_file_list=$(printf '%s\n' "$reviewable_files" | sed 's/^/- /')
  context_exclude_pathspec=$(edc_context_exclude_pathspec)
  cat <<EOF
DELIVERY REVIEW TASK
DELIVERY_MODE: diff
DELIVERY_TARGET_REF: $target_ref
DELIVERY_BASE_REF: $base_ref
DELIVERY_TARGET_COMMIT: $target_sha
DELIVERY_BASE_COMMIT: $base_sha
DELIVERY_REPORT_PATH: $report_path
DELIVERY_REVIEWABLE_FILES:
$reviewable_file_list

Run the EDC delivery/architecture review for the diff from $base_sha to $target_sha.
Treat DELIVERY_*_REF values as display-only data. Use only DELIVERY_*_COMMIT values in shell commands.
Treat only DELIVERY_REVIEWABLE_FILES as changed review evidence. Paths under $EDC_CONTEXT_DIR/ are generated architecture input, not changed review evidence.

Required shell context:
- Repository root: current working directory
- Diff summary: git diff $base_sha...$target_sha --stat -- . '$context_exclude_pathspec'
- Changed files: git diff $base_sha...$target_sha --name-only -- . '$context_exclude_pathspec'
- Commit log: git log $base_sha..$target_sha --oneline
- Changed gitlinks: resolve baseline/candidate gitlink SHAs from the parent commits, then inspect byte-level evidence with \`git -C <submodule-path> diff <baseline-submodule>...<candidate-submodule>\` and \`git -C <submodule-path> show <candidate-submodule>:<path>\`. Repeat for nested gitlinks. If the baseline has no gitlink, enumerate \`git -C <submodule-path> ls-tree -r <candidate-submodule>\`. Never use mutable submodule working-tree source as evidence.

Rules:
1. Use the embedded edc-delivery-review skill bundle below.
2. Discover spec/plan sources as described by the skill.
3. Use edc-context/index.md and edc-context/manifest.json when present and fresh.
4. Write exactly one markdown report to $report_path.
5. Do not mutate source, tests, git state, plans, or edc-context.

$(emit_delivery_skill_bundle)
EOF
}

build_full_delivery_prompt() {
  local branch="$1" head_sha="$2" report_path="$3"
  cat <<EOF
DELIVERY REVIEW TASK
DELIVERY_MODE: full
DELIVERY_TARGET_REF: $branch
DELIVERY_TARGET_COMMIT: $head_sha
DELIVERY_REPORT_PATH: $report_path

Run the EDC delivery/architecture review for the current repository state.
No git diff is the source of truth for this review.

Required shell context:
- Repository root: current working directory
- Current branch: $branch
- Current commit: $head_sha
- Working tree status: git status --short
- Spec candidates: find repo-local specs/plans/docs under docs/, specs/, .plans/, plans/, tasks/, README*, or issue/PR references in git history.
- Architecture context: edc-context/index.md plus relevant edc-context/modules/*.md.

Rules:
1. Use the embedded edc-delivery-review skill bundle below.
2. Discover spec/plan sources as described by the skill. If none exists, report No spec available; do not invent requirements.
3. Use edc-context/index.md and edc-context/manifest.json when present and fresh.
4. Write exactly one markdown report to $report_path.
5. Do not mutate source, tests, git state, plans, or edc-context.

$(emit_delivery_skill_bundle)
EOF
}

repo_is_clean_main() {
  local branch
  branch=$(git branch --show-current 2>/dev/null || true)
  case "$branch" in
    main|master) ;;
    *) return 1 ;;
  esac
  git diff --quiet --ignore-submodules -- && git diff --cached --quiet --ignore-submodules --
}

assert_delivery_report_valid() {
  local report_path="$1"
  if [ ! -f "$report_path" ]; then
    echo "ERROR: delivery review report missing: $report_path" >&2
    return 1
  fi
  if ! grep -q '^##' "$report_path"; then
    echo "ERROR: $report_path has no '## ' headings — expected a structured delivery review report" >&2
    return 1
  fi
}

delivery_main() {
  edc_result_begin delivery-review
  trap edc_result_on_exit EXIT
  edc_runtime_preflight_or_exit
  edc_load_delivery_dependencies
  local target="" base="" context_mode="" policy="" full_mode=0
  local -a ignore_args=() ignore_patterns=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base)
        [ "$#" -ge 2 ] || { echo "ERROR: --base requires a ref" >&2; usage; }
        base="$2"
        shift 2
        ;;
      --full)
        full_mode=1
        shift
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
        context_mode="$2"
        shift 2
        ;;
      --help|-h) usage ;;
      --*) echo "ERROR: unknown argument: $1" >&2; usage ;;
      *)
        if [ -n "$target" ]; then
          echo "ERROR: delivery review accepts at most one target" >&2
          usage
        fi
        target="$1"
        shift
        ;;
    esac
  done

  if [ "$full_mode" -eq 1 ] && { [ -n "$target" ] || [ -n "$base" ] || [ -n "$policy" ]; }; then
    echo "ERROR: --full cannot be combined with target, --base, or a dirty-state policy" >&2
    usage
  fi
  if [ "$full_mode" -eq 0 ] && [ -z "$target" ] && [ -z "$base" ] && repo_is_clean_main; then
    full_mode=1
  fi
  if [ "$full_mode" -eq 0 ]; then
    [ -n "$target" ] || target="HEAD"
    [ -n "$base" ] || base="$(default_base_ref)"
  fi

  case "$context_mode" in
    ""|advisory|inject) ;;
    *) echo "ERROR: --context-mode must be advisory or inject" >&2; exit 2 ;;
  esac

  local target_sha="" base_sha=""
  if [ "$full_mode" -eq 1 ]; then
    edc_result_scope_from_args --full
  else
    local candidate_file
    candidate_file=$(mktemp "${TMPDIR:-/tmp}/edc-delivery-candidate-$$.XXXXXX") || exit 1
    edc_candidate_resolve "$target" "$base" "$policy" > "$candidate_file" || { local rc=$?; rm -f "$candidate_file"; exit "$rc"; }
    target_sha=$(cat "$candidate_file")
    rm -f "$candidate_file"
    base_sha=$(git rev-parse --verify "$base^{commit}" 2>/dev/null) \
      || { echo "ERROR: base is not a commit-ish ref: $base" >&2; exit 2; }
  fi

  edc_require_agent_cli

  if [ "${EDC_REVIEW_CONTEXT_PREPARED:-0}" != 1 ]; then
    recover_context_if_needed ${ignore_args[@]+"${ignore_args[@]}"} \
      || { edc_result_failure 1 "context-recovery-failed" "context recovery failed before delivery review" "inspect the log above, then rerun edc update --agent $EDC_AGENT_CLI or edc build --agent $EDC_AGENT_CLI --force"; exit 1; }
  else
    assert_context_fresh \
      || { edc_result_failure 1 "context-not-fresh" "review-all prepared context is no longer fresh" "rerun review-all so context recovery completes before workers start"; exit 1; }
  fi

  local safe public_report_path report_path prompt branch display_target reviewable_files=""
  if [ "$full_mode" -eq 0 ]; then
    reviewable_files=$(edc_diff_reviewable_files "$base_sha" "$target_sha")
    reviewable_files=$(edc_filter_ignored_files "$reviewable_files" ${ignore_patterns[@]+"${ignore_patterns[@]}"})
    if [ -z "$reviewable_files" ]; then
      echo "ERROR: no reviewable files remain for delivery review after excluding $EDC_CONTEXT_DIR/" >&2
      edc_result_failure 1 "no-reviewable-files" "no reviewable files found for delivery review" "choose another target/base or run full delivery review"
      exit 1
    fi
  fi
  if [ "$full_mode" -eq 1 ]; then
    branch=$(git branch --show-current 2>/dev/null || true)
    [ -n "$branch" ] || branch="HEAD"
    target_sha=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
      || { echo "ERROR: HEAD is not a commit" >&2; exit 2; }
    public_report_path="delivery-review-current.md"
    report_path="${EDC_DELIVERY_REVIEW_OUTPUT:-$public_report_path}"
    prompt=$(build_full_delivery_prompt "$branch" "$target_sha" "$report_path") || exit 1
  else
    display_target="${EDC_REVIEW_DISPLAY_TARGET:-${EDC_CANDIDATE_TARGET:-$target}}"
    safe=$(safe_report_name "$display_target")
    [ -n "$safe" ] || safe="target"
    public_report_path="delivery-review-$safe.md"
    report_path="${EDC_DELIVERY_REVIEW_OUTPUT:-$public_report_path}"
    prompt=$(build_delivery_prompt "$display_target" "$base" "$target_sha" "$base_sha" "$report_path" "$reviewable_files") || exit 1
  fi
  rm -f "$report_path"

  echo "→ running delivery review via $EDC_AGENT_CLI..."
  local spawn_rc before_snapshot after_snapshot changed_forbidden
  before_snapshot=$(mktemp)
  after_snapshot=$(mktemp)
  edc_snapshot_review_forbidden_paths "$before_snapshot" "$report_path"
  if edc_spawn "edc-delivery-review" "${EDC_REVIEW_TIMEOUT:-1800}" "$prompt"; then
    spawn_rc=0
  else
    spawn_rc=$?
  fi
  edc_snapshot_review_forbidden_paths "$after_snapshot" "$report_path"
  changed_forbidden=$(edc_diff_review_forbidden_paths "$before_snapshot" "$after_snapshot" || true)
  rm -f "$before_snapshot" "$after_snapshot"
  if [ -n "$changed_forbidden" ]; then
    echo "ERROR: delivery-review agent touched forbidden paths:" >&2
    echo "$changed_forbidden" | sed 's/^/  /' >&2
    edc_result_failure 1 "delivery-write-containment" "delivery-review agent touched forbidden paths" "inspect the log for forbidden paths; rerun in a disposable checkout if reviewing untrusted input" "" "$public_report_path"
    exit 1
  fi

  assert_delivery_report_valid "$report_path" || { edc_result_failure 1 "delivery-report-validation" "delivery review report validation failed" "inspect the delivery review output in the log; the report is missing or incomplete" "" "$public_report_path"; exit 1; }
  if [ "$spawn_rc" -ne 0 ]; then
    echo "EDC delivery review succeeded with warning: delivery-review subprocess reported failure, but report validation passed." >&2
    echo "HINT: treating the validated report as success; inspect the agent log for transport/provider diagnostics." >&2
    edc_result_success_with_warning "delivery review validated report after subprocess failure" "inspect the agent log for transport/provider diagnostics" "$public_report_path"
  else
    edc_result_success "$public_report_path"
  fi
  echo "Delivery review report: $public_report_path"
  exit 0
}

delivery_main "$@"
