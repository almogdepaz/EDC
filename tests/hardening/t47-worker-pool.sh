#!/usr/bin/env bash
# t47-worker-pool: bounded deterministic worker execution and cleanup.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POOL="$ROOT/plugins/edc/hooks/lib/worker-pool.mjs"

. "$(dirname "$0")/lib/check.sh"
check_init --file
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; check_cleanup' EXIT

RUNNER="$TMP/fake-worker.sh"
cat > "$RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
task_file="${1:?task file required}"
mode="${WORKER_MODE:-success}"
id="${EDC_TASK_ID:?}"
out=$(node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(j.outputs[0])' "$task_file")
mkdir -p "$(dirname "$out")"
printf '%s\n' "$id" > "${WORKER_STATE:?}/active-$id"
active=$(find "$WORKER_STATE" -maxdepth 1 -name 'active-*' | wc -l | tr -d ' ')
printf '%s\t%s\n' "$id" "$active" >> "$WORKER_STATE/overlap.log"

case "$mode:$id" in
  failure:fail)
    sleep 0.2
    rm -f "$WORKER_STATE/active-$id"
    exit 17
    ;;
  failure:slow)
    sleep 30 &
    child=$!
    printf '%s\n' "$child" > "$WORKER_STATE/descendant.pid"
    wait "$child"
    ;;
  timeout:*)
    sleep 30 &
    child=$!
    printf '%s\n' "$$" > "$WORKER_STATE/runner.pid"
    printf '%s\n' "$child" > "$WORKER_STATE/descendant.pid"
    wait "$child"
    ;;
  missing:*)
    rm -f "$WORKER_STATE/active-$id"
    exit 0
    ;;
  escape:*)
    printf 'outside\n' > "${WORKER_ESCAPE_TARGET:?}"
    ln -s "$WORKER_ESCAPE_TARGET" "$out"
    rm -f "$WORKER_STATE/active-$id"
    exit 0
    ;;
  *)
    sleep 0.35
    ;;
esac

printf '%s\n' "$id" > "$out"
rm -f "$WORKER_STATE/active-$id"
RUNNER
chmod +x "$RUNNER"

write_manifest() {
  local run_dir="$1" max="$2" timeout="$3"
  shift 3
  mkdir -p "$run_dir/prompts" "$run_dir/staged" "$run_dir/state"
  local tasks="" id comma=""
  for id in "$@"; do
    printf 'task %s\n' "$id" > "$run_dir/prompts/$id.md"
    tasks+="$comma{\"id\":\"$id\",\"phase\":\"test/$id\",\"promptFile\":\"$run_dir/prompts/$id.md\",\"timeoutSeconds\":$timeout,\"outputs\":[\"$run_dir/staged/$id.txt\"]}"
    comma=,
  done
  cat > "$run_dir/tasks.json" <<EOF
{"schemaVersion":1,"runId":"t47","runDir":"$run_dir","maxConcurrency":$max,"tasks":[$tasks]}
EOF
}

# Validation rejects worker-controlled output paths outside the run directory.
invalid="$TMP/invalid"
write_manifest "$invalid" 2 5 one
node -e 'const fs=require("fs"); const p=process.argv[1]; const j=JSON.parse(fs.readFileSync(p,"utf8")); j.tasks[0].outputs=["/tmp/t47-escape.txt"]; fs.writeFileSync(p,JSON.stringify(j));' "$invalid/tasks.json"
invalid_out=$(node "$POOL" --runner "$RUNNER" "$invalid/tasks.json" 2>&1)
invalid_rc=$?
if [ "$invalid_rc" -ne 0 ] && printf '%s' "$invalid_out" | grep -q 'outside runDir'; then
  check "47.1: rejects declared outputs outside runDir" 1
else
  check "47.1: rejects declared outputs outside runDir" 0
  printf '%s\n' "$invalid_out"
fi

# Three real workers overlap at two, never three; aggregate order follows manifest.
parallel="$TMP/parallel"
write_manifest "$parallel" 2 5 first second third
WORKER_STATE="$parallel/state" node "$POOL" --runner "$RUNNER" "$parallel/tasks.json" >"$parallel/out.log" 2>"$parallel/err.log"
parallel_rc=$?
max_overlap=$(awk -F '\t' 'BEGIN{m=0} $2>m{m=$2} END{print m}' "$parallel/state/overlap.log" 2>/dev/null || echo 0)
if [ "$parallel_rc" -eq 0 ] && [ "$max_overlap" -eq 2 ]; then
  check "47.2: enforces bounded concurrency with real workers" 1
