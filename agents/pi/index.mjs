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
  getContextFreshness,
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

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function currentPiModelSlug(ctx) {
  const provider = ctx?.model?.provider;
  const id = ctx?.model?.id;
  if (typeof provider !== "string" || typeof id !== "string") return "";
  return `${provider}/${id}`;
}

function injectPiBackendEnv(prompt, ctx) {
  const lines = ["export EDC_AGENT_CLI=pi"];
  const model = currentPiModelSlug(ctx);
  if (model) lines.push(`export EDC_PI_MODEL=${shellQuote(model)}`);

  const injection = `${lines.join("\n")}\n`;
  if (prompt.includes("```bash\n")) {
    return prompt.replace("```bash\n", `\`\`\`bash\n${injection}`);
  }
  return `${injection}\n${prompt}`;
}

function tokenizeArgs(args) {
  return String(args || "").trim().split(/\s+/).filter(Boolean);
}

function isHelpRequest(args) {
  return tokenizeArgs(args).some((arg) => arg === "-h" || arg === "--help");
}

function renderCommandHelp(cmd) {
  if (cmd.name === "edc-run-review") {
    return [
      "Usage: /edc-run-review [target|--pr <number-or-url>] [--base <ref>] [--ignore <glob>]... [--no-context-refresh|--ignore-context]",
      "",
      "Runs differential review. With no arguments, reviews `HEAD`.",
      "",
      "Context behavior:",
      "- default: prompt before building/updating stale or missing EDC context, then run review if accepted",
      "- `--no-context-refresh`: do not build/update; use existing context if usable, otherwise review directly",
      "- `--ignore-context`: pure direct review; do not read prebuilt `edc-context/`",
    ].join("\n");
  }

  return [`Usage: /${cmd.name}`, "", cmd.description].join("\n");
}

function sendInfo(pi, customType, content) {
  pi.sendMessage({ customType, content, display: true });
}

function reviewArgsWithDefaultTarget(args) {
  const trimmed = String(args || "").trim();
  return trimmed || "HEAD";
}

function reviewSkipsContextPrompt(args) {
  const tokens = tokenizeArgs(args);
  return tokens.includes("--no-context-refresh") || tokens.includes("--ignore-context");
}

async function shouldProceedWithReview(args, ctx) {
  if (reviewSkipsContextPrompt(args)) return true;

  const freshness = getContextFreshness(ctx.cwd);
  if (freshness.state !== "missing" && freshness.state !== "stale") return true;

  if (!ctx.ui?.confirm || ctx.hasUI === false) return true;

  const isMissing = freshness.state === "missing";
  const action = isMissing ? "build" : "update";
  const detail = isMissing
    ? "edc-context is missing or incomplete."
    : `edc-context is stale (built at ${String(freshness.sourceCommit || "unknown").slice(0, 8)}, HEAD is ${String(freshness.headCommit || "unknown").slice(0, 8)}).`;

  return ctx.ui.confirm(
    `EDC context ${freshness.state}`,
    `${detail}\n\nRun edc ${action} before reviewing? This may spawn agent subprocesses.`,
  );
}

function reviewDeclinedMessage(args) {
  const renderedArgs = reviewArgsWithDefaultTarget(args);
  return [
    "Review cancelled; EDC context was not refreshed.",
    "",
    "To review anyway without refreshing context, run:",
    `\`/edc-run-review ${renderedArgs} --no-context-refresh\``,
    "",
    "For a pure direct review that ignores any existing `edc-context/`, run:",
    `\`/edc-run-review ${renderedArgs} --ignore-context\``,
  ].join("\n");
}

/** @type {(pi: import("@mariozechner/pi-coding-agent").ExtensionAPI) => Promise<void>} */
export default async function edcExtension(pi) {
  if (process.env.EDC_PI_SUBPROCESS === "1") return;

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
        if (isHelpRequest(args)) {
          sendInfo(pi, "edc-command-help", renderCommandHelp(cmd));
          return;
        }

        let renderedArgs = args || "";
        if (cmd.name === "edc-run-review") {
          renderedArgs = reviewArgsWithDefaultTarget(args);
          const proceed = await shouldProceedWithReview(renderedArgs, ctx);
          if (!proceed) {
            sendInfo(pi, "edc-review-preflight", reviewDeclinedMessage(renderedArgs));
            return;
          }
        }

        const prompt = injectPiBackendEnv(renderCommandPrompt(cmd.file, renderedArgs), ctx);
        await pi.sendUserMessage(prompt);
      },
    });
  }
}
