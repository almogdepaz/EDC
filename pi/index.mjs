/**
 * EDC extension for pi (https://pi.dev).
 *
 * Mirrors the Claude Code plugin:
 *   - registers one interactive /edc menu for user-facing workflows
 *   - on session_start: surfaces edc-context/index.md (in inject mode)
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
} from "../plugins/edc/hooks/lib/route.mjs";
import { BACKGROUND_JOB_TERMINATION_GRACE_MS } from "../plugins/edc/hooks/lib/termination-policy.mjs";
import { argTokens, renderArgs, renderShellArgs, shellQuote, tokenizeArgs } from "./lib/args.mjs";
import {
  backgroundJobAlreadyRunningMessage,
  backgroundJobStartedMessage,
  renderBackgroundFooterStatus,
} from "./lib/background-result.mjs";
import {
  applyDirtyReviewPolicy,
  defaultBaseReviewArgs,
  reviewContextSummary,
  reviewDeclinedMessage,
  shouldProceedWithReview,
} from "./lib/review-scope.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
// pi/index.mjs → repo root → plugins/edc
const PLUGIN_ROOT = join(__dirname, "..", "plugins", "edc");
const EDC_COMMAND = {
  name: "edc",
  description: "Open the interactive EDC menu",
};

const EDC_MENU = {
  FULL_REVIEW: "full repo review",
  DIFF_DEFAULT: "changes vs default branch",
  DIFF_CUSTOM: "changes vs custom base",
  JOB_STATUS: "job status",
  KILL_JOB: "kill running edc job",
  BUILD: "build context",
  FORCE_BUILD: "force rebuild context",
  UPDATE_DEFAULT: "update context",
  DOCTOR: "doctor / validate context",
  CANCEL: "cancel",
};

const EDC_LENS_MENU = {
  COMBINED: "combined review",
  SECURITY: "security review",
  DELIVERY: "delivery review",
  QUALITY: "quality review",
  CANCEL: "cancel",
};

const VISIBLE_SKILLS = ["edc-review", "edc-audit", "edc-delivery-review"];
const EDC_ORCHESTRATOR_BASH_TIMEOUT_SECONDS = 7200;
const EDC_FOREGROUND_COMMAND_TIMEOUT_MS = 60 * 1000;
const MAX_COMMAND_OUTPUT_CHARS = 12000;
const EDC_BACKGROUND_STATUS_GIT_PATH = "edc/status";
const EDC_BACKGROUND_STALE_MS = 12 * 60 * 60 * 1000;
const EDC_BACKGROUND_STARTING_STALE_MS = 60 * 1000;
const EDC_BACKGROUND_UI_KEY = "edc-review";
const EDC_BACKGROUND_UI_POLL_MS = 2000;
const EDC_BACKGROUND_TERMINATION_POLL_MS = 25;
const EDC_LOCAL_COMMAND_TIMEOUT_MS = 10000;

let backgroundStatusTimer = null;

function currentPiModelSlug(ctx) {
  const provider = ctx?.model?.provider;
  const id = ctx?.model?.id;
  if (typeof provider !== "string" || typeof id !== "string") return "";
  return `${provider}/${id}`;
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
    "- full repo review",
    "- changes vs default branch",
    "- changes vs custom base",
    "- job status",
    "- kill running edc job",
    "- build context",
    "- force rebuild context",
    "- update context",
    "- doctor / validate context",
    "",
    "Direct commands:",
    "  /edc kill",
    "",
    "Non-interactive use is intentionally CLI-only:",
    "  edc review full --agent pi",
    "  edc review diff --agent pi",
    "  edc security full --agent pi",
    "  edc delivery diff <base> --agent pi",
    "  edc quality full --agent pi",
    "  edc build --agent pi",
    "  edc build --agent pi --force",
    "  edc update --agent pi",
  ].join("\n");
}

function sendInfo(pi, customType, content) {
  pi.sendMessage({ customType, content, display: true });
}

function isEdcOrchestratorCommand(command) {
  const commandBoundary = "(?:^|[;&|()\\r\\n]\\s*)";
  const scriptName = "edc-(?:build|update|review|review-all|delivery-review|audit|doctor)\\.sh";
  return new RegExp(`${commandBoundary}edc(?:\\s|$)`).test(command)
    || new RegExp(`${commandBoundary}(?:bash\\s+)?["']?(?:\\$HOME|~)/\\.edc/scripts/${scriptName}["']?(?:\\s|$)`).test(command);
}

function extendEdcBashTimeout(event) {
  const command = event?.input?.command;
  if (typeof command !== "string" || !isEdcOrchestratorCommand(command)) return;

  const currentTimeout = Number(event.input.timeout || 0);
  if (!Number.isFinite(currentTimeout) || currentTimeout < EDC_ORCHESTRATOR_BASH_TIMEOUT_SECONDS) {
    event.input.timeout = EDC_ORCHESTRATOR_BASH_TIMEOUT_SECONDS;
  }
}

function findTrustedRuntimeBootstrap() {
  const pluginBootstrap = join(PLUGIN_ROOT, "hooks", "lib", "runtime-bootstrap.mjs");
  if (existsSync(pluginBootstrap)) return pluginBootstrap;

  const home = process.env.HOME || "";
  if (home) {
    const homeBootstrap = join(home, ".edc", "hooks", "lib", "runtime-bootstrap.mjs");
    if (existsSync(homeBootstrap)) return homeBootstrap;
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

function appendCapturedOutput(current, chunk) {
  return tailText(`${current}${chunk}`);
}

function runEdcScript(scriptName, args, ctx) {
  const bootstrap = findTrustedRuntimeBootstrap();
  if (!bootstrap) {
    return Promise.resolve({ code: 127, stdout: "", stderr: "SCRIPT_MISSING: trusted EDC runtime bootstrap is unavailable; reinstall EDC\n" });
  }

  const configuredTimeoutMs = Number(process.env.EDC_FOREGROUND_COMMAND_TIMEOUT_MS);
  const timeoutMs = Number.isFinite(configuredTimeoutMs) && configuredTimeoutMs > 0 ? configuredTimeoutMs : EDC_FOREGROUND_COMMAND_TIMEOUT_MS;
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [bootstrap, scriptName, ...args], {
      cwd: ctx.cwd,
      detached: true,
      env: piSubprocessEnv(ctx),
      stdio: ["ignore", "pipe", "pipe"],
      signal: ctx.signal,
    });

    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;
    let timeoutTimer = null;
    let escalationTimer = null;
    const onStdout = (chunk) => { stdout = appendCapturedOutput(stdout, chunk); };
    const onStderr = (chunk) => { stderr = appendCapturedOutput(stderr, chunk); };
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutTimer);
      clearTimeout(escalationTimer);
      child.stdout.off("data", onStdout);
      child.stderr.off("data", onStderr);
      child.off("error", onError);
      child.off("close", onClose);
      resolve(result);
    };
    const onError = (error) => {
      finish({ code: 1, stdout, stderr: appendCapturedOutput(stderr, `${error.message}\n`) });
    };
    const onClose = async (code, signal) => {
      if (timedOut) {
        let processGroupExited = false;
        try {
          processGroupExited = await waitForSignalTargetExit(child.pid, true);
        } catch {
          // Negative process-group signaling is unavailable on some platforms.
        }
        const cleanupText = processGroupExited ? "" : "; process group did not exit";
        finish({ code: 124, stdout, stderr: appendCapturedOutput(stderr, `ERROR: foreground EDC command timed out${cleanupText}\n`) });
        return;
      }
      const exitCode = typeof code === "number" ? code : 1;
      const signalText = signal ? `terminated by ${signal}\n` : "";
      finish({ code: exitCode, stdout, stderr: appendCapturedOutput(stderr, signalText) });
    };

    child.stdout.setEncoding("utf-8");
    child.stderr.setEncoding("utf-8");
    child.stdout.on("data", onStdout);
    child.stderr.on("data", onStderr);
    child.on("error", onError);
    child.on("close", onClose);
    timeoutTimer = setTimeout(() => {
      timedOut = true;
      try {
        process.kill(-child.pid, "SIGTERM");
      } catch (error) {
        if (error?.code !== "ESRCH") child.kill("SIGTERM");
      }
      escalationTimer = setTimeout(() => {
        try {
          process.kill(-child.pid, "SIGKILL");
        } catch (error) {
          if (error?.code !== "ESRCH") child.kill("SIGKILL");
        }
      }, BACKGROUND_JOB_TERMINATION_GRACE_MS);
    }, timeoutMs);
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
      timeout: EDC_LOCAL_COMMAND_TIMEOUT_MS,
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
    .map(([key, value]) => `${key}=${String(value).replace(/[\x00-\x1f\x7f]+/g, " ")}`)
    .join("\n") + "\n";
}

function currentHead(cwd) {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], {
      cwd,
      timeout: EDC_LOCAL_COMMAND_TIMEOUT_MS,
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
  const structuredPrefix = `
  structured_reason=""
  structured_hint=""
  if [ -f "$result_file" ]; then
    structured_reason="$(node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(j.failureReason || j.reasonCode || "");' "$result_file" 2>/dev/null || true)"
    structured_hint="$(node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(j.failureHint || "");' "$result_file" 2>/dev/null || true)"
  fi
  if [ -n "$structured_reason" ]; then
    failure_reason="$structured_reason"
    failure_hint="$structured_hint"`;

  if (kind !== "review") {
    return `
if [ "$rc" -ne 0 ]; then${structuredPrefix}
  elif [ -n "$started_head" ] && [ -n "$finished_head" ] && [ "$started_head" != "$finished_head" ]; then
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
if [ "$rc" -ne 0 ]; then${structuredPrefix}
  elif [ -n "$started_head" ] && [ -n "$finished_head" ] && [ "$started_head" != "$finished_head" ]; then
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
  elif grep -q 'ERROR: no changed files found for target:' "$log_file" 2>/dev/null; then
    failure_reason="no changed files found for review"
    failure_hint="review uses committed diff plus dirty tracked files; commit changes, modify a tracked file, or choose another target/base"
  elif grep -q 'ERROR: no reviewable files after filtering tool output and ignore rules' "$log_file" 2>/dev/null; then
    failure_reason="no reviewable files after filtering"
    failure_hint="changed files are EDC scratch files or matched by --ignore/.edcignore; choose another target/base or adjust ignore rules"
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

  const bootstrap = findTrustedRuntimeBootstrap();
  if (!bootstrap) {
    return { error: "SCRIPT_MISSING: trusted EDC runtime bootstrap is unavailable; reinstall EDC" };
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
result_file="$status_dir/result.json"
mkdir -p "$status_dir"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_head="$(git rev-parse HEAD 2>/dev/null || true)"
args_text="$(printf '%s ' "$@" | sed 's/ $//')"
status_line() {
  local LC_ALL=C status_key="$1" status_value="\${2-}"
  while [[ "$status_value" =~ [[:cntrl:]]+ ]]; do
    status_value="\${status_value/"\${BASH_REMATCH[0]}"/ }"
  done
  printf '%s=%s\n' "$status_key" "$status_value"
}
{
  status_line "kind" "${kind}"
  status_line "status" "running"
  status_line "started_at" "$started_at"
  status_line "run_id" "${runId}"
  status_line "pid" "$$"
  status_line "args" "$args_text"
  status_line "log" "$log_display"
  [ -n "$started_head" ] && status_line "started_head" "$started_head"
} > "$status_file"

rm -f "$result_file"
EDC_RESULT_FILE="$result_file" ${shellQuote(process.execPath)} ${shellQuote(bootstrap)} ${shellQuote(scriptName)} "$@" > "$log_file" 2>&1
rc=$?
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
finished_head="$(git rev-parse HEAD 2>/dev/null || true)"
repo_changed=""
if [ -n "$started_head" ] && [ -n "$finished_head" ] && [ "$started_head" != "$finished_head" ]; then
  repo_changed="HEAD changed from $(printf '%s' "$started_head" | cut -c1-8) to $(printf '%s' "$finished_head" | cut -c1-8) during background ${kind}; result may reflect the earlier repo state"
fi
read_result_field() {
  [ -f "$result_file" ] || return 0
  node -e '
    const fs = require("fs");
    const key = process.argv[2];
    const json = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    let value = "";
    if (key === "status") value = json.status || (Number(json.exitCode) === 0 ? "success" : "failed");
    else if (key === "reasonCode") value = json.reasonCode || "";
    else if (key === "message") value = json.message || json.failureReason || "";
    else if (key === "hint") value = json.hint || json.failureHint || "";
    else if (key === "failedPhase") value = json.failedPhase || "";
    else if (key === "childResult") value = json.childResult || "";
    else if (key === "scope") value = json.scope || "";
    else if (key === "base") value = json.base || "";
    else if (key === "target") value = json.target || "";
    else if (key === "candidateKind") value = json.candidateKind || "";
    else if (key === "candidateCommit") value = json.candidateCommit || "";
    else if (key === "dirtyTrackedIncluded") value = typeof json.dirtyTrackedIncluded === "boolean" ? (json.dirtyTrackedIncluded ? "included" : "excluded") : "";
    else if (key === "untrackedIncluded") value = typeof json.untrackedIncluded === "boolean" ? (json.untrackedIncluded ? "included" : "excluded") : "";
    else if (key === "finalReview") value = json.finalReview || "";
    else if (key === "outputs") value = Array.isArray(json.outputs) ? json.outputs.join(", ") : "";
    else if (key === "details") value = json.details ? JSON.stringify(json.details) : "";
    process.stdout.write(String(value || "").replace(/[\\x00-\\x1f\\x7f]+/g, " "));
  ' "$result_file" "$1" 2>/dev/null || true
}
structured_status="$(read_result_field status)"
structured_reason_code="$(read_result_field reasonCode)"
structured_message="$(read_result_field message)"
structured_result_hint="$(read_result_field hint)"
structured_failed_phase="$(read_result_field failedPhase)"
structured_child_result="$(read_result_field childResult)"
structured_scope="$(read_result_field scope)"
structured_base="$(read_result_field base)"
structured_target="$(read_result_field target)"
structured_candidate_kind="$(read_result_field candidateKind)"
structured_candidate_commit="$(read_result_field candidateCommit)"
structured_dirty_tracked="$(read_result_field dirtyTrackedIncluded)"
structured_untracked="$(read_result_field untrackedIncluded)"
structured_outputs="$(read_result_field outputs)"
structured_details="$(read_result_field details)"
final_review=""
if [ ${shellQuote(kind)} = "review" ]; then
  final_review="$(awk '/^Verified: /{p=$2} /^Consolidated: /{if (p == "") p=$2} END{print p}' "$log_file" 2>/dev/null || true)"
fi
structured_final_review="$(read_result_field finalReview)"
[ -n "$structured_final_review" ] && final_review="$structured_final_review"
failure_reason=""
failure_hint=""
${failureClassificationShell(kind)}
[ -n "$structured_message" ] && failure_reason="$structured_message"
[ -n "$structured_result_hint" ] && failure_hint="$structured_result_hint"
status_value="\${structured_status:-}"
if [ -z "$status_value" ]; then
  if [ "$rc" -eq 0 ]; then status_value="success"; else status_value="failed"; fi
fi
{
  status_line "kind" "${kind}"
  status_line "status" "$status_value"
  status_line "exit_code" "$rc"
  status_line "started_at" "$started_at"
  status_line "finished_at" "$finished_at"
  status_line "run_id" "${runId}"
  status_line "pid" "$$"
  status_line "args" "$args_text"
  status_line "log" "$log_display"
  [ -n "$started_head" ] && status_line "started_head" "$started_head"
  [ -n "$finished_head" ] && status_line "finished_head" "$finished_head"
  [ -n "$repo_changed" ] && status_line "repo_changed" "$repo_changed"
  [ -n "$structured_reason_code" ] && status_line "reason_code" "$structured_reason_code"
  [ -n "$structured_failed_phase" ] && status_line "failed_phase" "$structured_failed_phase"
  [ -n "$structured_child_result" ] && status_line "child_result" "$structured_child_result"
  [ -n "$structured_scope" ] && status_line "scope" "$structured_scope"
  [ -n "$structured_base" ] && status_line "base" "$structured_base"
  [ -n "$structured_target" ] && status_line "target" "$structured_target"
  [ -n "$structured_candidate_kind" ] && status_line "candidate_kind" "$structured_candidate_kind"
  [ -n "$structured_candidate_commit" ] && status_line "candidate_commit" "$structured_candidate_commit"
  [ -n "$structured_dirty_tracked" ] && status_line "dirty_tracked_files" "$structured_dirty_tracked"
  [ -n "$structured_untracked" ] && status_line "untracked_files" "$structured_untracked"
  [ -n "$structured_outputs" ] && status_line "outputs" "$structured_outputs"
  [ -n "$structured_details" ] && status_line "details" "$structured_details"
  [ -n "$failure_reason" ] && status_line "failure_reason" "$failure_reason"
  [ -n "$failure_hint" ] && status_line "failure_hint" "$failure_hint"
  [ -n "$final_review" ] && status_line "final_review" "$final_review"
} > "$status_file"
`;

  const child = spawn("bash", ["-lc", script], {
    cwd: ctx.cwd,
    detached: true,
    stdio: "ignore",
    env: piSubprocessEnv(ctx),
  });
  child.on("error", (error) => {
    markRunningBackgroundFailed(
      ctx.cwd,
      statusPath,
      {
        kind,
        started_at: startedAt,
        run_id: runId,
        pid: "spawn-error",
        args: renderedArgs,
        log: logPath.display,
        started_head: startedHead,
      },
      `failed to start background ${kind}: ${error.message}`,
      "verify bash is available on PATH, then rerun the EDC job",
    );
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

function isSignalTargetAlive(pid, processGroup) {
  try {
    process.kill(processGroup ? -pid : pid, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    if (error?.code === "EPERM") return true;
    throw error;
  }
}

async function waitForSignalTargetExit(pid, processGroup) {
  const deadline = Date.now() + BACKGROUND_JOB_TERMINATION_GRACE_MS;
  while (isSignalTargetAlive(pid, processGroup)) {
    if (Date.now() >= deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, EDC_BACKGROUND_TERMINATION_POLL_MS));
  }
  return true;
}

function terminalKillOutcome(message) {
  return { isTerminal: true, message };
}

function runningKillOutcome(message) {
  return { isTerminal: false, message };
}

async function killBackgroundJob(cwd) {
  const job = readBackgroundJobStatus(cwd);
  if (!job) return terminalKillOutcome("No running background EDC job found.");

  const status = job.status;
  const kind = status.kind || "job";
  if (status.status !== "running") {
    return terminalKillOutcome(`No running background EDC job found. Current ${kind} status: ${status.status || "unknown"}.`);
  }

  const active = runningBackgroundJob(cwd);
  if (!active) return terminalKillOutcome("No running background EDC job found; stale status was cleaned up.");

  const pid = Number(status.pid);
  if (!Number.isInteger(pid) || pid <= 0) {
    return runningKillOutcome(`Cannot kill background EDC ${kind} ${status.run_id || "current"}: status file has invalid pid ${status.pid || "missing"}.`);
  }

  let processGroup = true;
  try {
    process.kill(-pid, "SIGTERM");
  } catch (groupError) {
    processGroup = false;
    try {
      process.kill(pid, "SIGTERM");
    } catch (pidError) {
      if (pidError?.code !== "ESRCH") {
        return runningKillOutcome(`Failed to kill background EDC ${kind} ${status.run_id || "current"}: ${pidError?.message || groupError?.message || "unknown error"}`);
      }
    }
  }

  let terminated;
  try {
    terminated = await waitForSignalTargetExit(pid, processGroup);
  } catch (error) {
    return runningKillOutcome(`Failed to verify background EDC ${kind} ${status.run_id || "current"} termination: ${error?.message || "unknown error"}`);
  }
  if (!terminated) {
    try {
      process.kill(processGroup ? -pid : pid, "SIGKILL");
    } catch (error) {
      if (error?.code !== "ESRCH") {
        return runningKillOutcome(`Failed to force-kill background EDC ${kind} ${status.run_id || "current"}: ${error?.message || "unknown error"}`);
      }
    }
    try {
      terminated = await waitForSignalTargetExit(pid, processGroup);
    } catch (error) {
      return runningKillOutcome(`Failed to verify background EDC ${kind} ${status.run_id || "current"} force-kill: ${error?.message || "unknown error"}`);
    }
  }
  if (!terminated) {
    return runningKillOutcome(`Failed to kill background EDC ${kind} ${status.run_id || "current"}: ${processGroup ? "process group" : "process"} ${pid} remained alive after SIGKILL.`);
  }

  markRunningBackgroundCancelled(cwd, job.statusPath, status);
  return terminalKillOutcome([
    `Background EDC ${kind} killed.`,
    "",
    `Run ID: ${status.run_id || "current"}`,
    `PID: ${status.pid}`,
    status.log ? `Log: ${status.log}` : "",
  ].filter(Boolean).join("\n"));
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
  if (status.reason_code) lines.push(`code: ${status.reason_code}`);
  if (status.started_at) lines.push(`started: ${status.started_at}`);
  if (status.finished_at) lines.push(`finished: ${status.finished_at}`);
  if (status.final_review) lines.push(`final review: ${status.final_review}`);
  if (status.args) lines.push(`args: ${status.args}`);
  if (status.pid) lines.push(`pid: ${status.pid}`);
  if (status.started_head) lines.push(`started HEAD: ${status.started_head.slice(0, 8)}`);
  if (status.finished_head && status.finished_head !== status.started_head) lines.push(`finished HEAD: ${status.finished_head.slice(0, 8)}`);
  if (status.repo_changed) lines.push(`warning: ${status.repo_changed}`);
  if (status.failed_phase) lines.push(`failed phase: ${status.failed_phase}`);
  if (status.scope) lines.push(`scope: ${status.scope}`);
  if (status.base) lines.push(`base: ${status.base}`);
  if (status.target) lines.push(`target: ${status.target}`);
  if (status.candidate_kind) lines.push(`candidate: ${status.candidate_kind}`);
  if (status.candidate_commit) lines.push(`candidate commit: ${status.candidate_commit.slice(0, 12)}`);
  if (status.dirty_tracked_files) lines.push(`dirty tracked files: ${status.dirty_tracked_files}`);
  if (status.untracked_files) lines.push(`untracked files: ${status.untracked_files}`);
  if (status.outputs) lines.push(`outputs: ${status.outputs}`);
  if (status.failure_reason) lines.push(`reason: ${status.failure_reason}`);
  if (status.failure_hint) lines.push(`hint: ${status.failure_hint}`);
  if (status.details) lines.push(`details: ${status.details}`);
  if (status.child_result) lines.push(`child result: ${status.child_result}`);
  if (status.log) lines.push(`log: ${status.log}`);
  lines.push("");
  if (status.status === "success") {
    lines.push(`EDC ${kind} complete.`);
  } else if (status.status === "success-with-warning") {
    lines.push(`EDC ${kind} complete with warnings.`);
  } else if (status.status === "failed") {
    lines.push(`EDC ${kind} failed. Open the log above for details.`);
  } else if (status.status === "cancelled") {
    lines.push(`EDC ${kind} cancelled.`);
  } else {
    lines.push("Still running. Check again with `/edc` → Job status.");
  }
  return lines.join("\n");
}

function canShowBackgroundStatusUi(ctx) {
  return ctx?.hasUI !== false && !!ctx?.ui
    && (typeof ctx.ui.setStatus === "function" || typeof ctx.ui.setWidget === "function");
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

function interactiveOnlyMessage() {
  return [
    "/edc is interactive-only.",
    "",
    "Use the EDC CLI for non-interactive runs:",
    "  edc review full --agent pi",
    "  edc review diff --agent pi",
    "  edc security full --agent pi",
    "  edc quality full --agent pi",
    "  edc build --agent pi",
    "  edc build --agent pi --force",
    "  edc update --agent pi",
  ].join("\n");
}

async function killRunningJobAction(pi, ctx) {
  const outcome = await killBackgroundJob(ctx.cwd);
  if (outcome.isTerminal) {
    stopBackgroundStatusWatcher();
    clearBackgroundStatusUi(ctx);
  } else {
    startBackgroundStatusWatcher(ctx);
  }
  sendInfo(pi, "edc-job-kill", outcome.message);
}

async function startReviewJob(pi, ctx, kind, scriptName, args, commandName = "review", scope = "") {
  const renderedArgs = args || [];
  const freshness = getContextFreshness(ctx.cwd);
  const proceed = await shouldProceedWithReview(renderedArgs, ctx, freshness);
  if (!proceed) {
    sendInfo(pi, "edc-review-preflight", reviewDeclinedMessage(renderedArgs, commandName, scope));
    return;
  }

  const result = startBackgroundJob(kind, scriptName, renderedArgs, ctx);
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

function reviewConfigForLens(lens, isFullScope) {
  switch (lens) {
    case EDC_LENS_MENU.COMBINED:
      return { kind: "review-all", scriptName: "edc-review-all.sh", commandName: "review", args: isFullScope ? ["--full"] : null };
    case EDC_LENS_MENU.SECURITY:
      return { kind: "review", scriptName: "edc-review.sh", commandName: "security", args: isFullScope ? ["--full"] : null };
    case EDC_LENS_MENU.DELIVERY:
      return { kind: "delivery-review", scriptName: "edc-delivery-review.sh", commandName: "delivery", args: isFullScope ? ["--full"] : null };
    case EDC_LENS_MENU.QUALITY:
      return { kind: "audit", scriptName: "edc-audit.sh", commandName: "quality", args: isFullScope ? [] : null };
    default:
      return null;
  }
}

async function selectReviewLens(ctx) {
  return ctx.ui.select("review lens", [
    EDC_LENS_MENU.COMBINED,
    EDC_LENS_MENU.SECURITY,
    EDC_LENS_MENU.DELIVERY,
    EDC_LENS_MENU.QUALITY,
    EDC_LENS_MENU.CANCEL,
  ]);
}

async function argsForReviewScope(ctx, scopeChoice) {
  switch (scopeChoice) {
    case EDC_MENU.FULL_REVIEW:
      return { isFullScope: true, args: [] };
    case EDC_MENU.DIFF_DEFAULT: {
      const policy = await applyDirtyReviewPolicy(defaultBaseReviewArgs(ctx.cwd), ctx);
      return policy.cancelled ? policy : { isFullScope: false, args: policy.args };
    }
    case EDC_MENU.DIFF_CUSTOM: {
      if (typeof ctx.ui.input !== "function") {
        return { error: "custom refs require CLI for now: edc review diff <base> --agent pi" };
      }
      const base = await ctx.ui.input("base ref", { placeholder: "origin/main" });
      if (!base) return { cancelled: true };
      const target = await ctx.ui.input("target ref", { placeholder: "HEAD" });
      if (!target) return { cancelled: true };
      const policy = await applyDirtyReviewPolicy([String(target), "--base", String(base)], ctx);
      return policy.cancelled ? policy : { isFullScope: false, args: policy.args };
    }
    default:
      return { cancelled: true };
  }
}

async function runReviewFromMenuScope(pi, ctx, scopeChoice) {
  const scope = await argsForReviewScope(ctx, scopeChoice);
  if (scope.cancelled) return;
  if (scope.error) {
    sendInfo(pi, "edc-review-scope", scope.error);
    return;
  }

  const lens = await selectReviewLens(ctx);
  if (!lens || lens === EDC_LENS_MENU.CANCEL) {
    sendInfo(pi, "edc-menu", "EDC menu cancelled.");
    return;
  }

  const config = reviewConfigForLens(lens, scope.isFullScope);
  if (!config) {
    sendInfo(pi, "edc-menu", "EDC menu cancelled.");
    return;
  }
  await startReviewJob(pi, ctx, config.kind, config.scriptName, config.args ?? scope.args, config.commandName, scope.isFullScope ? "full" : "diff");
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
    await killRunningJobAction(pi, ctx);
    return;
  }

  if (!ctx.hasUI || !ctx.ui?.select) {
    sendInfo(pi, "edc-command-help", interactiveOnlyMessage());
    return;
  }

  const choice = await ctx.ui.select("EDC", [
    EDC_MENU.FULL_REVIEW,
    EDC_MENU.DIFF_DEFAULT,
    EDC_MENU.DIFF_CUSTOM,
    EDC_MENU.JOB_STATUS,
    EDC_MENU.KILL_JOB,
    EDC_MENU.BUILD,
    EDC_MENU.FORCE_BUILD,
    EDC_MENU.UPDATE_DEFAULT,
    EDC_MENU.DOCTOR,
    EDC_MENU.CANCEL,
  ]);

  switch (choice) {
    case EDC_MENU.FULL_REVIEW:
    case EDC_MENU.DIFF_DEFAULT:
    case EDC_MENU.DIFF_CUSTOM:
      await runReviewFromMenuScope(pi, ctx, choice);
      break;
    case EDC_MENU.JOB_STATUS:
      startBackgroundStatusWatcher(ctx);
      sendInfo(pi, "edc-job-status", renderBackgroundJobStatus("", ctx.cwd));
      break;
    case EDC_MENU.KILL_JOB:
      await killRunningJobAction(pi, ctx);
      break;
    case EDC_MENU.BUILD:
      runBackgroundAction(pi, ctx, "build", "edc-build.sh");
      break;
    case EDC_MENU.FORCE_BUILD:
      runBackgroundAction(pi, ctx, "build", "edc-build.sh", ["--force"]);
      break;
    case EDC_MENU.UPDATE_DEFAULT:
      runBackgroundAction(pi, ctx, "update", "edc-update.sh");
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
