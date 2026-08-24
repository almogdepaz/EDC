#!/usr/bin/env node
import { spawn } from "node:child_process";
import {
  closeSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { WORKER_PROCESS_GROUP_TERMINATION_GRACE_MS } from "./termination-policy.mjs";

function fail(message) {
  process.stderr.write(`ERROR: worker pool: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  let runner = "";
  let manifest = "";
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--runner") {
      runner = argv[index + 1] || "";
      index += 1;
    } else if (!manifest) {
      manifest = arg;
    } else {
      fail(`unexpected argument: ${arg}`);
    }
  }
  if (!runner) fail("--runner is required");
  if (!manifest) fail("task manifest path is required");
  return { runner: resolve(runner), manifest: resolve(manifest) };
}

function parseJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`);
  }
}

function rejectUnknownFields(value, allowed, label) {
  const unknown = Object.keys(value).filter((key) => !allowed.has(key));
  if (unknown.length > 0) fail(`${label} has unknown fields: ${unknown.join(", ")}`);
}

function pathWithin(parent, candidate) {
  const rel = relative(parent, candidate);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

function nearestExistingPath(path) {
  let current = path;
  while (!existsSync(current)) {
    const parent = dirname(current);
    if (parent === current) return current;
    current = parent;
  }
  return current;
}

function canonicalOwnershipPath(path, caseInsensitive) {
  const existing = nearestExistingPath(path);
  const unresolvedSuffix = relative(existing, path);
  const canonicalPath = resolve(realpathSync(existing), unresolvedSuffix);
  return caseInsensitive ? canonicalPath.normalize("NFC").toLowerCase() : canonicalPath;
}

function runDirIsCaseInsensitive(runDir) {
  let probeDir = "";
  let probeError = null;
  let cleanupError = null;
  let caseInsensitive = false;
  try {
    probeDir = mkdtempSync(join(runDir, ".edc-case-probe-"));
    writeFileSync(join(probeDir, "lowercase"), "probe\n");
    caseInsensitive = existsSync(join(probeDir, "LOWERCASE"));
  } catch (error) {
    probeError = error;
  } finally {
    if (probeDir) {
      try {
        rmSync(probeDir, { recursive: true });
      } catch (error) {
        cleanupError = error;
      }
    }
  }
  if (cleanupError) fail(`could not clean up runDir filesystem case probe: ${cleanupError.message}`);
  if (probeError) fail(`could not probe runDir filesystem case sensitivity: ${probeError.message}`);
  return caseInsensitive;
}

function validateRunPath(path, runDir, runDirReal, label, mustExist) {
  if (typeof path !== "string" || !isAbsolute(path)) fail(`${label} must be an absolute path`);
  if (path.includes("\n") || path.includes("\r")) fail(`${label} must not contain newlines`);
  const normalized = resolve(path);
  if (!pathWithin(runDir, normalized)) fail(`${label} is outside runDir: ${path}`);
  if (mustExist && !existsSync(normalized)) fail(`${label} does not exist: ${path}`);
  const existing = nearestExistingPath(normalized);
  const existingReal = realpathSync(existing);
  if (!pathWithin(runDirReal, existingReal)) fail(`${label} escapes runDir through a symlink: ${path}`);
  return normalized;
}

function validateManifest(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) fail("manifest must be an object");
  rejectUnknownFields(input, new Set(["schemaVersion", "runId", "runDir", "maxConcurrency", "tasks"]), "manifest");
  if (input.schemaVersion !== 1) fail("manifest schemaVersion must equal 1");
  if (typeof input.runId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(input.runId)) fail("manifest runId is invalid");
  if (typeof input.runDir !== "string" || !isAbsolute(input.runDir)) fail("manifest runDir must be absolute");
  const runDir = resolve(input.runDir);
  if (!existsSync(runDir) || !statSync(runDir).isDirectory()) fail(`manifest runDir does not exist: ${runDir}`);
  const runDirReal = realpathSync(runDir);
  if (!Number.isInteger(input.maxConcurrency) || input.maxConcurrency < 1 || input.maxConcurrency > 64) {
    fail("manifest maxConcurrency must be an integer from 1 to 64");
  }
  if (!Array.isArray(input.tasks) || input.tasks.length === 0) fail("manifest tasks must be a non-empty array");
  const caseInsensitive = runDirIsCaseInsensitive(runDir);

  const ids = new Set();
  const outputOwners = new Map();
  const tasks = input.tasks.map((task, index) => {
    const label = `tasks[${index}]`;
    if (!task || typeof task !== "object" || Array.isArray(task)) fail(`${label} must be an object`);
    rejectUnknownFields(task, new Set(["id", "phase", "module", "promptFile", "timeoutSeconds", "outputs", "failurePolicy"]), label);
    if (typeof task.id !== "string" || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(task.id)) fail(`${label}.id must be kebab-case`);
    if (ids.has(task.id)) fail(`duplicate task id: ${task.id}`);
    ids.add(task.id);
    if (typeof task.phase !== "string" || task.phase.length === 0 || /[\r\n]/.test(task.phase)) fail(`${label}.phase is invalid`);
    if (task.module !== undefined && (typeof task.module !== "string" || task.module.length === 0 || /[\r\n]/.test(task.module))) {
      fail(`${label}.module is invalid`);
    }
    if (!Number.isInteger(task.timeoutSeconds) || task.timeoutSeconds < 1) fail(`${label}.timeoutSeconds must be a positive integer`);
    const failurePolicy = task.failurePolicy || "fail-fast";
    if (!["fail-fast", "continue"].includes(failurePolicy)) fail(`${label}.failurePolicy must be fail-fast or continue`);
    if (!Array.isArray(task.outputs) || task.outputs.length === 0) fail(`${label}.outputs must be a non-empty array`);
    const promptFile = validateRunPath(task.promptFile, runDir, runDirReal, `${label}.promptFile`, true);
    const outputs = task.outputs.map((path, outputIndex) => validateRunPath(path, runDir, runDirReal, `${label}.outputs[${outputIndex}]`, false));
    if (new Set(outputs).size !== outputs.length) fail(`${label}.outputs contains duplicates`);
    outputs.forEach((output, outputIndex) => {
      const ownershipPath = canonicalOwnershipPath(output, caseInsensitive);
      const owner = outputOwners.get(ownershipPath);
      const declaredOutput = task.outputs[outputIndex];
      if (owner?.taskId === task.id) {
        fail(`${label}.outputs contains duplicates: ${owner.output} and ${declaredOutput}`);
      }
      if (owner) {
        fail(`output '${declaredOutput}' for task '${task.id}' conflicts with output '${owner.output}' for task '${owner.taskId}'`);
      }
      outputOwners.set(ownershipPath, { taskId: task.id, output: declaredOutput });
    });
    return { ...task, failurePolicy, promptFile, outputs };
  });

  return { ...input, runDir, tasks };
}

