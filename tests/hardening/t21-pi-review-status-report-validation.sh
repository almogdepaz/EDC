#!/usr/bin/env bash
# Pi review status should classify report validation failures from review logs.
set -euo pipefail

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import edcExtension from "./pi/index.mjs";

delete process.env.EDC_PI_SUBPROCESS;

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
async function waitFor(predicate, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(50);
  }
  return predicate();
}

const cwd = mkdtempSync(join(tmpdir(), "edc-pi-report-validation-"));
let childPid = 0;
try {
  execFileSync("git", ["init", "-q"], { cwd });
  const scriptsDir = join(cwd, ".edc", "scripts");
  mkdirSync(scriptsDir, { recursive: true });
  const reviewScript = join(scriptsDir, "edc-review.sh");
  writeFileSync(reviewScript, `#!/usr/bin/env bash
set -euo pipefail
echo "ERROR: report validation failed for module agent-wrappers" >&2
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

  const selections = ["Review current branch vs main", "Job status"];
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
  assert.match(status.content, /reason: review report validation failed for module agent-wrappers/);
  assert.match(status.content, /hint: inspect the module reviewer output in the log/);
} finally {
  if (childPid) {
    try { process.kill(childPid, "SIGTERM"); } catch {}
  }
  rmSync(cwd, { recursive: true, force: true });
}
NODE
