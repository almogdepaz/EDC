#!/usr/bin/env bash
# Task 4 smoke test: timeouts + pipe guards
# Run from repo root: bash tests/hardening/t4-timeouts-pipe-guards.sh
set -euo pipefail

SCRIPT="plugins/edc/scripts/edc-review.sh"
ROOT="$(pwd)"
TMPDIR_T4=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T4"' EXIT
# Per-phase run_with_timeout wraps now live in edc-lib.sh (SPAWN section); the build/update
# spawn calls (with their EDC_*_TIMEOUT defaults) live in the recover helper.
SPAWN="plugins/edc/scripts/edc-lib.sh"
RECOVER="plugins/edc/scripts/edc-recover-context.sh"

echo "=== T4: Timeouts + pipe guards ==="

# ── 4a: TIMEOUT_BIN detection logic present ───────────────────────────────────
# TIMEOUT_BIN + run_with_timeout live in edc-lib.sh now; orchestrators only call them.
if grep -q 'TIMEOUT_BIN' "$SPAWN" && grep -q 'run_with_timeout' "$SPAWN" \
  && ! grep -q 'case "${1:-}"' "$SPAWN" \
  && grep -q 'EDC_TIMEOUT_WARNED' "$SPAWN"; then
  echo "PASS: TIMEOUT_BIN detection and run_with_timeout present"
else
  echo "FAIL: timeout infrastructure missing from $SPAWN"
  exit 1
fi

# ── 4b: agent spawns wrapped with run_with_timeout ──────────────────────────────
# All stream-json backends route through one shared helper that wraps the actual
# agent command with run_with_timeout.
wrapped=$(grep -cE '^\s+run_with_timeout' "$SPAWN")
if [ "$wrapped" -eq 1 ] && grep -q '^edc_run_filtered_stream()' "$SPAWN"; then
  echo "PASS: agent spawns wrapped with shared run_with_timeout helper"
else
  echo "FAIL: expected one shared run_with_timeout helper in $SPAWN, found $wrapped wrappers"
  exit 1
fi

# ── 4b2: stream capture/filter pipeline is shared, not per-backend duplicated ─
if grep -q '^edc_run_filtered_stream()' "$SPAWN" \
  && [ "$(grep -c 'tee "\$capture"' "$SPAWN")" -eq 1 ]; then
  echo "PASS: stream capture/filter pipeline is shared"
else
  echo "FAIL: stream capture/filter pipeline is duplicated across backends"
  exit 1
fi

# ── 4c: per-phase timeouts configurable via env vars with defaults ────────────
# Callers pass EDC_*_TIMEOUT defaults to edc_spawn. EDC_BUILD/UPDATE_TIMEOUT
# live in the recover helper (used by every orchestrator); EDC_REVIEW_TIMEOUT
# stays in the review orchestrator (review-specific phase).
missing=""
for var in EDC_BUILD_TIMEOUT EDC_UPDATE_TIMEOUT; do
  if ! grep -qE "\\\$\\{$var:-[0-9]+\\}" "$RECOVER"; then
    missing="$missing $var"
  fi
done
if ! grep -qE "\\\$\\{EDC_REVIEW_TIMEOUT:-[0-9]+\\}" "$SCRIPT"; then
  missing="$missing EDC_REVIEW_TIMEOUT"
fi
if [ -z "$missing" ]; then
  echo "PASS: EDC_{BUILD,UPDATE,REVIEW}_TIMEOUT env overrides with defaults present"
else
  echo "FAIL: missing env-override timeouts:$missing"
  exit 1
fi

# ── 4d: run_with_timeout actually works (non-timeout path) ───────────────────
# Set TIMEOUT_BIN explicitly (mirrors what the script detects) then source function
if command -v timeout > /dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  TIMEOUT_BIN=""
fi
# run_with_timeout lives in edc-lib.sh (shared by all orchestrators).
RUNTIME="plugins/edc/scripts/edc-lib.sh"
eval "$(awk '/^run_with_timeout\(\)/{found=1} found{print} /^\}$/{if(found){exit}}' "$RUNTIME")"

