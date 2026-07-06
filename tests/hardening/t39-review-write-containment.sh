#!/usr/bin/env bash
# t39-review-write-containment: review subagents may write only assigned review reports.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/plugins/edc/scripts/edc-review.sh"
TMP="$(mktemp -d)"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP" "$LOG_DIR"' EXIT

setup_repo() {
  cd "$TMP"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email test@test.com
  git config user.name Test
  git config commit.gpgsign false
  mkdir -p src edc-context/modules edc-context/reports .edc/skills/edc-review
  printf 'one\n' > src/a.txt
  printf 'clean\n' > src/clean.txt
  git add src/a.txt src/clean.txt
  git commit -q -m init
  printf 'two\n' > src/a.txt
  git add src/a.txt
  git commit -q -m change
  printf '# Repo\n\n## Route by path/task\n' > edc-context/index.md
  printf '# Core\n\n## Scope\n' > edc-context/modules/core.md
  printf '## Issues\n' > edc-context/reports/issues.md
  cat > edc-context/manifest.json <<EOF
{"schemaVersion":2,"sourceCommit":"$(git rev-parse HEAD)","repoContextFile":"edc-context/index.md","reports":{"issues":"edc-context/reports/issues.md","complexity":"edc-context/reports/complexity.md"},"build":{"buildInfoFile":"edc-context/build/build.json"},"policy":{"defaultMode":"advisory","unmatchedPathPolicy":"warn-allow"},"unmapped":{"allowedGlobs":[]},"modules":[{"name":"core","doc":"edc-context/modules/core.md","priority":10,"match":{"prefixes":["src/"]}}]}
EOF
  printf 'REVIEW_SKILL_MARKER\n' > .edc/skills/edc-review/SKILL.md
  printf 'METHODOLOGY_MARKER\n' > .edc/skills/edc-review/methodology.md
  printf 'ADVERSARIAL_MARKER\n' > .edc/skills/edc-review/adversarial.md
  printf 'REPORTING_MARKER\n' > .edc/skills/edc-review/reporting.md
  printf 'PATTERNS_MARKER\n' > .edc/skills/edc-review/patterns.md
}

write_fake_claude() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/shasum" <<MOCK
#!/usr/bin/env bash
last=""
for arg in "\$@"; do
  last="\$arg"
done
printf '%s\n' "\$last" >> "$LOG_DIR/shasum-paths.log"
exec /usr/bin/shasum "\$@"
MOCK
  chmod +x "$TMP/bin/shasum"
  cat > "$TMP/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
prompt=$(cat)
mkdir -p edc-context/review-tasks
if [ "${EDC_T39_FORBIDDEN_WRITE:-0}" = "1" ]; then
  printf 'pwned\n' >> src/a.txt
fi
printf '## Findings\n\nmock review\n' > edc-context/review-tasks/report-core.md
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"reviewed"}]}}\n'
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok"}\n'
if [ "${EDC_T39_EXIT_AFTER_REPORT:-0}" = "1" ]; then
  exit 1
fi
MOCK
  chmod +x "$TMP/bin/claude"
}

setup_repo
write_fake_claude

set +e
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 EDC_T39_FORBIDDEN_WRITE=1 bash "$SCRIPT" HEAD --base HEAD~1 >"$LOG_DIR/bad.out" 2>"$LOG_DIR/bad.err"
bad_rc=$?
set -e
if [ "$bad_rc" -ne 0 ] && grep -q 'review subagent touched forbidden paths' "$LOG_DIR/bad.err" && grep -q 'src/a.txt' "$LOG_DIR/bad.err"; then
  echo "PASS: review containment blocks source writes"
else
  echo "FAIL: review containment did not block source writes"
  echo "--- stdout ---"; cat "$LOG_DIR/bad.out"
  echo "--- stderr ---"; cat "$LOG_DIR/bad.err"
  exit 1
fi

node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const result = JSON.parse(readFileSync('edc-context/build/last-run.json', 'utf8'));
assert.equal(result.kind, 'review');
assert.equal(result.exitCode, 1);
assert.equal(result.reasonCode, 'review-write-containment');
assert.equal(result.failedModule, 'core');
NODE
echo "PASS: review containment writes structured failure result"

git checkout -- src/a.txt
rm -rf edc-context/review-tasks review-HEAD.md
set +e
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 bash "$SCRIPT" HEAD --base HEAD~1 >"$LOG_DIR/good.out" 2>"$LOG_DIR/good.err"
good_rc=$?
set -e
if [ "$good_rc" -eq 0 ] && [ -f review-HEAD.md ] && grep -q 'mock review' review-HEAD.md; then
  echo "PASS: review containment allows assigned report writes"
else
  echo "FAIL: review containment blocked valid report write"
  echo "--- stdout ---"; cat "$LOG_DIR/good.out"
  echo "--- stderr ---"; cat "$LOG_DIR/good.err"
  exit 1
fi

node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const result = JSON.parse(readFileSync('edc-context/build/last-run.json', 'utf8'));
assert.equal(result.kind, 'review');
assert.equal(result.exitCode, 0);
assert.equal(result.reasonCode, 'success');
assert.equal(result.finalReview, 'review-HEAD.md');
NODE
echo "PASS: review success writes structured result"

rm -rf edc-context/review-tasks review-HEAD.md
set +e
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 EDC_T39_EXIT_AFTER_REPORT=1 bash "$SCRIPT" HEAD --base HEAD~1 >"$LOG_DIR/warn.out" 2>"$LOG_DIR/warn.err"
warn_rc=$?
set -e
if [ "$warn_rc" -eq 0 ] \
  && [ -f review-HEAD.md ] \
  && grep -q 'mock review' review-HEAD.md \
  && grep -q 'review subprocess for module core reported failure, but report validation passed' "$LOG_DIR/warn.err"; then
  node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const result = JSON.parse(readFileSync('edc-context/build/last-run.json', 'utf8'));
assert.equal(result.kind, 'review');
assert.equal(result.status, 'success-with-warning');
assert.equal(result.exitCode, 0);
assert.equal(result.reasonCode, 'success-with-warning');
NODE
  echo "PASS: review accepts valid report after failed agent rc with warning"
else
  echo "FAIL: review did not accept valid report after failed agent rc"
  echo "--- stdout ---"; cat "$LOG_DIR/warn.out"
  echo "--- stderr ---"; cat "$LOG_DIR/warn.err"
  exit 1
fi

if [ -f "$LOG_DIR/shasum-paths.log" ] && grep -qx 'src/clean.txt' "$LOG_DIR/shasum-paths.log"; then
  echo "FAIL: review containment hashed clean tracked files"
  cat "$LOG_DIR/shasum-paths.log"
  exit 1
else
  echo "PASS: review containment hashes only changed-path candidates"
fi