function writeJsonAtomic(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(temporary, path);
}

const { runner, manifest: manifestPath } = parseArgs(process.argv.slice(2));
if (!existsSync(runner) || !statSync(runner).isFile()) fail(`runner does not exist: ${runner}`);
const manifest = validateManifest(parseJson(manifestPath, "task manifest"));
const runDirReal = realpathSync(manifest.runDir);

function validProducedOutput(path) {
  try {
    return existsSync(path) && statSync(path).isFile() && pathWithin(runDirReal, realpathSync(path));
  } catch {
    return false;
  }
}

const startedAt = new Date();
const results = manifest.tasks.map((task) => ({
  id: task.id,
  phase: task.phase,
  ...(task.module ? { module: task.module } : {}),
  status: "queued",
  exitCode: null,
  signal: null,
  startedAt: null,
  finishedAt: null,
  durationMs: null,
  outputs: task.outputs,
}));

let nextIndex = 0;
let stopping = false;
let stageReason = "";
let finalized = false;
const active = new Map();

function terminateProcessGroup(child, signal = "SIGTERM") {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}

function requestStop(reason, exceptIndex = -1) {
  if (!stopping) {
    stopping = true;
    stageReason = reason;
    for (let index = nextIndex; index < results.length; index += 1) results[index].status = "cancelled";
    nextIndex = results.length;
  }
  for (const [index, running] of active) {
    if (index === exceptIndex) continue;
    running.cancellationRequested = true;
    terminateProcessGroup(running.child);
    running.killTimer = setTimeout(
      () => terminateProcessGroup(running.child, "SIGKILL"),
      WORKER_PROCESS_GROUP_TERMINATION_GRACE_MS,
    );
    running.killTimer.unref();
  }
}

function finishStage() {
  if (finalized || active.size > 0 || (!stopping && nextIndex < manifest.tasks.length)) return;
  finalized = true;
  const finishedAt = new Date();
  const successful = results.every((result) => result.status === "success");
  const stage = {
    schemaVersion: 1,
    kind: "worker-stage-result",
    runId: manifest.runId,
    status: successful ? "success" : "failed",
    reason: successful ? "" : stageReason || "one or more workers failed",
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationMs: finishedAt.getTime() - startedAt.getTime(),
    tasks: results,
  };
  writeJsonAtomic(join(manifest.runDir, "stage-result.json"), stage);
  if (successful) {
    process.stdout.write(`worker pool: ${results.length} task(s) completed\n`);
    process.exitCode = 0;
  } else {
    process.stderr.write(`ERROR: worker pool: ${stage.reason}\n`);
    process.exitCode = 1;
  }
}

