/**
 * Shared routing/context-injection helpers.
 *
 * Used by:
 *   - plugins/edc/hooks/session-start.mjs (Claude Code, Cursor)
 *   - plugins/edc/hooks/pretooluse-context-inject.mjs (Claude Code, Cursor)
 *   - agents/pi/index.mjs (Pi extension)
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
      existsSync(join(dir, "scripts", "edc-route.sh")) &&
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

export function loadManifest(projectRoot) {
  const manifestPath = join(projectRoot, EDC_MANIFEST_REL);
  if (!existsSync(manifestPath)) return null;
  try {
    return JSON.parse(readFileSync(manifestPath, "utf-8"));
  } catch {
    return null;
  }
}

export function manifestPath(projectRoot) {
  return join(projectRoot, EDC_MANIFEST_REL);
}

// --- staleness ---

export function checkStaleness(projectRoot, manifest) {
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

// --- file path extraction ---

/**
 * Extract candidate file paths from a tool invocation.
 * Accepts both Claude-style (Bash/Edit/Write) and pi-style (bash/edit/write)
 * tool names so this lib is shared across runtimes.
 */
export function extractFilePaths(toolName, toolInput) {
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

export function extractFilePathsFromBash(command) {
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
  if (projectRoot && normalized.startsWith(projectRoot)) {
    normalized = normalized.slice(projectRoot.length).replace(/^\//, "");
  }
  return normalized;
}

// --- routing ---

export function routeFile(manifestPathArg, filePath, pluginRoot) {
  const route = join(pluginRoot, "scripts", "edc-route.sh");
  if (!existsSync(route)) return null;
  try {
    const out = execFileSync(route, [manifestPathArg, filePath], {
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const name = out.trim();
    return name || null;
  } catch {
    // exit 1 (no match) or 2 (ambiguous) — both surface as no module
    return null;
  }
}

export function moduleDocPath(manifest, moduleName) {
  const mod = (manifest.modules || []).find((m) => m.name === moduleName);
  if (!mod) return null;
  return mod.doc || `${EDC_MODULES_DIR_REL}/${moduleName}.md`;
}

// --- dedup ---

function hashId(id) {
  return createHash("sha256").update(id).digest("hex").slice(0, 16);
}

export function dedupPath(sessionId) {
  const safe = /^[a-zA-Z0-9_-]+$/.test(sessionId)
    ? sessionId
    : hashId(sessionId);
  return join(tmpdir(), `edc-injected-modules-${safe}.json`);
}

/**
 * Returns true if the module was already injected for this session.
 * Side-effect: marks the module injected on first call.
 */
export function isDuplicate(sessionId, moduleName) {
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

// --- orchestrator script install ---

export function isEdcProject(projectRoot) {
  return (
    existsSync(join(projectRoot, ".git")) ||
    existsSync(join(projectRoot, EDC_MANIFEST_REL))
  );
}

/**
 * Copy plugins/edc/scripts/edc-review.sh into <projectRoot>/.edc/scripts/
 * if missing or stale. Idempotent. Best-effort (logs warnings, never throws).
 */
export function installOrchestratorScript(projectRoot, pluginRoot) {
  if (!isEdcProject(projectRoot)) return;

  const pluginScript = join(pluginRoot, "scripts", "edc-review.sh");
  if (!existsSync(pluginScript)) return;

  const destDir = join(projectRoot, ".edc", "scripts");
  const destScript = join(destDir, "edc-review.sh");

  let shouldCopy = !existsSync(destScript);
  if (!shouldCopy) {
    try {
      const srcMtime = statSync(pluginScript).mtimeMs;
      const dstMtime = statSync(destScript).mtimeMs;
      shouldCopy = srcMtime > dstMtime;
    } catch {
      shouldCopy = true;
    }
  }

  if (shouldCopy) {
    try {
      mkdirSync(destDir, { recursive: true });
      copyFileSync(pluginScript, destScript);
      chmodSync(destScript, 0o755);
    } catch (err) {
      process.stderr.write(
        `[edc] WARNING: could not install edc-review.sh: ${err.message}\n`,
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

  const mPath = manifestPath(projectRoot);
  const seen = new Set();
  for (const fp of filePaths) {
    const normalized = normalizePath(fp, projectRoot);
    const moduleName = routeFile(mPath, normalized, pluginRoot);
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
