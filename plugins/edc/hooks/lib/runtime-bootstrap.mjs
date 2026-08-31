#!/usr/bin/env node
import { existsSync, mkdirSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { constants } from "node:os";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { preflightRuntimeSource, RUNTIME_MANIFEST, sourcePathFor } from "./runtime-manifest.mjs";
import { RUNTIME_BOOTSTRAP_TERMINATION_GRACE_MS } from "./termination-policy.mjs";

const ALLOWED_ORCHESTRATORS = new Set([
  "edc-audit.sh",
  "edc-build.sh",
  "edc-delivery-review.sh",
  "edc-doctor.sh",
  "edc-review-all.sh",
  "edc-review.sh",
  "edc-update.sh",
]);

function structured(reasonCode, message, hint, details = {}, exitCode = 1) {
  return {
    schemaVersion: 1,
    status: "failed",
    reasonCode,
    message,
    hint,
    details,
    exitCode,
  };
}

function trustedSourceRoots() {
  const modulePath = fileURLToPath(import.meta.url);
  const sourceRoot = dirname(dirname(dirname(realpathSync(modulePath))));
  const invokedPath = process.argv[1] ? resolve(process.argv[1]) : modulePath;
  const invokedSourceRoot = dirname(dirname(dirname(invokedPath)));
  return { sourceRoot, invokedSourceRoot };
}

function isAllowedSourceRoot(sourceRoot, invokedSourceRoot) {
  if (basename(sourceRoot) !== ".edc" && basename(invokedSourceRoot) !== ".edc") return true;
  const home = process.env.HOME;
  if (!home) return false;
  try {
    return realpathSync(resolve(home, ".edc")) === sourceRoot;
  } catch {
    return false;
  }
}

function writeStructuredResult(result) {
  const resultFile = process.env.EDC_RESULT_FILE;
  if (!resultFile) return;

  const destination = resolve(resultFile);
  const temporary = `${destination}.bootstrap.${process.pid}.${randomUUID()}`;
  try {
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { flag: "wx", mode: 0o600 });
    renameSync(temporary, destination);
  } catch {
    rmSync(temporary, { force: true });
  }
}

function fail(result) {
  writeStructuredResult(result);
  process.stderr.write(`${JSON.stringify(result)}\n`);
  process.exit(result.exitCode || 1);
}

const [scriptName, ...scriptArgs] = process.argv.slice(2);
if (!ALLOWED_ORCHESTRATORS.has(scriptName)) {
  fail(structured(
    "runtime-validation-failed",
    "trusted runtime bootstrap rejected an unknown orchestrator",
    "invoke EDC through a supported command wrapper",
    { scriptName: scriptName || "" },
    64,
  ));
}

const projectRoot = process.cwd();
const { sourceRoot, invokedSourceRoot } = trustedSourceRoots();
if (!isAllowedSourceRoot(sourceRoot, invokedSourceRoot)) {
  fail(structured(
    "runtime-validation-failed",
    "repo-local EDC runtime execution is unsupported",
    "invoke EDC through the trusted package or ~/.edc/scripts/edc",
    { sourceRoot },
  ));
}
try {
  preflightRuntimeSource(sourceRoot);
} catch (error) {
  fail(error.result || structured(
    "runtime-validation-failed",
    error.message || "trusted runtime preflight failed",
    "reinstall EDC from a trusted package and retry",
  ));
}

const scriptArtifact = RUNTIME_MANIFEST.artifacts.find(
  (artifact) => artifact.destination === `.edc/scripts/${scriptName}`,
);
const trustedScript = scriptArtifact ? sourcePathFor(sourceRoot, scriptArtifact) : "";
if (!trustedScript || !existsSync(trustedScript)) {
  fail(structured(
    "runtime-install-incomplete",
    "trusted orchestrator source is missing",
    "reinstall EDC from a complete trusted package and retry",
    { missingPath: scriptArtifact?.source || `scripts/${scriptName}` },
  ));
}

const child = spawn("bash", [trustedScript, ...scriptArgs], {
  cwd: projectRoot,
  detached: true,
  env: process.env,
  stdio: "inherit",
});
const forwardedSignals = ["SIGTERM", "SIGINT", "SIGHUP"];
let requestedSignal = "";

function signalChildGroup(signal) {
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}

const signalHandlers = new Map(forwardedSignals.map((signal) => [signal, () => {
  if (requestedSignal) return;
  requestedSignal = signal;
  signalChildGroup(signal);
  setTimeout(() => {
    signalChildGroup("SIGKILL");
    removeSignalHandlers();
    process.exit(128 + constants.signals[signal]);
  }, RUNTIME_BOOTSTRAP_TERMINATION_GRACE_MS);
}]));
for (const [signal, handler] of signalHandlers) process.on(signal, handler);

function removeSignalHandlers() {
  for (const [signal, handler] of signalHandlers) process.off(signal, handler);
}

child.on("error", (error) => {
  removeSignalHandlers();
  fail(structured(
    "runtime-execution-failed",
    `could not execute trusted orchestrator: ${error.message}`,
    "verify bash is available, then retry",
    { scriptName, code: error.code || "unknown" },
  ));
});
child.on("close", (code, signal) => {
  if (requestedSignal) return;
  removeSignalHandlers();
  if (typeof code === "number") process.exit(code);
  const signalNumber = signal ? constants.signals[signal] : 0;
  process.exit(signalNumber ? 128 + signalNumber : 1);
});