# ── 4d1: fallback restores distinct caller TERM/INT traps exactly ─────────────
trap_test_timeout_bin="$TIMEOUT_BIN"
TIMEOUT_BIN=""
EDC_TIMEOUT_WARNED=1
trap 'printf "%s\n" "t4 custom term" > /dev/null' TERM
trap 'printf "%s\n" "t4 custom int" > /dev/null' INT
expected_term_trap=$(trap -p TERM)
expected_int_trap=$(trap -p INT)
trap_rc0=0
run_with_timeout 30 "trap-restore-rc0" true || trap_rc0=$?
actual_rc0_term_trap=$(trap -p TERM)
actual_rc0_int_trap=$(trap -p INT)
trap 'printf "%s\n" "t4 custom term" > /dev/null' TERM
trap 'printf "%s\n" "t4 custom int" > /dev/null' INT
trap_rc23=0
run_with_timeout 30 "trap-restore-rc23" sh -c 'exit 23' || trap_rc23=$?
actual_rc23_term_trap=$(trap -p TERM)
actual_rc23_int_trap=$(trap -p INT)
trap - TERM INT
TIMEOUT_BIN="$trap_test_timeout_bin"
if [ "$trap_rc0" -eq 0 ] && [ "$trap_rc23" -eq 23 ] \
  && [ "$actual_rc0_term_trap" = "$expected_term_trap" ] && [ "$actual_rc0_int_trap" = "$expected_int_trap" ] \
  && [ "$actual_rc23_term_trap" = "$expected_term_trap" ] && [ "$actual_rc23_int_trap" = "$expected_int_trap" ]; then
  echo "PASS: fallback restores distinct caller TERM/INT traps"
else
  echo "FAIL: fallback changed caller traps (rc0=$trap_rc0 rc23=$trap_rc23 rc0_term='$actual_rc0_term_trap' rc0_int='$actual_rc0_int_trap' rc23_term='$actual_rc23_term_trap' rc23_int='$actual_rc23_int_trap')"
  exit 1
fi

result=$(run_with_timeout 5 "test-phase" echo "hello from timeout")
if [ "$result" = "hello from timeout" ]; then
  echo "PASS: run_with_timeout runs fast commands correctly"
else
  echo "FAIL: run_with_timeout failed fast command, got: '$result'"
  exit 1
fi

# ── 4d2: fallback reaps its watchdog shell and timer on fast completion ───────
REAL_SLEEP=$(command -v sleep)
REAL_MV=$(command -v mv)
mkdir -p "$TMPDIR_T4/watchdog-bin"
cat > "$TMPDIR_T4/watchdog-bin/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "30" ]; then
  printf '%s %s\n' "$PPID" "$$" > "$EDC_T4_WATCHDOG_PIDS"
  if [ "${EDC_T4_BREAK_WATCHDOG_SLEEP:-0}" = "1" ]; then
    exit 86
  fi
fi
exec "$EDC_T4_REAL_SLEEP" "$@"
EOF
cat > "$TMPDIR_T4/watchdog-bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "${EDC_T4_BREAK_WATCHDOG_PUBLICATION:-0}" = "1" ]; then
  case "${2:-}" in
    *.watchdog-pid)
      printf '%s\n' "$EDC_T4_SENTINEL_PID" > "$2"
      exit 87
      ;;
  esac
fi
exec "$EDC_T4_REAL_MV" "$@"
EOF
cat > "$TMPDIR_T4/watchdog-bin/fast-command" <<'EOF'
#!/usr/bin/env bash
while [ ! -s "$EDC_T4_WATCHDOG_PIDS" ]; do
  "$EDC_T4_REAL_SLEEP" 0.01
done
printf '%s\n' "fallback-fast"
exit 23
EOF
cat > "$TMPDIR_T4/watchdog-bin/long-command" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$EDC_T4_COMMAND_PID"
exec "$EDC_T4_REAL_SLEEP" 30
EOF
chmod +x "$TMPDIR_T4/watchdog-bin/sleep" "$TMPDIR_T4/watchdog-bin/mv" "$TMPDIR_T4/watchdog-bin/fast-command" "$TMPDIR_T4/watchdog-bin/long-command"
watchdog_pids="$TMPDIR_T4/watchdog-pids"
(
  export PATH="$TMPDIR_T4/watchdog-bin:$PATH"
  export EDC_T4_REAL_SLEEP="$REAL_SLEEP"
  export EDC_T4_REAL_MV="$REAL_MV"
  export EDC_T4_WATCHDOG_PIDS="$watchdog_pids"
  TIMEOUT_BIN=""
  EDC_TIMEOUT_WARNED=1
  fallback_rc=0
  fallback_output=$(run_with_timeout 30 "fallback-fast-test" fast-command 2>&1) || fallback_rc=$?
  [ "$fallback_output" = "fallback-fast" ] && [ "$fallback_rc" -eq 23 ]
) &
fallback_probe_pid=$!
fallback_probe_running=1
fallback_poll=0
while [ "$fallback_poll" -lt 40 ]; do
  if ! kill -0 "$fallback_probe_pid" 2>/dev/null; then
    fallback_probe_running=0
    break
  fi
  sleep 0.05
  fallback_poll=$((fallback_poll + 1))
