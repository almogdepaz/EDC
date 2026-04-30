import { readFileSync, writeFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { tmpdir } from "os";
import { createHash } from "crypto";
import { execFileSync } from "child_process";

// --- I/O helpers ---

function parseInput(raw) {
  try {
    const parsed = JSON.parse(raw);
    return {
      toolName: parsed.tool_name || "",
      toolInput: parsed.tool_input || {},
      sessionId: parsed.session_id || parsed.conversation_id || "",
      cwd:
        parsed.cwd ||
        parsed.workspace_roots?.[0] ||
        process.env.CLAUDE_PROJECT_ROOT ||
        process.env.CURSOR_PROJECT_DIR ||
        process.cwd(),
      hookEventName: parsed.hook_event_name || "PreToolUse",
      raw: parsed,
    };
  } catch {
    return null;
  }
}

function detectPlatform(raw) {
  if (
    raw &&
    ("conversation_id" in raw ||
      "cursor_version" in raw ||
      "workspace_roots" in raw)
  ) {
    return "cursor";
  }
  return "claude-code";
}

function formatOutput(platform, hookEventName, content) {
  if (!content) return "{}";
  if (platform === "cursor") {
    return JSON.stringify({ additional_context: content });
  }
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName,
      additionalContext: content,
    },
  });
}

// --- file path extraction ---

function extractFilePaths(toolName, toolInput) {
  if (toolName === "Edit" || toolName === "Write") {
    const fp = toolInput.file_path;
    return fp ? [fp] : [];
  }
  if (toolName === "Bash") {
    return extractFilePathsFromBash(toolInput.command || "");
  }
  return [];
}

function extractFilePathsFromBash(command) {
  const paths = [];
  const extPattern =
    /(?:^|\s)((?:\.\/|\/|[\w.-]+\/)+[\w.-]+\.(?:ts|tsx|js|jsx|mjs|cjs|py|rs|go|java|rb|css|scss|html|json|yaml|yml|toml|md|sql|sh|svelte|vue))\b/g;
  let match;
  while ((match = extPattern.exec(command)) !== null) {
    paths.push(match[1]);
  }
  return paths;
}

// --- manifest + routing ---

function loadManifest(projectRoot) {
  const manifestPath = join(projectRoot, ".context", "manifest.json");
  if (!existsSync(manifestPath)) return null;
  try {
    return JSON.parse(readFileSync(manifestPath, "utf-8"));
  } catch {
    return null;
  }
}

function normalizePath(p, projectRoot) {
  let normalized = p.replace(/^\.\//, "");
  if (projectRoot && normalized.startsWith(projectRoot)) {
    normalized = normalized.slice(projectRoot.length).replace(/^\//, "");
  }
  return normalized;
}

function routeScriptPath() {
  const pluginDir = dirname(dirname(fileURLToPath(import.meta.url)));
  return join(pluginDir, "scripts", "edc-route.sh");
}

function routeFile(manifestPath, filePath) {
  const route = routeScriptPath();
  if (!existsSync(route)) return null;
  try {
    const out = execFileSync(route, [manifestPath, filePath], {
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

function moduleDocPath(manifest, moduleName) {
  const mod = (manifest.modules || []).find((m) => m.name === moduleName);
  if (!mod) return null;
  return mod.doc || `.context/modules/${moduleName}.md`;
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

// --- main ---

function main() {
  let raw = "";
  try {
    raw = readFileSync(0, "utf-8");
  } catch {
    return "{}";
  }

  const input = parseInput(raw);
  if (!input) return "{}";

  const platform = detectPlatform(input.raw);
  const projectRoot = input.cwd;

  const manifest = loadManifest(projectRoot);
  if (!manifest) return "{}";

  // advisory mode: hook is a no-op
  if (manifest.policy?.defaultMode === "advisory") return "{}";

  const filePaths = extractFilePaths(input.toolName, input.toolInput);
  if (filePaths.length === 0) return "{}";

  const manifestPath = join(projectRoot, ".context", "manifest.json");

  const seen = new Set();
  for (const fp of filePaths) {
    const normalized = normalizePath(fp, projectRoot);
    const moduleName = routeFile(manifestPath, normalized);
    if (!moduleName || seen.has(moduleName)) continue;
    seen.add(moduleName);

    if (isDuplicate(input.sessionId, moduleName)) continue;

    const docRel = moduleDocPath(manifest, moduleName);
    if (!docRel) continue;
    const docPath = join(projectRoot, docRel);
    if (!existsSync(docPath)) continue;

    try {
      const content = readFileSync(docPath, "utf-8");
      const header = `[edc] Auto-injected context for module "${moduleName}" (editing ${normalized})`;
      return formatOutput(
        platform,
        input.hookEventName,
        `${header}\n\n${content}`,
      );
    } catch {
      continue;
    }
  }

  return "{}";
}

try {
  const output = main();
  process.stdout.write(output);
} catch (err) {
  process.stderr.write(
    `[${new Date().toISOString()}] edc pretooluse hook error: ${err.message}\n`,
  );
  process.stdout.write("{}");
}
