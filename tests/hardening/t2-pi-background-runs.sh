#!/usr/bin/env bash
# Pi background review status must survive edc-context cleanup during recovery.
set -euo pipefail

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import edcExtension from "./agents/pi/index.mjs";

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

const cwd = mkdtempSync(join(tmpdir(), "edc-pi-bg-runs-"));
let childPid = 0;
try {
  execFileSync("git", ["init", "-q"], { cwd });

  const scriptsDir = join(cwd, ".edc", "scripts");
  mkdirSync(scriptsDir, { recursive: true });
  const reviewScript = join(scriptsDir, "edc-review.sh");
  writeFileSync(reviewScript, `#!/usr/bin/env bash
set -euo pipefail
rm -rf edc-context AGENTS.md
sleep 1
echo "Verified: review-HEAD.md"
`);
  chmodSync(reviewScript, 0o755);

  const messages = [];
  let handler;
  const pi = {
    on() {},
    registerCommand(_name, config) {
      handler = config.handler;
    },
    sendMessage(message) {
      messages.push(message);
    },
  };
  await edcExtension(pi);
  assert.equal(typeof handler, "function", "extension should register /edc handler");

  const selections = ["Review current branch vs main", "Review status"];
  const ctx = {
    cwd,
    hasUI: true,
    ui: {
      select: async () => selections.shift(),
      confirm: async () => true,
    },
    model: { provider: "test", id: "model" },
  };

  await handler("", ctx);
  const started = messages.find((message) => message.customType === "edc-review-background");
  assert.ok(started, "review start message should be emitted");
  assert.match(started.content, /Background review started\./);
  assert.match(started.content, /Log: \.git\/edc\/review\.log/, "log path should be in git metadata");
  assert.match(started.content, /Status: \.git\/edc\/status/, "status path should not be inside edc-context or .edc");
  const pidMatch = started.content.match(/^PID: (\d+)$/m);
  childPid = pidMatch ? Number(pidMatch[1]) : 0;
  const statusPathMatch = started.content.match(/^Status: (.+)$/m);
  const logPathMatch = started.content.match(/^Log: (.+)$/m);
  assert.ok(statusPathMatch, "start message should include a status path");
  assert.ok(logPathMatch, "start message should include a log path");
  const statusPathFromMessage = join(cwd, statusPathMatch[1]);
  const logPathFromMessage = join(cwd, logPathMatch[1]);

  assert.ok(await waitFor(() => existsSync(statusPathFromMessage), 1000), "background wrapper should write initial status");
  assert.ok(await waitFor(() => existsSync(logPathFromMessage), 1000), "background wrapper should write review log");
  await waitFor(() => !existsSync(join(cwd, "edc-context")), 1000);

  await handler("", ctx);
  const status = messages.filter((message) => message.customType === "edc-review-status").at(-1);
  assert.ok(status, "review status message should be emitted");
  assert.match(status.content, /status: running/, "status should survive edc-context cleanup while review runs");

  assert.ok(await waitFor(() => /status=success/.test(readFileSync(statusPathFromMessage, "utf-8")), 3000));
  assert.match(readFileSync(logPathFromMessage, "utf-8"), /Verified: review-HEAD\.md/);
} finally {
  if (childPid) {
    try { process.kill(childPid, "SIGTERM"); } catch {}
  }
  rmSync(cwd, { recursive: true, force: true });
}
NODE