done
fallback_probe_rc=0
if [ "$fallback_probe_running" -eq 0 ]; then
  wait "$fallback_probe_pid" || fallback_probe_rc=$?
fi
watchdog_shell_pid=""
watchdog_sleep_pid=""
if [ -s "$watchdog_pids" ]; then
  read -r watchdog_shell_pid watchdog_sleep_pid < "$watchdog_pids"
fi
watchdog_shell_alive=0
watchdog_sleep_alive=0
if [ -n "$watchdog_shell_pid" ] && kill -0 "$watchdog_shell_pid" 2>/dev/null; then
  watchdog_shell_alive=1
fi
if [ -n "$watchdog_sleep_pid" ] && kill -0 "$watchdog_sleep_pid" 2>/dev/null; then
  watchdog_sleep_alive=1
fi
if [ "$fallback_probe_running" -ne 0 ] || [ "$fallback_probe_rc" -ne 0 ] \
  || [ -z "$watchdog_shell_pid" ] || [ -z "$watchdog_sleep_pid" ] \
  || [ "$watchdog_shell_alive" -ne 0 ] || [ "$watchdog_sleep_alive" -ne 0 ]; then
  for cleanup_pid in "$watchdog_sleep_pid" "$watchdog_shell_pid" "$fallback_probe_pid"; do
    [ -z "$cleanup_pid" ] || kill "$cleanup_pid" 2>/dev/null || true
  done
  wait "$fallback_probe_pid" 2>/dev/null || true
  echo "FAIL: fallback fast command leaked or blocked (probe_running=$fallback_probe_running probe_rc=$fallback_probe_rc watchdog_shell_alive=$watchdog_shell_alive watchdog_sleep_alive=$watchdog_sleep_alive)"
  exit 1
fi
echo "PASS: fallback fast command promptly reaps watchdog shell and timer"

# ── 4d3: fallback fails closed when its timer process fails ───────────────────
broken_watchdog_dir="$TMPDIR_T4/broken-watchdog"
broken_watchdog_pids="$broken_watchdog_dir/watchdog-pids"
broken_command_pid_file="$broken_watchdog_dir/command-pid"
broken_result_file="$broken_watchdog_dir/result"
broken_error_file="$broken_watchdog_dir/error"
broken_trap_result_file="$broken_watchdog_dir/traps-restored"
mkdir -p "$broken_watchdog_dir"
(
  export PATH="$TMPDIR_T4/watchdog-bin:$PATH"
  export TMPDIR="$broken_watchdog_dir"
  export EDC_T4_REAL_SLEEP="$REAL_SLEEP"
  export EDC_T4_REAL_MV="$REAL_MV"
  export EDC_T4_WATCHDOG_PIDS="$broken_watchdog_pids"
  export EDC_T4_COMMAND_PID="$broken_command_pid_file"
  export EDC_T4_BREAK_WATCHDOG_SLEEP=1
  TIMEOUT_BIN=""
  EDC_TIMEOUT_WARNED=1
  trap 'printf "%s\n" "broken custom term" > /dev/null' TERM
  trap 'printf "%s\n" "broken custom int" > /dev/null' INT
  broken_expected_term_trap=$(trap -p TERM)
  broken_expected_int_trap=$(trap -p INT)
  broken_rc=0
  run_with_timeout 30 "broken-watchdog-test" long-command > /dev/null 2> "$broken_error_file" || broken_rc=$?
  if [ "$(trap -p TERM)" = "$broken_expected_term_trap" ] && [ "$(trap -p INT)" = "$broken_expected_int_trap" ]; then
    : > "$broken_trap_result_file"
  fi
  trap - TERM INT
  printf '%s\n' "$broken_rc" > "$broken_result_file"
) &
broken_probe_pid=$!
broken_probe_running=1
broken_poll=0
while [ "$broken_poll" -lt 40 ]; do
  if ! kill -0 "$broken_probe_pid" 2>/dev/null; then
    broken_probe_running=0
    break
  fi
  sleep 0.05
  broken_poll=$((broken_poll + 1))
done
broken_probe_rc=0
if [ "$broken_probe_running" -eq 0 ]; then
  wait "$broken_probe_pid" || broken_probe_rc=$?
