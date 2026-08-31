#!/usr/bin/env bash
set -euo pipefail

if [ "${EDC_T54_WATCHDOG_INNER:-0}" != "1" ]; then
  node --input-type=module - "$0" "$@" <<'NODE'
import { constants } from "node:os";
import { spawn } from "node:child_process";

const [script, ...args] = process.argv.slice(2);
const timeoutMs = Number(process.env.EDC_T54_WATCHDOG_SECONDS || 45) * 1000;
const child = spawn("bash", [script, ...args], {
  detached: true,
  env: { ...process.env, EDC_T54_WATCHDOG_INNER: "1" },
  stdio: "inherit",
});
let childClosed = false;
let killTimer = null;
let pollTimer = null;
let requestedExitCode = null;

function signalGroup(signal) {
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (error?.code !== "ESRCH") throw error;
  }
}

function groupIsRunning() {
  try {
    process.kill(-child.pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function finishAfterGroupExit() {
  if (!childClosed || groupIsRunning()) {
    pollTimer = setTimeout(finishAfterGroupExit, 10);
    return;
  }
  if (killTimer) clearTimeout(killTimer);
  process.exit(requestedExitCode);
}

function terminateTree(exitCode, signal) {
  if (requestedExitCode !== null) return;
  requestedExitCode = exitCode;
  signalGroup(signal);
  killTimer = setTimeout(() => signalGroup("SIGKILL"), 2500);
  finishAfterGroupExit();
}

const watchdog = setTimeout(() => {
  process.stderr.write("FAIL: t54 exceeded bounded watchdog\n");
  terminateTree(124, "SIGTERM");
}, timeoutMs);

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(signal, () => terminateTree(128 + constants.signals[signal], signal));
}

child.on("error", (error) => {
  clearTimeout(watchdog);
  process.stderr.write(`FAIL: t54 watchdog could not start test shell: ${error.message}\n`);
  process.exit(1);
});
child.on("close", (code, signal) => {
  childClosed = true;
  if (requestedExitCode !== null) return;
  clearTimeout(watchdog);
  if (killTimer) clearTimeout(killTimer);
  if (pollTimer) clearTimeout(pollTimer);
  process.exit(typeof code === "number" ? code : 128 + (constants.signals[signal] || 0));
});
NODE
  exit $?
fi

if [ "${EDC_T54_WATCHDOG_PROBE:-0}" = "1" ]; then
  printf '%s\n' "$$" >"$EDC_T54_WATCHDOG_PROBE_PID"
  exec node -e 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000)'
fi

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STREAM_FILTER="$ROOT/plugins/edc/hooks/lib/stream-filter.mjs"
PI_SUPERVISOR="$ROOT/plugins/edc/hooks/lib/pi-supervisor.mjs"
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

watchdog_probe_pid_file="$TMP/watchdog-probe.pid"
start=$(now_ms)
set +e
EDC_T54_WATCHDOG_INNER=0 EDC_T54_WATCHDOG_SECONDS=0.2 \
  EDC_T54_WATCHDOG_PROBE=1 EDC_T54_WATCHDOG_PROBE_PID="$watchdog_probe_pid_file" \
  bash "$0" >"$TMP/watchdog-probe.out" 2>&1
watchdog_probe_rc=$?
set -e
watchdog_probe_elapsed=$(( $(now_ms) - start ))
watchdog_probe_pid=$([ -s "$watchdog_probe_pid_file" ] && tr -d '\n' <"$watchdog_probe_pid_file" || true)
watchdog_probe_alive=0
[ -z "$watchdog_probe_pid" ] || ! kill -0 "$watchdog_probe_pid" 2>/dev/null || watchdog_probe_alive=1
if [ "$watchdog_probe_rc" -eq 124 ] \
  && [ "$watchdog_probe_elapsed" -ge 2500 ] && [ "$watchdog_probe_elapsed" -lt 5000 ] \
  && [ -n "$watchdog_probe_pid" ] && [ "$watchdog_probe_alive" -eq 0 ]; then
  pass "bounded watchdog escalates, reaps its test tree, and leaves no timer process"
else
  fail "bounded watchdog rc=$watchdog_probe_rc elapsed=${watchdog_probe_elapsed}ms pid=${watchdog_probe_pid:-missing} alive=$watchdog_probe_alive"
  cat "$TMP/watchdog-probe.out" >&2
fi

cat >"$TMP/managed-child.mjs" <<'NODE'
import { existsSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";

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
} else if (mode === "descendant") {
  const grandchild = spawn(process.execPath, [process.argv[1], "resistant"], {
    stdio: "ignore",
    env: {
      ...process.env,
      CHILD_STARTED: process.env.GRANDCHILD_STARTED,
      CHILD_MARKER: process.env.GRANDCHILD_MARKER,
      EMIT_AGENT_END: "0",
    },
  });
  grandchild.unref();
  if (started) writeFileSync(started, `${process.pid}\n`);
  if (process.env.EMIT_AGENT_END === "1") {
    const readyTimer = setInterval(() => {
      if (!existsSync(process.env.GRANDCHILD_STARTED)) return;
      clearInterval(readyTimer);
      process.stdout.write(`${JSON.stringify({
        type: "agent_end",
        messages: [{ role: "assistant", stopReason: "stop", content: [{ type: "text", text: "ok" }] }],
      })}\n`);
    }, 10);
  }
  setInterval(() => {}, 1000);
} else if (mode === "spontaneous-descendant") {
  const grandchild = spawn(process.execPath, [process.argv[1], "resistant"], {
    stdio: "ignore",
    env: {
      ...process.env,
      CHILD_STARTED: process.env.GRANDCHILD_STARTED,
      CHILD_MARKER: process.env.GRANDCHILD_MARKER,
      EMIT_AGENT_END: "0",
    },
  });
  grandchild.unref();
  while (!existsSync(process.env.GRANDCHILD_STARTED)) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  process.exit(0);
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
stream_timeout_pid=$([ -s "$TMP/stream-timeout.pid" ] && tr -d '\n' <"$TMP/stream-timeout.pid" || true)
stream_timeout_alive=0
[ -z "$stream_timeout_pid" ] || ! kill -0 "$stream_timeout_pid" 2>/dev/null || stream_timeout_alive=1
if [ "$stream_timeout_rc" -eq 1 ] \
  && [ "$stream_timeout_elapsed" -ge 1700 ] \
  && [ "$stream_timeout_elapsed" -lt 3500 ] \
  && [ -n "$stream_timeout_pid" ] \
  && [ "$stream_timeout_alive" -eq 0 ]; then
  pass "stream-filter does not report timeout completion before its resistant group is gone (${stream_timeout_elapsed}ms)"
else
  fail "stream-filter timeout rc=$stream_timeout_rc elapsed=${stream_timeout_elapsed}ms pid=${stream_timeout_pid:-missing} alive=$stream_timeout_alive"
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
pi_success_pid=$([ -s "$TMP/pi-success.pid" ] && tr -d '\n' <"$TMP/pi-success.pid" || true)
pi_success_alive=0
[ -z "$pi_success_pid" ] || ! kill -0 "$pi_success_pid" 2>/dev/null || pi_success_alive=1
if [ "$pi_success_rc" -eq 0 ] \
  && [ "$pi_success_elapsed" -ge 800 ] \
  && [ "$pi_success_elapsed" -lt 2500 ] \
  && [ -n "$pi_success_pid" ] \
  && [ "$pi_success_alive" -eq 0 ]; then
  pass "pi-supervisor does not report success before its resistant group is gone (${pi_success_elapsed}ms)"
else
  fail "pi-supervisor success rc=$pi_success_rc elapsed=${pi_success_elapsed}ms pid=${pi_success_pid:-missing} alive=$pi_success_alive"
  cat "$TMP/pi-success.out" >&2
fi

run_descendant_case() {
  local supervisor="$1" label="$2"
  local parent_started="$TMP/$label-parent.pid"
  local grandchild_started="$TMP/$label-grandchild.pid"
  local marker="$TMP/$label.marker"
  local output="$TMP/$label.out"
  local start elapsed rc grandchild_pid grandchild_alive=0
  start=$(now_ms)
  set +e
  if [ "$supervisor" = "stream" ]; then
    CHILD_STARTED="$parent_started" GRANDCHILD_STARTED="$grandchild_started" GRANDCHILD_MARKER="$marker" \
      node "$STREAM_FILTER" --run 1 descendant-timeout -- node "$TMP/managed-child.mjs" descendant >"$output" 2>&1
  else
    EMIT_AGENT_END=1 CHILD_STARTED="$parent_started" GRANDCHILD_STARTED="$grandchild_started" GRANDCHILD_MARKER="$marker" \
      node "$PI_SUPERVISOR" node "$TMP/managed-child.mjs" descendant >"$output" 2>&1
  fi
  rc=$?
  set -e
  elapsed=$(( $(now_ms) - start ))
  [ -s "$grandchild_started" ] && grandchild_pid=$(tr -d '\n' <"$grandchild_started") || grandchild_pid=""
  [ -z "$grandchild_pid" ] || ! kill -0 "$grandchild_pid" 2>/dev/null || grandchild_alive=1
  if [ "$rc" -eq "$([ "$supervisor" = stream ] && echo 1 || echo 0)" ] \
    && [ "$elapsed" -ge 800 ] && [ "$elapsed" -lt 3000 ] \
    && [ -n "$grandchild_pid" ] && [ "$grandchild_alive" -eq 0 ]; then
    pass "$label terminates resistant descendants as a detached process group (${elapsed}ms)"
  else
    fail "$label descendant rc=$rc elapsed=${elapsed}ms grandchild=${grandchild_pid:-missing} alive=$grandchild_alive"
    cat "$output" >&2
    [ -z "$grandchild_pid" ] || kill -KILL "$grandchild_pid" 2>/dev/null || true
  fi
}

run_descendant_case stream stream-filter
run_descendant_case pi pi-supervisor

run_spontaneous_descendant_case() {
  local supervisor="$1" label="$2"
  local grandchild_started="$TMP/$label-spontaneous-grandchild.pid"
  local marker="$TMP/$label-spontaneous.marker"
  local output="$TMP/$label-spontaneous.out"
  local start elapsed rc grandchild_pid grandchild_alive=0 expected
  expected=$([ "$supervisor" = stream ] && echo 0 || echo 1)
  start=$(now_ms)
  set +e
  if [ "$supervisor" = "stream" ]; then
    GRANDCHILD_STARTED="$grandchild_started" GRANDCHILD_MARKER="$marker" \
      node "$STREAM_FILTER" --run 10 spontaneous-descendant -- \
      node "$TMP/managed-child.mjs" spontaneous-descendant >"$output" 2>&1
  else
    GRANDCHILD_STARTED="$grandchild_started" GRANDCHILD_MARKER="$marker" \
      node "$PI_SUPERVISOR" node "$TMP/managed-child.mjs" spontaneous-descendant >"$output" 2>&1
  fi
  rc=$?
  set -e
  elapsed=$(( $(now_ms) - start ))
  grandchild_pid=$([ -s "$grandchild_started" ] && tr -d '\n' <"$grandchild_started" || true)
  [ -z "$grandchild_pid" ] || ! kill -0 "$grandchild_pid" 2>/dev/null || grandchild_alive=1
  if [ "$rc" -eq "$expected" ] \
    && [ "$elapsed" -ge 800 ] && [ "$elapsed" -lt 3000 ] \
    && [ -n "$grandchild_pid" ] && [ "$grandchild_alive" -eq 0 ]; then
    pass "$label cleans its process group after the direct child exits"
  else
    fail "$label spontaneous descendant rc=$rc elapsed=${elapsed}ms grandchild=${grandchild_pid:-missing} alive=$grandchild_alive"
    cat "$output" >&2
  fi
}

run_spontaneous_descendant_case stream stream-filter
run_spontaneous_descendant_case pi pi-supervisor

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
