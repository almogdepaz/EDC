#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ROOT="$ROOT" TMP="$TMP" node --input-type=module <<'NODE'
import fs, {
  mkdirSync,
  statSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const { buildSessionStartContent, buildToolCallInjection, getContextFreshness } = await import(
  pathToFileURL(join(process.env.ROOT, "plugins/edc/hooks/lib/route.mjs")).href
);
const tempRoot = process.env.TMP;
const outsideCanary = "SEC02_OUTSIDE_CANARY";
const failures = [];

function writeManifest(projectRoot, doc) {
  mkdirSync(join(projectRoot, "edc-context"), { recursive: true });
  writeFileSync(join(projectRoot, "edc-context/manifest.json"), JSON.stringify({
    policy: { defaultMode: "inject" },
    modules: [{
      name: "target",
      priority: 1,
      match: { prefixes: ["src/"] },
      doc,
    }],
  }));
}

function writeSessionManifest(projectRoot) {
  mkdirSync(join(projectRoot, "edc-context"), { recursive: true });
  writeFileSync(join(projectRoot, "edc-context/manifest.json"), JSON.stringify({
    policy: { defaultMode: "inject" },
    modules: [],
  }));
}

function inject(projectRoot) {
  return buildToolCallInjection({
    projectRoot,
    toolName: "edit",
    toolInput: { file_path: "src/file.ts" },
    sessionId: "",
  });
}

function expectNoInjection(name, projectRoot) {
  let result;
  try {
    result = inject(projectRoot);
  } catch (error) {
    failures.push(`${name}: threw ${error.message}`);
    return;
  }
  if (result !== null) {
    failures.push(`${name}: injected ${JSON.stringify(result)}`);
  }
}

const validProject = join(tempRoot, "valid-project");
mkdirSync(join(validProject, "edc-context/modules"), { recursive: true });
writeManifest(validProject, "edc-context/modules/target.md");
writeFileSync(join(validProject, "edc-context/modules/target.md"), "# canonical module\n");
const validResult = inject(validProject);
if (validResult?.moduleName !== "target"
  || validResult.normalizedPath !== "src/file.ts"
  || !validResult.content.endsWith("# canonical module\n")) {
  failures.push(`valid canonical doc changed: ${JSON.stringify(validResult)}`);
}

const emptyDocProject = join(tempRoot, "empty-doc-project");
mkdirSync(join(emptyDocProject, "edc-context/modules"), { recursive: true });
writeManifest(emptyDocProject, "");
writeFileSync(join(emptyDocProject, "edc-context/modules/target.md"), "# empty doc fallback must not inject\n");
expectNoInjection("explicit empty doc", emptyDocProject);

const nullDocProject = join(tempRoot, "null-doc-project");
mkdirSync(join(nullDocProject, "edc-context/modules"), { recursive: true });
writeManifest(nullDocProject, null);
writeFileSync(join(nullDocProject, "edc-context/modules/target.md"), "# null doc fallback must not inject\n");
expectNoInjection("explicit null doc", nullDocProject);

const traversalProject = join(tempRoot, "traversal-project");
mkdirSync(join(traversalProject, "edc-context/modules"), { recursive: true });
writeManifest(traversalProject, "../outside.txt");
writeFileSync(join(tempRoot, "outside.txt"), `${outsideCanary}:traversal\n`);
expectNoInjection("parent traversal", traversalProject);

const rootedTraversalProject = join(tempRoot, "rooted-traversal-project");
mkdirSync(join(rootedTraversalProject, "edc-context/modules"), { recursive: true });
writeManifest(rootedTraversalProject, "edc-context/modules/../../../outside.txt");
expectNoInjection("rooted parent traversal", rootedTraversalProject);

const absoluteProject = join(tempRoot, "absolute-project");
mkdirSync(join(absoluteProject, "edc-context/modules"), { recursive: true });
const absoluteOutside = join(tempRoot, "absolute-outside.txt");
writeFileSync(absoluteOutside, `${outsideCanary}:absolute\n`);
writeManifest(absoluteProject, absoluteOutside);
expectNoInjection("absolute path", absoluteProject);

const malformedProject = join(tempRoot, "malformed-project");
mkdirSync(join(malformedProject, "edc-context/modules"), { recursive: true });
writeManifest(malformedProject, { path: "edc-context/modules/target.md" });
expectNoInjection("malformed declaration", malformedProject);

const missingProject = join(tempRoot, "missing-project");
mkdirSync(join(missingProject, "edc-context/modules"), { recursive: true });
writeManifest(missingProject, "edc-context/modules/missing.md");
expectNoInjection("missing doc", missingProject);

const finalSymlinkProject = join(tempRoot, "final-symlink-project");
mkdirSync(join(finalSymlinkProject, "edc-context/modules"), { recursive: true });
const finalOutside = join(tempRoot, "final-outside.md");
writeFileSync(finalOutside, `${outsideCanary}:final-symlink\n`);
writeManifest(finalSymlinkProject, "edc-context/modules/target.md");
symlinkSync(finalOutside, join(finalSymlinkProject, "edc-context/modules/target.md"));
expectNoInjection("final-file symlink escape", finalSymlinkProject);

const intermediateSymlinkProject = join(tempRoot, "intermediate-symlink-project");
mkdirSync(join(intermediateSymlinkProject, "edc-context/modules"), { recursive: true });
const intermediateOutside = join(tempRoot, "intermediate-outside");
mkdirSync(intermediateOutside, { recursive: true });
writeFileSync(join(intermediateOutside, "target.md"), `${outsideCanary}:intermediate-symlink\n`);
writeManifest(intermediateSymlinkProject, "edc-context/modules/linked/target.md");
symlinkSync(intermediateOutside, join(intermediateSymlinkProject, "edc-context/modules/linked"));
expectNoInjection("intermediate-directory symlink escape", intermediateSymlinkProject);

const modulesSymlinkProject = join(tempRoot, "modules-symlink-project");
mkdirSync(join(modulesSymlinkProject, "edc-context"), { recursive: true });
const modulesOutside = join(tempRoot, "modules-outside");
mkdirSync(modulesOutside, { recursive: true });
writeFileSync(join(modulesOutside, "target.md"), `${outsideCanary}:modules-symlink\n`);
writeManifest(modulesSymlinkProject, "edc-context/modules/target.md");
symlinkSync(modulesOutside, join(modulesSymlinkProject, "edc-context/modules"));
expectNoInjection("modules-directory symlink escape", modulesSymlinkProject);

const contextSymlinkProject = join(tempRoot, "context-symlink-project");
mkdirSync(contextSymlinkProject, { recursive: true });
const contextOutside = join(tempRoot, "context-outside");
mkdirSync(join(contextOutside, "modules"), { recursive: true });
writeFileSync(join(contextOutside, "modules/target.md"), `${outsideCanary}:context-symlink\n`);
writeFileSync(join(contextOutside, "manifest.json"), JSON.stringify({
  policy: { defaultMode: "inject" },
  modules: [{ name: "target", match: { prefixes: ["src/"] }, doc: "edc-context/modules/target.md" }],
}));
symlinkSync(contextOutside, join(contextSymlinkProject, "edc-context"));
expectNoInjection("edc-context parent symlink escape", contextSymlinkProject);

const physicalProject = join(tempRoot, "physical-project");
mkdirSync(join(physicalProject, "edc-context/modules"), { recursive: true });
writeManifest(physicalProject, "edc-context/modules/target.md");
writeFileSync(join(physicalProject, "edc-context/modules/target.md"), "# symlinked project module\n");
const projectSymlink = join(tempRoot, "project-symlink");
symlinkSync(physicalProject, projectSymlink);
const projectSymlinkResult = inject(projectSymlink);
if (!projectSymlinkResult?.content.endsWith("# symlinked project module\n")) {
  failures.push(`symlinked project root rejected: ${JSON.stringify(projectSymlinkResult)}`);
}

const validIndexProject = join(tempRoot, "valid-index-project");
writeSessionManifest(validIndexProject);
writeFileSync(join(validIndexProject, "edc-context/index.md"), "# canonical index\n");
const validIndexResult = buildSessionStartContent(validIndexProject);
if (validIndexResult.mode !== "inject" || validIndexResult.content !== "# canonical index\n") {
  failures.push(`valid canonical index changed: ${JSON.stringify(validIndexResult)}`);
}

const manifestSymlinkProject = join(tempRoot, "manifest-symlink-project");
mkdirSync(join(manifestSymlinkProject, "edc-context"), { recursive: true });
writeFileSync(join(manifestSymlinkProject, "edc-context/index.md"), "# must not inject through redirected manifest\n");
const manifestOutside = join(tempRoot, "manifest-outside.json");
writeFileSync(manifestOutside, JSON.stringify({ policy: { defaultMode: "inject" }, modules: [] }));
symlinkSync(manifestOutside, join(manifestSymlinkProject, "edc-context/manifest.json"));
const manifestSymlinkResult = buildSessionStartContent(manifestSymlinkProject);
if (manifestSymlinkResult.mode !== "no-context" || manifestSymlinkResult.content !== "") {
  failures.push(`manifest symlink escape accepted: ${JSON.stringify(manifestSymlinkResult)}`);
}

const indexSymlinkProject = join(tempRoot, "index-symlink-project");
writeSessionManifest(indexSymlinkProject);
const indexOutside = join(tempRoot, "index-outside.md");
writeFileSync(indexOutside, `## ${outsideCanary}:index-symlink\n`);
symlinkSync(indexOutside, join(indexSymlinkProject, "edc-context/index.md"));
const indexSymlinkResult = buildSessionStartContent(indexSymlinkProject);
if (indexSymlinkResult.content.includes(outsideCanary) || indexSymlinkResult.content !== "") {
  failures.push(`index symlink escape injected: ${JSON.stringify(indexSymlinkResult)}`);
}
const indexSymlinkFreshness = getContextFreshness(indexSymlinkProject);
if (indexSymlinkFreshness.state !== "missing" || indexSymlinkFreshness.reason !== "index") {
  failures.push(`freshness followed index symlink escape: ${JSON.stringify(indexSymlinkFreshness)}`);
}

const sessionContextSymlinkProject = join(tempRoot, "session-context-symlink-project");
mkdirSync(sessionContextSymlinkProject, { recursive: true });
const sessionContextOutside = join(tempRoot, "session-context-outside");
mkdirSync(sessionContextOutside, { recursive: true });
writeFileSync(join(sessionContextOutside, "manifest.json"), JSON.stringify({
  policy: { defaultMode: "inject" },
  modules: [],
}));
writeFileSync(join(sessionContextOutside, "index.md"), `${outsideCanary}:context-index\n`);
symlinkSync(sessionContextOutside, join(sessionContextSymlinkProject, "edc-context"));
const sessionContextSymlinkResult = buildSessionStartContent(sessionContextSymlinkProject);
if (sessionContextSymlinkResult.mode !== "no-context"
  || sessionContextSymlinkResult.content.includes(outsideCanary)
  || sessionContextSymlinkResult.content !== "") {
  failures.push(`session edc-context symlink escape accepted: ${JSON.stringify(sessionContextSymlinkResult)}`);
}

const physicalIndexProject = join(tempRoot, "physical-index-project");
writeSessionManifest(physicalIndexProject);
writeFileSync(join(physicalIndexProject, "edc-context/index.md"), "# symlinked project index\n");
const indexProjectSymlink = join(tempRoot, "index-project-symlink");
symlinkSync(physicalIndexProject, indexProjectSymlink);
const projectSymlinkIndexResult = buildSessionStartContent(indexProjectSymlink);
if (projectSymlinkIndexResult.content !== "# symlinked project index\n") {
  failures.push(`symlinked project index rejected: ${JSON.stringify(projectSymlinkIndexResult)}`);
}

const missingIndexProject = join(tempRoot, "missing-index-project");
writeSessionManifest(missingIndexProject);
const missingIndexResult = buildSessionStartContent(missingIndexProject);
if (missingIndexResult.content !== "") {
  failures.push(`missing index was not silent: ${JSON.stringify(missingIndexResult)}`);
}

const malformedIndexProject = join(tempRoot, "malformed-index-project");
writeSessionManifest(malformedIndexProject);
mkdirSync(join(malformedIndexProject, "edc-context/index.md"));
let malformedIndexResult;
try {
  malformedIndexResult = buildSessionStartContent(malformedIndexProject);
} catch (error) {
  failures.push(`malformed index threw: ${error.message}`);
}
if (malformedIndexResult && malformedIndexResult.content !== "") {
  failures.push(`malformed index was not silent: ${JSON.stringify(malformedIndexResult)}`);
}

const invalidManifestProject = join(tempRoot, "invalid-manifest-project");
mkdirSync(join(invalidManifestProject, "edc-context"), { recursive: true });
writeFileSync(join(invalidManifestProject, "edc-context/manifest.json"), "not json\n");
const invalidManifestResult = buildSessionStartContent(invalidManifestProject);
if (invalidManifestResult.mode !== "no-context" || invalidManifestResult.content !== "") {
  failures.push(`invalid manifest was not silent: ${JSON.stringify(invalidManifestResult)}`);
}

const absentManifestProject = join(tempRoot, "absent-manifest-project");
mkdirSync(join(absentManifestProject, "edc-context"), { recursive: true });
const absentManifestResult = buildSessionStartContent(absentManifestProject);
if (absentManifestResult.mode !== "no-context" || absentManifestResult.content !== "") {
  failures.push(`missing manifest was not silent: ${JSON.stringify(absentManifestResult)}`);
}

const raceProject = join(tempRoot, "validation-read-race-project");
mkdirSync(join(raceProject, "edc-context/modules"), { recursive: true });
writeManifest(raceProject, "edc-context/modules/target.md");
const raceDocPath = join(raceProject, "edc-context/modules/target.md");
const raceOutsidePath = join(tempRoot, "race-outside.md");
writeFileSync(raceDocPath, "# original contained bytes\n");
writeFileSync(raceOutsidePath, `${outsideCanary}:validation-read-swap\n`);
const raceDocIdentity = statSync(raceDocPath);
const originalReadFileSync = fs.readFileSync;
const originalCloseSync = fs.closeSync;
let raceFired = false;
let raceDescriptorClosed = false;
fs.readFileSync = function patchedReadFileSync(target, ...args) {
  let readsRaceDoc = false;
  if (typeof target === "string") {
    try {
      const declared = fs.statSync(target);
      readsRaceDoc = declared.dev === raceDocIdentity.dev && declared.ino === raceDocIdentity.ino;
    } catch {
      // Unrelated missing reads are handled by the production helper.
    }
  } else if (typeof target === "number") {
    const opened = fs.fstatSync(target);
    readsRaceDoc = opened.dev === raceDocIdentity.dev && opened.ino === raceDocIdentity.ino;
  }
  if (readsRaceDoc && !raceFired) {
    raceFired = true;
    unlinkSync(raceDocPath);
    symlinkSync(raceOutsidePath, raceDocPath);
  }
  return originalReadFileSync.call(fs, target, ...args);
};
fs.closeSync = function patchedCloseSync(fd) {
  const opened = fs.fstatSync(fd);
  if (opened.dev === raceDocIdentity.dev && opened.ino === raceDocIdentity.ino) {
    raceDescriptorClosed = true;
  }
  return originalCloseSync.call(fs, fd);
};
syncBuiltinESMExports();
let raceResult;
try {
  raceResult = inject(raceProject);
} finally {
  fs.readFileSync = originalReadFileSync;
  fs.closeSync = originalCloseSync;
  syncBuiltinESMExports();
}
if (!raceFired) {
  failures.push("deterministic validation/read swap hook did not fire");
} else if (!raceResult?.content.endsWith("# original contained bytes\n")
  || raceResult.content.includes(outsideCanary)) {
  failures.push(`validation/read swap exposed changed path: ${JSON.stringify(raceResult)}`);
}
if (!raceDescriptorClosed) {
  failures.push("validated module descriptor was not closed");
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exit(1);
}
console.log("PASS: injected context files remain contained; deterministic swap fired and descriptor closed");
NODE
