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
  readFileSync,
  writeFileSync,
  existsSync,
  copyFileSync,
  statSync,
  chmodSync,
  mkdirSync,
  readdirSync,
} from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { tmpdir } from "os";
import { createHash } from "crypto";
import { execFileSync } from "child_process";
import {
  EDC_CONTEXT_DIR,
  EDC_MANIFEST_REL,
  EDC_INDEX_REL,
  EDC_MODULES_DIR_REL,
} from "./paths.mjs";

// --- plugin layout ---

/**
 * Resolve the plugin root (directory containing scripts/, hooks/, skills/).
 * `metaUrl` is `import.meta.url` of the importing file under hooks/.
 * Falls back to env override when called from outside the plugin tree
 * (e.g. the pi extension shipped from repo root).
 */
export function resolvePluginRoot(metaUrl) {
  if (process.env.EDC_PLUGIN_ROOT) return process.env.EDC_PLUGIN_ROOT;
  // metaUrl points at .../hooks/lib/route.mjs OR .../hooks/<file>.mjs
  // Walk up until we find the dir containing scripts/ + skills/.
  let dir = dirname(fileURLToPath(metaUrl));
  for (let i = 0; i < 6; i++) {
    if (
      existsSync(join(dir, "scripts", "edc-review.sh")) &&
      existsSync(join(dir, "skills"))
    ) {
      return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  // last-resort: assume two-up from this file
  return dirname(dirname(fileURLToPath(metaUrl)));
}

// --- manifest ---

function loadManifest(projectRoot) {
  const manifestPath = join(projectRoot, EDC_MANIFEST_REL);
  if (!existsSync(manifestPath)) return null;
  try {
    return JSON.parse(readFileSync(manifestPath, "utf-8"));
  } catch {
    return null;
  }
}

function manifestPath(projectRoot) {
  return join(projectRoot, EDC_MANIFEST_REL);
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

  const indexPath = join(projectRoot, EDC_INDEX_REL);
  if (!existsSync(indexPath)) return { state: "missing", reason: "index" };

  try {
    if (!/^##/m.test(readFileSync(indexPath, "utf-8"))) {
      return { state: "missing", reason: "index-structure" };
    }
  } catch {
    return { state: "missing", reason: "index" };
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
  // Catch any path-shaped token: optional ./ or /, then at least one
  // dir/segment pair (extensionless OK). Routing filters non-matches.
  const pathPattern = /(?:^|[\s=:'"`])(\.{0,2}\/?[\w.-]+(?:\/[\w.-]+)+)/g;
  let match;
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
  return new RegExp(re);
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

/**
 * Legacy signature kept for any external caller. Loads the manifest from disk
 * and dispatches to routeFileSync. New code should call routeFileSync directly
 * with an already-parsed manifest to avoid the file read.
 *
 * The third param (pluginRoot) is unused — routing is pure JS.
 */
function routeFile(manifestPathArg, filePath, _pluginRoot) {
  if (!existsSync(manifestPathArg)) return null;
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPathArg, "utf-8"));
  } catch {
    return null;
  }
  return routeFileSync(manifest, filePath);
}

function moduleDocPath(manifest, moduleName) {
  const mod = (manifest.modules || []).find((m) => m.name === moduleName);
  if (!mod) return null;
  return mod.doc || `${EDC_MODULES_DIR_REL}/${moduleName}.md`;
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

// --- project-local runtime install ---

function isEdcProject(projectRoot) {
  return (
    existsSync(join(projectRoot, ".git")) ||
    existsSync(join(projectRoot, EDC_MANIFEST_REL))
  );
}

/**
 * Copy runtime scripts and private prompt bundles into <projectRoot>/.edc/ if
 * missing or stale. Idempotent. Best-effort (logs warnings, never throws).
 *
 * The project-local .edc/skills tree is intentionally NOT a pi skill location;
 * it is private prompt material consumed by edc-lib.sh in spawned subprocesses.
 */
export function installOrchestratorScript(projectRoot, pluginRoot) {
  if (!isEdcProject(projectRoot)) return;

  installScriptFiles(projectRoot, pluginRoot);
  installClassifierRuntime(projectRoot, pluginRoot);
  installPrivatePromptBundles(projectRoot, pluginRoot);
}

function shouldCopyFile(src, dst) {
  if (!existsSync(dst)) return true;
  try {
    return statSync(src).mtimeMs > statSync(dst).mtimeMs;
  } catch {
    return true;
  }
}

function installScriptFiles(projectRoot, pluginRoot) {
  const sourceDir = join(pluginRoot, "scripts");
  if (!existsSync(sourceDir)) return;

  const destDir = join(projectRoot, ".edc", "scripts");

  let scriptNames;
  try {
    scriptNames = readdirSync(sourceDir).filter(
      (name) => name === "edc" || (name.endsWith(".sh") && name !== "edc-spawn-analyze.sh"),
    );
  } catch {
    return;
  }

  for (const scriptName of scriptNames) {
    const pluginScript = join(sourceDir, scriptName);
    const destScript = join(destDir, scriptName);
    if (!shouldCopyFile(pluginScript, destScript)) continue;

    try {
      mkdirSync(destDir, { recursive: true });
      copyFileSync(pluginScript, destScript);
      chmodSync(destScript, 0o755);
    } catch (err) {
      process.stderr.write(
        `[edc] WARNING: could not install ${scriptName}: ${err.message}\n`,
      );
    }
  }
}

function installClassifierRuntime(projectRoot, pluginRoot) {
  const sourceDir = join(pluginRoot, "hooks", "lib");
  const destDir = join(projectRoot, ".edc", "hooks", "lib");
  for (const fileName of ["classify-cli.mjs", "json-cli.mjs", "pi-supervisor.mjs", "stream-filter.mjs", "route.mjs", "paths.mjs"]) {
    const src = join(sourceDir, fileName);
    const dst = join(destDir, fileName);
    if (!existsSync(src) || !shouldCopyFile(src, dst)) continue;
    try {
      mkdirSync(destDir, { recursive: true });
      copyFileSync(src, dst);
      if (["classify-cli.mjs", "json-cli.mjs", "pi-supervisor.mjs", "stream-filter.mjs"].includes(fileName)) chmodSync(dst, 0o755);
    } catch (err) {
      process.stderr.write(
        `[edc] WARNING: could not install classifier runtime ${fileName}: ${err.message}\n`,
      );
    }
  }
}

function installPrivatePromptBundles(projectRoot, pluginRoot) {
  const bundleRoots = [join(pluginRoot, "prompt-bundles"), join(pluginRoot, "skills")];
  const destRoot = join(projectRoot, ".edc", "skills");

  for (const bundleRoot of bundleRoots) {
    if (!existsSync(bundleRoot)) continue;
    let bundleNames;
    try {
      bundleNames = readdirSync(bundleRoot).filter((name) =>
        existsSync(join(bundleRoot, name, "SKILL.md")),
      );
    } catch {
      continue;
    }

    for (const bundleName of bundleNames) {
      copyTreeIfStale(join(bundleRoot, bundleName), join(destRoot, bundleName));
    }
  }
}

function copyTreeIfStale(sourceDir, destDir) {
  let entries;
  try {
    entries = readdirSync(sourceDir, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    const src = join(sourceDir, entry.name);
    const dst = join(destDir, entry.name);
    if (entry.isDirectory()) {
      copyTreeIfStale(src, dst);
      continue;
    }
    if (!entry.isFile() || !shouldCopyFile(src, dst)) continue;

    try {
      mkdirSync(destDir, { recursive: true });
      copyFileSync(src, dst);
    } catch (err) {
      process.stderr.write(
        `[edc] WARNING: could not install prompt bundle file ${entry.name}: ${err.message}\n`,
      );
    }
  }
}

// --- composite helper for session_start ---

/**
 * Build the session-start context block.
 * Returns { content: string, mode: "advisory" | "inject" | "no-context" }.
 * `content` is empty string when the hook should be a no-op
 * (advisory mode, or no manifest with no notice — caller decides).
 */
export function buildSessionStartContent(projectRoot) {
  const manifest = loadManifest(projectRoot);
  const indexPath = join(projectRoot, EDC_INDEX_REL);

  if (!manifest) {
    return {
      mode: "no-context",
      content: [
        "## EDC Context",
        "",
        "No codebase context built yet. Run `/edc-build` to generate deep architectural context.",
        "This enables automatic context injection when editing files.",
      ].join("\n"),
    };
  }

  if (manifest.policy?.defaultMode === "advisory") {
    return { mode: "advisory", content: "" };
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
  if (existsSync(indexPath)) {
    try {
      parts.push(readFileSync(indexPath, "utf-8"));
    } catch {
      // file disappeared between check and read
    }
  }
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
  pluginRoot,
  sessionId,
}) {
  const manifest = loadManifest(projectRoot);
  if (!manifest) return null;
  if (manifest.policy?.defaultMode === "advisory") return null;

  const filePaths = extractFilePaths(toolName, toolInput);
  if (filePaths.length === 0) return null;

  const seen = new Set();
  for (const fp of filePaths) {
    const normalized = normalizePath(fp, projectRoot);
    const moduleName = routeFileSync(manifest, normalized);
    if (!moduleName || seen.has(moduleName)) continue;
    seen.add(moduleName);

    if (isDuplicate(sessionId, moduleName)) continue;

    const docRel = moduleDocPath(manifest, moduleName);
    if (!docRel) continue;
    const docPath = join(projectRoot, docRel);
    if (!existsSync(docPath)) continue;

    try {
      const content = readFileSync(docPath, "utf-8");
      const header = `[edc] Auto-injected context for module "${moduleName}" (touching ${normalized})`;
      return {
        moduleName,
        normalizedPath: normalized,
        content: `${header}\n\n${content}`,
      };
    } catch {
      continue;
    }
  }
  return null;
}
