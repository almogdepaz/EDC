import { readFileSync } from "fs";
import {
  buildSessionStartContent,
} from "./lib/route.mjs";
import { detectPlatform } from "./lib/platform.mjs";

// --- I/O helpers ---

function parseInput(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
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
  const { mode, content } = buildSessionStartContent(projectRoot);
  if (mode === "advisory") return;

  const output = formatOutput(platform, content);
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
