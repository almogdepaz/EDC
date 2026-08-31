#!/usr/bin/env bash
# t41-review-all-orchestrator: combined review runs security, delivery, quality and aggregates phase results.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '=== T41: review-all orchestrator ===\n'

setup_runtime() {
  rm -rf "$TMP/work" "$TMP/plugin"
  mkdir -p "$TMP/work"
  cp -R "$ROOT/plugins/edc" "$TMP/plugin"

  cat > "$TMP/plugin/scripts/edc-review.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'security|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
mkdir -p "$(dirname "$EDC_REVIEW_PROMOTION_OUTPUT")" "$(dirname "$EDC_RESULT_FILE")"
printf '## security\n' > "$EDC_REVIEW_PROMOTION_OUTPUT"
cat > "$EDC_RESULT_FILE" <<'JSON'
{"schemaVersion":1,"kind":"review","phase":"security","status":"success","exitCode":0,"reasonCode":"success","message":"security review succeeded","outputs":["review-HEAD.md"],"finalReview":"review-HEAD.md"}
JSON
SH

  cat > "$TMP/plugin/scripts/edc-delivery-review.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'delivery|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
mkdir -p "$(dirname "$EDC_DELIVERY_REVIEW_OUTPUT")" "$(dirname "$EDC_RESULT_FILE")"
case "${EDC_T41_DELIVERY:-success}" in
  success)
    printf '## delivery\n\nno findings\n' > "$EDC_DELIVERY_REVIEW_OUTPUT"
    cat > "$EDC_RESULT_FILE" <<'JSON'
{"schemaVersion":1,"kind":"delivery-review","phase":"delivery","status":"success","exitCode":0,"reasonCode":"success","message":"delivery review succeeded","outputs":["delivery-review-HEAD.md"],"finalReview":"delivery-review-HEAD.md"}
JSON
    ;;
  warning)
    printf 'x' > "$EDC_DELIVERY_REVIEW_OUTPUT"
    . "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/edc-lib.sh"
    if edc_file_has_substantive_content "$EDC_DELIVERY_REVIEW_OUTPUT"; then
      echo 'truncated report was incorrectly accepted' >&2
      exit 1
    fi
    edc_write_coverage_gap_report "$EDC_DELIVERY_REVIEW_OUTPUT" "Delivery Review Coverage Gap" \
      "Delivery review unavailable; the reviewer produced truncated output."
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

  cat > "$TMP/plugin/scripts/edc-audit.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'quality|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
mkdir -p "$(dirname "$EDC_AUDIT_COMPLEXITY_OUTPUT")" "$(dirname "$EDC_RESULT_FILE")"
printf '## complexity\n' > "$EDC_AUDIT_COMPLEXITY_OUTPUT"
printf '## issues\n' > "$EDC_AUDIT_ISSUES_OUTPUT"
cat > "$EDC_RESULT_FILE" <<'JSON'
{"schemaVersion":1,"kind":"audit","phase":"quality","status":"success","exitCode":0,"reasonCode":"success","message":"quality review succeeded","outputs":["edc-context/reports/issues.md","edc-context/reports/complexity.md"]}
JSON
SH
  cat > "$TMP/plugin/scripts/edc-recover-context.sh" <<'SH'
#!/usr/bin/env bash
recover_context_if_needed() { return 0; }
SH
  chmod +x "$TMP/plugin/scripts/edc-review.sh" "$TMP/plugin/scripts/edc-delivery-review.sh" "$TMP/plugin/scripts/edc-audit.sh" "$TMP/plugin/scripts/edc-recover-context.sh"
  git -C "$TMP/work" init -q
  git -C "$TMP/work" config user.email test@example.com
  git -C "$TMP/work" config user.name Test
  git -C "$TMP/work" config commit.gpgsign false
  printf 'tracked\n' > "$TMP/work/tracked.txt"
  git -C "$TMP/work" add tracked.txt
  git -C "$TMP/work" commit -q -m initial
  git -C "$TMP/work" branch -M main
}

setup_runtime
(
  cd "$TMP/work"
  export EDC_AGENT_CLI=pi
  export EDC_CONTEXT_MODE=advisory
  export EDC_T41_LOG="$TMP/phases-warning.log"
  export EDC_T41_DELIVERY=warning
  bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main --committed-only --ignore 'generated/**' --context-mode advisory > "$TMP/warning.out" 2>&1
)

candidate_sha=$(git -C "$TMP/work" rev-parse HEAD)
expected=$(printf '%s\n' \
  "security|agent=pi|ctx=advisory|args=$candidate_sha --committed-only --base main --ignore generated/** --context-mode advisory" \
  "delivery|agent=pi|ctx=advisory|args=$candidate_sha --committed-only --base main --ignore generated/** --context-mode advisory" \
  "quality|agent=pi|ctx=advisory|args=$candidate_sha --committed-only --base main --ignore generated/** --context-mode advisory" | LC_ALL=C sort)
actual=$(LC_ALL=C sort "$TMP/phases-warning.log")
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
assert.equal(result.candidateKind, 'committed');
assert.equal(result.candidateCommit, '$candidate_sha');
assert.equal(result.dirtyTrackedIncluded, false);
assert.equal(result.untrackedIncluded, false);
assert.equal(result.phases.length, 3);
assert.equal(result.phases.find((phase) => phase.phase === 'delivery').status, 'success-with-warning');
assert.deepEqual(result.outputs, ['review-HEAD.md', 'delivery-review-HEAD.md', 'edc-context/reports/issues.md', 'edc-context/reports/complexity.md']);
assert.match(readFileSync('$TMP/work/delivery-review-HEAD.md', 'utf8'), /reviewer produced truncated output/);
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
  bash "$TMP/plugin/scripts/edc-review-all.sh" --full --ignore 'generated/**' --context-mode advisory > "$TMP/full.out" 2>&1
)

expected_full=$(printf '%s\n' \
  'security|agent=pi|ctx=advisory|args=--full --ignore generated/** --context-mode advisory' \
  'delivery|agent=pi|ctx=advisory|args=--full --ignore generated/** --context-mode advisory' \
  'quality|agent=pi|ctx=advisory|args=--ignore generated/** --context-mode advisory' | LC_ALL=C sort)
actual_full=$(LC_ALL=C sort "$TMP/phases-full.log")
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
  bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main --committed-only > "$TMP/fail.out" 2>&1
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
assert.equal(result.phases.length, 3);
assert.equal(result.phases.find((phase) => phase.phase === 'delivery').status, 'failed');
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
