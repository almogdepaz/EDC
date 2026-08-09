#!/usr/bin/env bash
# edc-review-all orchestrator: run security, delivery, and quality concurrently.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
SCRIPT_DIR="$EDC_SCRIPTS_DIR"

find_phase_script() {
  local name="$1" candidate
  for candidate in \
    "$SCRIPT_DIR/$name" \
    ".edc/scripts/$name" \
    "$HOME/.edc/scripts/$name"
  do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

usage() {
  cat <<'EOF'
Usage: edc-review-all.sh [target] [--base <ref>] [--include-working-tree|--committed-only] [--ignore <glob>]... [--context-mode advisory|inject]
       edc-review-all.sh --full [--ignore <glob>]... [--context-mode advisory|inject]

Runs security, delivery/architecture, and quality review concurrently.

Dirty differential reviews require one explicit policy:
  --include-working-tree  review staged, unstaged, deleted, and non-ignored untracked files
  --committed-only        review only the committed target and exclude all working-tree changes
EOF
}

FULL_SCOPE=0
REVIEW_TARGET=""
REVIEW_BASE=""
REVIEW_POLICY=""
COMMON_ARGS=()

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --full)
        FULL_SCOPE=1
        shift
        ;;
      --include-working-tree)
        [ -z "$REVIEW_POLICY" ] || { echo "ERROR: choose only one of --include-working-tree or --committed-only" >&2; return 2; }
        REVIEW_POLICY=include-working-tree
        shift
        ;;
      --committed-only)
        [ -z "$REVIEW_POLICY" ] || { echo "ERROR: choose only one of --include-working-tree or --committed-only" >&2; return 2; }
        REVIEW_POLICY=committed-only
        shift
        ;;
      --base)
        [ "$#" -ge 2 ] || { echo "ERROR: --base requires a value" >&2; return 2; }
        REVIEW_BASE="$2"
        shift 2
        ;;
      --ignore|--context-mode)
        [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; return 2; }
        COMMON_ARGS+=("$1" "$2")
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --*)
        echo "ERROR: unknown review-all option: $1" >&2
        usage >&2
        return 2
        ;;
      *)
        [ -z "$REVIEW_TARGET" ] || { echo "ERROR: review-all accepts only one target" >&2; return 2; }
        REVIEW_TARGET="$1"
        shift
        ;;
    esac
  done

  if [ "$FULL_SCOPE" -eq 1 ]; then
    [ -z "$REVIEW_TARGET" ] && [ -z "$REVIEW_BASE" ] && [ -z "$REVIEW_POLICY" ] || {
      echo "ERROR: --full cannot be combined with a differential target, --base, or dirty-state policy" >&2
      return 2
    }
  fi
}

PHASE_RESULT_SPECS=()
PHASE_PIDS=()
PHASE_NAMES=()
PHASE_RESULTS=()
PHASE_RCS=()

write_review_all_result() {
  local result_file finished_head
  result_file=$(edc_result_file)
  finished_head=$(git rev-parse HEAD 2>/dev/null || true)
  local aggregate_rc=0
  node "$EDC_JSON_CLI" review-all-aggregate "$result_file" "$EDC_RESULT_STARTED_HEAD" "$finished_head" ${PHASE_RESULT_SPECS[@]+"${PHASE_RESULT_SPECS[@]}"} || aggregate_rc=$?
  EDC_RESULT_WRITTEN=1
  return "$aggregate_rc"
}

start_phase() {
  local phase_name="$1" script="$2" result_file="$3"
  shift 3
  echo "→ review-all: starting $phase_name"
  EDC_RESULT_FILE="$result_file" EDC_REVIEW_CONTEXT_PREPARED=1 bash "$script" "$@" &
  PHASE_NAMES+=("$phase_name")
  PHASE_RESULTS+=("$result_file")
  PHASE_PIDS+=("$!")
}

