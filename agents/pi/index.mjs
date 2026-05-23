/**
 * EDC extension for pi (https://github.com/mariozechner/pi).
 *
 * Mirrors the Claude Code plugin:
 *   - registers user-facing slash commands (/edc-build, /edc-update,
 *     /edc-run-review, /edc-doctor)
 *   - on session_start: installs the orchestrator script into the project
 *     and surfaces edc-context/index.md (in inject mode)
 *   - on tool_call (bash|edit|write): injects the relevant module doc
 *     once per session (in inject mode)
 *   - exposes only human-facing skills (edc-review, edc-audit)
 *
 * Mode is controlled by edc-context/manifest.json's `policy.defaultMode`
 * ("advisory" | "inject"), same as for Claude Code.
 *
 * Loaded via the repo-root package.json:
 *   "pi": { "extensions": ["./agents/pi/index.mjs"] }
 */

import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildSessionStartContent,
  buildToolCallInjection,
  installOrchestratorScript,
} from "../../plugins/edc/hooks/lib/route.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
// agents/pi/index.mjs → repo root → plugins/edc
const PLUGIN_ROOT = join(__dirname, "..", "..", "plugins", "edc");
const COMMANDS_DIR = join(PLUGIN_ROOT, "commands");

const COMMANDS = [
  {
    name: "edc-build",
    description:
      "Build or update deep architectural context for the codebase",
    file: "edc-build.md",
  },
  {
    name: "edc-update",
    description: "Incrementally update edc-context/ from branch changes",
    file: "edc-update.md",
  },
  {
    name: "edc-run-review",
    description: "Differential code review using codebase context",
    file: "edc-run-review.md",
  },
  {
    name: "edc-doctor",
    description: "Validate the context tree, manifest, and routing coverage",
    file: "edc-doctor.md",
  },
];

const VISIBLE_SKILLS = ["edc-review", "edc-audit"];

/**
 * Strip YAML frontmatter from a markdown command file and return the body.
 * Returns null if the file is missing.
 */
function readCommandBody(file) {
  const path = join(COMMANDS_DIR, file);
  if (!existsSync(path)) return null;
  const raw = readFileSync(path, "utf-8");
  if (!raw.startsWith("---")) return raw;
  const end = raw.indexOf("\n---", 3);
  if (end < 0) return raw;
  return raw.slice(end + 4).replace(/^\s*\n/, "");
}

/**
 * Build the prompt the agent receives when /<name> is invoked.
 * The original commands reference $ARGUMENTS — substitute with user-supplied args.
 */
function renderCommandPrompt(file, args) {
  const body = readCommandBody(file);
  if (!body) {
    return `Command "${file}" is missing from the plugin bundle. Cannot proceed.`;
  }
  return body.replace(/\$ARGUMENTS/g, args || "");
}

/** @type {(pi: import("@mariozechner/pi-coding-agent").ExtensionAPI) => Promise<void>} */
export default async function edcExtension(pi) {
  // -- skills ---------------------------------------------------------------
  pi.on("resources_discover", async () => {
    const skillsDir = join(PLUGIN_ROOT, "skills");
    const skillPaths = VISIBLE_SKILLS.map((name) => join(skillsDir, name)).filter(
      (path) => existsSync(join(path, "SKILL.md")),
    );
    if (skillPaths.length === 0) return {};
    return { skillPaths };
  });

  // -- session start --------------------------------------------------------
  pi.on("session_start", async (_event, ctx) => {
    try {
      installOrchestratorScript(ctx.cwd, PLUGIN_ROOT);
    } catch {
      // best effort
    }
    const { mode, content } = buildSessionStartContent(ctx.cwd);
    if (mode === "advisory" || !content) return;
    pi.sendMessage({
      customType: "edc-session-context",
      content,
      display: content,
    });
  });

  // -- per-tool context injection ------------------------------------------
  pi.on("tool_call", async (event, ctx) => {
    // Only intercept file-touching tools.
    const t = String(event.toolName || "").toLowerCase();
    if (t !== "bash" && t !== "edit" && t !== "write") return;

    let sessionId;
    try {
      sessionId = ctx.sessionManager.getSessionId();
    } catch {
      sessionId = "";
    }

    const injection = buildToolCallInjection({
      projectRoot: ctx.cwd,
      toolName: t,
      toolInput: event.input || {},
      pluginRoot: PLUGIN_ROOT,
      sessionId,
    });
    if (!injection) return;

    // Dedup is handled by buildToolCallInjection via a tmpfile keyed on
    // session id (see plugins/edc/hooks/lib/route.mjs::isDuplicate). The
    // file persists across extension reloads within a session, so a separate
    // in-process layer adds no coverage.

    pi.sendMessage({
      customType: "edc-context-inject",
      content: injection.content,
      display: `[edc] injected module "${injection.moduleName}" for ${injection.normalizedPath}`,
    });
  });

  // -- slash commands -------------------------------------------------------
  for (const cmd of COMMANDS) {
    pi.registerCommand(cmd.name, {
      description: cmd.description,
      handler: async (args, ctx) => {
        const prompt = renderCommandPrompt(cmd.file, args);
        await pi.sendUserMessage(prompt);
      },
    });
  }
}