else
  check "47.2: enforces bounded concurrency with real workers" 0
  cat "$parallel/out.log" "$parallel/err.log" 2>/dev/null || true
  printf 'max_overlap=%s\n' "$max_overlap"
fi

if node -e 'const j=require(process.argv[1]); process.exit(j.status==="success" && j.tasks.map(t=>t.id).join(",")==="first,second,third" && j.tasks.every(t=>t.status==="success") ? 0 : 1)' "$parallel/stage-result.json"; then
  check "47.3: writes deterministic manifest-order results" 1
else
  check "47.3: writes deterministic manifest-order results" 0
  cat "$parallel/stage-result.json" 2>/dev/null || true
fi

# A failed task cancels its running sibling process group and never starts queued work.
failure="$TMP/failure"
write_manifest "$failure" 2 20 slow fail queued
start=$(date +%s)
WORKER_MODE=failure WORKER_STATE="$failure/state" node "$POOL" --runner "$RUNNER" "$failure/tasks.json" >"$failure/out.log" 2>"$failure/err.log"
failure_rc=$?
duration=$(( $(date +%s) - start ))
descendant_alive=0
if [ -f "$failure/state/descendant.pid" ]; then
  descendant=$(cat "$failure/state/descendant.pid")
  sleep 0.2
  kill -0 "$descendant" 2>/dev/null && descendant_alive=1
fi
if [ "$failure_rc" -ne 0 ] && [ "$duration" -lt 5 ] && [ -f "$failure/state/descendant.pid" ] && [ "$descendant_alive" -eq 0 ] && [ ! -f "$failure/staged/queued.txt" ] && node -e 'const j=require(process.argv[1]); process.exit(j.status==="failed" && j.tasks.some(t=>t.id==="fail" && t.status==="failed") && j.tasks.some(t=>t.id==="queued" && t.status==="cancelled") ? 0 : 1)' "$failure/stage-result.json"; then
  check "47.4: failure cancels descendants and queued tasks" 1
else
  check "47.4: failure cancels descendants and queued tasks" 0
  cat "$failure/out.log" "$failure/err.log" 2>/dev/null || true
  printf 'rc=%s duration=%s descendant_alive=%s\n' "$failure_rc" "$duration" "$descendant_alive"
fi

# Pool timeout is an independent backstop and also kills descendants.
timeout_run="$TMP/timeout"
write_manifest "$timeout_run" 1 1 timeout
start=$(date +%s)
WORKER_MODE=timeout WORKER_STATE="$timeout_run/state" node "$POOL" --runner "$RUNNER" "$timeout_run/tasks.json" >"$timeout_run/out.log" 2>"$timeout_run/err.log"
timeout_rc=$?
duration=$(( $(date +%s) - start ))
timeout_descendant_alive=0
if [ -f "$timeout_run/state/descendant.pid" ]; then
  descendant=$(cat "$timeout_run/state/descendant.pid")
  sleep 0.2
  kill -0 "$descendant" 2>/dev/null && timeout_descendant_alive=1
fi
if [ "$timeout_rc" -ne 0 ] && [ "$duration" -lt 5 ] && [ "$timeout_descendant_alive" -eq 0 ] && node -e 'const j=require(process.argv[1]); process.exit(j.tasks[0].status==="timed-out" ? 0 : 1)' "$timeout_run/stage-result.json"; then
  check "47.5: timeout terminates the worker process group" 1
else
  check "47.5: timeout terminates the worker process group" 0
  cat "$timeout_run/out.log" "$timeout_run/err.log" 2>/dev/null || true
  printf 'rc=%s duration=%s descendant_alive=%s\n' "$timeout_rc" "$duration" "$timeout_descendant_alive"
fi

# SIGHUP must use the same cancellation path as TERM/INT so detached worker
# groups do not outlive the pool.
hup_run="$TMP/hup"
write_manifest "$hup_run" 1 30 timeout
WORKER_MODE=timeout WORKER_STATE="$hup_run/state" node "$POOL" --runner "$RUNNER" "$hup_run/tasks.json" >"$hup_run/out.log" 2>"$hup_run/err.log" &
hup_pool_pid=$!
for _ in $(seq 1 500); do
  [ -f "$hup_run/state/descendant.pid" ] && break
  sleep 0.01
done
kill -HUP "$hup_pool_pid"
wait "$hup_pool_pid"
hup_rc=$?
sleep 0.2
hup_descendant=$(cat "$hup_run/state/descendant.pid" 2>/dev/null || true)
hup_descendant_alive=0
if [ -n "$hup_descendant" ] && kill -0 "$hup_descendant" 2>/dev/null; then
  hup_descendant_alive=1
