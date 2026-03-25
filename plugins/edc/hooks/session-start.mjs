import { readFileSync, existsSync } from "fs";
import { join } from "path";
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

// --- staleness check ---

function checkStaleness(projectRoot) {
  const metaPath = join(projectRoot, ".context", ".meta.json");
  if (!existsSync(metaPath)) return null;

  try {
    const meta = JSON.parse(readFileSync(metaPath, "utf-8"));
    const lastCommit = meta.lastCommit;
    if (!lastCommit) return null;

    const head = execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: projectRoot,
      timeout: 3000,
      encoding: "utf-8",
    }).trim();

    if (head !== lastCommit) {
      return { stale: true, lastCommit, headCommit: head };
    }
    return { stale: false, lastCommit, headCommit: head };
  } catch {
    return null;
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
  const contextPath = join(projectRoot, "context.md");

  const parts = [];

  if (!existsSync(contextPath)) {
    parts.push(
      [
        "## EDC Context",
        "",
        "No codebase context built yet. Run `/edc:edc-build` to generate deep architectural context.",
        "This enables automatic context injection when editing files.",
      ].join("\n"),
    );
  } else {
    // check staleness first
    const staleness = checkStaleness(projectRoot);
    if (staleness?.stale) {
      parts.push(
        [
          "## EDC Staleness Warning",
          "",
          `Context was built at commit \`${staleness.lastCommit.slice(0, 8)}\` but HEAD is \`${staleness.headCommit.slice(0, 8)}\`.`,
          "Run `/edc:edc-build` to update.",
        ].join("\n"),
      );
    }

    try {
      parts.push(readFileSync(contextPath, "utf-8"));
    } catch {
      // file disappeared between check and read
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
