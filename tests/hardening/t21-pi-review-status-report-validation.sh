#!/usr/bin/env bash
# Pi review status should classify report validation failures from review logs.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TRUSTED_PACKAGE="$TMP/trusted-package"
mkdir -p "$TRUSTED_PACKAGE/plugins"
cp -R "$ROOT/pi" "$TRUSTED_PACKAGE/pi"
cp -R "$ROOT/plugins/edc" "$TRUSTED_PACKAGE/plugins/edc"
cat >"$TRUSTED_PACKAGE/plugins/edc/scripts/edc-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "ERROR: report validation failed for module agent-wrappers" >&2
exit 1
EOF
chmod +x "$TRUSTED_PACKAGE/plugins/edc/scripts/edc-review.sh"

EDC_TEST_EXTENSION="$TRUSTED_PACKAGE/pi/index.mjs" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const { default: edcExtension } = await import(pathToFileURL(process.env.EDC_TEST_EXTENSION).href);

delete process.env.EDC_PI_SUBPROCESS;

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
async function waitFor(predicate, timeoutMs = 10000) {
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

  const messages = [];
  let handler;
  const pi = {
    on() {},
    registerCommand(_name, config) { handler = config.handler; },
    sendMessage(message) { messages.push(message); },
  };
  await edcExtension(pi);

  const selections = ["changes vs default branch", "security review", "job status"];
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
  assert.ok(await waitFor(() => existsSync(statusPath) && /status=failed/.test(readFileSync(statusPath, "utf-8"))));

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