fi
if [ "$hup_rc" -ne 0 ] \
  && [ "$hup_descendant_alive" -eq 0 ] \
  && node -e 'const j=require(process.argv[1]); process.exit(j.status === "failed" && j.tasks[0].status === "cancelled" && /SIGHUP/.test(j.reason) ? 0 : 1)' "$hup_run/stage-result.json"; then
  check "47.5a: SIGHUP cancels the detached worker process group" 1
else
  check "47.5a: SIGHUP cancels the detached worker process group" 0
  cat "$hup_run/out.log" "$hup_run/err.log" "$hup_run/stage-result.json" 2>/dev/null || true
  printf 'rc=%s descendant=%s descendant_alive=%s\n' "$hup_rc" "${hup_descendant:-missing}" "$hup_descendant_alive"
fi
hup_runner=$(cat "$hup_run/state/runner.pid" 2>/dev/null || true)
case "$hup_runner" in
  ''|*[!0-9]*) ;;
  *) kill -KILL -- "-$hup_runner" 2>/dev/null || true ;;
esac

# A continue policy records failure but lets independent workers finish so the
# phase coordinator can apply output-specific validation/warning semantics.
continue_run="$TMP/continue"
write_manifest "$continue_run" 2 5 ok fail after
node -e 'const fs=require("fs"); const p=process.argv[1]; const j=JSON.parse(fs.readFileSync(p,"utf8")); j.tasks.find(t=>t.id==="fail").failurePolicy="continue"; fs.writeFileSync(p,JSON.stringify(j));' "$continue_run/tasks.json"
WORKER_MODE=failure WORKER_STATE="$continue_run/state" node "$POOL" --runner "$RUNNER" "$continue_run/tasks.json" >"$continue_run/out.log" 2>"$continue_run/err.log"
continue_rc=$?
if [ "$continue_rc" -ne 0 ] && [ -f "$continue_run/staged/ok.txt" ] && [ -f "$continue_run/staged/after.txt" ] && node -e 'const j=require(process.argv[1]); process.exit(j.status==="failed" && j.tasks.find(t=>t.id==="fail").status==="failed" && j.tasks.find(t=>t.id==="after").status==="success" ? 0 : 1)' "$continue_run/stage-result.json"; then
  check "47.6: continue policy records failure without cancelling independent tasks" 1
else
  check "47.6: continue policy records failure without cancelling independent tasks" 0
  cat "$continue_run/out.log" "$continue_run/err.log" "$continue_run/stage-result.json" 2>/dev/null || true
fi

# Exit zero is insufficient when a declared output was not produced.
missing_run="$TMP/missing"
write_manifest "$missing_run" 1 5 missing
WORKER_MODE=missing WORKER_STATE="$missing_run/state" node "$POOL" --runner "$RUNNER" "$missing_run/tasks.json" >"$missing_run/out.log" 2>"$missing_run/err.log"
missing_rc=$?
if [ "$missing_rc" -ne 0 ] && node -e 'const j=require(process.argv[1]); process.exit(j.tasks[0].status==="failed" && /declared output/.test(j.reason) ? 0 : 1)' "$missing_run/stage-result.json"; then
  check "47.7: successful process without declared output fails the task" 1
else
  check "47.7: successful process without declared output fails the task" 0
  cat "$missing_run/out.log" "$missing_run/err.log" "$missing_run/stage-result.json" 2>/dev/null || true
fi

# A worker cannot satisfy containment with an output symlink escaping runDir.
escape_run="$TMP/escape"
write_manifest "$escape_run" 1 5 escape
WORKER_MODE=escape WORKER_STATE="$escape_run/state" WORKER_ESCAPE_TARGET="$TMP/outside.txt" node "$POOL" --runner "$RUNNER" "$escape_run/tasks.json" >"$escape_run/out.log" 2>"$escape_run/err.log"
escape_rc=$?
if [ "$escape_rc" -ne 0 ] && node -e 'const j=require(process.argv[1]); process.exit(j.tasks[0].status==="failed" ? 0 : 1)' "$escape_run/stage-result.json"; then
  check "47.8: rejects declared output symlinks escaping runDir" 1
else
  check "47.8: rejects declared output symlinks escaping runDir" 0
  cat "$escape_run/out.log" "$escape_run/err.log" "$escape_run/stage-result.json" 2>/dev/null || true
fi

