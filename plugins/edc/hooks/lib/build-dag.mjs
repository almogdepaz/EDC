#!/usr/bin/env node
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const [planPath, runId, runDir, concurrencyText, moduleBundlePath, auditBundlePath, timeoutText] = process.argv.slice(2);
if (!planPath || !runId || !runDir || !concurrencyText || !moduleBundlePath || !auditBundlePath || !timeoutText) {
  process.stderr.write("ERROR: build dag requires plan, run metadata, bundles, and timeout\n");
  process.exit(2);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    process.stderr.write(`ERROR: could not read ${path}: ${error.message}\n`);
    process.exit(2);
  }
}

function writeJsonAtomic(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(temporary, path);
}

const plan = readJson(planPath);
if (!Array.isArray(plan.tasks) || plan.tasks.length === 0) {
  process.stderr.write("ERROR: build plan has no tasks\n");
  process.exit(2);
}
const moduleBundle = readFileSync(moduleBundlePath, "utf8");
const auditBundle = readFileSync(auditBundlePath, "utf8");
const maxConcurrency = Number(concurrencyText);
const timeoutSeconds = Number(timeoutText);
const promptsDir = join(runDir, "prompts");
const auditReportsDir = join(runDir, "staged", "audit-tasks");
mkdirSync(promptsDir, { recursive: true });
mkdirSync(auditReportsDir, { recursive: true });

const modules = [];
const moduleTasks = [];
const auditTasks = [];
for (const [index, task] of plan.tasks.entries()) {
  const sequence = index + 1;
  const moduleTaskId = `module-context-${sequence}`;
  const auditTaskId = `build-audit-${sequence}`;
  const modulePrompt = join(promptsDir, `${moduleTaskId}.md`);
  const auditPrompt = join(promptsDir, `${auditTaskId}.md`);
  const auditReport = join(auditReportsDir, `module-${sequence}.md`);

  writeFileSync(modulePrompt, `MODULE CONTEXT TASK\nMODULE: ${task.module}\nOUTPUT: ${task.out}\n\n${task.prompt}\n\nDo not launch agents or invoke skills as processes. Follow the embedded methodology directly. Write only the declared output.\n\n${moduleBundle}\n`);
  writeFileSync(auditPrompt, `AUDIT WORKER TASK\nAUDIT_MODULE: ${task.module}\nAUDIT_MODULE_DOC: ${task.out}\nAUDIT_REPORT_PATH: ${auditReport}\n\nRun a scoped code-quality audit for this module. Read the staged module doc and only the smallest source scope needed. Write exactly one markdown report to the declared path. Do not write canonical reports. Do not launch agents.\n\n${auditBundle}\n`);

  modules.push({ module: task.module, moduleDoc: task.out, auditReport });
  moduleTasks.push({
    id: moduleTaskId,
    phase: `edc-build/module/${task.module}`,
    module: task.module,
    promptFile: modulePrompt,
    timeoutSeconds,
    failurePolicy: "fail-fast",
    outputs: [task.out],
  });
  auditTasks.push({
    id: auditTaskId,
    phase: `edc-build/audit/${task.module}`,
    module: task.module,
    promptFile: auditPrompt,
    timeoutSeconds,
    failurePolicy: "fail-fast",
    outputs: [auditReport],
  });
}

const base = { schemaVersion: 1, runId, runDir, maxConcurrency };
writeJsonAtomic(join(runDir, "module-manifest.json"), { ...base, tasks: moduleTasks });
writeJsonAtomic(join(runDir, "build-audit-manifest.json"), { ...base, tasks: auditTasks });
writeJsonAtomic(join(runDir, "build-modules.json"), { schemaVersion: 1, modules });