function launch(index) {
  const task = manifest.tasks[index];
  const result = results[index];
  const taskDir = join(manifest.runDir, "tasks", task.id);
  mkdirSync(taskDir, { recursive: true });
  const taskFile = join(taskDir, "task.json");
  writeJsonAtomic(taskFile, {
    schemaVersion: 1,
    runId: manifest.runId,
    runDir: manifest.runDir,
    ...task,
  });
  const stdoutPath = join(taskDir, "stdout.log");
  const stderrPath = join(taskDir, "stderr.log");
  const stdoutFd = openSync(stdoutPath, "w");
  const stderrFd = openSync(stderrPath, "w");
  const launchedAt = new Date();
  result.status = "running";
  result.startedAt = launchedAt.toISOString();

  const child = spawn(runner, [taskFile], {
    cwd: process.cwd(),
    detached: true,
    env: {
      ...process.env,
      EDC_RUN_ID: manifest.runId,
      EDC_TASK_ID: task.id,
      EDC_TASK_PHASE: task.phase,
      EDC_SPAWN_LOG: join(manifest.runDir, "spawn-log.jsonl"),
      EDC_TRANSCRIPT_DIR: join(manifest.runDir, "transcripts"),
      ...(task.module ? { EDC_TASK_MODULE: task.module } : {}),
    },
    stdio: ["ignore", stdoutFd, stderrFd],
  });
  const running = { child, stdoutFd, stderrFd, cancellationRequested: false, killTimer: null, timeoutTimer: null };
  active.set(index, running);

  running.timeoutTimer = setTimeout(() => {
    if (!active.has(index)) return;
    result.status = "timed-out";
    stageReason = `task ${task.id} timed out after ${task.timeoutSeconds}s`;
    if (task.failurePolicy === "fail-fast") requestStop(stageReason, index);
    terminateProcessGroup(child);
    running.killTimer = setTimeout(
      () => terminateProcessGroup(child, "SIGKILL"),
      WORKER_PROCESS_GROUP_TERMINATION_GRACE_MS,
    );
    running.killTimer.unref();
  }, task.timeoutSeconds * 1000);

  child.on("error", (error) => {
    if (!active.has(index)) return;
    result.status = "failed";
    stageReason = `task ${task.id} could not start: ${error.message}`;
    if (task.failurePolicy === "fail-fast") requestStop(stageReason, index);
  });

  child.on("close", (code, signal) => {
    const current = active.get(index);
    if (!current) return;
    clearTimeout(current.timeoutTimer);
    if (current.killTimer) clearTimeout(current.killTimer);
    closeSync(current.stdoutFd);
    closeSync(current.stderrFd);
    active.delete(index);
    const finishedAt = new Date();
    result.finishedAt = finishedAt.toISOString();
    result.durationMs = finishedAt.getTime() - launchedAt.getTime();
    result.exitCode = code;
    result.signal = signal;

    if (result.status === "timed-out" || result.status === "failed") {
      // Preserve classifications assigned before close.
    } else if (current.cancellationRequested) {
      result.status = "cancelled";
    } else if (code === 0) {
      const missingOutputs = task.outputs.filter((path) => !validProducedOutput(path));
      if (missingOutputs.length === 0) {
        result.status = "success";
      } else {
        result.status = "failed";
        stageReason = `task ${task.id} did not produce declared output: ${missingOutputs.join(", ")}`;
        if (task.failurePolicy === "fail-fast") requestStop(stageReason, index);
      }
    } else {
      result.status = "failed";
      stageReason = `task ${task.id} exited ${code === null ? `on ${signal}` : `with code ${code}`}`;
      if (task.failurePolicy === "fail-fast") requestStop(stageReason, index);
    }

    schedule();
  });
}

function schedule() {
  while (!stopping && active.size < manifest.maxConcurrency && nextIndex < manifest.tasks.length) {
    const index = nextIndex;
    nextIndex += 1;
    launch(index);
  }
  finishStage();
}

function handleSignal(signal) {
  requestStop(`worker pool received ${signal}`);
  finishStage();
}

process.on("SIGINT", () => handleSignal("SIGINT"));
process.on("SIGTERM", () => handleSignal("SIGTERM"));
schedule();
