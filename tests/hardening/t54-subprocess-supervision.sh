#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STREAM_FILTER="$ROOT/plugins/edc/hooks/lib/stream-filter.mjs"
PI_SUPERVISOR="$ROOT/plugins/edc/hooks/lib/pi-supervisor.mjs"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

cat >"$TMP/managed-child.mjs" <<'NODE'
import { writeFileSync } from "node:fs";

const mode = process.argv[2];
const started = process.env.CHILD_STARTED;
const marker = process.env.CHILD_MARKER;

if (mode === "resistant") {
  process.on("SIGTERM", () => {});
  if (started) writeFileSync(started, `${process.pid}\n`);
  if (process.env.EMIT_AGENT_END === "1") {
    process.stdout.write(`${JSON.stringify({
      type: "agent_end",
      messages: [{ role: "assistant", stopReason: "stop", content: [{ type: "text", text: "ok" }] }],
    })}\n`);
  }
  setTimeout(() => writeFileSync(marker, "survived\n"), 3000);
} else if (mode === "signal") {
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.on(signal, () => {
      writeFileSync(process.env.CHILD_SIGNAL, `${signal}\n`);
      process.removeAllListeners(signal);
      process.kill(process.pid, signal);
    });
  }
  if (started) writeFileSync(started, `${process.pid}\n`);
  setTimeout(() => writeFileSync(marker, "survived\n"), 1500);
} else if (mode === "late-output") {
  const outputBeforeSignal = process.env.CHILD_OUTPUT_BEFORE_SIGNAL === "1";
  process.on("SIGTERM", () => {
    writeFileSync(process.env.CHILD_SIGNAL, "SIGTERM\n");
    if (outputBeforeSignal) {
      process.removeAllListeners("SIGTERM");
      process.kill(process.pid, "SIGTERM");
      return;
    }
    setTimeout(() => {
      process.stdout.write("late child output\n");
      setTimeout(() => {
        process.removeAllListeners("SIGTERM");
        process.kill(process.pid, "SIGTERM");
      }, 25);
    }, 100);
  });
  if (started) writeFileSync(started, `${process.pid}\n`);
  process.stdout.write("ready\n");
  if (outputBeforeSignal) setTimeout(() => process.stdout.write("late child output\n"), 100);
  setTimeout(() => writeFileSync(marker, "survived\n"), 1500);
} else {
  process.exit(64);
}
NODE

node -e 'process.stdout.write("x".repeat(1024 * 1024))' >"$TMP/stdin-payload.txt"

