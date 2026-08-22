#!/usr/bin/env node
import { appendFileSync, readFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { createInterface } from "node:readline";
import { constants } from "node:os";
import { SUBPROCESS_TERMINATION_GRACE_MS } from "./termination-policy.mjs";

const agent = process.env.STREAM_FILTER_AGENT || process.env.EDC_AGENT_CLI || "agent";
const model = process.env.STREAM_FILTER_MODEL || "";
const capture = process.env.STREAM_FILTER_CAPTURE || "";
let childToKill = null;
let commandTimer = null;
let escalationTimer = null;
let exiting = false;
let requestedExitCode = null;
let exited = false;

function signalExitCode(signal) {
  const signalNumber = signal ? constants.signals[signal] : 0;
  return signalNumber ? 128 + signalNumber : 1;
}

function childIsRunning() {
  return Boolean(childToKill?.pid) && childToKill.exitCode === null && childToKill.signalCode === null;
}

function clearLifecycleTimers() {
  if (commandTimer) clearTimeout(commandTimer);
  if (escalationTimer) clearTimeout(escalationTimer);
  commandTimer = null;
  escalationTimer = null;
}

function exitOnce(code) {
  if (exited) return;
  exited = true;
  clearLifecycleTimers();
  process.exit(code);
}

function finish(code, signal = "SIGTERM") {
  if (exiting) return;
  exiting = true;
  requestedExitCode = code;
  if (commandTimer) {
    clearTimeout(commandTimer);
    commandTimer = null;
  }
  if (!childIsRunning()) {
    exitOnce(code);
    return;
  }

  childToKill.kill(signal);
  escalationTimer = setTimeout(() => {
    if (childIsRunning()) childToKill.kill("SIGKILL");
  }, SUBPROCESS_TERMINATION_GRACE_MS);
}

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(signal, () => finish(signalExitCode(signal), signal));
}

function isCodexAuthFailure(text) {
  return /401 Unauthorized|Missing bearer|authentication token has been invalidated|token_invalidated|session has ended|app_session_terminated|Failed to refresh token/.test(text);
}

function isModelRejection(text) {
  const lower = String(text).toLowerCase();
  return /model.*not found|model.*not supported|unsupported model|unknown model|invalid model|model_not_found/.test(lower);
}

function printCodexAuthFailure() {
  console.error("ERROR: Codex authentication failed. Run 'codex logout && codex login' for ChatGPT OAuth, or pipe an API key with 'codex login --with-api-key'.");
}

function printAgentModelListHint() {
  switch (agent) {
    case "pi": {
      const search = model ? spawnSync("pi", ["--list-models", model], { encoding: "utf8" }) : { stdout: "" };
      const all = search.stdout ? search : spawnSync("pi", ["--list-models"], { encoding: "utf8" });
      const output = all.stdout || all.stderr || "";
      if (output) {
        console.error(`available pi models matching '${model}' (or all models if no exact search result):`);
        console.error(output.split(/\r?\n/).slice(0, 80).join("\n"));
      } else {
        console.error("could not fetch pi models. run: pi --list-models");
      }
      break;
    }
    case "codex":
      console.error("Codex CLI does not expose a stable model-list command in this version. Run 'codex --help', omit --model to use the backend default, or choose a model supported by your Codex auth mode.");
      break;
    case "claude":
      console.error("Claude CLI does not expose a stable model-list command in this version. Run 'claude --help', omit --model to use the backend default, or use a supported alias/full model name.");
      break;
    default:
      console.error(`omit --model to use the backend default, or choose a model supported by '${agent}'.`);
      break;
  }
}

function printModelRejection(message) {
  if (model) {
    console.error(`ERROR: model '${model}' was rejected by ${agent}: ${message}`);
    printAgentModelListHint();
  } else {
    console.error(`ERROR: model was rejected by ${agent}: ${message}`);
    console.error("hint: omit --model to use the backend default, or set EDC_BUILD_MODEL / EDC_REVIEW_MODEL to a supported model.");
  }
}

function firstValue(obj) {
  if (!obj || typeof obj !== "object") return "";
  const value = Object.values(obj)[0];
  return value == null ? "" : String(value).slice(0, 80);
}

function readableError(value) {
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value);
      return parsed?.error?.message || parsed?.message || value;
    } catch {
      return value;
    }
  }
  if (value && typeof value === "object") {
    return value.error?.message || value.message || JSON.stringify(value);
  }
  return String(value);
}

function handlePlain(line) {
  if (isCodexAuthFailure(line)) {
    printCodexAuthFailure();
    finish(86);
  }
  if (isModelRejection(line)) {
    printModelRejection(line);
    finish(87);
  }
}

function emitLine(value, stderr = false) {
  if (!value) return false;
  (stderr ? process.stderr : process.stdout).write(`${value}\n`);
  return true;
}

