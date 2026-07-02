#!/usr/bin/env bash
# Pi review status should explain common background review failures.
set -euo pipefail

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import edcExtension from "./pi/index.mjs";

delete process.env.EDC_PI_SUBPROCESS;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate, timeoutMs = 3000) {
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

  const scriptsDir = join(cwd, ".edc", "scripts");
  mkdirSync(scriptsDir, { recursive: true });
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

  const selections = ["Review current branch vs default branch", "Job status"];
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
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=failed/.test(readFileSync(statusPath, "utf-8")), 3000));

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
  selections.push("Review current branch vs default branch", "Job status");
  const messagesBeforeStructuredStart = messages.length;
  await handler("", ctx);
  const structuredStart = messages.slice(messagesBeforeStructuredStart).find((message) => message.customType === "edc-background");
  assert.ok(structuredStart, "structured failure scenario should start a background review");
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=failed/.test(readFileSync(statusPath, "utf-8")) && /structured validation/.test(readFileSync(statusPath, "utf-8")), 3000));
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
  selections.push("Review current branch vs default branch", "Job status");
  await handler("", ctx);
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=success/.test(readFileSync(statusPath, "utf-8")), 3000));
  await handler("", ctx);
  const structuredSuccessStatus = messages.filter((message) => message.customType === "edc-job-status").at(-1);
  assert.match(structuredSuccessStatus.content, /final review: review-structured\.md/);

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
  selections.push("Review current branch vs default branch");
  const messagesBeforeRestart = messages.length;
  await handler("", ctx);
  const restartMessage = messages.slice(messagesBeforeRestart).find((message) => message.customType === "edc-background");
  assert.ok(restartMessage, "restart message should be emitted");
  assert.match(restartMessage.content, /Background EDC review started\./);
  assert.doesNotMatch(restartMessage.content, /already running/);
} finally {
  if (childPid) {
    try { process.kill(childPid, "SIGTERM"); } catch {}
  }
  rmSync(cwd, { recursive: true, force: true });
}
NODE
