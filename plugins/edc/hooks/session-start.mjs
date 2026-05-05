import { readFileSync, existsSync, copyFileSync, statSync, chmodSync } from "fs";
import { mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { execFileSync } from "child_process";

// --- I/O helpers ---

function parseInput(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function detectPlatform(input) {
  if (
    input &&
    ("conversation_id" in input ||
      "cursor_version" in input ||
      "workspace_roots" in input)
  ) {
    return "cursor";
  }
  return "claude-code";
}

function resolveProjectRoot(input) {
  if (input?.cwd) return input.cwd;
  return (
    process.env.CLAUDE_PROJECT_ROOT ||
    process.env.CURSOR_PROJECT_DIR ||
    process.cwd()
  );
}

function formatOutput(platform, content) {
  if (!content) return "";
  if (platform === "cursor") {
    return JSON.stringify({ additional_context: content });
  }
  // claude-code: plain string
  return content;
}

// --- manifest loading ---

function loadManifest(projectRoot) {
  const manifestPath = join(projectRoot, ".context", "manifest.json");
  if (!existsSync(manifestPath)) return null;
  try {
    return JSON.parse(readFileSync(manifestPath, "utf-8"));
  } catch {
    return null;
  }
}

// --- staleness check ---

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

// --- script install ---
// Copy edc-review.sh from plugin bundle into project's .edc/scripts/ if missing or stale.
// Only runs inside an EDC-aware project: requires either .git/ or .context/manifest.json
// so a stray session in ~/Downloads doesn't drop .edc/scripts/ into random dirs.

function isEdcProject(projectRoot) {
  return (
    existsSync(join(projectRoot, ".git")) ||
    existsSync(join(projectRoot, ".context", "manifest.json"))
  );
}

function installOrchestratorScript(projectRoot) {
  if (!isEdcProject(projectRoot)) return;

  const pluginDir = dirname(dirname(fileURLToPath(import.meta.url)));
  const pluginScript = join(pluginDir, "scripts", "edc-review.sh");
  if (!existsSync(pluginScript)) return; // plugin bundle missing script — skip silently

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

// --- main ---

function main() {
  let raw = "";
  try {
    raw = readFileSync(0, "utf-8");
  } catch {
    // no stdin
  }

  const input = parseInput(raw);
  const platform = detectPlatform(input);
  const projectRoot = resolveProjectRoot(input);

  // ensure orchestrator script is installed in project
  installOrchestratorScript(projectRoot);

  const manifest = loadManifest(projectRoot);
  const indexPath = join(projectRoot, ".context", "index.md");

  const parts = [];

  if (!manifest) {
    parts.push(
      [
        "## EDC Context",
        "",
        "No codebase context built yet. Run `/edc:edc-build` to generate deep architectural context.",
        "This enables automatic context injection when editing files.",
      ].join("\n"),
    );
  } else {
    // advisory mode: hook is a no-op
    if (manifest.policy?.defaultMode === "advisory") {
      return;
    }

    const staleness = checkStaleness(projectRoot, manifest);
    if (staleness?.stale) {
      parts.push(
        [
          "## EDC Staleness Warning",
          "",
          `Context was built at commit \`${staleness.sourceCommit.slice(0, 8)}\` but HEAD is \`${staleness.headCommit.slice(0, 8)}\`.`,
          "Run `/edc:edc-build` to update.",
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
  }

  const output = formatOutput(platform, parts.join("\n\n"));
  if (output) {
    process.stdout.write(output);
  }
}

try {
  main();
} catch (err) {
  process.stderr.write(
    `[${new Date().toISOString()}] edc session-start hook error: ${err.message}\n`,
  );
  // always output valid content (empty = no injection)
  process.stdout.write("");
}
