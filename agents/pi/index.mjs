/**
 * EDC extension for pi (https://github.com/mariozechner/pi).
 *
 * Mirrors the Claude Code plugin:
 *   - registers one interactive /edc menu for user-facing workflows
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

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync, spawn } from "node:child_process";
import { join, dirname, isAbsolute } from "node:path";
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
const EDC_COMMAND = {
  name: "edc",
  description: "Open the interactive EDC menu",
};

const EDC_MENU = {
  REVIEW_MAIN: "Review current branch vs main",
  REVIEW_STATUS: "Review status",
  BUILD: "Build context",
  UPDATE_MAIN: "Update context from main",
  AUDIT: "Audit complexity",
  DOCTOR: "Doctor / validate context",
  CANCEL: "Cancel",
};

const VISIBLE_SKILLS = ["edc-review", "edc-audit"];
const EDC_ORCHESTRATOR_BASH_TIMEOUT_SECONDS = 7200;
const MAX_COMMAND_OUTPUT_CHARS = 12000;
const EDC_BACKGROUND_STATUS_GIT_PATH = "edc/status";
const EDC_BACKGROUND_REVIEW_LOG_GIT_PATH = "edc/review.log";
const EDC_BACKGROUND_REVIEW_STALE_MS = 12 * 60 * 60 * 1000;

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function currentPiModelSlug(ctx) {
  const provider = ctx?.model?.provider;
  const id = ctx?.model?.id;
  if (typeof provider !== "string" || typeof id !== "string") return "";
  return `${provider}/${id}`;
}

function tokenizeArgs(args) {
  return String(args || "").trim().split(/\s+/).filter(Boolean);
}

function isHelpRequest(args) {
  return tokenizeArgs(args).some((arg) => arg === "-h" || arg === "--help");
}

function renderEdcHelp() {
  return [
    "Usage: /edc",
    "",
    "Opens the interactive EDC menu.",
    "",
    "Menu actions:",
    "- Review current branch vs main",
    "- Review status",
    "- Build context",
    "- Update context from main",
    "- Audit complexity",
    "- Doctor / validate context",
    "",
    "Non-interactive use is intentionally CLI-only:",
    "  edc review --agent pi HEAD --base main",
    "  edc build --agent pi",
    "  edc update --agent pi --base main",
  ].join("\n");
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

function isEdcOrchestratorCommand(command) {
  const scriptName = "edc-(?:build|update|review|audit|doctor)\\.sh";
  return new RegExp(`(?:^|[\\s"'])\\.edc/scripts/${scriptName}(?:[\\s"']|$)`).test(command)
    || new RegExp(`(?:^|[\\s"'])\\$HOME/\\.edc/scripts/${scriptName}(?:[\\s"']|$)`).test(command)
    || new RegExp(`(?:^|[\\s"'])/[^\\s"']*/\\.edc/scripts/${scriptName}(?:[\\s"']|$)`).test(command);
}

function extendEdcBashTimeout(event) {
  const command = event?.input?.command;
  if (typeof command !== "string" || !isEdcOrchestratorCommand(command)) return;

  const currentTimeout = Number(event.input.timeout || 0);
  if (!Number.isFinite(currentTimeout) || currentTimeout < EDC_ORCHESTRATOR_BASH_TIMEOUT_SECONDS) {
    event.input.timeout = EDC_ORCHESTRATOR_BASH_TIMEOUT_SECONDS;
  }
}

function commitDistance(cwd, sourceCommit, headCommit) {
  if (!sourceCommit || !headCommit) return "unknown";
  try {
    return execFileSync("git", ["rev-list", "--count", `${sourceCommit}..${headCommit}`], {
      cwd,
      timeout: 3000,
      encoding: "utf-8",
    }).trim() || "0";
  } catch {
    return "unknown";
  }
}

function reviewContextSummary(ctx, freshness = getContextFreshness(ctx.cwd)) {
  switch (freshness.state) {
    case "fresh":
      return "EDC context: fresh.";
    case "missing":
      return [
        "EDC context: missing/incomplete.",
        `reason: ${freshness.reason || "unknown"}`,
        "review will build context before reviewing unless you pass --no-context-refresh or --ignore-context.",
      ].join("\n");
    case "stale": {
      const source = String(freshness.sourceCommit || "unknown");
      const head = String(freshness.headCommit || "unknown");
      const behind = commitDistance(ctx.cwd, freshness.sourceCommit, freshness.headCommit);
      return [
        "EDC context: stale.",
        `built at: ${source.slice(0, 8)}`,
        `HEAD: ${head.slice(0, 8)}`,
        `behind by: ${behind} commit${behind === "1" ? "" : "s"}`,
        "review will update context before reviewing unless you pass --no-context-refresh or --ignore-context.",
      ].join("\n");
    }
    case "unknown":
      return [`EDC context: unknown.`, `reason: ${freshness.reason || "unknown"}`].join("\n");
    default:
      return `EDC context: ${freshness.state || "unknown"}.`;
  }
}

async function shouldProceedWithReview(args, ctx, freshness = getContextFreshness(ctx.cwd)) {
  if (reviewSkipsContextPrompt(args)) return true;

  if (freshness.state !== "missing" && freshness.state !== "stale") return true;

  if (!ctx.ui?.confirm || ctx.hasUI === false) return true;

  const isMissing = freshness.state === "missing";
  const action = isMissing ? "build" : "update";

  return ctx.ui.confirm(
    `EDC context ${freshness.state}`,
    `${reviewContextSummary(ctx, freshness)}\n\nRun edc ${action} before reviewing? This may spawn agent subprocesses and can take several minutes.`,
  );
}

function reviewDeclinedMessage(args) {
  const renderedArgs = reviewArgsWithDefaultTarget(args);
  return [
    "Review cancelled; EDC context was not refreshed.",
    "",
    "To review anyway without refreshing context, use the CLI:",
    `\`edc review --agent pi ${renderedArgs} --no-context-refresh\``,
    "",
    "For a pure direct review that ignores any existing `edc-context/`, run:",
    `\`edc review --agent pi ${renderedArgs} --ignore-context\``,
  ].join("\n");
}

function findEdcScript(cwd, scriptName) {
  const localScript = join(cwd, ".edc", "scripts", scriptName);
  if (existsSync(localScript)) return localScript;

  const home = process.env.HOME || "";
  if (home) {
    const homeScript = join(home, ".edc", "scripts", scriptName);
    if (existsSync(homeScript)) return homeScript;
  }

  return "";
}

function nowRunId() {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
  return `${stamp}-review-${process.pid}`;
}

function piSubprocessEnv(ctx, bashPath = "") {
  const env = { ...process.env, EDC_AGENT_CLI: "pi" };
  if (bashPath) {
    env.EDC_BASH = bashPath;
    env.PATH = `${dirname(bashPath)}:${env.PATH || ""}`;
  }
  const model = currentPiModelSlug(ctx);
  if (model) env.EDC_PI_MODEL = model;
  return env;
}

function isBash4OrNewer(path) {
  try {
    const version = execFileSync(path, ["-lc", "printf '%s' \"${BASH_VERSINFO[0]}\""], {
      timeout: 3000,
      encoding: "utf-8",
    }).trim();
    return Number(version) >= 4;
  } catch {
    return false;
  }
}

function resolveBashExecutable() {
  const candidates = [];
  const pathBash = process.env.PATH
    ? process.env.PATH.split(":").map((dir) => join(dir, "bash"))
    : [];
  candidates.push(...pathBash, "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash");

  const seen = new Set();
  for (const candidate of candidates) {
    if (!candidate || seen.has(candidate) || !existsSync(candidate)) continue;
    seen.add(candidate);
    if (isBash4OrNewer(candidate)) return candidate;
  }
  return "";
}

function runEdcScript(scriptName, args, ctx) {
  const edcScript = findEdcScript(ctx.cwd, scriptName);
  if (!edcScript) {
    return Promise.resolve({ code: 127, stdout: "", stderr: "SCRIPT_MISSING: install EDC orchestrator first\n" });
  }

  const bashPath = resolveBashExecutable();
  if (!bashPath) {
    return Promise.resolve({ code: 2, stdout: "", stderr: "ERROR: requires bash >= 4.0 (on macOS: brew install bash)\n" });
  }

  const script = `set -- ${args || ""}\nexec ${shellQuote(bashPath)} ${shellQuote(edcScript)} "$@"`;
  return new Promise((resolve) => {
    const child = spawn(bashPath, ["-lc", script], {
      cwd: ctx.cwd,
      env: piSubprocessEnv(ctx, bashPath),
      stdio: ["ignore", "pipe", "pipe"],
      signal: ctx.signal,
    });

    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf-8");
    child.stderr.setEncoding("utf-8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => {
      resolve({ code: 1, stdout, stderr: `${stderr}${error.message}\n` });
    });
    child.on("close", (code, signal) => {
      const exitCode = typeof code === "number" ? code : 1;
      const signalText = signal ? `terminated by ${signal}\n` : "";
      resolve({ code: exitCode, stdout, stderr: `${stderr}${signalText}` });
    });
  });
}

