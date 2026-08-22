#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { constants } from "node:os";
import { SUBPROCESS_TERMINATION_GRACE_MS } from "./termination-policy.mjs";

const SUCCESS_STOP_REASONS = new Set(["stop"]);
const cmd = process.argv.slice(2);

if (cmd.length === 0) {
  process.stderr.write("ERROR: missing pi command\n");
  process.exit(2);
}

let child = spawn(cmd[0], cmd.slice(1), {
  stdio: ["ignore", "pipe", "pipe"],
});
let exiting = false;
let requestedExitCode = null;
let escalationTimer = null;
let exited = false;

function errorText(value) {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    for (const key of ["errorMessage", "message", "error"]) {
      if (value[key]) return errorText(value[key]);
    }
    try {
      return JSON.stringify(value, Object.keys(value).sort());
    } catch {
      return String(value);
    }
  }
  return String(value);
}

function finalAssistant(messages) {
  if (!Array.isArray(messages)) return undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message && typeof message === "object" && message.role === "assistant") return message;
  }
  return undefined;
}

function classifyAgentEnd(event) {
  const assistant = finalAssistant(event.messages);
  if (!assistant) return { ok: false, reason: "agent_end did not include a final assistant message" };

  if (assistant.errorMessage) return { ok: false, reason: errorText(assistant.errorMessage) };

  const stopReason = assistant.stopReason;
  if (!SUCCESS_STOP_REASONS.has(stopReason)) {
    return { ok: false, reason: `agent_end stopReason was ${stopReason || "missing"}` };
  }

  return { ok: true, reason: "" };
}

function plaintextFatalReason(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return "";
  if (/^No API key found for\b/.test(trimmed)) return trimmed;
  if (/^Use \/login to log into a provider\b/.test(trimmed)) return trimmed;
  return "";
}

function signalExitCode(signal) {
  const signalNumber = signal ? constants.signals[signal] : 0;
  return signalNumber ? 128 + signalNumber : 1;
}

function childIsRunning() {
  return Boolean(child?.pid) && child.exitCode === null && child.signalCode === null;
}

function exitOnce(code) {
  if (exited) return;
  exited = true;
  if (escalationTimer) clearTimeout(escalationTimer);
  escalationTimer = null;
  process.exit(code);
}

function stopChild(signal) {
  if (!childIsRunning()) return false;
  child.kill(signal);
  escalationTimer = setTimeout(() => {
    if (childIsRunning()) child.kill("SIGKILL");
  }, SUBPROCESS_TERMINATION_GRACE_MS);
  return true;
}

function finish(code, signal = "SIGTERM") {
  if (exiting) return;
  exiting = true;
  requestedExitCode = code;
  if (!stopChild(signal)) exitOnce(code);
}

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(signal, () => finish(signalExitCode(signal), signal));
}

child.stderr.on("data", (chunk) => {
  const text = chunk.toString();
  const reason = plaintextFatalReason(text);
  if (reason) {
    process.stderr.write(`ERROR: pi subprocess: ${reason}\n`);
    finish(1);
    return;
  }
  process.stdout.write(chunk);
});

const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
lines.on("line", (line) => {
  const reason = plaintextFatalReason(line);
  if (reason) {
    process.stderr.write(`ERROR: pi subprocess: ${reason}\n`);
    finish(1);
    return;
  }

  process.stdout.write(`${line}\n`);
  if (line.length === 0) return;

  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return;
  }

  if (event.type === "error") {
    process.stderr.write(`ERROR: pi subprocess: ${errorText(event.error || event)}\n`);
    finish(1);
    return;
  }

  if (event.type === "agent_end") {
    // Pi emits agent_end before its built-in provider retry begins.
    if (event.willRetry === true) return;

    const result = classifyAgentEnd(event);
    if (!result.ok) {
      process.stderr.write(`ERROR: pi subprocess: ${result.reason}\n`);
      finish(1);
      return;
    }
    finish(0);
  }
});

child.on("error", (error) => {
  process.stderr.write(`ERROR: pi subprocess: ${error.message}\n`);
  if (!exiting) finish(1);
  else if (!childIsRunning()) exitOnce(requestedExitCode ?? 1);
});

child.on("exit", () => {
  if (exiting) {
    child.stdout.destroy();
    child.stderr.destroy();
  }
});

child.on("close", (code, signal) => {
  if (exiting) {
    exitOnce(requestedExitCode ?? 1);
    return;
  }
  if (typeof code === "number" && code !== 0) {
    exitOnce(code);
    return;
  }
  if (signal) {
    exitOnce(signalExitCode(signal));
    return;
  }
  process.stderr.write("ERROR: pi subprocess ended without successful agent_end\n");
  exitOnce(1);
});
