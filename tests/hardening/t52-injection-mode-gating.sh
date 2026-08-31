#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ROOT="$ROOT" TMP="$TMP" node --input-type=module <<'NODE'
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const { buildSessionStartContent, buildToolCallInjection } = await import(
  pathToFileURL(join(process.env.ROOT, "plugins/edc/hooks/lib/route.mjs")).href
);
const sessionCanary = "SEC03_SESSION_CANARY";
const moduleCanary = "SEC03_MODULE_CANARY";
const failures = [];
const missingPolicy = Symbol("missing-policy");

const cases = [
  { name: "inject", policy: { defaultMode: "inject" }, expectedMode: "inject", injects: true },
  { name: "advisory", policy: { defaultMode: "advisory" }, expectedMode: "advisory", injects: false },
  { name: "missing-policy", policy: missingPolicy, expectedMode: "no-context", injects: false },
  { name: "missing-defaultMode", policy: {}, expectedMode: "no-context", injects: false },
  { name: "null-mode", policy: { defaultMode: null }, expectedMode: "no-context", injects: false },
  { name: "numeric-mode", policy: { defaultMode: 1 }, expectedMode: "no-context", injects: false },
  { name: "object-mode", policy: { defaultMode: { value: "inject" } }, expectedMode: "no-context", injects: false },
  { name: "empty-mode", policy: { defaultMode: "" }, expectedMode: "no-context", injects: false },
  { name: "inject-case-variant", policy: { defaultMode: "Inject" }, expectedMode: "no-context", injects: false },
  { name: "advisory-case-variant", policy: { defaultMode: "ADVISORY" }, expectedMode: "no-context", injects: false },
  { name: "unknown-mode", policy: { defaultMode: "bogus" }, expectedMode: "no-context", injects: false },
];

for (const testCase of cases) {
  const projectRoot = join(process.env.TMP, testCase.name);
  mkdirSync(join(projectRoot, "edc-context/modules"), { recursive: true });
  writeFileSync(join(projectRoot, "edc-context/index.md"), `${sessionCanary}:${testCase.name}\n`);
  writeFileSync(join(projectRoot, "edc-context/modules/target.md"), `${moduleCanary}:${testCase.name}\n`);
  const manifest = {
    modules: [{
      name: "target",
      priority: 1,
      match: { prefixes: ["src/"] },
      doc: "edc-context/modules/target.md",
    }],
  };
  if (testCase.policy !== missingPolicy) manifest.policy = testCase.policy;
  writeFileSync(join(projectRoot, "edc-context/manifest.json"), JSON.stringify(manifest));

  const session = buildSessionStartContent(projectRoot);
  const tool = buildToolCallInjection({
    projectRoot,
    toolName: "edit",
    toolInput: { file_path: "src/file.ts" },
    sessionId: "",
  });

  if (session.mode !== testCase.expectedMode) {
    failures.push(`${testCase.name}: session mode ${session.mode}, expected ${testCase.expectedMode}`);
  }
  if (testCase.injects) {
    if (session.content !== `${sessionCanary}:${testCase.name}\n`) {
      failures.push(`${testCase.name}: canonical session content changed: ${JSON.stringify(session)}`);
    }
    if (tool?.moduleName !== "target"
      || !tool.content.endsWith(`${moduleCanary}:${testCase.name}\n`)) {
      failures.push(`${testCase.name}: canonical module injection changed: ${JSON.stringify(tool)}`);
    }
  } else {
    if (session.content !== ""
      || session.content.includes(sessionCanary)
      || session.content.includes(moduleCanary)) {
      failures.push(`${testCase.name}: session bytes exposed: ${JSON.stringify(session)}`);
    }
    if (tool !== null) {
      failures.push(`${testCase.name}: module bytes exposed: ${JSON.stringify(tool)}`);
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exit(1);
}
console.log("PASS: only exact inject mode enables session and module injection");
NODE