# The production runner delegates to edc_spawn and preserves pool provenance.
production_runner="$ROOT/plugins/edc/scripts/edc-worker.sh"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/pi" <<'MOCK_PI'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\t%s\t%s\n' "${EDC_RUN_ID:-}" "${EDC_TASK_ID:-}" "${EDC_TASK_PHASE:-}" "$*" >> "${PI_CALLS_LOG:?}"
for arg in "$@"; do
  case "$arg" in
    @*)
      output=$(grep '^OUTPUT: ' "${arg#@}" | sed 's/^OUTPUT: //')
      mkdir -p "$(dirname "$output")"
      printf '## worker output\n' > "$output"
      ;;
  esac
done
printf '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"ok"}]}]}\n'
MOCK_PI
chmod +x "$TMP/bin/pi"
production="$TMP/production"
write_manifest "$production" 2 5 alpha beta
printf 'OUTPUT: %s\n' "$production/staged/alpha.txt" > "$production/prompts/alpha.md"
printf 'OUTPUT: %s\n' "$production/staged/beta.txt" > "$production/prompts/beta.md"
extension="$TMP/observer.ts"
printf 'export default function observer() {}\n' > "$extension"
: > "$production/pi.log"
PATH="$TMP/bin:$PATH" PI_CALLS_LOG="$production/pi.log" EDC_AGENT_CLI=pi EDC_PI_EXTENSION_PATH="$extension" node "$POOL" --runner "$production_runner" "$production/tasks.json" >"$production/out.log" 2>"$production/err.log"
production_rc=$?
if [ "$production_rc" -eq 0 ] && [ -f "$production/staged/alpha.txt" ] && [ -f "$production/staged/beta.txt" ] && [ "$(wc -l < "$production/pi.log" | tr -d ' ')" -eq 2 ] && grep -q $'t47\talpha\ttest/alpha\t' "$production/pi.log" && grep -Fq -- "--no-extensions -e $extension" "$production/pi.log"; then
  check "47.9: production runner uses edc_spawn with task provenance and explicit extension" 1
else
  check "47.9: production runner uses edc_spawn with task provenance and explicit extension" 0
  cat "$production/out.log" "$production/err.log" "$production/pi.log" 2>/dev/null || true
fi

set_two_task_outputs() {
  node -e '
    const fs = require("fs");
    const [path, firstOutput, secondOutput] = process.argv.slice(1);
    const manifest = JSON.parse(fs.readFileSync(path, "utf8"));
    manifest.tasks[0].outputs = [firstOutput];
    manifest.tasks[1].outputs = [secondOutput];
    fs.writeFileSync(path, JSON.stringify(manifest));
  ' "$1/tasks.json" "$2" "$3"
}

check_output_collision_rejected() {
  local run_dir="$1" description="$2" first_output="$3" second_output="$4"
  set_two_task_outputs "$run_dir" "$first_output" "$second_output"
  WORKER_STATE="$run_dir/state" node "$POOL" --runner "$RUNNER" "$run_dir/tasks.json" >"$run_dir/out.log" 2>"$run_dir/err.log"
  local rc=$? launches=0
  if [ -f "$run_dir/state/overlap.log" ]; then
    launches=$(wc -l < "$run_dir/state/overlap.log" | tr -d ' ')
  fi
  if [ "$rc" -eq 2 ] \
    && grep -Fq 'first' "$run_dir/err.log" \
    && grep -Fq 'second' "$run_dir/err.log" \
    && grep -Fq "$first_output" "$run_dir/err.log" \
    && grep -Fq "$second_output" "$run_dir/err.log" \
    && [ "$launches" -eq 0 ] \
    && [ ! -e "$run_dir/stage-result.json" ]; then
    check "$description" 1
  else
    check "$description" 0
    cat "$run_dir/out.log" "$run_dir/err.log" 2>/dev/null || true
    printf 'rc=%s launches=%s stage_result=%s\n' "$rc" "$launches" "$([ -e "$run_dir/stage-result.json" ] && echo yes || echo no)"
  fi
}

# Output ownership is manifest-wide: aliases must fail validation before launch.
exact_collision="$TMP/exact-collision"
write_manifest "$exact_collision" 2 5 first second
exact_output="$exact_collision/staged/shared.txt"
check_output_collision_rejected "$exact_collision" "47.10: rejects exact cross-task output collisions before launch" "$exact_output" "$exact_output"

normalized_collision="$TMP/normalized-collision"
write_manifest "$normalized_collision" 2 5 first second
normalized_output="$normalized_collision/staged/shared.txt"
normalized_alias="$normalized_collision/staged/nested/../shared.txt"
check_output_collision_rejected "$normalized_collision" "47.11: rejects normalized cross-task output aliases before launch" "$normalized_output" "$normalized_alias"