for spec in TERM:143 INT:130 HUP:129; do
  signal=${spec%%:*}
  expected=${spec##*:}
  set +e
  EDC_STREAM_STDIN_FILE="$TMP/stdin-payload.txt" \
    node "$STREAM_FILTER" --run 30 self-signal -- bash -c "kill -$signal \$\$" >"$TMP/self-$signal.out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq "$expected" ]; then
    pass "stream-filter maps spontaneous SIG$signal child exit to $expected"
  else
    fail "stream-filter spontaneous SIG$signal returned $rc, expected $expected"
    cat "$TMP/self-$signal.out" >&2
  fi
done

start=$(now_ms)
set +e
CHILD_STARTED="$TMP/stream-timeout.pid" CHILD_MARKER="$TMP/stream-timeout.marker" \
  node "$STREAM_FILTER" --run 1 resistant-timeout -- node "$TMP/managed-child.mjs" resistant \
  >"$TMP/stream-timeout.out" 2>&1
stream_timeout_rc=$?
set -e
stream_timeout_elapsed=$(( $(now_ms) - start ))
if [ "$stream_timeout_rc" -eq 1 ] \
  && [ "$stream_timeout_elapsed" -ge 1700 ] \
  && [ "$stream_timeout_elapsed" -lt 3500 ] \
  && [ -s "$TMP/stream-timeout.pid" ]; then
  pass "stream-filter waits through grace, escalates, reaps, and preserves timeout failure (${stream_timeout_elapsed}ms)"
else
  fail "stream-filter timeout rc=$stream_timeout_rc elapsed=${stream_timeout_elapsed}ms pid=$([ -s "$TMP/stream-timeout.pid" ] && echo yes || echo no)"
  cat "$TMP/stream-timeout.out" >&2
fi

start=$(now_ms)
set +e
EMIT_AGENT_END=1 CHILD_STARTED="$TMP/pi-success.pid" CHILD_MARKER="$TMP/pi-success.marker" \
  node "$PI_SUPERVISOR" node "$TMP/managed-child.mjs" resistant \
  >"$TMP/pi-success.out" 2>&1
pi_success_rc=$?
set -e
pi_success_elapsed=$(( $(now_ms) - start ))
if [ "$pi_success_rc" -eq 0 ] \
  && [ "$pi_success_elapsed" -ge 800 ] \
  && [ "$pi_success_elapsed" -lt 2500 ] \
  && [ -s "$TMP/pi-success.pid" ]; then
  pass "pi-supervisor waits through grace, escalates, reaps, and preserves agent_end success (${pi_success_elapsed}ms)"
else
  fail "pi-supervisor success rc=$pi_success_rc elapsed=${pi_success_elapsed}ms pid=$([ -s "$TMP/pi-success.pid" ] && echo yes || echo no)"
  cat "$TMP/pi-success.out" >&2
fi

run_parent_signal_case() {
  local supervisor="$1" signal="$2" expected="$3" label="$4"
  local started="$TMP/$label-$signal.started"
  local received="$TMP/$label-$signal.received"
  local marker="$TMP/$label-$signal.marker"
  local output="$TMP/$label-$signal.out"
  if [ "$supervisor" = "stream" ]; then
    CHILD_STARTED="$started" CHILD_SIGNAL="$received" CHILD_MARKER="$marker" \
      node "$STREAM_FILTER" --run 30 parent-signal -- node "$TMP/managed-child.mjs" signal \
      >"$output" 2>&1 &
  else
    CHILD_STARTED="$started" CHILD_SIGNAL="$received" CHILD_MARKER="$marker" \
      node "$PI_SUPERVISOR" node "$TMP/managed-child.mjs" signal \
      >"$output" 2>&1 &
  fi
  local supervisor_pid=$!
  local attempts=0
  while [ ! -s "$started" ] && [ "$attempts" -lt 500 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -s "$started" ]; then
    kill -KILL "$supervisor_pid" 2>/dev/null || true
    wait "$supervisor_pid" 2>/dev/null || true
    fail "$label child did not start for SIG$signal"
    return
  fi
  kill -"$signal" "$supervisor_pid"
  set +e
  wait "$supervisor_pid"
  local rc=$?
  set -e
  local observed=""
  [ -f "$received" ] && observed=$(tr -d '\n' <"$received")
  if [ "$rc" -eq "$expected" ] && [ "$observed" = "SIG$signal" ]; then
    pass "$label forwards exact SIG$signal, waits, and exits $expected"
  else
    fail "$label SIG$signal rc=$rc expected=$expected child_received=${observed:-missing}"
    cat "$output" >&2
  fi
}

for spec in TERM:143 INT:130 HUP:129; do
  signal=${spec%%:*}
  expected=${spec##*:}
  run_parent_signal_case stream "$signal" "$expected" stream-filter
  run_parent_signal_case pi "$signal" "$expected" pi-supervisor
done

run_closed_stdout_case() {
  local label="$1" output_before_signal="$2" expected="$3"
  local fifo="$TMP/$label.fifo"
  local started="$TMP/$label.started"
  local received="$TMP/$label.received"
  local marker="$TMP/$label.marker"
  local errors="$TMP/$label.err"
  mkfifo "$fifo"
  head -n 1 <"$fifo" >/dev/null &
  local reader_pid=$!
  CHILD_OUTPUT_BEFORE_SIGNAL="$output_before_signal" \
    CHILD_STARTED="$started" CHILD_SIGNAL="$received" CHILD_MARKER="$marker" \
    node "$PI_SUPERVISOR" node "$TMP/managed-child.mjs" late-output \
    >"$fifo" 2>"$errors" &
  local supervisor_pid=$!
  local attempts=0
  while [ ! -s "$started" ] && [ "$attempts" -lt 500 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ "$output_before_signal" = "0" ]; then kill -TERM "$supervisor_pid"; fi
  wait "$reader_pid"
  set +e
  wait "$supervisor_pid"
  local rc=$?
  set -e
  local observed=""
  [ -f "$received" ] && observed=$(tr -d '\n' <"$received")
  if [ "$rc" -eq "$expected" ] \
    && [ "$observed" = "SIGTERM" ] \
    && ! grep -q 'EPIPE' "$errors"; then
    pass "$label handles closed stdout, terminates the child, and exits $expected"
  else
    fail "$label rc=$rc expected=$expected child_received=${observed:-missing} epipe=$([ -s "$errors" ] && grep -q EPIPE "$errors" && echo yes || echo no)"
    cat "$errors" >&2
  fi
}

run_closed_stdout_case pi-signal-before-epipe 0 143
run_closed_stdout_case pi-epipe-before-signal 1 1

# Cooperative signal children write after 1.5s if orphaned. Resistant children
# write after 3s; the two required grace windows plus signal cases exceed that.
sleep 2
for marker in "$TMP"/*.marker; do
  if [ -e "$marker" ]; then
    fail "managed child survived supervision and wrote $(basename "$marker")"
  fi
done

if [ "$failures" -ne 0 ]; then
  printf 't54-subprocess-supervision: %s failed\n' "$failures" >&2
  exit 1
fi
printf 't54-subprocess-supervision: all checks passed\n'