function tailText(text, maxChars = MAX_COMMAND_OUTPUT_CHARS) {
  if (text.length <= maxChars) return text;
  return `${text.slice(0, 1000)}\n\n... output truncated ...\n\n${text.slice(-maxChars)}`;
}

function combinedOutput(result) {
  return tailText(`${result.stdout || ""}${result.stderr || ""}`.trim());
}

function renderDirectCommandResult(commandName, args, result) {
  const output = combinedOutput(result);
  const label = commandName.replace(/^edc-/, "edc ");
  if (result.code === 0) {
    return [`${label} completed.`, output ? "" : "", output ? "```text" : "", output, output ? "```" : ""].filter(Boolean).join("\n");
  }
  return [`${label} failed with exit code ${result.code}.`, "", "Output:", "```text", output, "```"].join("\n");
}

function backgroundGitPath(cwd, gitRelativePath) {
  try {
    const gitPath = execFileSync("git", ["rev-parse", "--git-path", gitRelativePath], {
      cwd,
      timeout: 3000,
      encoding: "utf-8",
    }).trim();
    if (!gitPath) return null;
    return {
      path: isAbsolute(gitPath) ? gitPath : join(cwd, gitPath),
      display: gitPath,
    };
  } catch {
    return null;
  }
}

function backgroundStatusPath(cwd) {
  return backgroundGitPath(cwd, EDC_BACKGROUND_STATUS_GIT_PATH);
}

