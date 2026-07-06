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

# shellcheck source=edc-assert-fresh.sh
. "$SCRIPT_DIR/edc-assert-fresh.sh"
# shellcheck source=edc-recover-context.sh
. "$SCRIPT_DIR/edc-recover-context.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  EDC_AGENT_CLI=<claude|cursor|codex|pi> edc-delivery-review.sh [target] --base <ref> [--ignore <glob>]... [--context-mode advisory|inject]
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
  local target="$1" base="$2" report_path="$3"
  cat <<EOF
DELIVERY REVIEW TASK
DELIVERY_MODE: diff
DELIVERY_TARGET: $target
DELIVERY_BASE: $base
DELIVERY_REPORT_PATH: $report_path

Run the EDC delivery/architecture review for the diff from $base to $target.

Required shell context:
- Repository root: current working directory
- Diff summary: git diff $base...$target --stat
- Changed files: git diff $base...$target --name-only
- Commit log: git log $base..$target --oneline

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
  local target="" base="" context_mode="" full_mode=0
  local -a ignore_args=()

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
      --ignore)
        [ "$#" -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; usage; }
        ignore_args+=("$1" "$2")
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

  if [ "$full_mode" -eq 1 ] && { [ -n "$target" ] || [ -n "$base" ]; }; then
    echo "ERROR: --full cannot be combined with target or --base" >&2
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

  edc_require_agent_cli

  if [ "$full_mode" -eq 0 ]; then
    git rev-parse --verify "$target^{commit}" >/dev/null 2>&1 \
      || { echo "ERROR: target is not a commit-ish ref: $target" >&2; exit 2; }
    git rev-parse --verify "$base^{commit}" >/dev/null 2>&1 \
      || { echo "ERROR: base is not a commit-ish ref: $base" >&2; exit 2; }
  fi

  recover_context_if_needed ${ignore_args[@]+"${ignore_args[@]}"} \
    || exit 1

  local safe report_path prompt branch head_sha
  if [ "$full_mode" -eq 1 ]; then
    branch=$(git branch --show-current 2>/dev/null || true)
    [ -n "$branch" ] || branch="HEAD"
    head_sha=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
      || { echo "ERROR: HEAD is not a commit" >&2; exit 2; }
    report_path="delivery-review-current.md"
    prompt=$(build_full_delivery_prompt "$branch" "$head_sha" "$report_path") || exit 1
  else
    safe=$(safe_report_name "$target")
    [ -n "$safe" ] || safe="target"
    report_path="delivery-review-$safe.md"
    prompt=$(build_delivery_prompt "$target" "$base" "$report_path") || exit 1
  fi
  rm -f "$report_path"

  echo "→ running delivery review via $EDC_AGENT_CLI..."
  local spawn_rc
  if edc_spawn "edc-delivery-review" "${EDC_REVIEW_TIMEOUT:-1800}" "$prompt"; then
    spawn_rc=0
  else
    spawn_rc=$?
  fi

  assert_delivery_report_valid "$report_path" || { edc_result_failure 1 "delivery-report-validation" "delivery review report validation failed" "inspect the delivery review output in the log; the report is missing or incomplete" "" "$report_path"; exit 1; }
  if [ "$spawn_rc" -ne 0 ]; then
    echo "EDC delivery review succeeded with warning: delivery-review subprocess reported failure, but report validation passed." >&2
    echo "HINT: treating the validated report as success; inspect the agent log for transport/provider diagnostics." >&2
    edc_result_success_with_warning "delivery review validated report after subprocess failure" "inspect the agent log for transport/provider diagnostics" "$report_path"
  else
    edc_result_success "$report_path"
  fi
  echo "Delivery review report: $report_path"
  exit 0
}

delivery_main "$@"
