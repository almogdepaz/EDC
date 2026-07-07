#!/usr/bin/env bash
# t41-review-all-orchestrator: combined review runs security, delivery, quality and aggregates phase results.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/plugins/edc/scripts/edc-review-all.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '=== T41: review-all orchestrator ===\n'

setup_runtime() {
  rm -rf "$TMP/work"
  mkdir -p "$TMP/work/.edc/scripts" "$TMP/work/.edc/hooks/lib"
  cp "$SCRIPT" "$TMP/work/.edc/scripts/edc-review-all.sh"
  cp "$ROOT/plugins/edc/scripts/edc-lib.sh" "$TMP/work/.edc/scripts/edc-lib.sh"
  cp "$ROOT/plugins/edc/hooks/lib/json-cli.mjs" "$TMP/work/.edc/hooks/lib/json-cli.mjs"
  cp "$ROOT/plugins/edc/hooks/lib/route.mjs" "$TMP/work/.edc/hooks/lib/route.mjs"
  cp "$ROOT/plugins/edc/hooks/lib/paths.mjs" "$TMP/work/.edc/hooks/lib/paths.mjs"
  chmod +x "$TMP/work/.edc/scripts/edc-review-all.sh" "$TMP/work/.edc/scripts/edc-lib.sh"

  cat > "$TMP/work/.edc/scripts/edc-review.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'security|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
mkdir -p "$(dirname "$EDC_RESULT_FILE")"
cat > "$EDC_RESULT_FILE" <<'JSON'
{"schemaVersion":1,"kind":"review","phase":"security","status":"success","exitCode":0,"reasonCode":"success","message":"security review succeeded","outputs":["review-HEAD.md"],"finalReview":"review-HEAD.md"}
JSON
SH

  cat > "$TMP/work/.edc/scripts/edc-delivery-review.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'delivery|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
mkdir -p "$(dirname "$EDC_RESULT_FILE")"
case "${EDC_T41_DELIVERY:-success}" in
  success)
    cat > "$EDC_RESULT_FILE" <<'JSON'
{"schemaVersion":1,"kind":"delivery-review","phase":"delivery","status":"success","exitCode":0,"reasonCode":"success","message":"delivery review succeeded","outputs":["delivery-review-HEAD.md"],"finalReview":"delivery-review-HEAD.md"}
JSON
    ;;
  warning)
    cat > "$EDC_RESULT_FILE" <<'JSON'
{"schemaVersion":1,"kind":"delivery-review","phase":"delivery","status":"success-with-warning","exitCode":0,"reasonCode":"success-with-warning","message":"delivery review validated report after subprocess failure","hint":"inspect delivery log for transport diagnostics","outputs":["delivery-review-HEAD.md"],"finalReview":"delivery-review-HEAD.md"}
JSON
    ;;
  fail)
    cat > "$EDC_RESULT_FILE" <<'JSON'
{"schemaVersion":1,"kind":"delivery-review","phase":"delivery","status":"failed","exitCode":1,"reasonCode":"delivery-report-validation","message":"delivery review report validation failed","hint":"inspect delivery review output","failedModule":"delivery"}
JSON
    exit 1
    ;;
  *)
    echo "bad EDC_T41_DELIVERY" >&2
    exit 2
    ;;
esac
SH

  cat > "$TMP/work/.edc/scripts/edc-audit.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'quality|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
mkdir -p "$(dirname "$EDC_RESULT_FILE")"
cat > "$EDC_RESULT_FILE" <<'JSON'
{"schemaVersion":1,"kind":"audit","phase":"quality","status":"success","exitCode":0,"reasonCode":"success","message":"quality review succeeded","outputs":["edc-context/reports/issues.md","edc-context/reports/complexity.md"]}
JSON
SH
  chmod +x "$TMP/work/.edc/scripts/edc-review.sh" "$TMP/work/.edc/scripts/edc-delivery-review.sh" "$TMP/work/.edc/scripts/edc-audit.sh"
}

setup_runtime
(
  cd "$TMP/work"
  export EDC_AGENT_CLI=pi
  export EDC_CONTEXT_MODE=advisory
  export EDC_T41_LOG="$TMP/phases-warning.log"
  export EDC_T41_DELIVERY=warning
  bash .edc/scripts/edc-review-all.sh HEAD --base main --ignore 'generated/**' --context-mode advisory > "$TMP/warning.out" 2>&1
)

