#!/usr/bin/env bash
# Pi review status should classify provider websocket failures from nested pi subprocesses.
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

const cwd = mkdtempSync(join(tmpdir(), "edc-pi-provider-failure-"));
let childPid = 0;
try {
  execFileSync("git", ["init", "-q"], { cwd });
  const scriptsDir = join(cwd, ".edc", "scripts");
  mkdirSync(scriptsDir, { recursive: true });
  const reviewScript = join(scriptsDir, "edc-review.sh");
  writeFileSync(reviewScript, `#!/usr/bin/env bash
set -euo pipefail
echo "ERROR: pi subprocess: WebSocket closed 1006" >&2
echo "ERROR: edc-update invocation failed" >&2
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

  const selections = ["Security review current branch vs default branch", "Job status"];
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
  const statusPath = join(cwd, ".git", "edc", "status");
  const pidMatch = readFileSync(statusPath, "utf-8").match(/^pid=(\d+)$/m);
  childPid = pidMatch ? Number(pidMatch[1]) : 0;
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=failed/.test(readFileSync(statusPath, "utf-8")), 3000));

  await handler("", ctx);
  const status = messages.filter((message) => message.customType === "edc-job-status").at(-1);
  assert.ok(status, "job status message should be emitted");
  assert.match(status.content, /status: failed/);
  assert.match(status.content, /reason: pi provider websocket closed during background review/);
  assert.match(status.content, /hint: provider connection dropped while a nested pi subprocess was running/);
} finally {
  if (childPid) {
    try { process.kill(childPid, "SIGTERM"); } catch {}
  }
  rmSync(cwd, { recursive: true, force: true });
}
NODE