fi
broken_watchdog_shell_pid=""
broken_watchdog_sleep_pid=""
broken_command_pid=""
[ ! -s "$broken_watchdog_pids" ] || read -r broken_watchdog_shell_pid broken_watchdog_sleep_pid < "$broken_watchdog_pids"
[ ! -s "$broken_command_pid_file" ] || read -r broken_command_pid < "$broken_command_pid_file"
broken_child_alive=0
for broken_pid in "$broken_watchdog_shell_pid" "$broken_watchdog_sleep_pid" "$broken_command_pid"; do
  if [ -n "$broken_pid" ] && kill -0 "$broken_pid" 2>/dev/null; then
    broken_child_alive=1
  fi
done
broken_result=0
[ ! -s "$broken_result_file" ] || read -r broken_result < "$broken_result_file"
broken_artifact=$(find "$broken_watchdog_dir" -name 'edc-timeout-*' -print -quit)
if [ "$broken_probe_running" -ne 0 ] || [ "$broken_probe_rc" -ne 0 ] || [ "$broken_result" -eq 0 ] \
  || ! grep -q 'fallback watchdog timer failed (exit 86)' "$broken_error_file" \
  || [ ! -f "$broken_trap_result_file" ] || [ "$broken_child_alive" -ne 0 ] || [ -n "$broken_artifact" ]; then
  for cleanup_pid in "$broken_watchdog_sleep_pid" "$broken_watchdog_shell_pid" "$broken_command_pid" "$broken_probe_pid"; do
    [ -z "$cleanup_pid" ] || kill "$cleanup_pid" 2>/dev/null || true
  done
  wait "$broken_probe_pid" 2>/dev/null || true
  echo "FAIL: broken fallback timer did not fail closed (probe_running=$broken_probe_running probe_rc=$broken_probe_rc result=$broken_result child_alive=$broken_child_alive artifact=${broken_artifact:-none})"
  [ ! -f "$broken_error_file" ] || cat "$broken_error_file"
  exit 1
fi
echo "PASS: broken fallback timer fails closed and reaps all processes"

# ── 4d4: fallback timer PID publication is atomic and fail-closed ─────────────
publication_dir="$TMPDIR_T4/broken-publication"
publication_watchdog_pids="$publication_dir/watchdog-pids"
publication_command_pid_file="$publication_dir/command-pid"
publication_result_file="$publication_dir/result"
publication_error_file="$publication_dir/error"
mkdir -p "$publication_dir"
"$REAL_SLEEP" 30 &
publication_sentinel_pid=$!
(
  export PATH="$TMPDIR_T4/watchdog-bin:$PATH"
  export TMPDIR="$publication_dir"
  export EDC_T4_REAL_SLEEP="$REAL_SLEEP"
  export EDC_T4_REAL_MV="$REAL_MV"
  export EDC_T4_WATCHDOG_PIDS="$publication_watchdog_pids"
  export EDC_T4_COMMAND_PID="$publication_command_pid_file"
  export EDC_T4_BREAK_WATCHDOG_PUBLICATION=1
  export EDC_T4_SENTINEL_PID="$publication_sentinel_pid"
  TIMEOUT_BIN=""
  EDC_TIMEOUT_WARNED=1
  publication_rc=0
  run_with_timeout 30 "watchdog-publication-test" long-command > /dev/null 2> "$publication_error_file" || publication_rc=$?
  printf '%s\n' "$publication_rc" > "$publication_result_file"
) &
publication_probe_pid=$!
publication_probe_running=1
publication_poll=0
while [ "$publication_poll" -lt 40 ]; do
  if ! kill -0 "$publication_probe_pid" 2>/dev/null; then
    publication_probe_running=0
    break
  fi
  sleep 0.05
  publication_poll=$((publication_poll + 1))
done
publication_probe_rc=0
if [ "$publication_probe_running" -eq 0 ]; then
  wait "$publication_probe_pid" || publication_probe_rc=$?
fi
publication_watchdog_shell_pid=""
publication_watchdog_sleep_pid=""
publication_command_pid=""
[ ! -s "$publication_watchdog_pids" ] || read -r publication_watchdog_shell_pid publication_watchdog_sleep_pid < "$publication_watchdog_pids"
[ ! -s "$publication_command_pid_file" ] || read -r publication_command_pid < "$publication_command_pid_file"
publication_child_alive=0
for publication_pid in "$publication_watchdog_shell_pid" "$publication_watchdog_sleep_pid" "$publication_command_pid"; do
  if [ -n "$publication_pid" ] && kill -0 "$publication_pid" 2>/dev/null; then
    publication_child_alive=1
  fi
