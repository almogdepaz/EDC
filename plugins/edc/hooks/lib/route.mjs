/**
 * Shared routing/context-injection helpers.
 *
 * Used by:
 *   - plugins/edc/hooks/session-start.mjs (Claude Code, Cursor)
 *   - plugins/edc/hooks/pretooluse-context-inject.mjs (Claude Code, Cursor)
 *   - pi/index.mjs (Pi extension)
 *
 * Pure functions only — no stdin/stdout, no platform detection.
 */

import {
  closeSync,
  constants as fsConstants,
  fstatSync,
  openSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from "fs";
import { isAbsolute, join, relative, resolve, sep } from "path";
import { tmpdir } from "os";
import { createHash } from "crypto";
import { execFileSync } from "child_process";
import {
  EDC_CONTEXT_DIR,
  EDC_MANIFEST_REL,
  EDC_INDEX_REL,
  EDC_MODULES_DIR_REL,
} from "./paths.mjs";
// --- manifest ---

function loadManifest(projectRoot) {
  const manifestContent = readContainedRegularFile(projectRoot, EDC_CONTEXT_DIR, EDC_MANIFEST_REL);
  if (manifestContent === null) return null;
  try {
    return JSON.parse(manifestContent);
  } catch {
    return null;
  }
}

// --- staleness ---

function checkStaleness(projectRoot, manifest) {
  const sourceCommit = manifest?.sourceCommit;
  if (!sourceCommit) return null;
  try {
    const head = execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: projectRoot,
      timeout: 3000,
      encoding: "utf-8",
    }).trim();
    if (head !== sourceCommit) {
      return { stale: true, sourceCommit, headCommit: head };
    }
    return { stale: false, sourceCommit, headCommit: head };
  } catch {
    return null;
  }
}

export function getContextFreshness(projectRoot) {
  const manifest = loadManifest(projectRoot);
  if (!manifest) return { state: "missing", reason: "manifest" };

  const indexContent = readContainedRegularFile(projectRoot, EDC_CONTEXT_DIR, EDC_INDEX_REL);
  if (indexContent === null) return { state: "missing", reason: "index" };
  if (!/^##/m.test(indexContent)) {
    return { state: "missing", reason: "index-structure" };
  }

  let headCommit;
  try {
    headCommit = execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: projectRoot,
      timeout: 3000,
      encoding: "utf-8",
    }).trim();
  } catch {
    return { state: "unknown", reason: "git" };
  }

  const sourceCommit = manifest.sourceCommit || "";
  if (sourceCommit !== headCommit) {
    return { state: "stale", sourceCommit, headCommit };
  }

  return { state: "fresh", sourceCommit, headCommit };
}

// --- file path extraction ---

/**
 * Extract candidate file paths from a tool invocation.
 * Accepts both Claude-style (Bash/Edit/Write) and pi-style (bash/edit/write)
 * tool names so this lib is shared across runtimes.
 */
function extractFilePaths(toolName, toolInput) {
  const t = String(toolName || "").toLowerCase();
  if (t === "edit" || t === "write") {
    const fp = toolInput?.file_path;
    return fp ? [fp] : [];
  }
  if (t === "bash") {
    return extractFilePathsFromBash(toolInput?.command || "");
  }
  return [];
}

