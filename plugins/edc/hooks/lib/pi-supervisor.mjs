#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

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

function stopChild() {
  if (!child || child.killed || child.exitCode !== null || child.signalCode !== null) return;
  child.kill("SIGTERM");
  setTimeout(() => {
    if (child && child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  }, 5000).unref();
}

function finish(code) {
  if (exiting) return;
  exiting = true;
  stopChild();
  process.exit(code);
}

function handleSignal(signal) {
  stopChild();
  process.exit(128 + signal);
}

process.on("SIGTERM", () => handleSignal(15));
process.on("SIGINT", () => handleSignal(2));

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
  finish(1);
});

child.on("close", (code) => {
  if (exiting) return;
  if (code && code !== 0) process.exit(code);
  process.stderr.write("ERROR: pi subprocess ended without successful agent_end\n");
  process.exit(1);
});
