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
  node "$ROOT/plugins/edc/hooks/lib/runtime-manifest.mjs" install "$TMP" "$ROOT/plugins/edc" >/dev/null
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
previous=""
for arg in "$@"; do
  if [ "$previous" = "--system-prompt-file" ]; then
    prompt=$(cat "$arg")
    break
  fi
  previous="$arg"
done
task_path=$(printf '%s' "$prompt" | grep -oE 'TASK FILE: [^ ]+' | head -1 | awk '{print $3}')
report_path="$(dirname "$task_path")/report-core.md"
mkdir -p "$(dirname "$report_path")"
if [ "${EDC_T39_FORBIDDEN_WRITE:-0}" = "1" ]; then
  printf 'pwned\n' >> src/a.txt
fi
if [ "${EDC_T39_FORBIDDEN_CANONICAL_REPORT_WRITE:-0}" = "1" ]; then
  printf 'pwned\n' >> edc-context/reports/issues.md
fi
if [ "${EDC_T39_FORBIDDEN_GIT_HOOK_WRITE:-0}" = "1" ]; then
  mkdir -p .git/hooks
  printf '#!/usr/bin/env bash\necho pwned\n' > .git/hooks/pre-commit
fi
if [ "${EDC_T39_EMPTY_REPORT:-0}" = "1" ]; then
  : > "$report_path"
elif [ "${EDC_T39_SKIP_REPORT:-0}" != "1" ]; then
  printf 'mock review without canonical headings\n' > "$report_path"
fi
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
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 EDC_T39_FORBIDDEN_WRITE=1 bash "$SCRIPT" HEAD --base HEAD~1 --committed-only >"$LOG_DIR/bad.out" 2>"$LOG_DIR/bad.err"
bad_rc=$?
set -e
if [ "$bad_rc" -ne 0 ] \
  && grep -q 'forbidden paths changed during the security worker stage' "$LOG_DIR/bad.err" \
  && grep -q 'src/a.txt' "$LOG_DIR/bad.err" \
  && grep -q 'pwned' src/a.txt; then
  echo "PASS: review containment detects source writes without rewriting them"
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
assert.equal(Object.hasOwn(result, 'failedModule'), false);
NODE
echo "PASS: review containment writes structured failure result"

git checkout -- src/a.txt
rm -rf edc-context/review-tasks review-HEAD.md
set +e
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 EDC_T39_FORBIDDEN_CANONICAL_REPORT_WRITE=1 bash "$SCRIPT" HEAD --base HEAD~1 --committed-only >"$LOG_DIR/canonical-report.out" 2>"$LOG_DIR/canonical-report.err"
canonical_report_rc=$?
set -e
if [ "$canonical_report_rc" -ne 0 ] \
  && grep -q 'forbidden paths changed during the security worker stage' "$LOG_DIR/canonical-report.err" \
  && grep -q 'edc-context/reports/issues.md' "$LOG_DIR/canonical-report.err"; then
  echo "PASS: security review protects canonical reports as phase-owned state"
else
  echo "FAIL: security review did not protect canonical reports"
  echo "--- stdout ---"; cat "$LOG_DIR/canonical-report.out"
  echo "--- stderr ---"; cat "$LOG_DIR/canonical-report.err"
  exit 1
fi
printf '## Issues\n' > edc-context/reports/issues.md
rm -rf edc-context/review-tasks review-HEAD.md
set +e
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 EDC_T39_FORBIDDEN_GIT_HOOK_WRITE=1 bash "$SCRIPT" HEAD --base HEAD~1 --committed-only >"$LOG_DIR/git-hook.out" 2>"$LOG_DIR/git-hook.err"
git_hook_rc=$?
set -e
if [ "$git_hook_rc" -ne 0 ] \
  && grep -q 'forbidden paths changed during the security worker stage' "$LOG_DIR/git-hook.err" \
  && grep -q '.git/hooks/pre-commit' "$LOG_DIR/git-hook.err" \
  && [ -f .git/hooks/pre-commit ]; then
  echo "PASS: review containment detects git hook writes without rewriting them"