function backgroundReviewLogPath(cwd) {
  return backgroundGitPath(cwd, EDC_BACKGROUND_REVIEW_LOG_GIT_PATH);
}

function isPidAlive(pidText) {
  const pid = Number(pidText);
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function isStatusStale(status) {
  const startedAt = Date.parse(status.started_at || "");
  return Number.isFinite(startedAt) && Date.now() - startedAt > EDC_BACKGROUND_REVIEW_STALE_MS;
}

function serializeStatus(fields) {
  return Object.entries(fields)
    .filter(([, value]) => value !== undefined && value !== null && value !== "")
    .map(([key, value]) => `${key}=${value}`)
    .join("\n") + "\n";
}

function currentHead(cwd) {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], {
      cwd,
      timeout: 3000,
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

function markRunningReviewFailed(statusPath, status, reason, hint) {
  writeFileSync(statusPath.path, serializeStatus({
    status: "failed",
    exit_code: 1,
    started_at: status.started_at,
    finished_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    run_id: status.run_id || "current",
    pid: status.pid,
    args: status.args,
    log: status.log,
    started_head: status.started_head,
    failure_reason: reason,
    failure_hint: hint,
  }));
}

function runningReview(cwd) {
  const statusPath = backgroundStatusPath(cwd);
  if (!statusPath || !existsSync(statusPath.path)) return null;

  const status = parseStatus(readFileSync(statusPath.path, "utf-8"));
  if (status.status !== "running") return null;

  const alive = isPidAlive(status.pid);
  if (alive === true) return { runId: status.run_id || "current", status };
  if (alive === null && !isStatusStale(status)) return { runId: status.run_id || "current", status };

  const reason = alive === false
    ? "background review process is no longer running"
    : "background review status is stale";
  markRunningReviewFailed(
    statusPath,
    status,
    reason,
    "starting a new review is allowed; inspect the previous log if needed",
  );
  return null;
}

function writeRunningReviewStatus(statusPath, logPath, fields) {
  writeFileSync(statusPath.path, serializeStatus({
    status: "running",
    started_at: fields.startedAt,
    run_id: fields.runId,
    pid: fields.pid,
    args: fields.args,
    log: logPath.display,
    started_head: fields.startedHead,
  }));
}

function startBackgroundReview(args, ctx) {
  const existing = runningReview(ctx.cwd);
  if (existing) {
    return { alreadyRunning: true, ...existing };
  }

  const reviewScript = findEdcScript(ctx.cwd, "edc-review.sh");
  if (!reviewScript) {
    return { error: "SCRIPT_MISSING: install EDC orchestrator first" };
  }

  const bashPath = resolveBashExecutable();
  if (!bashPath) {
    return { error: "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" };
  }

  const statusPath = backgroundStatusPath(ctx.cwd);
  const logPath = backgroundReviewLogPath(ctx.cwd);
  if (!statusPath || !logPath) {
    return { error: "ERROR: background EDC review requires a git repo" };
  }

  const runId = nowRunId();
  mkdirSync(dirname(statusPath.path), { recursive: true });
  mkdirSync(dirname(logPath.path), { recursive: true });
  const startedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const startedHead = currentHead(ctx.cwd);
  writeRunningReviewStatus(statusPath, logPath, {
    startedAt,
    runId,
    pid: "starting",
    args,
    startedHead,
  });

  const script = `
set -- ${args}
status_file=${shellQuote(statusPath.path)}
log_file=${shellQuote(logPath.path)}
log_display=${shellQuote(logPath.display)}
status_dir=${shellQuote(dirname(statusPath.path))}
mkdir -p "$status_dir"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_head="$(git rev-parse HEAD 2>/dev/null || true)"
args_text="$(printf '%s ' "$@" | sed 's/ $//')"
{
  echo "status=running"
  echo "started_at=$started_at"
  echo "run_id=${runId}"
  echo "pid=$$"
  echo "args=$args_text"
  echo "log=$log_display"
  [ -n "$started_head" ] && echo "started_head=$started_head"
} > "$status_file"

${shellQuote(bashPath)} ${shellQuote(reviewScript)} "$@" > "$log_file" 2>&1
rc=$?
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
finished_head="$(git rev-parse HEAD 2>/dev/null || true)"
final_review="$(awk '/^Verified: /{p=$2} /^Consolidated: /{if (p == "") p=$2} END{print p}' "$log_file" 2>/dev/null || true)"
failure_reason=""
failure_hint=""
if [ "$rc" -ne 0 ]; then
  if [ -n "$started_head" ] && [ -n "$finished_head" ] && [ "$started_head" != "$finished_head" ]; then
    failure_reason="HEAD changed during background review"
    failure_hint="rerun the review after the working branch stops changing"
  elif grep -q 'report validation failed for module' "$log_file" 2>/dev/null; then
    failed_module="$(awk '/report validation failed for module/{print $NF}' "$log_file" | tail -1)"
    if [ -n "$failed_module" ]; then
      failure_reason="review report validation failed for module $failed_module"
    else
      failure_reason="review report validation failed"
    fi
    failure_hint="inspect the module reviewer output in the log; the reviewer likely wrote an incomplete report"
  elif grep -q "has no '## ' headings" "$log_file" 2>/dev/null; then
    failure_reason="review report validation failed"
    failure_hint="inspect the module reviewer output in the log; the report is missing required headings"
  elif [ ! -f edc-context/manifest.json ] || [ ! -f edc-context/index.md ] || [ ! -f AGENTS.md ]; then
    failure_reason="context recovery did not produce a complete edc-context layout"
    failure_hint="run edc doctor, inspect the log, then rerun edc review or edc build --agent pi"
  else
    failure_reason="review pipeline failed"
    failure_hint="inspect the log for the subprocess error and rerun after fixing it"
  fi
fi
{
  if [ "$rc" -eq 0 ]; then echo "status=success"; else echo "status=failed"; fi
  echo "exit_code=$rc"
  echo "started_at=$started_at"
  echo "finished_at=$finished_at"
  echo "run_id=${runId}"
  echo "pid=$$"
  echo "args=$args_text"
  echo "log=$log_display"
  [ -n "$started_head" ] && echo "started_head=$started_head"
  [ -n "$finished_head" ] && echo "finished_head=$finished_head"
  [ -n "$failure_reason" ] && echo "failure_reason=$failure_reason"
  [ -n "$failure_hint" ] && echo "failure_hint=$failure_hint"
  [ -n "$final_review" ] && echo "final_review=$final_review"
} > "$status_file"
`;

  const child = spawn(bashPath, ["-lc", script], {
    cwd: ctx.cwd,
    detached: true,
    stdio: "ignore",
    env: piSubprocessEnv(ctx, bashPath),
  });
  child.unref();

  return { runId, pid: child.pid, logFile: logPath.display, statusFile: statusPath.display };
}

function parseStatus(content) {
  const status = {};
  for (const line of content.split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index <= 0) continue;
    status[line.slice(0, index)] = line.slice(index + 1);
  }
  return status;
}

function renderReviewStatus(args, cwd) {
  const requested = String(args || "").trim();
  if (requested && requested !== "latest" && requested !== "current") {
    return "EDC keeps only the current background review status. Use `/edc` → Review status without a run id.";
  }

  const statusPath = backgroundStatusPath(cwd);
  if (!statusPath || !existsSync(statusPath.path)) {
    return "No background EDC review runs found.";
  }

  const status = parseStatus(readFileSync(statusPath.path, "utf-8"));
  const runId = status.run_id || "current";
  const lines = [
    `EDC review run: ${runId}`,
    `status: ${status.status || "unknown"}`,
  ];
  if (status.exit_code) lines.push(`exit code: ${status.exit_code}`);
  if (status.started_at) lines.push(`started: ${status.started_at}`);
  if (status.finished_at) lines.push(`finished: ${status.finished_at}`);
  if (status.final_review) lines.push(`final review: ${status.final_review}`);
  if (status.args) lines.push(`args: ${status.args}`);
  if (status.pid) lines.push(`pid: ${status.pid}`);
  if (status.started_head) lines.push(`started HEAD: ${status.started_head.slice(0, 8)}`);
  if (status.finished_head && status.finished_head !== status.started_head) lines.push(`finished HEAD: ${status.finished_head.slice(0, 8)}`);
  if (status.failure_reason) lines.push(`reason: ${status.failure_reason}`);
  if (status.failure_hint) lines.push(`hint: ${status.failure_hint}`);
  if (status.log) lines.push(`log: ${status.log}`);
  lines.push("");
  if (status.status === "success") {
    lines.push("Review complete.");
  } else if (status.status === "failed") {
    lines.push("Review failed. Open the log above for details.");
  } else {
    lines.push("Still running. Check again with `/edc` → Review status.");
  }
  return lines.join("\n");
}

function backgroundReviewStartedMessage(result, contextSummary = "") {
  return [
    "Background review started.",
    contextSummary ? "" : null,
    contextSummary || null,
    "",
    `Run ID: ${result.runId}`,
    `PID: ${result.pid}`,
    `Log: ${result.logFile}`,
    `Status: ${result.statusFile}`,
    "",
    "Check progress: `/edc` → Review status.",
  ].filter((line) => line !== null).join("\n");
}

function backgroundReviewAlreadyRunningMessage(result) {
  return [
    "A background EDC review is already running for this repo.",
    "",
    `Run ID: ${result.runId}`,
    result.status?.log ? `Log: ${result.status.log}` : "",
    "",
    "Check progress: `/edc` → Review status.",
  ].filter(Boolean).join("\n");
}

function interactiveOnlyMessage() {
  return [
    "/edc is interactive-only.",
    "",
    "Use the EDC CLI for non-interactive runs:",
    "  edc review --agent pi HEAD --base main",
    "  edc build --agent pi",
    "  edc update --agent pi --base main",
  ].join("\n");
}

async function runReviewAgainstMain(pi, ctx) {
  const renderedArgs = "HEAD --base main";
  const freshness = getContextFreshness(ctx.cwd);
  const proceed = await shouldProceedWithReview(renderedArgs, ctx, freshness);
  if (!proceed) {
    sendInfo(pi, "edc-review-preflight", reviewDeclinedMessage(renderedArgs));
    return;
  }

  const result = startBackgroundReview(renderedArgs, ctx);
  if (result.error) {
    sendInfo(pi, "edc-review-background", result.error);
  } else if (result.alreadyRunning) {
    sendInfo(pi, "edc-review-background", backgroundReviewAlreadyRunningMessage(result));
  } else {
    sendInfo(pi, "edc-review-background", backgroundReviewStartedMessage(result, reviewContextSummary(ctx, freshness)));
  }
}

async function runScriptAction(pi, ctx, label, scriptName, args = "") {
  sendInfo(pi, "edc-command-start", `Running ${label}...`);
  const result = await runEdcScript(scriptName, args, ctx);
  sendInfo(pi, "edc-command-result", renderDirectCommandResult(label, args, result));
}

async function handleEdcMenu(pi, args, ctx) {
  if (isHelpRequest(args)) {
    sendInfo(pi, "edc-command-help", renderEdcHelp());
    return;
  }

  if (!ctx.hasUI || !ctx.ui?.select) {
    sendInfo(pi, "edc-command-help", interactiveOnlyMessage());
    return;
  }

  const choice = await ctx.ui.select("EDC", [
    EDC_MENU.REVIEW_MAIN,
    EDC_MENU.REVIEW_STATUS,
    EDC_MENU.BUILD,
    EDC_MENU.UPDATE_MAIN,
    EDC_MENU.AUDIT,
    EDC_MENU.DOCTOR,
    EDC_MENU.CANCEL,
  ]);

  switch (choice) {
    case EDC_MENU.REVIEW_MAIN:
      await runReviewAgainstMain(pi, ctx);
      break;
    case EDC_MENU.REVIEW_STATUS:
      sendInfo(pi, "edc-review-status", renderReviewStatus("", ctx.cwd));
      break;
    case EDC_MENU.BUILD:
      await runScriptAction(pi, ctx, "edc build", "edc-build.sh");
      break;
    case EDC_MENU.UPDATE_MAIN:
      await runScriptAction(pi, ctx, "edc update", "edc-update.sh", "--base main");
      break;
    case EDC_MENU.AUDIT:
      await runScriptAction(pi, ctx, "edc audit", "edc-audit.sh");
      break;
    case EDC_MENU.DOCTOR:
      await runScriptAction(pi, ctx, "edc doctor", "edc-doctor.sh");
      break;
    default:
      sendInfo(pi, "edc-menu", "EDC menu cancelled.");
      break;
  }
}

/** @type {(pi: import("@earendil-works/pi-coding-agent").ExtensionAPI) => Promise<void>} */
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

    if (t === "bash") {
      extendEdcBashTimeout(event);
    }

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
  pi.registerCommand(EDC_COMMAND.name, {
    description: EDC_COMMAND.description,
    handler: async (args, ctx) => {
      await handleEdcMenu(pi, args, ctx);
    },
  });
}
