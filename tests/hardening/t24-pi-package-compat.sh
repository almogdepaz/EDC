#!/usr/bin/env bash
# t24-pi-package-compat: smoke-test EDC loading beside common pi package styles.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import edcExtension from "./pi/index.mjs";

function makeFakePi() {
  const events = new Map();
  const calls = {
    commands: [],
    messages: [],
    providers: [],
    tools: [],
  };
  const api = {
    on(name, handler) {
      const handlers = events.get(name) || [];
      handlers.push(handler);
      events.set(name, handlers);
    },
    registerCommand(name, options) {
      calls.commands.push({ name, options });
    },
    registerProvider(name, provider) {
      calls.providers.push({ name, provider });
    },
    registerTool(name, tool) {
      calls.tools.push({ name, tool });
    },
    sendMessage(message) {
      calls.messages.push(message);
    },
  };
  async function emit(name, event, ctx) {
    const results = [];
    for (const handler of events.get(name) || []) {
      results.push(await handler(event, ctx));
    }
    return results;
  }
  return { api, calls, events, emit };
}

async function fakeProviderPackage(pi) {
  pi.registerProvider("compat-provider", {
    listModels: async () => [{ id: "compat-model" }],
  });
  pi.on("session_start", async (event) => {
    event.providerSawSession = true;
  });
}

async function fakeContextPrunePackage(pi, skillDir) {
  pi.on("resources_discover", async () => ({ skillPaths: [skillDir] }));
  pi.on("tool_call", async (event) => {
    event.input = { ...(event.input || {}), contextPruneSawToolCall: true };
  });
}

function makeRepo(mode) {
  const cwd = mkdtempSync(join(tmpdir(), `edc-pi-compat-${mode}-`));
  mkdirSync(join(cwd, "edc-context", "modules"), { recursive: true });
  writeFileSync(join(cwd, "edc-context", "index.md"), "# Repo Index\n## Module Map\n- src-mod\n");
  writeFileSync(join(cwd, "edc-context", "modules", "src-mod.md"), "# src-mod docs\n");
  writeFileSync(join(cwd, "edc-context", "manifest.json"), JSON.stringify({
    schemaVersion: 2,
    policy: { defaultMode: mode },
    modules: [
      { name: "src-mod", priority: 50, match: { prefixes: ["src/"] }, doc: "edc-context/modules/src-mod.md" },
    ],
  }, null, 2));
  execFileSync("git", ["init", "-q"], { cwd });
  execFileSync("git", ["config", "user.email", "a@example.com"], { cwd });
  execFileSync("git", ["config", "user.name", "a"], { cwd });
  execFileSync("git", ["add", "edc-context"], { cwd });
  execFileSync("git", ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], { cwd });
  const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd, encoding: "utf-8" }).trim();
  const manifestPath = join(cwd, "edc-context", "manifest.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf-8"));
  manifest.sourceCommit = head;
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  return cwd;
}

async function loadStack(order, mode) {
  delete process.env.EDC_PI_SUBPROCESS;
  const cwd = makeRepo(mode);
  const fakePi = makeFakePi();
  const pruneSkill = join(cwd, "context-prune-skill");
  mkdirSync(pruneSkill, { recursive: true });
  writeFileSync(join(pruneSkill, "SKILL.md"), "# context prune\n");

  for (const name of order) {
    if (name === "provider") await fakeProviderPackage(fakePi.api);
    if (name === "context-prune") await fakeContextPrunePackage(fakePi.api, pruneSkill);
    if (name === "edc") await edcExtension(fakePi.api);
  }

  return { cwd, pruneSkill, ...fakePi };
}

function flattenSkillPaths(results) {
  return results.flatMap((result) => Array.isArray(result?.skillPaths) ? result.skillPaths : []);
}

async function assertCompatible(order, mode) {
  const stack = await loadStack(order, mode);
  try {
    assert.deepEqual(stack.calls.commands.map((command) => command.name).sort(), ["edc"]);
    assert.deepEqual(stack.calls.providers.map((provider) => provider.name), ["compat-provider"]);
    assert.deepEqual(stack.calls.tools, [], "EDC must not register or override shared tools");

    const skillPaths = flattenSkillPaths(await stack.emit("resources_discover", { type: "resources_discover" }, { cwd: stack.cwd }));
    const skillNames = skillPaths.map((path) => path.split("/").pop()).sort();
    assert.deepEqual(skillNames, ["context-prune-skill", "edc-audit", "edc-review"]);

    const sessionEvent = { type: "session_start" };
    const sessionId = `t24-${mode}-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const ctx = {
      cwd: stack.cwd,
      hasUI: false,
      sessionManager: { getSessionId: () => sessionId },
    };
    const beforeSessionMessages = stack.calls.messages.length;
    await stack.emit("session_start", sessionEvent, ctx);
    assert.equal(sessionEvent.providerSawSession, true, "provider package should still receive session_start");

    const sessionMessages = stack.calls.messages.slice(beforeSessionMessages)
      .filter((message) => message.customType === "edc-session-context");
    assert.equal(sessionMessages.length, mode === "inject" ? 1 : 0);

    const toolEvent = { type: "tool_call", toolName: "edit", input: { file_path: "src/foo.ts" } };
    const beforeToolMessages = stack.calls.messages.length;
    await stack.emit("tool_call", toolEvent, ctx);
    assert.equal(toolEvent.input.contextPruneSawToolCall, true, "context-prune package should still receive tool_call");

    const injectionMessages = stack.calls.messages.slice(beforeToolMessages)
      .filter((message) => message.customType === "edc-context-inject");
    assert.equal(injectionMessages.length, mode === "inject" ? 1 : 0);

    const bashEvent = {
      type: "tool_call",
      toolName: "bash",
      input: { command: "bash .edc/scripts/edc-review.sh --base main", timeout: 1200 },
    };
    await stack.emit("tool_call", bashEvent, ctx);
    assert.equal(bashEvent.input.contextPruneSawToolCall, true);
    assert.ok(bashEvent.input.timeout >= 7200, "EDC should only mutate bash timeout for EDC orchestrator calls");
  } finally {
    await stack.emit("session_shutdown", { type: "session_shutdown" }, { cwd: stack.cwd, hasUI: false });
    rmSync(stack.cwd, { recursive: true, force: true });
  }
}

await assertCompatible(["provider", "context-prune", "edc"], "advisory");
await assertCompatible(["edc", "provider", "context-prune"], "inject");

process.env.EDC_PI_SUBPROCESS = "1";
const subprocessStack = makeFakePi();
await edcExtension(subprocessStack.api);
assert.deepEqual(subprocessStack.calls.commands, []);
assert.equal(subprocessStack.events.size, 0, "nested pi subprocess must not load EDC recursively");

delete process.env.EDC_PI_SUBPROCESS;
NODE

echo "PASS: pi package compatibility smoke"