function extractFilePathsFromBash(command) {
  const paths = new Set();

  // Deterministic escape hatch for complex shell syntax that regex tokenization
  // cannot parse safely: one explicit path per comment line.
  const hintPattern = /(?:^|\n)\s*#\s*edc-context-path:\s*(.+?)(?=\r?\n|$)/g;
  let match;
  while ((match = hintPattern.exec(command)) !== null) {
    const hintedPath = match[1].trim();
    if (hintedPath) paths.add(hintedPath);
  }

  // Catch any path-shaped token: optional ./ or /, then at least one
  // dir/segment pair (extensionless OK). Routing filters non-matches.
  const pathPattern = /(?:^|[\s=:'"`])(\.{0,2}\/?[\w.-]+(?:\/[\w.-]+)+)/g;
  while ((match = pathPattern.exec(command)) !== null) {
    paths.add(match[1]);
  }
  return [...paths];
}

export function normalizePath(p, projectRoot) {
  let normalized = p.replace(/^\.\//, "");
  if (projectRoot) {
    const root = projectRoot.replace(/\/+$/, "");
    if (normalized === root) {
      normalized = "";
    } else if (normalized.startsWith(`${root}/`)) {
      normalized = normalized.slice(root.length + 1);
    }
  }
  return normalized;
}

// --- routing ---

const MAX_GLOB_DIAGNOSTIC_CHARS = 200;

function formatGlobPatternForDiagnostic(pattern) {
  const text = String(pattern);
  const bounded = text.length > MAX_GLOB_DIAGNOSTIC_CHARS ? `${text.slice(0, MAX_GLOB_DIAGNOSTIC_CHARS)}…` : text;
  return JSON.stringify(bounded);
}

export class InvalidGlobPatternError extends Error {
  constructor(pattern, cause) {
    super(`invalid glob pattern ${formatGlobPatternForDiagnostic(pattern)}`, { cause });
    this.name = "InvalidGlobPatternError";
    this.pattern = String(pattern);
  }
}

/**
 * Convert an EDC manifest glob pattern into a RegExp. Supports `*` (no slash),
 * `**` (any), `?` (single non-slash),
 * and `[...]` character classes. Anchored.
 */
function globToRegex(glob) {
  let re = "^";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        re += ".*";
        i++;
      } else {
        re += "[^/]*";
      }
    } else if (c === "?") {
      re += "[^/]";
    } else if (c === "[") {
      const end = glob.indexOf("]", i + 1);
      if (end === -1) {
        re += "\\[";
      } else {
        re += glob.slice(i, end + 1);
        i = end;
      }
    } else if (/[.+^$(){}|\\]/.test(c)) {
      re += "\\" + c;
    } else {
      re += c;
    }
  }
  re += "$";
  try {
    return new RegExp(re);
  } catch (error) {
    throw new InvalidGlobPatternError(glob, error);
  }
}

export function validateClassifierGlobs(manifest, ignorePatterns = []) {
  for (const pattern of ignorePatterns) globToRegex(pattern);
  for (const mod of manifest?.modules || []) {
    for (const pattern of mod?.match?.globs || []) globToRegex(pattern);
  }
  for (const entry of manifest?.contextless?.entries || []) {
    for (const pattern of entry?.globs || []) globToRegex(pattern);
  }
  for (const pattern of manifest?.unmapped?.allowedGlobs || []) globToRegex(pattern);
}

function pathMatchesPattern(filePath, pattern) {
  if (pattern.endsWith("/")) return filePath.startsWith(pattern);
  return filePath === pattern || filePath.startsWith(`${pattern}/`) || globToRegex(pattern).test(filePath);
}

function routeFileStateSync(manifest, filePath) {
  if (!manifest || !Array.isArray(manifest.modules)) return { state: "uncovered" };

  const exact = [];
  const prefix = [];
  const globs = [];
  for (const mod of manifest.modules) {
    const name = mod.name;
    if (!name) continue;
    const prio = Number(mod.priority || 0);
    const m = mod.match || {};
    for (const p of m.exactFiles || []) exact.push({ name, prio, pattern: p });
    for (const p of m.prefixes || []) prefix.push({ name, prio, pattern: p });
    for (const p of m.globs || []) globs.push({ name, prio, pattern: p });
  }

  const pickWinner = (candidates) => {
    if (candidates.length === 0) return undefined;
    let maxP = -Infinity;
    for (const candidate of candidates) if (candidate.prio > maxP) maxP = candidate.prio;
    const tops = candidates.filter((candidate) => candidate.prio === maxP);
    const names = new Set(tops.map((candidate) => candidate.name));
    if (names.size === 1) return tops[0].name;
    return null;
  };

  const t1 = exact.filter((rule) => rule.pattern === filePath);
  if (t1.length > 0) {
    const winner = pickWinner(t1);
    return winner ? { state: "context-module", module: winner } : { state: "ambiguous" };
  }

  const t2Hits = prefix.filter((rule) => filePath.startsWith(rule.pattern));
  if (t2Hits.length > 0) {
    let maxLen = 0;
    for (const rule of t2Hits) if (rule.pattern.length > maxLen) maxLen = rule.pattern.length;
    const longest = t2Hits.filter((rule) => rule.pattern.length === maxLen);
    const winner = pickWinner(longest);
    return winner ? { state: "context-module", module: winner } : { state: "ambiguous" };
  }

  const seenModules = new Set();
  const t3 = [];
  for (const rule of globs) {
    if (seenModules.has(rule.name)) continue;
    if (globToRegex(rule.pattern).test(filePath)) {
      seenModules.add(rule.name);
      t3.push(rule);
    }
  }
  if (t3.length > 0) {
    const winner = pickWinner(t3);
    return winner ? { state: "context-module", module: winner } : { state: "ambiguous" };
  }

  return { state: "uncovered" };
}

