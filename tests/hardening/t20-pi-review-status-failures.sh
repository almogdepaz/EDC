#!/usr/bin/env bash
# Pi review status should explain common background review failures.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TRUSTED_PACKAGE="$TMP/trusted-package"
mkdir -p "$TRUSTED_PACKAGE/plugins"
cp -R "$ROOT/pi" "$TRUSTED_PACKAGE/pi"
cp -R "$ROOT/plugins/edc" "$TRUSTED_PACKAGE/plugins/edc"

EDC_TEST_EXTENSION="$TRUSTED_PACKAGE/pi/index.mjs" EDC_TEST_PLUGIN_ROOT="$TRUSTED_PACKAGE/plugins/edc" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const { default: edcExtension } = await import(pathToFileURL(process.env.EDC_TEST_EXTENSION).href);

delete process.env.EDC_PI_SUBPROCESS;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(50);
  }
  return predicate();
}

const cwd = mkdtempSync(join(tmpdir(), "edc-pi-status-fail-"));
let childPid = 0;
try {
  execFileSync("git", ["init", "-q"], { cwd });
  execFileSync("git", ["config", "user.email", "a@example.com"], { cwd });
  execFileSync("git", ["config", "user.name", "a"], { cwd });
  writeFileSync(join(cwd, "tracked.txt"), "one\n");
  execFileSync("git", ["add", "tracked.txt"], { cwd });
  execFileSync("git", ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], { cwd });

  const scriptsDir = join(process.env.EDC_TEST_PLUGIN_ROOT, "scripts");
  const reviewScript = join(scriptsDir, "edc-review.sh");
  writeFileSync(reviewScript, `#!/usr/bin/env bash
set -euo pipefail
printf 'two\\n' > tracked.txt
git add tracked.txt
git -c commit.gpgsign=false commit -q -m 'move head during review'
echo 'simulated review failure' >&2
exit 1
`);
  chmodSync(reviewScript, 0o755);
  const messages = [];
  let handler;
  const pi = {
    on() {},
    registerCommand(_name, config) { handler = config.handler; },
    sendMessage(message) { messages.push(message); },
  };
  await edcExtension(pi);

  const selections = ["security review", "changed files vs default branch", "job status"];
  const ctx = {
    cwd,
    hasUI: true,
    ui: {
      select: async () => selections.shift(),
      confirm: async () => true,
    },
    model: { provider: "test", id: "model" },
  };

  const messagesBeforeStart = messages.length;
  await handler("", ctx);
  const startMessage = messages.slice(messagesBeforeStart).at(-1);
  assert.equal(messages.length, messagesBeforeStart + 1, "successful background review start should emit one compact command result");
  assert.equal(startMessage.customType, "edc-background");
  assert.match(startMessage.content, /Background EDC review started\./);

  const statusPath = join(cwd, ".git", "edc", "status");
  const pidMatch = readFileSync(statusPath, "utf-8").match(/^pid=(\d+)$/m);
  childPid = pidMatch ? Number(pidMatch[1]) : 0;
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=failed/.test(readFileSync(statusPath, "utf-8")), 10000));

  await handler("", ctx);
  const status = messages.filter((message) => message.customType === "edc-job-status").at(-1);
  assert.ok(status, "review status message should be emitted");
  assert.match(status.content, /status: failed/);
  assert.match(status.content, /reason: HEAD changed during background review/);
  assert.match(status.content, /hint: rerun the review after the working branch stops changing/);

  writeFileSync(reviewScript, `#!/usr/bin/env bash
set -euo pipefail
mkdir -p .git/edc
cat > .git/edc/result.json <<'JSON'
{"kind":"review","exitCode":1,"reasonCode":"report-validation","failedModule":"core","failureReason":"structured validation for module core","failureHint":"structured hint from result file"}
JSON
echo 'generic log failure' >&2
exit 1
`);
  chmodSync(reviewScript, 0o755);
  selections.push("security review", "changed files vs default branch", "job status");
  const messagesBeforeStructuredStart = messages.length;
  await handler("", ctx);
  const structuredStart = messages.slice(messagesBeforeStructuredStart).find((message) => message.customType === "edc-background");
  assert.ok(structuredStart, "structured failure scenario should start a background review");
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=failed/.test(readFileSync(statusPath, "utf-8")) && /structured validation/.test(readFileSync(statusPath, "utf-8")), 10000));
  await handler("", ctx);
  const structuredStatus = messages.filter((message) => message.customType === "edc-job-status").at(-1);
  assert.match(structuredStatus.content, /reason: structured validation for module core/);
  assert.match(structuredStatus.content, /hint: structured hint from result file/);

  writeFileSync(reviewScript, `#!/usr/bin/env bash
set -euo pipefail
mkdir -p .git/edc
cat > .git/edc/result.json <<'JSON'
{"kind":"review","exitCode":0,"reasonCode":"success","finalReview":"review-structured.md"}
JSON
echo 'review succeeded without legacy verified log line'
exit 0
`);
  chmodSync(reviewScript, 0o755);
  selections.push("security review", "changed files vs default branch", "job status");
  await handler("", ctx);
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=success/.test(readFileSync(statusPath, "utf-8")), 10000));
  await handler("", ctx);
  const structuredSuccessStatus = messages.filter((message) => message.customType === "edc-job-status").at(-1);
  assert.match(structuredSuccessStatus.content, /final review: review-structured\.md/);

  const reviewAllScript = join(scriptsDir, "edc-review-all.sh");
  writeFileSync(reviewAllScript, `#!/usr/bin/env bash
set -euo pipefail
mkdir -p .git/edc
cat > .git/edc/result.json <<'JSON'
{"schemaVersion":1,"kind":"review-all","status":"success-with-warning","exitCode":0,"reasonCode":"success-with-warning","message":"review-all completed with warnings","hint":"inspect delivery phase log","scope":"differential","base":"main","target":"HEAD","dirtyTrackedIncluded":true,"untrackedIncluded":false,"phases":[{"phase":"security","status":"success"},{"phase":"delivery","status":"success-with-warning"},{"phase":"quality","status":"success"}],"outputs":["review-HEAD.md","delivery-review-HEAD.md"]}
JSON
echo 'review-all succeeded with warning'
exit 0
`);
  chmodSync(reviewAllScript, 0o755);
  selections.push("review all changes", "changed files vs default branch", "job status");
  await handler("", ctx);
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=success-with-warning/.test(readFileSync(statusPath, "utf-8")), 10000));
  await handler("", ctx);
  const structuredWarningStatus = messages.filter((message) => message.customType === "edc-job-status").at(-1);
  assert.match(structuredWarningStatus.content, /status: success-with-warning/);
  assert.match(structuredWarningStatus.content, /code: success-with-warning/);
  assert.match(structuredWarningStatus.content, /reason: review-all completed with warnings/);
  assert.match(structuredWarningStatus.content, /hint: inspect delivery phase log/);
  assert.match(structuredWarningStatus.content, /outputs: review-HEAD\.md, delivery-review-HEAD\.md/);
  assert.match(structuredWarningStatus.content, /scope: differential/);
  assert.match(structuredWarningStatus.content, /base: main/);
  assert.match(structuredWarningStatus.content, /target: HEAD/);
  assert.match(structuredWarningStatus.content, /dirty tracked files: included/);
  assert.match(structuredWarningStatus.content, /untracked files: excluded/);

  writeFileSync(reviewAllScript, `#!/usr/bin/env bash
set -euo pipefail
mkdir -p .git/edc
cat > .git/edc/result.json <<'JSON'
{"schemaVersion":1,"kind":"review-all","status":"failed","exitCode":1,"reasonCode":"delivery-report-validation","message":"delivery review report validation failed","hint":"inspect delivery review output","failedPhase":"delivery","childResult":"edc-context/build/review-all-delivery.json","phases":[{"phase":"security","status":"success"},{"phase":"delivery","status":"failed","reasonCode":"delivery-report-validation"}]}
JSON
echo 'review-all failed in delivery phase'
exit 1
`);
  chmodSync(reviewAllScript, 0o755);
  selections.push("review all changes", "changed files vs default branch", "job status");
  await handler("", ctx);
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=failed/.test(readFileSync(statusPath, "utf-8")) && /failed_phase=delivery/.test(readFileSync(statusPath, "utf-8")), 10000));
  await handler("", ctx);
  const structuredPhaseFailureStatus = messages.filter((message) => message.customType === "edc-job-status").at(-1);
  assert.match(structuredPhaseFailureStatus.content, /failed phase: delivery/);
  assert.match(structuredPhaseFailureStatus.content, /code: delivery-report-validation/);
  assert.match(structuredPhaseFailureStatus.content, /reason: delivery review report validation failed/);
  assert.match(structuredPhaseFailureStatus.content, /hint: inspect delivery review output/);
  assert.match(structuredPhaseFailureStatus.content, /child result: edc-context\/build\/review-all-delivery\.json/);

  writeFileSync(reviewScript, `#!/usr/bin/env bash
set -euo pipefail
echo 'ERROR: script did not produce review tasks. Output:' >&2
echo 'ERROR: no changed files found for target: HEAD' >&2
echo 'HINT: review uses committed diff plus dirty tracked files; commit changes, modify a tracked file, or choose another target/base.' >&2
exit 1
`);
  chmodSync(reviewScript, 0o755);
  selections.push("security review", "changed files vs default branch", "job status");
  await handler("", ctx);
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=failed/.test(readFileSync(statusPath, "utf-8")) && /no changed files/.test(readFileSync(statusPath, "utf-8")), 10000));
  await handler("", ctx);
  const noChangesStatus = messages.filter((message) => message.customType === "edc-job-status").at(-1);
  assert.match(noChangesStatus.content, /reason: no changed files found for review/);
  assert.match(noChangesStatus.content, /hint: review uses committed diff plus dirty tracked files/);

  const oldStartedAt = new Date(Date.now() - 120000).toISOString().replace(/\.\d{3}Z$/, "Z");
  writeFileSync(statusPath, [
    "kind=review",
    "status=running",
    `started_at=${oldStartedAt}`,
    "run_id=stuck-starting",
    "pid=starting",
    "args=HEAD --base master",
    "log=.git/edc/review.log",
    "",
  ].join("\n"));
  selections.push("security review", "changed files vs default branch");
  const messagesBeforeRestart = messages.length;
  await handler("", ctx);
  const restartMessage = messages.slice(messagesBeforeRestart).find((message) => message.customType === "edc-background");
  assert.ok(restartMessage, "restart message should be emitted");
  assert.match(restartMessage.content, /Background EDC review started\./);
  assert.doesNotMatch(restartMessage.content, /already running/);
  assert.ok(
    await waitFor(() => existsSync(statusPath) && /status=(failed|success|success-with-warning|cancelled)/.test(readFileSync(statusPath, "utf-8")), 10000),
    "restarted background review should finish before temp repo cleanup",
  );
} finally {
  if (childPid) {
    try { process.kill(childPid, "SIGTERM"); } catch {}
  }
  rmSync(cwd, { recursive: true, force: true });
}
NODE