symlink_collision="$TMP/symlink-collision"
write_manifest "$symlink_collision" 2 5 first second
ln -s staged "$symlink_collision/staged-alias"
symlink_output="$symlink_collision/staged/shared.txt"
symlink_alias="$symlink_collision/staged-alias/shared.txt"
check_output_collision_rejected "$symlink_collision" "47.12: rejects in-run symlink-directory output aliases before launch" "$symlink_output" "$symlink_alias"

case_behavior=$(node - "$TMP" <<'NODE'
const { existsSync, mkdtempSync, rmSync, writeFileSync } = require("fs");
const { join } = require("path");
let probeDir;
try {
  probeDir = mkdtempSync(join(process.argv[2], "case-probe-"));
  writeFileSync(join(probeDir, "lowercase"), "probe\n");
  process.stdout.write(existsSync(join(probeDir, "LOWERCASE")) ? "insensitive" : "sensitive");
} finally {
  if (probeDir) rmSync(probeDir, { recursive: true });
}
NODE
)
case_probe_rc=$?
case_collision="$TMP/case-collision"
write_manifest "$case_collision" 2 5 first second
lowercase_output="$case_collision/staged/shared.txt"
uppercase_output="$case_collision/staged/SHARED.txt"
if [ "$case_probe_rc" -ne 0 ]; then
  check "47.13: applies output ownership case rules for the actual filesystem" 0
  printf 'filesystem case probe failed with rc=%s\n' "$case_probe_rc"
elif [ "$case_behavior" = "insensitive" ]; then
  check_output_collision_rejected "$case_collision" "47.13: rejects case-aliased outputs on case-insensitive filesystems" "$lowercase_output" "$uppercase_output"
else
  set_two_task_outputs "$case_collision" "$lowercase_output" "$uppercase_output"
  WORKER_STATE="$case_collision/state" node "$POOL" --runner "$RUNNER" "$case_collision/tasks.json" >"$case_collision/out.log" 2>"$case_collision/err.log"
  case_rc=$?
  case_launches=0
  if [ -f "$case_collision/state/overlap.log" ]; then
    case_launches=$(wc -l < "$case_collision/state/overlap.log" | tr -d ' ')
  fi
  if [ "$case_rc" -eq 0 ] \
    && [ "$case_launches" -eq 2 ] \
    && [ "$(cat "$lowercase_output" 2>/dev/null)" = "first" ] \
    && [ "$(cat "$uppercase_output" 2>/dev/null)" = "second" ] \
    && node -e 'const stage=require(process.argv[1]); process.exit(stage.status === "success" && stage.tasks.every((task) => task.status === "success") ? 0 : 1)' "$case_collision/stage-result.json"; then
    check "47.13: allows case-distinct outputs on case-sensitive filesystems" 1
  else
    check "47.13: allows case-distinct outputs on case-sensitive filesystems" 0
    cat "$case_collision/out.log" "$case_collision/err.log" "$case_collision/stage-result.json" 2>/dev/null || true
    printf 'filesystem=%s rc=%s launches=%s\n' "$case_behavior" "$case_rc" "$case_launches"
  fi
fi

# Concurrent spawn errors remain failed even when fail-fast stop marks siblings.
start_failure_runner="$TMP/start-failure-worker.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$start_failure_runner"
chmod 600 "$start_failure_runner"
start_failure="$TMP/start-failure"
write_manifest "$start_failure" 2 5 first second
node -e 'const fs=require("fs"); const p=process.argv[1]; const j=JSON.parse(fs.readFileSync(p,"utf8")); j.tasks[0].failurePolicy="continue"; fs.writeFileSync(p,JSON.stringify(j));' "$start_failure/tasks.json"
node "$POOL" --runner "$start_failure_runner" "$start_failure/tasks.json" >"$start_failure/out.log" 2>"$start_failure/err.log"
start_failure_rc=$?
if [ "$start_failure_rc" -ne 0 ] && node -e 'const j=require(process.argv[1]); process.exit(j.tasks.length === 2 && j.tasks.every((task) => task.status === "failed") && /could not start/.test(j.reason) ? 0 : 1)' "$start_failure/stage-result.json"; then
  check "47.14: concurrent start failures remain failed" 1
else
  check "47.14: concurrent start failures remain failed" 0
  cat "$start_failure/out.log" "$start_failure/err.log" "$start_failure/stage-result.json" 2>/dev/null || true
fi

check_summary "T47"