function contextlessMatches(manifest, filePath, source) {
  const matches = [];
  if (source === "explicit") {
    for (const entry of manifest?.contextless?.entries || []) {
      const id = entry.id;
      if (!id) continue;
      const policy = entry.reviewPolicy || "account-only";
      for (const pattern of entry.globs || []) {
        if (pathMatchesPattern(filePath, pattern)) matches.push(`${id}:${policy}`);
      }
    }
  } else {
    for (const pattern of manifest?.unmapped?.allowedGlobs || []) {
      if (pathMatchesPattern(filePath, pattern)) matches.push("legacy-unmapped:account-only");
    }
  }
  return [...new Set(matches)];
}

/**
 * Classify a path into exactly one context coverage state. This is the single
 * classifier implementation used directly by JS callers and by classify-cli.mjs.
 */
export function classifyPathSync(manifest, filePath, ignorePatterns = []) {
  for (const pattern of ignorePatterns) {
    if (pathMatchesPattern(filePath, pattern)) return "ignored";
  }

  const routeState = routeFileStateSync(manifest, filePath);
  if (routeState.state === "ambiguous") return "ambiguous";

  const explicitContextless = contextlessMatches(manifest, filePath, "explicit");
  const legacyContextless = contextlessMatches(manifest, filePath, "legacy");
  const explicitState =
    explicitContextless.length === 0
      ? null
      : explicitContextless.length === 1
        ? `contextless:${explicitContextless[0]}`
        : "ambiguous";
  const legacyState =
    legacyContextless.length === 0
      ? null
      : legacyContextless.length === 1
        ? `contextless:${legacyContextless[0]}`
        : "ambiguous";

  if (routeState.state === "context-module") {
    return explicitState ? "ambiguous" : `context-module:${routeState.module}`;
  }
  return explicitState || legacyState || "uncovered";
}

/**
 * Route a file path to a module, in-process. Returns null on no-match or ambiguity.
 */
export function routeFileSync(manifest, filePath) {
  const state = routeFileStateSync(manifest, filePath);
  return state.state === "context-module" ? state.module : null;
}

function moduleDocPath(manifest, moduleName) {
  const mod = (manifest.modules || []).find((m) => m.name === moduleName);
  if (!mod) return null;
  return Object.prototype.hasOwnProperty.call(mod, "doc")
    ? mod.doc
    : `${EDC_MODULES_DIR_REL}/${moduleName}.md`;
}

function isPathInside(root, candidate) {
  const rel = relative(root, candidate);
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

function readContainedRegularFile(projectRoot, containmentRootRel, fileRel) {
  let fd;
  try {
    const physicalProjectRoot = realpathSync(projectRoot);
    const expectedContainmentRoot = resolve(physicalProjectRoot, containmentRootRel);
    const physicalContainmentRoot = realpathSync(join(projectRoot, containmentRootRel));
    if (physicalContainmentRoot !== expectedContainmentRoot) return null;

    const declaredFilePath = resolve(projectRoot, fileRel);
    const physicalFilePath = realpathSync(declaredFilePath);
    if (!isPathInside(physicalContainmentRoot, physicalFilePath)) return null;

    const noFollow = typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0;
    fd = openSync(physicalFilePath, fsConstants.O_RDONLY | noFollow);
    const openedStat = fstatSync(fd);
    if (!openedStat.isFile()) return null;

    const freshPhysicalFilePath = realpathSync(declaredFilePath);
    if (!isPathInside(physicalContainmentRoot, freshPhysicalFilePath)) return null;
    const declaredStat = statSync(declaredFilePath);
    if (declaredStat.dev !== openedStat.dev || declaredStat.ino !== openedStat.ino) return null;

    return readFileSync(fd, "utf-8");
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {
        // Best effort: the descriptor may already have been closed after an I/O error.
      }
    }
  }
}

