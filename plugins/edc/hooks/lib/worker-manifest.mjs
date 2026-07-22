#!/usr/bin/env node
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const [outputPath, runId, runDir, maxConcurrencyText, tasksPath] = process.argv.slice(2);
if (!outputPath || !runId || !runDir || !maxConcurrencyText || !tasksPath) {
  process.stderr.write("ERROR: worker manifest requires output, run id, run dir, concurrency, and task JSONL\n");
  process.exit(2);
}

let tasks;
try {
  tasks = readFileSync(tasksPath, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
} catch (error) {
  process.stderr.write(`ERROR: worker task JSONL is invalid: ${error.message}\n`);
  process.exit(2);
}

const manifest = {
  schemaVersion: 1,
  runId,
  runDir,
  maxConcurrency: Number(maxConcurrencyText),
  tasks,
};
mkdirSync(dirname(outputPath), { recursive: true });
const temporary = `${outputPath}.${process.pid}.tmp`;
writeFileSync(temporary, `${JSON.stringify(manifest, null, 2)}\n`);
renameSync(temporary, outputPath);
