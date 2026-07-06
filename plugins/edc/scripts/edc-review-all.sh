#!/usr/bin/env bash
# edc-review-all orchestrator: run security, delivery, and quality review phases.
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
Usage: edc-review-all.sh [target] [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject]

Runs security review, delivery/architecture review, then quality audit.
EOF
}

collect_audit_args() {
  AUDIT_ARGS=()
  local target="" base=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ignore|--context-mode)
        [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; return 2; }
        AUDIT_ARGS+=("$1" "$2")
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --base)
        [ "$#" -ge 2 ] || { echo "ERROR: --base requires a value" >&2; return 2; }
        base="$2"
        shift 2
        ;;
      --*)
        shift
        ;;
      *)
        if [ -z "$target" ]; then target="$1"; fi
        shift
        ;;
    esac
  done
  if [ -n "$target" ] || [ -n "$base" ]; then
    AUDIT_ARGS=("${target:-HEAD}" "--base" "$base" ${AUDIT_ARGS[@]+"${AUDIT_ARGS[@]}"})
  fi
}

PHASE_RESULT_SPECS=()

write_review_all_result() {
  local result_file finished_head
  result_file=$(edc_result_file)
  finished_head=$(git rev-parse HEAD 2>/dev/null || true)
  local aggregate_rc=0
  node "$EDC_JSON_CLI" review-all-aggregate "$result_file" "$EDC_RESULT_STARTED_HEAD" "$finished_head" ${PHASE_RESULT_SPECS[@]+"${PHASE_RESULT_SPECS[@]}"} || aggregate_rc=$?
  EDC_RESULT_WRITTEN=1
  return "$aggregate_rc"
}

run_phase() {
  local phase_name="$1" script="$2" result_file="$3"
  shift 3
  echo "→ review-all: $phase_name"
  local phase_rc=0 phase_status
  EDC_RESULT_FILE="$result_file" bash "$script" "$@" || phase_rc=$?
  PHASE_RESULT_SPECS+=("$phase_name" "$result_file" "$phase_rc")
  phase_status=$(node "$EDC_JSON_CLI" review-phase-status "$phase_name" "$result_file" "$phase_rc") || phase_status="failed"
  if [ "$phase_status" = "failed" ]; then
    write_review_all_result || true
    exit 1
  fi
}

main() {
  edc_result_begin review-all
  trap edc_result_on_exit EXIT
  edc_result_scope_from_args "$@"

  local security_script delivery_script audit_script
  security_script=$(find_phase_script edc-review.sh) || { echo "ERROR: edc-review.sh not found" >&2; exit 2; }
  delivery_script=$(find_phase_script edc-delivery-review.sh) || { echo "ERROR: edc-delivery-review.sh not found" >&2; exit 2; }
  audit_script=$(find_phase_script edc-audit.sh) || { echo "ERROR: edc-audit.sh not found" >&2; exit 2; }

  local -a review_args audit_args
  review_args=("$@")
  collect_audit_args "$@"
  audit_args=(${AUDIT_ARGS[@]+"${AUDIT_ARGS[@]}"})

  mkdir -p "$EDC_BUILD_DIR"
  run_phase security "$security_script" "$EDC_BUILD_DIR/review-all-security.json" ${review_args[@]+"${review_args[@]}"}
  run_phase delivery "$delivery_script" "$EDC_BUILD_DIR/review-all-delivery.json" ${review_args[@]+"${review_args[@]}"}
  run_phase quality "$audit_script" "$EDC_BUILD_DIR/review-all-quality.json" ${audit_args[@]+"${audit_args[@]}"}

  write_review_all_result || exit 1
}

main "$@"