wait_for_phases() {
  local index phase_rc
  for ((index = 0; index < ${#PHASE_PIDS[@]}; index++)); do
    phase_rc=0
    wait "${PHASE_PIDS[$index]}" || phase_rc=$?
    PHASE_RCS+=("$phase_rc")
    PHASE_RESULT_SPECS+=("${PHASE_NAMES[$index]}" "${PHASE_RESULTS[$index]}" "$phase_rc")
  done
}

promote_phase_output() {
  local phase="$1" result_file="$2" child_rc="$3" source="$4" destination="$5" kind="$6"
  local status
  status=$(node "$EDC_JSON_CLI" review-phase-status "$phase" "$result_file" "$child_rc") || status=failed
  [ "$status" != failed ] || return 0
  if ! node "$EDC_JSON_CLI" validate-staged-output "$source" "$EDC_REVIEW_PARALLEL_STAGED_DIR"; then
    node "$EDC_JSON_CLI" result-write "$result_file" "$kind" 1 promotion-containment-failed \
      "$phase staged output escaped private run containment" "inspect the phase run; staged outputs must be single-link regular files under Git state" "" "$destination" "$EDC_RESULT_STARTED_HEAD" "$(git rev-parse HEAD 2>/dev/null || true)" >/dev/null 2>&1 || true
    return 1
  fi
  if edc_promote_file "$source" "$destination"; then
    return 0
  fi
  node "$EDC_JSON_CLI" result-write "$result_file" "$kind" 1 promotion-failed \
    "$phase output promotion failed" "inspect filesystem permissions and staged output under Git state" "" "$destination" "$EDC_RESULT_STARTED_HEAD" "$(git rev-parse HEAD 2>/dev/null || true)" >/dev/null 2>&1 || true
  return 1
}

validate_quality_output_pair() {
  local result_file="$1" child_rc="$2" status source
  shift 2
  status=$(node "$EDC_JSON_CLI" review-phase-status quality "$result_file" "$child_rc") || status=failed
  [ "$status" != failed ] || return 2
  for source in "$@"; do
    if ! node "$EDC_JSON_CLI" validate-staged-output "$source" "$EDC_REVIEW_PARALLEL_STAGED_DIR"; then
      node "$EDC_JSON_CLI" result-write "$result_file" audit 1 promotion-containment-failed \
        "quality staged output escaped private run containment" "inspect the quality run; both staged reports must be single-link regular files under Git state" "" "" "$EDC_RESULT_STARTED_HEAD" "$(git rev-parse HEAD 2>/dev/null || true)" >/dev/null 2>&1 || true
      return 1
    fi
  done
}

safe_review_name() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

prepare_context_once() {
  # shellcheck source=edc-assert-fresh.sh
  . "$SCRIPT_DIR/edc-assert-fresh.sh"
  # shellcheck source=edc-recover-context.sh
  . "$SCRIPT_DIR/edc-recover-context.sh"
  recover_context_if_needed -- \
    || { edc_result_failure 1 context-recovery-failed "context recovery failed before parallel review" "inspect the recovery output above, then rerun edc update --agent $EDC_AGENT_CLI or edc build --agent $EDC_AGENT_CLI --force"; return 1; }
}

main() {
  edc_result_begin review-all
  trap edc_result_on_exit EXIT
  edc_runtime_preflight_or_exit
  parse_args "$@"

  local candidate_target="" security_script delivery_script audit_script
  local security_public delivery_public parallel_run_dir parallel_run_id
  local security_result delivery_result quality_result
  local -a review_args audit_args

  if [ "$FULL_SCOPE" -eq 1 ]; then
    # shellcheck source=edc-review-candidate.sh
    . "$SCRIPT_DIR/edc-review-candidate.sh"
    edc_candidate_export_full_scope
    review_args=(--full ${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"})
    audit_args=(${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"})
  else
    # shellcheck source=edc-review-candidate.sh
    . "$SCRIPT_DIR/edc-review-candidate.sh"
    local candidate_file
    candidate_file=$(mktemp "${TMPDIR:-/tmp}/edc-review-all-candidate-$$.XXXXXX") || exit 1
    edc_candidate_resolve "${REVIEW_TARGET:-HEAD}" "$REVIEW_BASE" "$REVIEW_POLICY" > "$candidate_file" || { local rc=$?; rm -f "$candidate_file"; exit "$rc"; }
    candidate_target=$(cat "$candidate_file")
    rm -f "$candidate_file"
    review_args=("$candidate_target" --committed-only)
    audit_args=("$candidate_target" --committed-only)
    if [ -n "$REVIEW_BASE" ]; then
      review_args+=(--base "$REVIEW_BASE")
      audit_args+=(--base "$REVIEW_BASE")
    fi
    review_args+=(${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"})
    audit_args+=(${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"})
  fi

  # Candidate resolution happens before recovery so generated context cannot
  # silently enter the candidate. Recovery completes once before any lens starts.
  prepare_context_once || exit 1

  security_script=$(find_phase_script edc-review.sh) || { echo "ERROR: edc-review.sh not found" >&2; exit 2; }
  delivery_script=$(find_phase_script edc-delivery-review.sh) || { echo "ERROR: edc-delivery-review.sh not found" >&2; exit 2; }
  audit_script=$(find_phase_script edc-audit.sh) || { echo "ERROR: edc-audit.sh not found" >&2; exit 2; }

  edc_create_worker_run review-all parallel_run_dir parallel_run_id || exit $?
  mkdir -p "$parallel_run_dir/staged" "$parallel_run_dir/results" "$EDC_BUILD_DIR"
  security_result="$parallel_run_dir/results/security.json"
  delivery_result="$parallel_run_dir/results/delivery.json"
  quality_result="$parallel_run_dir/results/quality.json"
  if [ "$FULL_SCOPE" -eq 1 ]; then
    security_public=review-HEAD.md
    delivery_public=delivery-review-current.md
  else
    security_public="review-$(safe_review_name "${REVIEW_TARGET:-HEAD}").md"
    delivery_public="delivery-review-$(safe_review_name "${REVIEW_TARGET:-HEAD}").md"
  fi
  export EDC_REVIEW_DISPLAY_TARGET="${REVIEW_TARGET:-HEAD}"
  export EDC_REVIEW_PARALLEL_STAGED_DIR="$parallel_run_dir/staged"
  export EDC_REVIEW_PROMOTION_OUTPUT="$parallel_run_dir/staged/security.md"
  export EDC_DELIVERY_REVIEW_OUTPUT="$parallel_run_dir/staged/delivery.md"
  export EDC_AUDIT_COMPLEXITY_OUTPUT="$parallel_run_dir/staged/complexity.md"
  export EDC_AUDIT_ISSUES_OUTPUT="$parallel_run_dir/staged/issues.md"

  start_phase security "$security_script" "$security_result" ${review_args[@]+"${review_args[@]}"}
  start_phase delivery "$delivery_script" "$delivery_result" ${review_args[@]+"${review_args[@]}"}
  start_phase quality "$audit_script" "$quality_result" ${audit_args[@]+"${audit_args[@]}"}
  wait_for_phases

  local promotion_rc=0
  promote_phase_output security "$security_result" "${PHASE_RCS[0]}" "$EDC_REVIEW_PROMOTION_OUTPUT" "$security_public" review || promotion_rc=1
  promote_phase_output delivery "$delivery_result" "${PHASE_RCS[1]}" "$EDC_DELIVERY_REVIEW_OUTPUT" "$delivery_public" delivery-review || promotion_rc=1
  local quality_validation_rc=0
  validate_quality_output_pair "$quality_result" "${PHASE_RCS[2]}" "$EDC_AUDIT_COMPLEXITY_OUTPUT" "$EDC_AUDIT_ISSUES_OUTPUT" || quality_validation_rc=$?
  if [ "$quality_validation_rc" -eq 0 ]; then
    promote_phase_output quality "$quality_result" "${PHASE_RCS[2]}" "$EDC_AUDIT_COMPLEXITY_OUTPUT" "$EDC_COMPLEXITY" audit || promotion_rc=1
    promote_phase_output quality "$quality_result" "${PHASE_RCS[2]}" "$EDC_AUDIT_ISSUES_OUTPUT" "$EDC_ISSUES" audit || promotion_rc=1
  elif [ "$quality_validation_rc" -eq 1 ]; then
    promotion_rc=1
  fi
  write_review_all_result || exit 1
  [ "$promotion_rc" -eq 0 ] || exit 1
}

main "$@"