function handleEvent(event) {
  if (event.type === "assistant") {
    const content = Array.isArray(event.message?.content) ? event.message.content : [];
    const text = content.filter((item) => item?.type === "text").map((item) => item.text || "").join("");
    if (emitLine(text)) return;
    const tool = content.find((item) => item?.type === "tool_use");
    if (tool) emitLine(`→ ${tool.name}(${firstValue(tool.input)})`);
    return;
  }

  if (event.type === "tool_call" && event.subtype === "started") {
    const [name, value] = Object.entries(event.tool_call || {})[0] || [];
    if (name) emitLine(`→ ${name}(${firstValue(value?.args || {})})`);
    return;
  }

  if (event.type === "result" && event.is_error === true) {
    const message = readableError(event.result ?? "unknown error");
    if (isModelRejection(message)) {
      printModelRejection(message);
      finish(87);
    }
    emitLine(`ERROR (subprocess): ${message}`, true);
    return;
  }

  if (event.type === "message_update" && event.assistantMessageEvent?.type === "text_delta") {
    emitLine(event.assistantMessageEvent.delta || "");
    return;
  }
  if (event.type === "tool_execution_start") {
    emitLine(`→ ${event.toolName}(${firstValue(event.args || {})})`);
    return;
  }
  if (event.type === "tool_execution_end" && event.isError === true) {
    const result = event.result?.content ?? event.result?.error ?? event.result ?? "tool execution failed";
    const message = `ERROR (subprocess): ${String(result)}`;
    if (isModelRejection(message)) {
      printModelRejection(message);
      finish(87);
    }
    emitLine(message, true);
    return;
  }
  if (event.type === "auto_retry_end" && event.success === false) {
    const message = `ERROR (subprocess): ${event.finalError || "provider request failed"}`;
    if (isModelRejection(message)) {
      printModelRejection(message);
      finish(87);
    }
    emitLine(message, true);
    return;
  }

  const msg = event.msg || {};
  if (msg.type === "agent_message") {
    emitLine(msg.message || "");
    return;
  }
  if (msg.type === "agent_reasoning") {
    emitLine(`… ${msg.text || ""}`);
    return;
  }
  if (msg.type === "exec_command_begin") {
    emitLine(`→ ${(Array.isArray(msg.command) ? msg.command.join(" ") : "").slice(0, 120)}`);
    return;
  }
  if (event.type === "error" || msg.type === "error") {
    const message = readableError(event.type === "error" ? (event.message ?? event.error ?? "unknown error") : (msg.message ?? "unknown error"));
    if (isCodexAuthFailure(message)) {
      printCodexAuthFailure();
      finish(86);
    }
    if (isModelRejection(message)) {
      printModelRejection(message);
      finish(87);
    }
    emitLine(`ERROR (subprocess): ${message}`, true);
  }
}

function processLine(line) {
  if (!line) return;
  if (capture) appendFileSync(capture, `${line}\n`);
  if (!line.startsWith("{")) {
    handlePlain(line);
    return;
  }
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    handlePlain(line);
    return;
  }
  handleEvent(event);
}

function filterStdin() {
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on("line", processLine);
  rl.on("close", () => finish(0));
}

function runCommand() {
  const args = process.argv.slice(3);
  const separator = args.indexOf("--");
  if (separator < 2) {
    console.error("usage: stream-filter.mjs --run <timeout-seconds> <phase> -- <command> [...]");
    process.exit(64);
  }
  const timeoutSeconds = Number(args[0]);
  const phase = args[1];
  const command = args.slice(separator + 1);
  if (command.length === 0) {
    console.error("ERROR: missing command");
    process.exit(64);
  }

  childToKill = spawn(command[0], command.slice(1), { stdio: ["pipe", "pipe", "pipe"] });
  const stdinText = process.env.EDC_STREAM_STDIN_FILE ? readFileSync(process.env.EDC_STREAM_STDIN_FILE, "utf8") : (process.env.EDC_STREAM_STDIN || "");
  childToKill.stdin.end(stdinText);
  commandTimer = setTimeout(() => {
    console.error(`ERROR: phase '${phase}' timed out after ${timeoutSeconds}s`);
    finish(1);
  }, timeoutSeconds * 1000);

  createInterface({ input: childToKill.stdout, crlfDelay: Infinity }).on("line", processLine);
  createInterface({ input: childToKill.stderr, crlfDelay: Infinity }).on("line", processLine);

  childToKill.on("error", (error) => {
    if (commandTimer) clearTimeout(commandTimer);
    commandTimer = null;
    console.error(`ERROR: ${error.message}`);
    if (!exiting) finish(1);
    else if (!childIsRunning()) exitOnce(requestedExitCode ?? 1);
  });
  childToKill.on("exit", () => {
    if (exiting) {
      childToKill.stdout.destroy();
      childToKill.stderr.destroy();
    }
  });
  childToKill.on("close", (code, signal) => {
    const finalCode = exiting
      ? (requestedExitCode ?? 1)
      : (typeof code === "number" ? code : signalExitCode(signal));
    exitOnce(finalCode);
  });
}

if (process.argv[2] === "--run") runCommand();
else filterStdin();
