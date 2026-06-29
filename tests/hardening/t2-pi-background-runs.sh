#!/usr/bin/env bash
# Pi background review status must survive edc-context cleanup during recovery.
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
  const statusPathFromMessage = join(cwd, ".git", "edc", "status");
  const logPathFromMessage = join(cwd, ".git", "edc", "review.log");

  assert.ok(await waitFor(() => existsSync(statusPathFromMessage), 1000), "background wrapper should write initial status in git metadata");
  assert.ok(await waitFor(() => existsSync(logPathFromMessage), 1000), "background wrapper should write review log in git metadata");
  assert.ok(!statusPathFromMessage.includes("edc-context"), "status path should not be inside edc-context");
  const pidMatch = readFileSync(statusPathFromMessage, "utf-8").match(/^pid=(\d+)$/m);
  childPid = pidMatch ? Number(pidMatch[1]) : 0;
  await waitFor(() => !existsSync(join(cwd, "edc-context")), 1000);

  await handler("", ctx);
  const status = messages.filter((message) => message.customType === "edc-job-status").at(-1);
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

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

const tmpBase = mkdtempSync(join(tmpdir(), "edc-pi-bg-quote-"));
let childPid = 0;
try {
  const mainRepo = join(tmpBase, "main$(touch pwned_marker)");
  const worktree = join(tmpBase, "wt");
  mkdirSync(mainRepo, { recursive: true });
  execFileSync("git", ["init", "-q"], { cwd: mainRepo });
  execFileSync("git", ["config", "user.email", "a@example.com"], { cwd: mainRepo });
  execFileSync("git", ["config", "user.name", "a"], { cwd: mainRepo });
  execFileSync("git", ["config", "commit.gpgsign", "false"], { cwd: mainRepo });
  writeFileSync(join(mainRepo, "tracked.txt"), "x\n");
  execFileSync("git", ["add", "tracked.txt"], { cwd: mainRepo });
  execFileSync("git", ["commit", "-q", "-m", "init"], { cwd: mainRepo });
  execFileSync("git", ["worktree", "add", "-q", worktree, "HEAD"], { cwd: mainRepo });

  const scriptsDir = join(worktree, ".edc", "scripts");
  mkdirSync(scriptsDir, { recursive: true });
  const reviewScript = join(scriptsDir, "edc-review.sh");
  writeFileSync(reviewScript, `#!/usr/bin/env bash
set -euo pipefail
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

  const ctx = {
    cwd: worktree,
    hasUI: true,
    ui: {
      select: async () => "Review current branch vs default branch",
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
  const statusPathDisplay = execFileSync("git", ["rev-parse", "--git-path", "edc/status"], { cwd: worktree, encoding: "utf-8" }).trim();
  const statusPath = statusPathDisplay.startsWith("/") ? statusPathDisplay : join(worktree, statusPathDisplay);
  assert.ok(await waitFor(() => existsSync(statusPath), 1000), "background wrapper should write initial status");
  const pidMatch = readFileSync(statusPath, "utf-8").match(/^pid=(\d+)$/m);
  childPid = pidMatch ? Number(pidMatch[1]) : 0;

  const markerPath = join(worktree, "pwned_marker");
  await waitFor(() => existsSync(markerPath), 1000);
  assert.equal(existsSync(markerPath), false, "git-path display strings must not execute shell command substitution");
} finally {
  if (childPid) {
    try { process.kill(childPid, "SIGTERM"); } catch {}
  }
  rmSync(tmpBase, { recursive: true, force: true });
}
NODE