function readModuleDoc(projectRoot, docRel) {
  if (typeof docRel !== "string"
    || isAbsolute(docRel)
    || !docRel.startsWith(`${EDC_MODULES_DIR_REL}/`)
    || docRel.split(/[\\/]/).includes("..")) {
    return null;
  }
  return readContainedRegularFile(projectRoot, EDC_MODULES_DIR_REL, docRel);
}

// --- dedup ---

function hashId(id) {
  return createHash("sha256").update(id).digest("hex").slice(0, 16);
}

function dedupPath(sessionId) {
  const safe = /^[a-zA-Z0-9_-]+$/.test(sessionId)
    ? sessionId
    : hashId(sessionId);
  return join(tmpdir(), `edc-injected-modules-${safe}.json`);
}

/**
 * Returns true if the module was already injected for this session.
 * Side-effect: marks the module injected on first call.
 */
function isDuplicate(sessionId, moduleName) {
  if (!sessionId) return false;
  const path = dedupPath(sessionId);
  let injected = {};
  try {
    injected = JSON.parse(readFileSync(path, "utf-8"));
  } catch {
    // first invocation or corrupt file
  }

  if (injected[moduleName]) return true;

  injected[moduleName] = Date.now();
  try {
    writeFileSync(path, JSON.stringify(injected));
  } catch {
    // best effort
  }
  return false;
}

// --- composite helper for session_start ---

/**
 * Build the session-start context block.
 * Returns { content: string, mode: "advisory" | "inject" | "no-context" }.
 * `content` is empty string when the hook should be a no-op. Missing context is
 * intentionally silent: globally installed extensions must not steer unrelated
 * agent sessions into EDC setup work.
 */
export function buildSessionStartContent(projectRoot) {
  const manifest = loadManifest(projectRoot);

  if (!manifest) {
    return { mode: "no-context", content: "" };
  }

  const defaultMode = manifest.policy?.defaultMode;
  if (defaultMode === "advisory") {
    return { mode: "advisory", content: "" };
  }
  if (defaultMode !== "inject") {
    return { mode: "no-context", content: "" };
  }

  const parts = [];
  const staleness = checkStaleness(projectRoot, manifest);
  if (staleness?.stale) {
    parts.push(
      [
        "## EDC Staleness Warning",
        "",
        `Context was built at commit \`${staleness.sourceCommit.slice(0, 8)}\` but HEAD is \`${staleness.headCommit.slice(0, 8)}\`.`,
        "Run `/edc-build` to update.",
      ].join("\n"),
    );
  }
  const indexContent = readContainedRegularFile(projectRoot, EDC_CONTEXT_DIR, EDC_INDEX_REL);
  if (indexContent !== null) parts.push(indexContent);
  return { mode: "inject", content: parts.join("\n\n") };
}

/**
 * Build the pre-tool-use context-injection payload.
 * Returns { moduleName, content, normalizedPath } or null.
 *
 * Caller is responsible for session-level dedup and for emitting/formatting.
 */
export function buildToolCallInjection({
  projectRoot,
  toolName,
  toolInput,
  sessionId,
}) {
  const manifest = loadManifest(projectRoot);
  if (!manifest) return null;
  if (manifest.policy?.defaultMode !== "inject") return null;

  const filePaths = extractFilePaths(toolName, toolInput);
  if (filePaths.length === 0) return null;

  const seen = new Set();
  const injections = [];
  for (const fp of filePaths) {
    const normalized = normalizePath(fp, projectRoot);
    const moduleName = routeFileSync(manifest, normalized);
    if (!moduleName || seen.has(moduleName)) continue;
    seen.add(moduleName);

    const docRel = moduleDocPath(manifest, moduleName);
    if (!docRel) continue;
    const content = readModuleDoc(projectRoot, docRel);
    if (content === null) continue;

    if (isDuplicate(sessionId, moduleName)) continue;

    const header = `[edc] Auto-injected context for module "${moduleName}" (touching ${normalized})`;
    injections.push({
      moduleName,
      normalizedPath: normalized,
      content: `${header}\n\n${content}`,
    });
  }
  if (injections.length === 0) return null;
  return {
    moduleName: injections[0].moduleName,
    normalizedPath: injections[0].normalizedPath,
    content: injections.map((injection) => injection.content).join("\n\n"),
  };
}
