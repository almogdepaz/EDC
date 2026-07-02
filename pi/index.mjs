/**
 * EDC extension for pi (https://pi.dev).
 *
 * Mirrors the Claude Code plugin:
 *   - registers one interactive /edc menu for user-facing workflows
 *   - on session_start: installs the orchestrator script into the project
 *     and surfaces edc-context/index.md (in inject mode)
 *   - on tool_call (bash|edit|write): injects the relevant module doc
 *     once per session (in inject mode)
 *   - exposes only human-facing skills (edc-review, edc-audit, edc-delivery-review)
 *
 * Mode is controlled by edc-context/manifest.json's `policy.defaultMode`
 * ("advisory" | "inject"), same as for Claude Code.
 *
 * Loaded via the repo-root package.json:
 *   "pi": { "extensions": ["./pi/index.mjs"] }
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
} from "../plugins/edc/hooks/lib/route.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
// pi/index.mjs → repo root → plugins/edc
const PLUGIN_ROOT = join(__dirname, "..", "plugins", "edc");
const EDC_COMMAND = {
  name: "edc",
  description: "Open the interactive EDC menu",
};

const EDC_MENU = {
  REVIEW_DEFAULT: "Review current branch vs default branch",
  DELIVERY_REVIEW_DEFAULT: "Review delivery / architecture",
  JOB_STATUS: "Job status",
  KILL_JOB: "Kill running EDC job",
  BUILD: "Build context",
  UPDATE_DEFAULT: "Update context from default branch",
  AUDIT: "Audit code quality",
  DOCTOR: "Doctor / validate context",
  CANCEL: "Cancel",
};

const VISIBLE_SKILLS = ["edc-review", "edc-audit", "edc-delivery-review"];
const EDC_ORCHESTRATOR_BASH_TIMEOUT_SECONDS = 7200;
const MAX_COMMAND_OUTPUT_CHARS = 12000;
const EDC_BACKGROUND_STATUS_GIT_PATH = "edc/status";
const EDC_BACKGROUND_STALE_MS = 12 * 60 * 60 * 1000;
const EDC_BACKGROUND_STARTING_STALE_MS = 60 * 1000;
const EDC_BACKGROUND_UI_KEY = "edc-review";
const EDC_BACKGROUND_UI_POLL_MS = 2000;

let backgroundStatusTimer = null;

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

function argTokens(args) {
  if (Array.isArray(args)) return args.map(String).filter((arg) => arg.length > 0);
  return tokenizeArgs(args);
}

function renderArgs(args) {
  return argTokens(args).join(" ");
}

function renderShellArgs(args) {
  return argTokens(args).map(shellQuote).join(" ");
}

function isHelpRequest(args) {
  return tokenizeArgs(args).some((arg) => arg === "-h" || arg === "--help");
}

function isKillJobRequest(args) {
  const tokens = tokenizeArgs(args).map((arg) => arg.toLowerCase());
  return tokens.some((arg) => arg === "kill" || arg === "stop" || arg === "kill-review" || arg === "stop-review" || arg === "cancel-review" || arg === "kill-job" || arg === "stop-job" || arg === "cancel-job");
}

function renderEdcHelp() {
  return [
    "Usage: /edc",
    "",
    "Opens the interactive EDC menu.",
    "",
    "Menu actions:",
    "- Review current branch vs default branch",
    "- Review delivery / architecture",
    "- Job status",
    "- Kill running EDC job",
    "- Build context",
    "- Update context from default branch",
    "- Audit code quality",
    "- Doctor / validate context",
    "",
    "Direct commands:",
    "  /edc kill",
    "",
    "Non-interactive use is intentionally CLI-only:",
    "  edc review --agent pi HEAD --base <default-branch>",
    "  edc delivery-review --agent pi HEAD --base <default-branch>",
    "  edc build --agent pi",
    "  edc update --agent pi --base <default-branch>",
  ].join("\n");
}

function sendInfo(pi, customType, content) {
  pi.sendMessage({ customType, content, display: true });
}

function reviewArgsWithDefaultTarget(args) {
  return renderArgs(args) || "HEAD";
}

function reviewSkipsContextPrompt(args) {
  const tokens = argTokens(args);
  return tokens.includes("--no-context-refresh") || tokens.includes("--ignore-context");
}

function isEdcOrchestratorCommand(command) {
  const scriptName = "edc-(?:build|update|review|delivery-review|audit|doctor)\\.sh";
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

function gitRefExists(cwd, ref) {
  try {
    execFileSync("git", ["rev-parse", "--verify", `${ref}^{commit}`], {
      cwd,
      timeout: 3000,
      stdio: ["ignore", "ignore", "ignore"],
    });
    return true;
  } catch {
    return false;
  }
}

function detectDefaultBaseRef(cwd) {
  try {
    const remoteHead = execFileSync("git", ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], {
      cwd,
      timeout: 3000,
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (remoteHead && gitRefExists(cwd, remoteHead)) return remoteHead;
  } catch {
    // origin/HEAD is optional in local/test repos.
  }

  for (const ref of ["main", "master", "origin/main", "origin/master"]) {
    if (gitRefExists(cwd, ref)) return ref;
  }

  return "main";
}

function defaultBaseReviewArgs(cwd) {
  return ["HEAD", "--base", detectDefaultBaseRef(cwd)];
}

function defaultBaseUpdateArgs(cwd) {
  return ["--base", detectDefaultBaseRef(cwd)];
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

function nowRunId(kind = "job") {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
  return `${stamp}-${kind}-${process.pid}`;
}

function piSubprocessEnv(ctx) {
  const env = { ...process.env, EDC_AGENT_CLI: "pi" };
  const model = currentPiModelSlug(ctx);
  if (model) env.EDC_PI_MODEL = model;
  return env;
}

function runEdcScript(scriptName, args, ctx) {
  const edcScript = findEdcScript(ctx.cwd, scriptName);
  if (!edcScript) {
    return Promise.resolve({ code: 127, stdout: "", stderr: "SCRIPT_MISSING: install EDC orchestrator first\n" });
  }

  return new Promise((resolve) => {
    const child = spawn("bash", [edcScript, ...args], {
      cwd: ctx.cwd,
      env: piSubprocessEnv(ctx),
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

function backgroundJobLogPath(cwd, kind) {
  return backgroundGitPath(cwd, `edc/${kind}.log`);
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
  return Number.isFinite(startedAt) && Date.now() - startedAt > EDC_BACKGROUND_STALE_MS;
}

function isStartingPidStale(status) {
  if (/^[1-9]\d*$/.test(String(status.pid || ""))) return false;
  const startedAt = Date.parse(status.started_at || "");
  return Number.isFinite(startedAt) && Date.now() - startedAt > EDC_BACKGROUND_STARTING_STALE_MS;
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

function writeFinishedBackgroundStatus(cwd, statusPath, status, fields) {
  writeFileSync(statusPath.path, serializeStatus({
    kind: status.kind || "review",
    status: fields.status,
    exit_code: fields.exitCode,
    started_at: status.started_at,
    finished_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    run_id: status.run_id || "current",
    pid: status.pid,
    args: status.args,
    log: status.log,
    started_head: status.started_head,
    finished_head: fields.finishedHead || currentHead(cwd),
    failure_reason: fields.reason,
    failure_hint: fields.hint,
    final_review: status.final_review,
    repo_changed: fields.repoChanged,
  }));
}

function markRunningBackgroundFailed(cwd, statusPath, status, reason, hint) {
  writeFinishedBackgroundStatus(cwd, statusPath, status, {
    status: "failed",
    exitCode: 1,
    reason,
    hint,
  });
}

function markRunningBackgroundCancelled(cwd, statusPath, status) {
  writeFinishedBackgroundStatus(cwd, statusPath, status, {
    status: "cancelled",
    exitCode: 130,
    reason: "cancelled by user",
    hint: `rerun edc ${status.kind || "job"} when ready`,
  });
}

function runningBackgroundJob(cwd) {
  const statusPath = backgroundStatusPath(cwd);
  if (!statusPath || !existsSync(statusPath.path)) return null;

  const status = parseStatus(readFileSync(statusPath.path, "utf-8"));
  if (status.status !== "running") return null;

  const alive = isPidAlive(status.pid);
  const startingPidStale = isStartingPidStale(status);
  if (alive === true) return { runId: status.run_id || "current", status };
  if (alive === null && !startingPidStale && !isStatusStale(status)) return { runId: status.run_id || "current", status };

  const kind = status.kind || "job";
  const reason = alive === false
    ? `background ${kind} process is no longer running`
    : startingPidStale
      ? `background ${kind} process did not finish starting`
      : `background ${kind} status is stale`;
  markRunningBackgroundFailed(
    cwd,
    statusPath,
    status,
    reason,
    `starting a new EDC job is allowed; inspect ${status.log || "the previous log"} if needed`,
  );
  return null;
}

function writeRunningBackgroundStatus(statusPath, logPath, fields) {
  writeFileSync(statusPath.path, serializeStatus({
    kind: fields.kind,
    status: "running",
    started_at: fields.startedAt,
    run_id: fields.runId,
    pid: fields.pid,
    args: fields.args,
    log: logPath.display,
    started_head: fields.startedHead,
  }));
}

function failureClassificationShell(kind) {
  if (kind !== "review") {
    return `
if [ "$rc" -ne 0 ]; then
  if [ -n "$started_head" ] && [ -n "$finished_head" ] && [ "$started_head" != "$finished_head" ]; then
    failure_reason="HEAD changed during background ${kind}"
    failure_hint="rerun edc ${kind} after the working branch stops changing"
  elif grep -Eq 'pi subprocess: WebSocket closed|WebSocket closed 1006|provider_transport_failure' "$log_file" 2>/dev/null; then
    failure_reason="pi provider websocket closed during background ${kind}"
    failure_hint="provider connection dropped while a nested pi subprocess was running; rerun edc ${kind}, and if it repeats reduce context/update scope"
  else
    failure_reason="${kind} pipeline failed"
    failure_hint="inspect the log for the subprocess error and rerun after fixing it"
  fi
fi`;
  }

  return `
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
  elif grep -Eq 'pi subprocess: WebSocket closed|WebSocket closed 1006|provider_transport_failure' "$log_file" 2>/dev/null; then
    failure_reason="pi provider websocket closed during background review"
    failure_hint="provider connection dropped while a nested pi subprocess was running; rerun edc review, and if it repeats run edc update --agent pi separately or reduce context scope"
  elif [ ! -f edc-context/manifest.json ] || [ ! -f edc-context/index.md ] || [ ! -f AGENTS.md ]; then
    failure_reason="context recovery did not produce a complete edc-context layout"
    failure_hint="run edc doctor, inspect the log, then rerun edc review or edc build --agent pi"
  else
    failure_reason="review pipeline failed"
    failure_hint="inspect the log for the subprocess error and rerun after fixing it"
  fi
fi`;
}

function startBackgroundJob(kind, scriptName, args, ctx) {
  const existing = runningBackgroundJob(ctx.cwd);
  if (existing) {
    return { alreadyRunning: true, ...existing };
  }

  const edcScript = findEdcScript(ctx.cwd, scriptName);
  if (!edcScript) {
    return { error: "SCRIPT_MISSING: install EDC orchestrator first" };
  }

  const statusPath = backgroundStatusPath(ctx.cwd);
  const logPath = backgroundJobLogPath(ctx.cwd, kind);
  if (!statusPath || !logPath) {
    return { error: `ERROR: background EDC ${kind} requires a git repo` };
  }

  const runId = nowRunId(kind);
  mkdirSync(dirname(statusPath.path), { recursive: true });
  mkdirSync(dirname(logPath.path), { recursive: true });
  const startedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const startedHead = currentHead(ctx.cwd);
  const renderedArgs = renderArgs(args);
  writeRunningBackgroundStatus(statusPath, logPath, {
    kind,
    startedAt,
    runId,
    pid: "starting",
    args: renderedArgs,
    startedHead,
  });

  const script = `
set -- ${renderShellArgs(args)}
status_file=${shellQuote(statusPath.path)}
log_file=${shellQuote(logPath.path)}
log_display=${shellQuote(logPath.display)}
status_dir=${shellQuote(dirname(statusPath.path))}
mkdir -p "$status_dir"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_head="$(git rev-parse HEAD 2>/dev/null || true)"
args_text="$(printf '%s ' "$@" | sed 's/ $//')"
{
  echo "kind=${kind}"
  echo "status=running"
  echo "started_at=$started_at"
  echo "run_id=${runId}"
  echo "pid=$$"
  echo "args=$args_text"
  echo "log=$log_display"
  [ -n "$started_head" ] && echo "started_head=$started_head"
} > "$status_file"

bash ${shellQuote(edcScript)} "$@" > "$log_file" 2>&1
rc=$?
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
finished_head="$(git rev-parse HEAD 2>/dev/null || true)"
repo_changed=""
if [ -n "$started_head" ] && [ -n "$finished_head" ] && [ "$started_head" != "$finished_head" ]; then
  repo_changed="HEAD changed from $(printf '%s' "$started_head" | cut -c1-8) to $(printf '%s' "$finished_head" | cut -c1-8) during background ${kind}; result may reflect the earlier repo state"
fi
final_review=""
if [ ${shellQuote(kind)} = "review" ]; then
  final_review="$(awk '/^Verified: /{p=$2} /^Consolidated: /{if (p == "") p=$2} END{print p}' "$log_file" 2>/dev/null || true)"
fi
failure_reason=""
failure_hint=""
${failureClassificationShell(kind)}
{
  echo "kind=${kind}"
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
  [ -n "$repo_changed" ] && echo "repo_changed=$repo_changed"
  [ -n "$failure_reason" ] && echo "failure_reason=$failure_reason"
  [ -n "$failure_hint" ] && echo "failure_hint=$failure_hint"
  [ -n "$final_review" ] && echo "final_review=$final_review"
} > "$status_file"
`;

  const child = spawn("bash", ["-lc", script], {
    cwd: ctx.cwd,
    detached: true,
    stdio: "ignore",
    env: piSubprocessEnv(ctx),
  });
  child.unref();

  return { kind, runId, pid: child.pid, logFile: logPath.display, statusFile: statusPath.display };
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

function readBackgroundJobStatus(cwd) {
  const statusPath = backgroundStatusPath(cwd);
  if (!statusPath || !existsSync(statusPath.path)) return null;
  return {
    statusPath,
    status: parseStatus(readFileSync(statusPath.path, "utf-8")),
  };
}

function killBackgroundJob(cwd) {
  const job = readBackgroundJobStatus(cwd);
  if (!job) return "No running background EDC job found.";

  const status = job.status;
  const kind = status.kind || "job";
  if (status.status !== "running") {
    return `No running background EDC job found. Current ${kind} status: ${status.status || "unknown"}.`;
  }

  const active = runningBackgroundJob(cwd);
  if (!active) return "No running background EDC job found; stale status was cleaned up.";

  const pid = Number(status.pid);
  if (!Number.isInteger(pid) || pid <= 0) {
    return `Cannot kill background EDC ${kind} ${status.run_id || "current"}: status file has invalid pid ${status.pid || "missing"}.`;
  }

  try {
    process.kill(-pid, "SIGTERM");
  } catch (groupError) {
    try {
      process.kill(pid, "SIGTERM");
    } catch (pidError) {
      return `Failed to kill background EDC ${kind} ${status.run_id || "current"}: ${pidError?.message || groupError?.message || "unknown error"}`;
    }
  }

  markRunningBackgroundCancelled(cwd, job.statusPath, status);
  return [
    `Background EDC ${kind} killed.`,
    "",
    `Run ID: ${status.run_id || "current"}`,
    `PID: ${status.pid}`,
    status.log ? `Log: ${status.log}` : "",
  ].filter(Boolean).join("\n");
}

function renderBackgroundJobStatus(args, cwd) {
  const requested = String(args || "").trim();
  if (requested && requested !== "latest" && requested !== "current") {
    return "EDC keeps only the current background job status. Use `/edc` → Job status without a run id.";
  }

  const job = readBackgroundJobStatus(cwd);
  if (!job) {
    return "No background EDC jobs found.";
  }

  const status = job.status;
  const kind = status.kind || "review";
  const runId = status.run_id || "current";
  const lines = [
    `EDC ${kind} run: ${runId}`,
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
  if (status.repo_changed) lines.push(`warning: ${status.repo_changed}`);
  if (status.failure_reason) lines.push(`reason: ${status.failure_reason}`);
  if (status.failure_hint) lines.push(`hint: ${status.failure_hint}`);
  if (status.log) lines.push(`log: ${status.log}`);
  lines.push("");
  if (status.status === "success") {
    lines.push(`EDC ${kind} complete.`);
  } else if (status.status === "failed") {
    lines.push(`EDC ${kind} failed. Open the log above for details.`);
  } else if (status.status === "cancelled") {
    lines.push(`EDC ${kind} cancelled.`);
  } else {
    lines.push("Still running. Check again with `/edc` → Job status.");
  }
  return lines.join("\n");
}

function formatBackgroundElapsed(status) {
  const startedAt = Date.parse(status.started_at || "");
  if (!Number.isFinite(startedAt)) return "";

  const finishedAt = Date.parse(status.finished_at || "");
  const end = Number.isFinite(finishedAt) ? finishedAt : Date.now();
  const elapsedSeconds = Math.max(0, Math.floor((end - startedAt) / 1000));
  if (elapsedSeconds < 60) return `${elapsedSeconds}s`;

  const elapsedMinutes = Math.floor(elapsedSeconds / 60);
  if (elapsedMinutes < 60) return `${elapsedMinutes}m`;

  const elapsedHours = Math.floor(elapsedMinutes / 60);
  const remainingMinutes = elapsedMinutes % 60;
  return `${elapsedHours}h ${remainingMinutes}m`;
}

function canShowBackgroundStatusUi(ctx) {
  return ctx?.hasUI !== false && !!ctx?.ui
    && (typeof ctx.ui.setStatus === "function" || typeof ctx.ui.setWidget === "function");
}

function renderBackgroundFooterStatus(status) {
  const kind = status.kind || "review";
  if (status.status === "running") {
    const elapsed = formatBackgroundElapsed(status);
    return `edc ${kind}: running${elapsed ? ` ${elapsed}` : ""}`;
  }
  if (status.status === "success") return `edc ${kind}: ✓ complete`;
  if (status.status === "failed") return `edc ${kind}: ✗ failed`;
  return `edc ${kind}: ${status.status || "unknown"}`;
}

function clearBackgroundStatusUi(ctx) {
  if (!canShowBackgroundStatusUi(ctx)) return;
  if (typeof ctx.ui.setStatus === "function") ctx.ui.setStatus(EDC_BACKGROUND_UI_KEY, undefined);
  if (typeof ctx.ui.setWidget === "function") ctx.ui.setWidget(EDC_BACKGROUND_UI_KEY, undefined);
}

function updateBackgroundStatusUi(ctx) {
  if (!canShowBackgroundStatusUi(ctx)) return "";

  const job = readBackgroundJobStatus(ctx.cwd);
  if (!job) {
    clearBackgroundStatusUi(ctx);
    return "";
  }

  const status = job.status.status || "unknown";
  if (status !== "running") {
    clearBackgroundStatusUi(ctx);
    return status;
  }

  if (typeof ctx.ui.setStatus === "function") {
    ctx.ui.setStatus(EDC_BACKGROUND_UI_KEY, renderBackgroundFooterStatus(job.status));
  }
  if (typeof ctx.ui.setWidget === "function") {
    ctx.ui.setWidget(EDC_BACKGROUND_UI_KEY, undefined);
  }
  return status;
}

function stopBackgroundStatusWatcher() {
  if (!backgroundStatusTimer) return;
  clearInterval(backgroundStatusTimer);
  backgroundStatusTimer = null;
}

function startBackgroundStatusWatcher(ctx) {
  if (!canShowBackgroundStatusUi(ctx)) return;

  stopBackgroundStatusWatcher();
  const currentStatus = updateBackgroundStatusUi(ctx);
  if (currentStatus !== "running") return;

  backgroundStatusTimer = setInterval(() => {
    const nextStatus = updateBackgroundStatusUi(ctx);
    if (nextStatus !== "running") stopBackgroundStatusWatcher();
  }, EDC_BACKGROUND_UI_POLL_MS);
  backgroundStatusTimer.unref?.();
}

function backgroundJobStartedMessage(result) {
  const kind = result.kind || "job";
  return [
    `Background EDC ${kind} started.`,
    "",
    `Run ID: ${result.runId}`,
    `PID: ${result.pid}`,
    result.logFile ? `Log: ${result.logFile}` : "",
  ].filter(Boolean).join("\n");
}

function backgroundJobAlreadyRunningMessage(result) {
  const kind = result.status?.kind || "job";
  return [
    `A background EDC ${kind} is already running for this repo.`,
    "",
    `Run ID: ${result.runId}`,
    result.status?.log ? `Log: ${result.status.log}` : "",
    "",
    "Check progress: `/edc` → Job status.",
  ].filter(Boolean).join("\n");
}

function interactiveOnlyMessage() {
  return [
    "/edc is interactive-only.",
    "",
    "Use the EDC CLI for non-interactive runs:",
    "  edc review --agent pi HEAD --base <default-branch>",
    "  edc build --agent pi",
    "  edc update --agent pi --base <default-branch>",
  ].join("\n");
}

function killRunningJobAction(pi, ctx) {
  const message = killBackgroundJob(ctx.cwd);
  stopBackgroundStatusWatcher();
  clearBackgroundStatusUi(ctx);
  sendInfo(pi, "edc-job-kill", message);
}

async function runReviewAgainstDefault(pi, ctx) {
  const renderedArgs = defaultBaseReviewArgs(ctx.cwd);
  const freshness = getContextFreshness(ctx.cwd);
  const proceed = await shouldProceedWithReview(renderedArgs, ctx, freshness);
  if (!proceed) {
    sendInfo(pi, "edc-review-preflight", reviewDeclinedMessage(renderedArgs));
    return;
  }

  const result = startBackgroundJob("review", "edc-review.sh", renderedArgs, ctx);
  if (result.error) {
    sendInfo(pi, "edc-background", result.error);
  } else if (result.alreadyRunning) {
    startBackgroundStatusWatcher(ctx);
    sendInfo(pi, "edc-background", backgroundJobAlreadyRunningMessage(result));
  } else {
    startBackgroundStatusWatcher(ctx);
    sendInfo(pi, "edc-background", backgroundJobStartedMessage(result));
  }
}

function runBackgroundAction(pi, ctx, kind, scriptName, args = "") {
  const result = startBackgroundJob(kind, scriptName, args, ctx);
  if (result.error) {
    sendInfo(pi, "edc-background", result.error);
  } else if (result.alreadyRunning) {
    startBackgroundStatusWatcher(ctx);
    sendInfo(pi, "edc-background", backgroundJobAlreadyRunningMessage(result));
  } else {
    startBackgroundStatusWatcher(ctx);
    sendInfo(pi, "edc-background", backgroundJobStartedMessage(result));
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

  if (isKillJobRequest(args)) {
    killRunningJobAction(pi, ctx);
    return;
  }

  if (!ctx.hasUI || !ctx.ui?.select) {
    sendInfo(pi, "edc-command-help", interactiveOnlyMessage());
    return;
  }

  const choice = await ctx.ui.select("EDC", [
    EDC_MENU.REVIEW_DEFAULT,
    EDC_MENU.DELIVERY_REVIEW_DEFAULT,
    EDC_MENU.JOB_STATUS,
    EDC_MENU.KILL_JOB,
    EDC_MENU.BUILD,
    EDC_MENU.UPDATE_DEFAULT,
    EDC_MENU.AUDIT,
    EDC_MENU.DOCTOR,
    EDC_MENU.CANCEL,
  ]);

  switch (choice) {
    case EDC_MENU.REVIEW_DEFAULT:
      await runReviewAgainstDefault(pi, ctx);
      break;
    case EDC_MENU.DELIVERY_REVIEW_DEFAULT:
      runBackgroundAction(pi, ctx, "delivery-review", "edc-delivery-review.sh", defaultBaseReviewArgs(ctx.cwd));
      break;
    case EDC_MENU.JOB_STATUS:
      startBackgroundStatusWatcher(ctx);
      sendInfo(pi, "edc-job-status", renderBackgroundJobStatus("", ctx.cwd));
      break;
    case EDC_MENU.KILL_JOB:
      killRunningJobAction(pi, ctx);
      break;
    case EDC_MENU.BUILD:
      runBackgroundAction(pi, ctx, "build", "edc-build.sh");
      break;
    case EDC_MENU.UPDATE_DEFAULT:
      runBackgroundAction(pi, ctx, "update", "edc-update.sh", defaultBaseUpdateArgs(ctx.cwd));
      break;
    case EDC_MENU.AUDIT:
      runBackgroundAction(pi, ctx, "audit", "edc-audit.sh");
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
    startBackgroundStatusWatcher(ctx);
    const { mode, content } = buildSessionStartContent(ctx.cwd);
    if (mode === "advisory" || !content) return;
    pi.sendMessage({
      customType: "edc-session-context",
      content,
      display: content,
    });
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    stopBackgroundStatusWatcher();
    clearBackgroundStatusUi(ctx);
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
