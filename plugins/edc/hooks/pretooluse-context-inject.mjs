import { readFileSync } from "fs";
import {
  resolvePluginRoot,
  buildToolCallInjection,
} from "./lib/route.mjs";
import { detectPlatform } from "./lib/platform.mjs";

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
  const pluginRoot = resolvePluginRoot(import.meta.url);

  const injection = buildToolCallInjection({
    projectRoot,
    toolName: input.toolName,
    toolInput: input.toolInput,
    pluginRoot,
    sessionId: input.sessionId,
  });

  if (!injection) return "{}";

  return formatOutput(platform, input.hookEventName, injection.content);
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