done
publication_result=0
[ ! -s "$publication_result_file" ] || read -r publication_result < "$publication_result_file"
publication_artifact=$(find "$publication_dir" -name 'edc-timeout-*' -print -quit)
publication_sentinel_alive=0
if kill -0 "$publication_sentinel_pid" 2>/dev/null; then
  publication_sentinel_alive=1
fi
if [ "$publication_probe_running" -ne 0 ] || [ "$publication_probe_rc" -ne 0 ] || [ "$publication_result" -ne 1 ] \
  || ! grep -q 'fallback watchdog timer PID publication failed' "$publication_error_file" \
  || [ "$publication_child_alive" -ne 0 ] || [ -n "$publication_artifact" ] || [ "$publication_sentinel_alive" -ne 1 ]; then
  for cleanup_pid in "$publication_watchdog_sleep_pid" "$publication_watchdog_shell_pid" "$publication_command_pid" "$publication_probe_pid" "$publication_sentinel_pid"; do
    [ -z "$cleanup_pid" ] || kill "$cleanup_pid" 2>/dev/null || true
  done
  wait "$publication_probe_pid" 2>/dev/null || true
  wait "$publication_sentinel_pid" 2>/dev/null || true
  echo "FAIL: fallback timer PID publication was not fail-closed (probe_running=$publication_probe_running probe_rc=$publication_probe_rc result=$publication_result child_alive=$publication_child_alive sentinel_alive=$publication_sentinel_alive artifact=${publication_artifact:-none})"
  [ ! -f "$publication_error_file" ] || cat "$publication_error_file"
  exit 1
fi
kill "$publication_sentinel_pid"
wait "$publication_sentinel_pid" 2>/dev/null || true
echo "PASS: fallback timer PID publication fails closed without unsafe signaling"

# ── 4e: run_with_timeout fires on exceeded time ───────────────────────────────
timeout_rc=0
run_with_timeout 1 "slow-test" sleep 5 2>/tmp/t4-timeout-err.txt || timeout_rc=$?
if [ "$timeout_rc" -eq 124 ] && grep -q 'timed out' /tmp/t4-timeout-err.txt; then
  echo "PASS: run_with_timeout preserves distinct timeout status"
else
  echo "FAIL: run_with_timeout did not return timeout status 124 (exit: $timeout_rc)"
  cat /tmp/t4-timeout-err.txt
  exit 1
fi

native_timeout_bin="$TIMEOUT_BIN"
TIMEOUT_BIN=""
fallback_timeout_rc=0
run_with_timeout 1 "fallback-slow-test" sleep 5 2>/tmp/t4-fallback-timeout-err.txt || fallback_timeout_rc=$?
TIMEOUT_BIN="$native_timeout_bin"
if [ "$fallback_timeout_rc" -eq 124 ] && grep -q 'timed out' /tmp/t4-fallback-timeout-err.txt; then
  echo "PASS: fallback watchdog preserves distinct timeout status"
else
  echo "FAIL: fallback watchdog did not return timeout status 124 (exit: $fallback_timeout_rc)"
  cat /tmp/t4-fallback-timeout-err.txt
  exit 1
fi

# ── 4f: pipe guards — null-check on read_meta_last_commit ────────────────────
cd "$TMPDIR_T4"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
git init -q
git config user.email "test@test.com"
git config user.name "Test"
git config commit.gpgsign false
touch dummy.txt && git add dummy.txt && git commit -q -m "init"
node "$ROOT/plugins/edc/hooks/lib/runtime-manifest.mjs" install "$TMPDIR_T4" "$ROOT/plugins/edc" >/dev/null

mkdir -p edc-context
# Write malformed manifest.json (no sourceCommit field)
printf '{"schemaVersion":2,"modules":[]}' > edc-context/manifest.json

result=0
bash "$ROOT/$SCRIPT" --check-context 2>/tmp/t4-pipe-err.txt || result=$?
if [ "$result" -ne 0 ] && grep -qi 'sourcecommit\|sourceCommit\|context' /tmp/t4-pipe-err.txt; then
  echo "PASS: malformed manifest.json causes clear error (not silent empty-string comparison)"
else
  echo "FAIL: expected error on malformed manifest.json, got exit $result"
  cat /tmp/t4-pipe-err.txt
  exit 1
fi

echo ""
echo "All T4 checks passed."
