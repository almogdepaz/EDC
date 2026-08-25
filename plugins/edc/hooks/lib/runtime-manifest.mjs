#!/usr/bin/env node
import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  renameSync,
  statSync,
  writeFileSync,
  realpathSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";

export const RUNTIME_SCHEMA_VERSION = 1;
export const RUNTIME_VERSION = "1.1.5";
const LOCK_STALE_MS = Number(process.env.EDC_RUNTIME_LOCK_STALE_MS || 120000);
const RUNTIME_VALIDATION_TIMEOUT_MS = 30000;

function script(name, executable = true) {
  return { source: `scripts/${name}`, destination: `.edc/scripts/${name}`, executable };
}

function hook(name, executable = name.endsWith(".mjs") && name !== "route.mjs" && name !== "paths.mjs" && name !== "platform.mjs") {
  return { source: `hooks/lib/${name}`, destination: `.edc/hooks/lib/${name}`, executable };
}

function skill(source) {
  const rel = source.replace(/^prompt-bundles\//, "").replace(/^skills\//, "");
  return { source, destination: `.edc/skills/${rel}`, executable: false };
}

export const RUNTIME_MANIFEST = Object.freeze({
  schemaVersion: RUNTIME_SCHEMA_VERSION,
  runtimeVersion: RUNTIME_VERSION,
  metadataPath: ".edc/runtime-metadata.json",
  artifacts: Object.freeze([
    script("edc"),
    script("edc-agent-backends.sh", false),
    script("edc-assert-fresh.sh"),
    script("edc-audit.sh"),
    script("edc-build.sh"),
    script("edc-clean-slate.sh"),
    script("edc-delivery-review.sh"),
    script("edc-doctor.sh"),
    script("edc-lib.sh", false),
    script("edc-manifest.sh"),
    script("edc-recover-context.sh"),
    script("edc-review-all.sh"),
    script("edc-review-candidate.sh", false),
    script("edc-review-plan.sh", false),
    script("edc-review.sh"),
    script("edc-update.sh"),
    script("edc-worker.sh"),
    hook("build-dag.mjs"),
    hook("classify-cli.mjs"),
    hook("json-cli.mjs"),
    hook("json-result-commands.mjs", false),
    hook("paths.mjs", false),
    hook("pi-supervisor.mjs"),
    hook("platform.mjs", false),
    hook("route.mjs", false),
    hook("runtime-bootstrap.mjs"),
    hook("runtime-manifest.mjs"),
    hook("stream-filter.mjs"),
    hook("termination-policy.mjs", false),
    hook("worker-manifest.mjs"),
    hook("worker-pool.mjs"),
    skill("prompt-bundles/edc-build-impl/SKILL.md"),
    skill("prompt-bundles/edc-build-impl/adapter-contract.md"),
    skill("prompt-bundles/edc-build-impl/manifest-schema.md"),
    skill("prompt-bundles/edc-context-curator-edit-impl/SKILL.md"),
    skill("prompt-bundles/edc-context-curator-impl/SKILL.md"),
    skill("prompt-bundles/edc-module-context-impl/SKILL.md"),
    skill("prompt-bundles/edc-module-context-impl/resources/COMPLETENESS_CHECKLIST.md"),
    skill("prompt-bundles/edc-module-context-impl/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md"),
    skill("prompt-bundles/edc-module-context-impl/resources/OUTPUT_REQUIREMENTS.md"),
    skill("prompt-bundles/edc-update-impl/SKILL.md"),
    skill("skills/edc-audit/SKILL.md"),
    skill("skills/edc-audit/references/quality-checks.md"),
    skill("skills/edc-audit/references/reporting.md"),
    skill("skills/edc-audit/references/scope-and-standards.md"),
    skill("skills/edc-audit/references/smell-baseline.md"),
    skill("skills/edc-delivery-review/SKILL.md"),
    skill("skills/edc-delivery-review/references/architecture-axis.md"),
    skill("skills/edc-delivery-review/references/reporting.md"),
    skill("skills/edc-delivery-review/references/spec-axis.md"),
    skill("skills/edc-review/SKILL.md"),
    skill("skills/edc-review/adversarial.md"),
    skill("skills/edc-review/methodology.md"),
    skill("skills/edc-review/patterns.md"),
    skill("skills/edc-review/reporting.md"),
  ]),
});

function structured(reasonCode, message, hint, details = {}, exitCode = 1) {
  return {
    schemaVersion: 1,
    status: reasonCode === "success" ? "success" : "failed",
    reasonCode,
    message,
    hint,
    details,
    exitCode,
  };
}

function fail(result) {
  const error = new Error(result.message);
  error.result = result;
  return error;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validateRelPath(path, field) {
  if (typeof path !== "string" || path.length === 0) throw fail(structured("runtime-validation-failed", `runtime manifest has invalid ${field}`, "reinstall EDC from a trusted package", { field }));
  if (path.startsWith("/") || path.includes("\0") || path.split(/[\\/]+/).includes("..")) {
    throw fail(structured("runtime-validation-failed", `runtime manifest ${field} escapes runtime root`, "reinstall EDC from a trusted package", { field, path }));
  }
}

export function validateRuntimeManifest(manifest = RUNTIME_MANIFEST, sourceRoot = "") {
  if (!isObject(manifest)) throw fail(structured("runtime-validation-failed", "runtime manifest is not an object", "reinstall EDC from a trusted package"));
  const allowedManifestFields = new Set(["schemaVersion", "runtimeVersion", "metadataPath", "artifacts"]);
  for (const field of Object.keys(manifest)) {
    if (!allowedManifestFields.has(field)) throw fail(structured("runtime-validation-failed", `runtime manifest has unknown field: ${field}`, "reinstall EDC from a trusted package", { field }));
  }
  if (manifest.schemaVersion !== RUNTIME_SCHEMA_VERSION) {
    throw fail(structured("runtime-version-mismatch", "runtime manifest schema version mismatch", "reinstall EDC so helper scripts and metadata agree", { expected: RUNTIME_SCHEMA_VERSION, observed: manifest.schemaVersion }));
  }
  if (manifest.runtimeVersion !== RUNTIME_VERSION) {
    throw fail(structured("runtime-version-mismatch", "runtime manifest version mismatch", "reinstall EDC so helper scripts and metadata agree", { expected: RUNTIME_VERSION, observed: manifest.runtimeVersion }));
  }
  validateRelPath(manifest.metadataPath, "metadataPath");
  if (!Array.isArray(manifest.artifacts) || manifest.artifacts.length === 0) {
    throw fail(structured("runtime-validation-failed", "runtime manifest has no artifacts", "reinstall EDC from a trusted package"));
  }
  const destinations = new Set();
  for (const artifact of manifest.artifacts) {
    if (!isObject(artifact)) throw fail(structured("runtime-validation-failed", "runtime manifest artifact is not an object", "reinstall EDC from a trusted package"));
    const allowedArtifactFields = new Set(["source", "destination", "executable"]);
    for (const field of Object.keys(artifact)) {
      if (!allowedArtifactFields.has(field)) throw fail(structured("runtime-validation-failed", `runtime manifest artifact has unknown field: ${field}`, "reinstall EDC from a trusted package", { field }));
    }
    validateRelPath(artifact.source, "source");
    validateRelPath(artifact.destination, "destination");
    if (!artifact.destination.startsWith(".edc/")) {
      throw fail(structured("runtime-validation-failed", "runtime manifest destination must be under managed global .edc", "reinstall EDC from a trusted package", { destination: artifact.destination }));
    }
    if (typeof artifact.executable !== "boolean") throw fail(structured("runtime-validation-failed", "runtime manifest executable flag must be boolean", "reinstall EDC from a trusted package", { source: artifact.source }));
    if (destinations.has(artifact.destination)) throw fail(structured("runtime-validation-failed", "runtime manifest declares a duplicate destination", "reinstall EDC from a trusted package", { destination: artifact.destination }));
    destinations.add(artifact.destination);
    if (sourceRoot && !existsSync(sourcePathFor(sourceRoot, artifact))) {
      throw fail(structured("runtime-install-incomplete", "runtime source file is missing", "reinstall EDC from a complete package", { missingPath: artifact.source }));
    }
  }
  return true;
}

export function sourcePathFor(sourceRoot, artifact) {
  if (basename(resolve(sourceRoot)) === ".edc") {
    return join(sourceRoot, artifact.destination.slice(".edc/".length));
  }
  return join(sourceRoot, artifact.source);
}

function hashFile(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

export function runtimeFingerprint(sourceRoot, manifest = RUNTIME_MANIFEST) {
  validateRuntimeManifest(manifest, sourceRoot);
  const hash = createHash("sha256");
  hash.update(`schema=${manifest.schemaVersion}\nversion=${manifest.runtimeVersion}\n`);
  for (const artifact of [...manifest.artifacts].sort((a, b) => a.destination.localeCompare(b.destination))) {
    const src = sourcePathFor(sourceRoot, artifact);
    hash.update(`${artifact.source}\0${artifact.destination}\0${artifact.executable ? "x" : "-"}\0`);
    hash.update(readFileSync(src));
    hash.update("\0");
  }
  return hash.digest("hex");
}

function copyArtifact(sourceRoot, artifact, stageRoot) {
  const src = sourcePathFor(sourceRoot, artifact);
  const dst = join(stageRoot, artifact.destination.slice(".edc/".length));
  mkdirSync(dirname(dst), { recursive: true });
  copyFileSync(src, dst);
  chmodSync(dst, artifact.executable ? 0o755 : 0o644);
}

function managedDestinations(manifest = RUNTIME_MANIFEST) {
  return new Set(manifest.artifacts.map((artifact) => artifact.destination));
}

function copyPreservedFiles(previousEdcRoot, stageRoot, manifest = RUNTIME_MANIFEST) {
  if (!existsSync(previousEdcRoot)) return;
  const managed = managedDestinations(manifest);
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const src = join(dir, entry.name);
      const relFromEdc = relative(previousEdcRoot, src).split(sep).join("/");
      const projectRel = `.edc/${relFromEdc}`;
      const dst = join(stageRoot, relFromEdc);
      if (entry.isDirectory()) {
        walk(src);
        continue;
      }
      if (!entry.isFile() || managed.has(projectRel)) continue;
      mkdirSync(dirname(dst), { recursive: true });
      copyFileSync(src, dst);
    }
  };
  walk(previousEdcRoot);
}

function writeMetadata(stageRoot, sourceRoot, manifest = RUNTIME_MANIFEST) {
  const metadata = {
    schemaVersion: RUNTIME_SCHEMA_VERSION,
    runtimeVersion: RUNTIME_VERSION,
    installedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    fingerprint: runtimeFingerprint(sourceRoot, manifest),
    artifacts: manifest.artifacts.map((artifact) => ({
      destination: artifact.destination,
      executable: artifact.executable,
      sha256: hashFile(sourcePathFor(sourceRoot, artifact)),
    })),
  };
  writeFileSync(join(stageRoot, "runtime-metadata.json"), `${JSON.stringify(metadata, null, 2)}\n`);
  return metadata;
}

function pathInside(root, candidate) {
  const rel = relative(root, candidate);
  return rel === "" || (!rel.startsWith("..") && !rel.startsWith("/") && !rel.includes(`..${sep}`));
}

function validateInstalledTree(projectRoot, manifest = RUNTIME_MANIFEST, trustedSourceRoot = "") {
  validateRuntimeManifest(manifest, trustedSourceRoot);
  const missingPaths = [];
  const badModes = [];
  for (const artifact of manifest.artifacts) {
    const path = join(projectRoot, artifact.destination);
    if (!existsSync(path)) {
      missingPaths.push(artifact.destination);
      continue;
    }
    const st = lstatSync(path);
    if (!st.isFile() || st.isSymbolicLink()) {
      missingPaths.push(artifact.destination);
      continue;
    }
    if (artifact.executable && (st.mode & 0o111) === 0) badModes.push(artifact.destination);
  }
  if (missingPaths.length > 0) {
    throw fail(structured("runtime-install-incomplete", "managed global EDC runtime is incomplete", "reinstall EDC from a trusted package", { missingPaths, missingPath: missingPaths[0] }));
  }
  if (badModes.length > 0) {
    throw fail(structured("runtime-validation-failed", "managed global EDC runtime has non-executable scripts", "reinstall EDC from a trusted package", { badModes }));
  }
  const metadataPath = join(projectRoot, manifest.metadataPath);
  if (!existsSync(metadataPath) || !lstatSync(metadataPath).isFile() || lstatSync(metadataPath).isSymbolicLink()) {
    throw fail(structured("runtime-install-incomplete", "managed global EDC runtime metadata is missing", "reinstall EDC from a trusted package", { missingPath: manifest.metadataPath }));
  }
  let metadata;
  try {
    metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
  } catch {
    throw fail(structured("runtime-validation-failed", "managed global EDC runtime metadata is corrupt", "reinstall EDC from a trusted package", { path: manifest.metadataPath }));
  }
  if (metadata.schemaVersion !== RUNTIME_SCHEMA_VERSION || metadata.runtimeVersion !== RUNTIME_VERSION) {
    throw fail(structured("runtime-version-mismatch", "managed global EDC runtime version mismatch", "reinstall EDC so ~/.edc matches this EDC version", { expected: RUNTIME_VERSION, observed: metadata.runtimeVersion || "unknown" }));
  }
  const expectedFingerprint = trustedSourceRoot ? runtimeFingerprint(trustedSourceRoot, manifest) : "";
  if (expectedFingerprint && metadata.fingerprint !== expectedFingerprint) {
    throw fail(structured("runtime-version-mismatch", "managed global EDC runtime fingerprint mismatch", "reinstall EDC so ~/.edc matches this EDC version", { expectedFingerprint, observedFingerprint: metadata.fingerprint || "missing" }));
  }
  if (!Array.isArray(metadata.artifacts)) {
    throw fail(structured("runtime-validation-failed", "managed global EDC runtime metadata has no artifact hashes", "reinstall EDC from a trusted package", { path: manifest.metadataPath }));
  }
  const metadataByDestination = new Map();
  for (const entry of metadata.artifacts) {
    if (!isObject(entry) || typeof entry.destination !== "string" || metadataByDestination.has(entry.destination)) {
      throw fail(structured("runtime-validation-failed", "managed global EDC runtime metadata has invalid artifacts", "reinstall EDC from a trusted package", { path: manifest.metadataPath }));
    }
    metadataByDestination.set(entry.destination, entry);
  }
  const changedPaths = [];
  for (const artifact of manifest.artifacts) {
    const entry = metadataByDestination.get(artifact.destination);
    const recordedHash = entry?.sha256;
    if (!entry || entry.executable !== artifact.executable || typeof recordedHash !== "string" || !/^[a-f0-9]{64}$/.test(recordedHash)) {
      throw fail(structured("runtime-validation-failed", "managed global EDC runtime metadata has invalid artifact hashes", "reinstall EDC from a trusted package", { path: artifact.destination }));
    }
    const expectedHash = trustedSourceRoot ? hashFile(sourcePathFor(trustedSourceRoot, artifact)) : recordedHash;
    if (hashFile(join(projectRoot, artifact.destination)) !== expectedHash) changedPaths.push(artifact.destination);
  }
  if (metadataByDestination.size !== manifest.artifacts.length) {
    throw fail(structured("runtime-validation-failed", "managed global EDC runtime metadata declares unexpected artifacts", "reinstall EDC from a trusted package", { path: manifest.metadataPath }));
  }
  if (changedPaths.length > 0) {
    throw fail(structured("runtime-integrity-mismatch", "managed global EDC runtime artifacts do not match trusted bytes", "reinstall EDC from a trusted package before running EDC", { changedPaths, path: changedPaths[0] }));
  }
  for (const artifact of manifest.artifacts.filter((entry) => entry.destination.endsWith(".mjs"))) {
    const path = join(projectRoot, artifact.destination);
    try {
      execFileSync(process.execPath, ["--check", path], { stdio: "ignore", timeout: RUNTIME_VALIDATION_TIMEOUT_MS });
    } catch {
      throw fail(structured("runtime-validation-failed", "managed global EDC runtime contains invalid JavaScript", "reinstall EDC from a trusted package", { path: artifact.destination }));
    }
  }
  workerManifestSmoke(projectRoot, trustedSourceRoot, manifest);
  return structured("success", "runtime preflight passed", "", { fingerprint: metadata.fingerprint }, 0);
}

function currentHomeRoot() {
  const home = process.env.HOME;
  if (!home) {
    throw fail(structured("runtime-validation-failed", "current HOME is required for managed EDC runtime access", "set HOME and reinstall EDC globally"));
  }
  try {
    return realpathSync(resolve(home));
  } catch {
    throw fail(structured("runtime-validation-failed", "current HOME cannot be resolved", "create HOME and reinstall EDC globally", { home: resolve(home) }));
  }
}

function assertCurrentHomeInstallRoot(root) {
  let target;
  try {
    target = realpathSync(resolve(root));
  } catch {
    throw fail(structured("runtime-validation-failed", "runtime install target cannot be resolved", "install EDC into the current HOME", { target: resolve(root) }));
  }
  const home = currentHomeRoot();
  if (target !== home) {
    throw fail(structured("runtime-validation-failed", "runtime install target must be the current HOME", "install EDC globally without a project-local target", { target, home }));
  }
  return target;
}

function assertCurrentHomeRuntimeSource(source) {
  const home = currentHomeRoot();
  let expected;
  try {
    expected = realpathSync(join(home, ".edc"));
  } catch {
    throw fail(structured("runtime-validation-failed", "current HOME has no managed EDC runtime", "reinstall EDC globally", { home }));
  }
  if (source !== expected) {
    throw fail(structured("runtime-validation-failed", "installed EDC runtime must be current HOME/.edc", "invoke the trusted package or current HOME global runtime", { source, expected }));
  }
}

export function preflightRuntimeSource(sourceRoot, manifest = RUNTIME_MANIFEST) {
  const requestedSource = resolve(sourceRoot);
  const source = realpathSync(requestedSource);
  if (basename(requestedSource) === ".edc" || basename(source) === ".edc") {
    assertCurrentHomeRuntimeSource(source);
    return validateInstalledTree(currentHomeRoot(), manifest, source);
  }

  validateRuntimeManifest(manifest, source);
  for (const artifact of manifest.artifacts) {
    const path = sourcePathFor(source, artifact);
    const st = lstatSync(path);
    if (!st.isFile() || st.isSymbolicLink()) {
      throw fail(structured("runtime-validation-failed", "trusted EDC runtime source contains a non-regular artifact", "reinstall EDC from a trusted package", { path: artifact.source }));
    }
  }
  for (const artifact of manifest.artifacts.filter((entry) => entry.destination.endsWith(".mjs"))) {
    try {
      execFileSync(process.execPath, ["--check", sourcePathFor(source, artifact)], { stdio: "ignore", timeout: RUNTIME_VALIDATION_TIMEOUT_MS });
    } catch {
      throw fail(structured("runtime-validation-failed", "trusted EDC runtime source contains invalid JavaScript", "reinstall EDC from a trusted package", { path: artifact.source }));
    }
  }
  workerManifestSmoke("", source, manifest);
  return structured("success", "runtime source preflight passed", "", { fingerprint: runtimeFingerprint(source, manifest) }, 0);
}

function workerManifestSmoke(projectRoot, trustedSourceRoot = "", manifest = RUNTIME_MANIFEST) {
  const smokeDir = mkdtempSync(join(tmpdir(), "edc-worker-manifest-smoke."));
  try {
    const tasks = join(smokeDir, "tasks.jsonl");
    const output = join(smokeDir, "manifest.json");
    writeFileSync(tasks, "");
    const artifact = manifest.artifacts.find((entry) => entry.destination === ".edc/hooks/lib/worker-manifest.mjs");
    if (trustedSourceRoot && !artifact) throw new Error("trusted runtime manifest omits worker-manifest helper");
    const helper = trustedSourceRoot
      ? sourcePathFor(trustedSourceRoot, artifact)
      : join(projectRoot, ".edc/hooks/lib/worker-manifest.mjs");
    execFileSync(process.execPath, [helper, output, "runtime-smoke", smokeDir, "1", tasks], { stdio: "ignore", timeout: RUNTIME_VALIDATION_TIMEOUT_MS });
    const smokeManifest = JSON.parse(readFileSync(output, "utf8"));
    if (smokeManifest.schemaVersion !== 1 || smokeManifest.runId !== "runtime-smoke" || !Array.isArray(smokeManifest.tasks)) {
      throw new Error("worker manifest smoke produced invalid manifest");
    }
  } catch {
    throw fail(structured("runtime-validation-failed", "worker-manifest smoke failed", "rerun the EDC installer to replace runtime helpers", { path: ".edc/hooks/lib/worker-manifest.mjs" }));
  } finally {
    rmSync(smokeDir, { recursive: true, force: true });
  }
}

function lockDir(projectRoot) {
  return join(projectRoot, ".edc.install.lock");
}

function lockIsStale(path) {
  try {
    return Date.now() - statSync(path).mtimeMs > LOCK_STALE_MS;
  } catch {
    return false;
  }
}

function readLockOwner(path) {
  try {
    const owner = JSON.parse(readFileSync(join(path, "owner.json"), "utf8"));
    return isObject(owner) ? owner : null;
  } catch {
    return null;
  }
}

function lockOwnerIsAlive(owner) {
  if (!Number.isSafeInteger(owner?.pid) || owner.pid <= 0) return false;
  try {
    process.kill(owner.pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function installBusy() {
  return fail(structured("runtime-install-busy", "managed global EDC runtime install is locked", "wait for the running EDC install/review to finish, then rerun", { lockPath: ".edc.install.lock" }));
}

function createOwnedLock(path, token) {
  mkdirSync(path);
  try {
    writeFileSync(join(path, "owner.json"), `${JSON.stringify({ pid: process.pid, token, startedAt: new Date().toISOString() })}\n`);
  } catch (error) {
    rmSync(path, { recursive: true, force: true });
    throw error;
  }
}

function acquireInstallLock(projectRoot) {
  const path = lockDir(projectRoot);
  const token = randomUUID();
  try {
    createOwnedLock(path, token);
  } catch (error) {
    if (error?.code !== "EEXIST") {
      throw fail(structured("runtime-validation-failed", "could not create managed global EDC runtime lock", "check the EDC install directory permissions and retry", { lockPath: ".edc.install.lock", code: error?.code || "unknown" }));
    }
    if (!lockIsStale(path) || lockOwnerIsAlive(readLockOwner(path))) throw installBusy();
    const abandonedPath = `${path}.abandoned.${process.pid}.${token}`;
    try {
      renameSync(path, abandonedPath);
      createOwnedLock(path, token);
    } catch (takeoverError) {
      if (!existsSync(path) && existsSync(abandonedPath)) renameSync(abandonedPath, path);
      if (takeoverError?.code === "EEXIST" || takeoverError?.code === "ENOENT") throw installBusy();
      throw fail(structured("runtime-validation-failed", "could not take ownership of stale EDC runtime lock", "check the EDC install directory permissions and retry", { lockPath: ".edc.install.lock", code: takeoverError?.code || "unknown" }));
    }
    rmSync(abandonedPath, { recursive: true, force: true });
  }
  return () => {
    if (readLockOwner(path)?.token === token) rmSync(path, { recursive: true, force: true });
  };
}

function validateStageRoot(stageEdcRoot, sourceRoot, manifest = RUNTIME_MANIFEST) {
  const stageProjectRoot = dirname(stageEdcRoot);
  const tmpProjectRoot = mkdtempSync(join(dirname(stageEdcRoot), ".edc-stage-project."));
  rmSync(tmpProjectRoot, { recursive: true, force: true });
  mkdirSync(tmpProjectRoot, { recursive: true });
  renameSync(stageEdcRoot, join(tmpProjectRoot, ".edc"));
  try {
    validateInstalledTree(tmpProjectRoot, manifest, sourceRoot);
    renameSync(join(tmpProjectRoot, ".edc"), stageEdcRoot);
  } finally {
    if (existsSync(join(tmpProjectRoot, ".edc")) && !existsSync(stageEdcRoot)) renameSync(join(tmpProjectRoot, ".edc"), stageEdcRoot);
    rmSync(tmpProjectRoot, { recursive: true, force: true });
  }
  if (!pathInside(stageProjectRoot, stageEdcRoot)) {
    throw fail(structured("runtime-validation-failed", "staged runtime escaped global install root", "reinstall EDC from a trusted package"));
  }
}

export function installRuntime(globalRoot, sourceRoot, manifest = RUNTIME_MANIFEST) {
  const root = assertCurrentHomeInstallRoot(globalRoot);
  const source = resolve(sourceRoot);
  validateRuntimeManifest(manifest, source);
  const release = acquireInstallLock(root);
  const parent = root;
  let stageRoot = "";
  let stageEdcRoot = "";
  const backupRoot = join(parent, `.edc.backup.${process.pid}.${Date.now()}`);
  let promoted = false;
  try {
    if (process.env.EDC_RUNTIME_FAIL_BEFORE_STAGE === "1") {
      throw fail(structured("runtime-validation-failed", "simulated runtime install allocation failure before staging", "rerun the EDC installer", { stage: "before-stage" }));
    }
    stageRoot = mkdtempSync(join(parent, ".edc.stage."));
    stageEdcRoot = join(stageRoot, ".edc");
    mkdirSync(stageEdcRoot, { recursive: true });
    for (const artifact of manifest.artifacts) copyArtifact(source, artifact, stageEdcRoot);
    copyPreservedFiles(join(root, ".edc"), stageEdcRoot, manifest);
    const metadata = writeMetadata(stageEdcRoot, source, manifest);
    validateStageRoot(stageEdcRoot, source, manifest);
    if (process.env.EDC_RUNTIME_FAIL_AFTER_STAGE === "1") {
      throw fail(structured("runtime-validation-failed", "simulated runtime install interruption after staging", "rerun the EDC installer", { stage: "after-stage" }));
    }
    if (existsSync(join(root, ".edc"))) renameSync(join(root, ".edc"), backupRoot);
    try {
      renameSync(stageEdcRoot, join(root, ".edc"));
      validateInstalledTree(root, manifest, source);
      promoted = true;
    } catch (error) {
      rmSync(join(root, ".edc"), { recursive: true, force: true });
      if (existsSync(backupRoot)) renameSync(backupRoot, join(root, ".edc"));
      throw error;
    }
    rmSync(backupRoot, { recursive: true, force: true });
    rmSync(stageRoot, { recursive: true, force: true });
    return structured("success", "runtime installed", "", { fingerprint: metadata.fingerprint }, 0);
  } catch (error) {
    if (!promoted && existsSync(backupRoot) && !existsSync(join(root, ".edc"))) renameSync(backupRoot, join(root, ".edc"));
    if (stageRoot) rmSync(stageRoot, { recursive: true, force: true });
    throw error.result ? error : fail(structured("runtime-validation-failed", error.message || "runtime install failed", "rerun the EDC installer after fixing the reported runtime file"));
  } finally {
    release();
  }
}

function printResult(result) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

function command() {
  const [cmd, ...args] = process.argv.slice(2);
  try {
    if (cmd === "inventory-check") {
      const [sourceRoot] = args;
      validateRuntimeManifest(RUNTIME_MANIFEST, sourceRoot || "");
      printResult({ schemaVersion: RUNTIME_SCHEMA_VERSION, runtimeVersion: RUNTIME_VERSION, artifactCount: RUNTIME_MANIFEST.artifacts.length, fingerprint: sourceRoot ? runtimeFingerprint(sourceRoot) : "" });
      return;
    }
    if (cmd === "install") {
      const [globalRoot, sourceRoot] = args;
      if (!globalRoot || !sourceRoot) throw fail(structured("runtime-validation-failed", "runtime install requires global and source roots", "call the global runtime installer with explicit roots"));
      printResult(installRuntime(globalRoot, sourceRoot));
      return;
    }
    if (cmd === "source-preflight") {
      const [sourceRoot] = args;
      if (!sourceRoot) throw fail(structured("runtime-validation-failed", "runtime source preflight requires a source root", "reinstall EDC from a trusted package"));
      printResult(preflightRuntimeSource(sourceRoot));
      return;
    }
    throw fail(structured("runtime-validation-failed", "usage: runtime-manifest.mjs inventory-check|install|source-preflight", "rerun with a valid runtime command", { command: cmd || "" }, 64));
  } catch (error) {
    printResult(error.result || structured("runtime-validation-failed", error.message || "runtime command failed", "rerun EDC after repairing the runtime"));
    process.exit(error.result?.exitCode || 1);
  }
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(new URL(import.meta.url)) === realpathSync(process.argv[1])) command();