expected=$'security|agent=pi|ctx=advisory|args=HEAD --base main --ignore generated/** --context-mode advisory\ndelivery|agent=pi|ctx=advisory|args=HEAD --base main --ignore generated/** --context-mode advisory\nquality|agent=pi|ctx=advisory|args=HEAD --base main --ignore generated/** --context-mode advisory'
actual=$(cat "$TMP/phases-warning.log")
if [ "$actual" = "$expected" ]; then
  echo "PASS: review-all runs security, delivery, quality with correct args"
else
  echo "FAIL: review-all phase log mismatch"
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual"
  exit 1
fi

node --input-type=module <<NODE
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const result = JSON.parse(readFileSync('$TMP/work/edc-context/build/last-run.json', 'utf8'));
assert.equal(result.kind, 'review-all');
assert.equal(result.status, 'success-with-warning');
assert.equal(result.exitCode, 0);
assert.equal(result.reasonCode, 'success-with-warning');
assert.equal(result.scope, 'differential');
assert.equal(result.base, 'main');
assert.equal(result.target, 'HEAD');
assert.equal(result.dirtyTrackedIncluded, true);
assert.equal(result.untrackedIncluded, false);
assert.equal(result.phases.length, 3);
assert.equal(result.phases.find((phase) => phase.phase === 'delivery').status, 'success-with-warning');
assert.deepEqual(result.outputs, ['review-HEAD.md', 'delivery-review-HEAD.md', 'edc-context/reports/issues.md', 'edc-context/reports/complexity.md']);
NODE
if grep -q 'phases:' "$TMP/warning.out" && grep -q 'delivery: success-with-warning' "$TMP/warning.out"; then
  echo "PASS: review-all aggregates warning phase into structured success-with-warning"
else
  echo "FAIL: review-all did not print warning phase summary"
  cat "$TMP/warning.out"
  exit 1
fi

setup_runtime
(
  cd "$TMP/work"
  export EDC_AGENT_CLI=pi
  export EDC_CONTEXT_MODE=advisory
  export EDC_T41_LOG="$TMP/phases-full.log"
  bash .edc/scripts/edc-review-all.sh --full --ignore 'generated/**' --context-mode advisory > "$TMP/full.out" 2>&1
)

expected_full=$'security|agent=pi|ctx=advisory|args=--full --ignore generated/** --context-mode advisory\ndelivery|agent=pi|ctx=advisory|args=--full --ignore generated/** --context-mode advisory\nquality|agent=pi|ctx=advisory|args=--ignore generated/** --context-mode advisory'
actual_full=$(cat "$TMP/phases-full.log")
if [ "$actual_full" = "$expected_full" ]; then
  echo "PASS: review-all full runs security/delivery full and quality full"
else
  echo "FAIL: review-all full phase log mismatch"
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_full" "$actual_full"
  exit 1
fi

node --input-type=module <<NODE
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const result = JSON.parse(readFileSync('$TMP/work/edc-context/build/last-run.json', 'utf8'));
assert.equal(result.kind, 'review-all');
assert.equal(result.status, 'success');
assert.equal(result.scope, 'full');
NODE

echo "PASS: review-all full writes full-scope aggregate result"

setup_runtime
set +e
(
  cd "$TMP/work"
  export EDC_AGENT_CLI=pi
  export EDC_CONTEXT_MODE=advisory
  export EDC_T41_LOG="$TMP/phases-fail.log"
  export EDC_T41_DELIVERY=fail
  bash .edc/scripts/edc-review-all.sh HEAD --base main > "$TMP/fail.out" 2>&1
)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  node --input-type=module <<NODE
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const result = JSON.parse(readFileSync('$TMP/work/edc-context/build/last-run.json', 'utf8'));
assert.equal(result.kind, 'review-all');
assert.equal(result.status, 'failed');
assert.equal(result.exitCode, 1);
assert.equal(result.failedPhase, 'delivery');
assert.equal(result.reasonCode, 'delivery-report-validation');
assert.equal(result.phases.length, 2);
assert.equal(result.phases[1].phase, 'delivery');
NODE
  if grep -q 'failed phase: delivery' "$TMP/fail.out" && grep -q 'code: delivery-report-validation' "$TMP/fail.out"; then
    echo "PASS: review-all failure result identifies failed child phase"
  else
    echo "FAIL: review-all failure output did not identify failed child phase"
    cat "$TMP/fail.out"
    exit 1
  fi
else
  echo "FAIL: review-all should fail when a child phase result fails"
  cat "$TMP/fail.out"
  exit 1
fi

printf '\nAll T41 checks passed.\n'
