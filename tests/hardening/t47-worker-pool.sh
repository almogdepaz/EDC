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

check_summary "T47"