else
  echo "FAIL: review containment did not block git hook writes"
  echo "--- stdout ---"; cat "$LOG_DIR/git-hook.out"
  echo "--- stderr ---"; cat "$LOG_DIR/git-hook.err"
  exit 1
fi
rm -f .git/hooks/pre-commit
rm -rf edc-context/review-tasks review-HEAD.md
set +e
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 bash "$SCRIPT" HEAD --base HEAD~1 --committed-only >"$LOG_DIR/good.out" 2>"$LOG_DIR/good.err"
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
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 EDC_T39_EXIT_AFTER_REPORT=1 bash "$SCRIPT" HEAD --base HEAD~1 --committed-only >"$LOG_DIR/warn.out" 2>"$LOG_DIR/warn.err"
warn_rc=$?
set -e
if [ "$warn_rc" -eq 0 ] \
  && [ -f review-HEAD.md ] \
  && grep -q 'mock review without canonical headings' review-HEAD.md \
  && grep -q 'review subprocess for module core reported status failed' "$LOG_DIR/warn.err"; then
  node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const result = JSON.parse(readFileSync('edc-context/build/last-run.json', 'utf8'));
assert.equal(result.kind, 'review');
assert.equal(result.status, 'success-with-warning');
assert.equal(result.exitCode, 0);
assert.equal(result.reasonCode, 'success-with-warning');
NODE
  echo "PASS: review accepts substantive noncanonical report after failed agent rc"
else
  echo "FAIL: review rejected substantive report after failed agent rc"
  echo "--- stdout ---"; cat "$LOG_DIR/warn.out"
  echo "--- stderr ---"; cat "$LOG_DIR/warn.err"
  exit 1
fi

rm -rf edc-context/review-tasks review-HEAD.md
set +e
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 EDC_T39_EXIT_AFTER_REPORT=1 EDC_T39_SKIP_REPORT=1 bash "$SCRIPT" HEAD --base HEAD~1 --committed-only >"$LOG_DIR/missing.out" 2>"$LOG_DIR/missing.err"
missing_rc=$?
set -e
if [ "$missing_rc" -eq 0 ] \
  && grep -Fq "Security review unavailable for module \`core\`" review-HEAD.md \
  && grep -q '^CONDITIONAL$' review-HEAD.md; then
  node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const result = JSON.parse(readFileSync('edc-context/build/last-run.json', 'utf8'));
assert.equal(result.kind, 'review');
assert.equal(result.status, 'success-with-warning');
assert.equal(result.exitCode, 0);
assert.equal(result.reasonCode, 'success-with-warning');
NODE
  echo "PASS: missing failed-worker report becomes explicit unavailable coverage"
else
  echo "FAIL: missing failed-worker report aborted or hid incomplete coverage"
  echo "--- stdout ---"; cat "$LOG_DIR/missing.out"
  echo "--- stderr ---"; cat "$LOG_DIR/missing.err"
  exit 1
fi

rm -rf edc-context/review-tasks review-HEAD.md
set +e
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=claude EDC_KEEP_REVIEW_TASKS=1 EDC_T39_EMPTY_REPORT=1 bash "$SCRIPT" HEAD --base HEAD~1 --committed-only >"$LOG_DIR/empty.out" 2>"$LOG_DIR/empty.err"
empty_rc=$?
set -e
if [ "$empty_rc" -eq 0 ] \
  && grep -Fq "Security review unavailable for module \`core\`" review-HEAD.md \
  && grep -q 'module core produced no substantive report' "$LOG_DIR/empty.err" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.status === "success-with-warning" ? 0 : 1)'; then
  echo "PASS: empty successful-worker report becomes explicit unavailable coverage"
else
  echo "FAIL: empty successful-worker report aborted or hid incomplete coverage"
  echo "--- stdout ---"; cat "$LOG_DIR/empty.out"
  echo "--- stderr ---"; cat "$LOG_DIR/empty.err"
  exit 1
fi

if [ -f "$LOG_DIR/shasum-paths.log" ] && grep -qx 'src/clean.txt' "$LOG_DIR/shasum-paths.log"; then
  echo "FAIL: review containment hashed clean tracked files"
  cat "$LOG_DIR/shasum-paths.log"
  exit 1
else
  echo "PASS: review containment hashes only changed-path candidates"
fi
