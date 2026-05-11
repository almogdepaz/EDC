#!/usr/bin/env bash
# Shared test helpers for hardening scripts.
#
# Usage:
#   . "$(dirname "$0")/lib/check.sh"
#   check_init               # in-process counters (PASS/FAIL bash vars)
#   check_init --file        # tmp-file counters (use when assertions run in
#                            # subshells; t15-style)
#   check "desc" "$cond"     # cond == "1" -> PASS, else FAIL
#   check_summary "T16"      # prints summary and sets exit code
#   check_passed             # echoes current PASS count
#   check_failed             # echoes current FAIL count
#
# The 2-arg `check` form covers 3 of 4 existing tests (t14/t15/t16). t9 uses
# a wider 5-arg signature and keeps its own helper.

__edc_check_backing="vars"
__edc_check_pass_file=""
__edc_check_fail_file=""
PASS=0
FAIL=0

check_init() {
  if [ "${1:-}" = "--file" ]; then
    __edc_check_backing="file"
    __edc_check_pass_file=$(mktemp)
    __edc_check_fail_file=$(mktemp)
    echo 0 > "$__edc_check_pass_file"
    echo 0 > "$__edc_check_fail_file"
    # Caller adds these to its trap; we do not install our own to avoid
    # clobbering a caller-managed EXIT trap.
  else
    __edc_check_backing="vars"
    PASS=0
    FAIL=0
  fi
}

check_cleanup() {
  if [ "$__edc_check_backing" = "file" ]; then
    rm -f "$__edc_check_pass_file" "$__edc_check_fail_file"
  fi
}

check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    if [ "$__edc_check_backing" = "file" ]; then
      echo $(( $(cat "$__edc_check_pass_file") + 1 )) > "$__edc_check_pass_file"
    else
      PASS=$((PASS + 1))
    fi
    echo "PASS: $desc"
  else
    if [ "$__edc_check_backing" = "file" ]; then
      echo $(( $(cat "$__edc_check_fail_file") + 1 )) > "$__edc_check_fail_file"
    else
      FAIL=$((FAIL + 1))
    fi
    echo "FAIL: $desc"
  fi
}

check_passed() {
  if [ "$__edc_check_backing" = "file" ]; then
    cat "$__edc_check_pass_file"
  else
    echo "$PASS"
  fi
}

check_failed() {
  if [ "$__edc_check_backing" = "file" ]; then
    cat "$__edc_check_fail_file"
  else
    echo "$FAIL"
  fi
}

# Print summary and exit non-zero if any test failed. Caller passes the
# test-suite label (e.g. "T16").
check_summary() {
  local label="$1"
  local p f
  p=$(check_passed)
  f=$(check_failed)
  echo
  echo "=== $label result: $p passed, $f failed ==="
  [ "$f" -eq 0 ]
}
