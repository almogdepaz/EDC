#!/usr/bin/env bash
# t10-pi-extension: smoke-test the pi extension wiring.
#
# Verifies:
#   - root package.json has the pi.extensions entry pointing at pi/index.mjs
#   - pi/index.mjs and agents/pi/index.mjs parse (node --check)
#   - shared lib (plugins/edc/hooks/lib/route.mjs) exports the expected names
#   - the extension factory runs end-to-end against a fake ExtensionAPI
#     (registers only the interactive /edc command, exposes only human-useful
#     skills, subscribes to the expected events, and buildToolCallInjection
#     produces module docs through the same code path)
set -uo pipefail

PASS=0
FAIL=0
say_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
say_fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# --- 1. package.json ---------------------------------------------------------
if [ ! -f package.json ]; then
  say_fail "root package.json present"
else
  ext=$(node -e 'console.log((JSON.parse(require("fs").readFileSync("package.json","utf-8")).pi?.extensions||[]).join(","))')
  case "$ext" in
    *"./pi/index.mjs"*) say_pass "package.json declares pi.extensions" ;;
    *) say_fail "package.json pi.extensions entry" "got: $ext" ;;
  esac
fi

# --- 2. extension entries parse ---------------------------------------------
if node --check pi/index.mjs 2>/dev/null; then
  say_pass "pi/index.mjs parses"
else
  say_fail "pi/index.mjs parses"
fi

if node --check agents/pi/index.mjs 2>/dev/null; then
  say_pass "agents/pi/index.mjs parses"
else
  say_fail "agents/pi/index.mjs parses"
fi

# --- 3. shared lib exports --------------------------------------------------
exports_check=$(node --input-type=module -e '
  import("./plugins/edc/hooks/lib/route.mjs").then(m => {
    // Public API — see plugins/edc/hooks/lib/route.mjs. Internal helpers
    // (loadManifest, routeFile, dedupPath, etc.) are intentionally unexported.
    const required = [
      "resolvePluginRoot",
      "installOrchestratorScript",
      "buildSessionStartContent",
      "buildToolCallInjection",
      "getContextFreshness",
      "normalizePath",
      "routeFileSync"
    ];
    const missing = required.filter(n => typeof m[n] !== "function");
    if (missing.length) { console.log("MISSING:" + missing.join(",")); process.exit(1); }
    console.log("OK");
  }).catch(e => { console.log("ERR:" + e.message); process.exit(1); });
' 2>&1)
if [ "$exports_check" = "OK" ]; then
  say_pass "lib/route.mjs exports expected helpers"
else
  say_fail "lib/route.mjs exports expected helpers" "$exports_check"
fi

# --- 4. extension factory wiring (fake ExtensionAPI) ------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a minimal fake ctx environment with a real edc-context/manifest.json so
# buildToolCallInjection has something to chew on.
mkdir -p "$TMP/edc-context/modules"
cat > "$TMP/edc-context/manifest.json" <<'EOF'
{
  "schemaVersion": 2,
  "policy": { "defaultMode": "inject" },
  "modules": [
    { "name": "src-mod", "priority": 50, "match": { "prefixes": ["src/"] }, "doc": "edc-context/modules/src-mod.md" }
  ]
}
EOF
echo "# src-mod docs" > "$TMP/edc-context/modules/src-mod.md"
cat > "$TMP/edc-context/index.md" <<'EOF'
# Repo Index
## Module Map
- src-mod
EOF
(
  cd "$TMP" || exit 1
  git init -q
  git config user.email a@example.com
  git config user.name a
  touch tracked.txt
  git add tracked.txt
  git -c commit.gpgsign=false commit -q -m init
  head_commit=$(git rev-parse HEAD)
  tmp_manifest=$(mktemp)
  jq --arg head "$head_commit" '.sourceCommit = $head' edc-context/manifest.json > "$tmp_manifest"
  mv "$tmp_manifest" edc-context/manifest.json
)

# Unique session id per test run so the file-based dedup (rooted in os.tmpdir())
# doesn't poison a re-run.
SESSION_ID="t10-$$-$(date +%s%N 2>/dev/null || date +%s)"

wiring=$(EDC_TEST_CWD="$TMP" EDC_TEST_SID="$SESSION_ID" node --input-type=module -e '
  delete process.env.EDC_PI_SUBPROCESS;
  const cwd = process.env.EDC_TEST_CWD;
  const sid = process.env.EDC_TEST_SID;
  const calls = { commands: [], events: [], messages: [], userMessages: [], notifications: [], confirmations: [], selections: [] };
  const fakePi = {
    on: (event, handler) => { calls.events.push({ event, handler }); },
    registerCommand: (name, opts) => { calls.commands.push({ name, opts }); },
    sendMessage: (m) => { calls.messages.push(m); },
    sendUserMessage: (m) => { calls.userMessages.push(m); },
  };
  const factory = (await import("./agents/pi/index.mjs")).default;
  await factory(fakePi);

  // 1. only the interactive /edc command is registered.
  const got = calls.commands.map(c => c.name).sort();
  if (JSON.stringify(got) !== JSON.stringify(["edc"])) {
    console.log("CMDS_FAIL:" + got.join(","));
    process.exit(1);
  }
  const edcCmd = calls.commands.find(c => c.name === "edc");

  // 2. expected events subscribed
  const evs = calls.events.map(e => e.event).sort();
  // Note: session_shutdown is no longer needed — dedup is file-based, not
  // in-process (see plugins/edc/hooks/lib/route.mjs::isDuplicate).
  for (const want of ["resources_discover","session_start","tool_call"]) {
    if (!evs.includes(want)) { console.log("MISSING_EVENT:" + want); process.exit(1); }
  }

  const fs = await import("node:fs");
  const childProcess = await import("node:child_process");

  fs.mkdirSync(`${cwd}/.edc/scripts`, { recursive: true });
  fs.writeFileSync(`${cwd}/.edc/scripts/edc-review.sh`, `#!/usr/bin/env bash\nset -euo pipefail\nif [ "\${BASH_VERSINFO[0]}" -lt 4 ]; then echo old-bash; exit 2; fi\necho "agent=$EDC_AGENT_CLI model=\${EDC_PI_MODEL:-}"\necho "review args: $*"\necho "Consolidated: review-HEAD.md"\necho "Verified: review-HEAD.md"\n`);
  fs.writeFileSync(`${cwd}/.edc/scripts/edc-build.sh`, `#!/usr/bin/env bash\nset -euo pipefail\nif [ "\${BASH_VERSINFO[0]}" -lt 4 ]; then echo old-bash; exit 2; fi\necho "build args: $* agent=$EDC_AGENT_CLI"\n`);
  fs.writeFileSync(`${cwd}/.edc/scripts/edc-update.sh`, `#!/usr/bin/env bash\nset -euo pipefail\nif [ "\${BASH_VERSINFO[0]}" -lt 4 ]; then echo old-bash; exit 2; fi\necho "update args: $* agent=$EDC_AGENT_CLI"\n`);
  fs.writeFileSync(`${cwd}/.edc/scripts/edc-audit.sh`, `#!/usr/bin/env bash\nset -euo pipefail\nif [ "\${BASH_VERSINFO[0]}" -lt 4 ]; then echo old-bash; exit 2; fi\necho "audit args: $* agent=$EDC_AGENT_CLI"\n`);
  fs.writeFileSync(`${cwd}/.edc/scripts/edc-doctor.sh`, `#!/usr/bin/env bash\nset -euo pipefail\nif [ "\${BASH_VERSINFO[0]}" -lt 4 ]; then echo old-bash; exit 2; fi\necho "doctor args: $* agent=$EDC_AGENT_CLI"\n`);
  for (const script of ["edc-review.sh", "edc-build.sh", "edc-update.sh", "edc-audit.sh", "edc-doctor.sh"]) {
    fs.chmodSync(`${cwd}/.edc/scripts/${script}`, 0o755);
  }

  const menuCtx = (selection, extra = {}) => ({
    cwd,
    hasUI: true,
    model: { provider: "test-provider", id: "test-model" },
    ui: {
      select: async (title, items) => {
        calls.selections.push({ title, items });
        return selection;
      },
      confirm: extra.confirm || (async (title, message) => {
        calls.confirmations.push({ title, message });
        return true;
      }),
    },
  });

  // 3. /edc menu review starts background review against HEAD --base main.
  await edcCmd.opts.handler("", menuCtx("Review current branch vs main"));
  if (calls.userMessages.length !== 0) {
    console.log("DIRECT_COMMAND_USED_MODEL_FAIL:" + JSON.stringify(calls.userMessages));
    process.exit(1);
  }
  const firstBackgroundMessage = calls.messages.at(-1)?.content || "";
  if (!firstBackgroundMessage.includes("Background review started.") || !firstBackgroundMessage.includes("EDC context: fresh.") || !firstBackgroundMessage.includes("Check progress: `/edc` → Review status.")) {
    console.log("MENU_REVIEW_FAIL:" + JSON.stringify(calls.messages.slice(-3)));
    process.exit(1);
  }
  const runId = (firstBackgroundMessage.match(/Run ID: (\S+)/) || [])[1];
  if (!runId) {
    console.log("RUN_ID_FAIL:" + firstBackgroundMessage);
    process.exit(1);
  }
  const statusFile = `${cwd}/.git/edc/status`;
  const logFile = `${cwd}/.git/edc/review.log`;
  for (let i = 0; i < 20; i++) {
    if (fs.existsSync(statusFile) && fs.readFileSync(statusFile, "utf-8").includes("status=success")) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  if (!fs.existsSync(logFile) || !fs.readFileSync(logFile, "utf-8").includes("Verified: review-HEAD.md")) {
    console.log("REVIEW_LOG_FAIL:" + (fs.existsSync(logFile) ? fs.readFileSync(logFile, "utf-8") : "missing"));
    process.exit(1);
  }
  const reviewArgs = (fs.readFileSync(statusFile, "utf-8").match(/^args=(.+)$/m) || [])[1] || "";
  if (reviewArgs !== "HEAD --base main") {
    console.log("MENU_REVIEW_ARGS_FAIL:" + reviewArgs);
    process.exit(1);
  }

  // 3b. /edc menu can show status for latest run.
  await edcCmd.opts.handler("", menuCtx("Review status"));
  const statusMessage = calls.messages.at(-1)?.content || "";
  if (!statusMessage.includes("status: success") || !statusMessage.includes("final review: review-HEAD.md") || !statusMessage.includes("log: .git/edc/review.log")) {
    console.log("STATUS_CMD_FAIL:" + JSON.stringify(statusMessage));
    process.exit(1);
  }

  // 3c. single-active-run guard refuses duplicate background reviews.
  fs.writeFileSync(statusFile, fs.readFileSync(statusFile, "utf-8")
    .replace("status=success", "status=running")
    .replace(/^pid=.*$/m, `pid=${process.pid}`));
  await edcCmd.opts.handler("", menuCtx("Review current branch vs main"));
  const alreadyRunningMessage = calls.messages.at(-1)?.content || "";
  if (!alreadyRunningMessage.includes("already running") || !alreadyRunningMessage.includes("Check progress: `/edc` → Review status.")) {
    console.log("ALREADY_RUNNING_FAIL:" + JSON.stringify(alreadyRunningMessage));
    process.exit(1);
  }
  fs.writeFileSync(statusFile, fs.readFileSync(statusFile, "utf-8").replace("status=running", "status=success"));

  // 3d. immediate duplicate starts are rejected before the child writes status.
  const raceDir = `${cwd}/race-review`;
  fs.mkdirSync(`${raceDir}/.edc/scripts`, { recursive: true });
  childProcess.execFileSync("git", ["init"], { cwd: raceDir, stdio: "ignore" });
  fs.writeFileSync(`${raceDir}/tracked.txt`, "x\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: raceDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: raceDir, stdio: "ignore" });
  fs.writeFileSync(`${raceDir}/.edc/scripts/edc-review.sh`, `#!/usr/bin/env bash\nset -euo pipefail\nsleep 2\necho "Verified: review-HEAD.md"\n`);
  fs.chmodSync(`${raceDir}/.edc/scripts/edc-review.sh`, 0o755);

  const bashCandidates = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"];
  const realBash = bashCandidates.find((candidate) => {
    try {
      return childProcess.execFileSync(candidate, ["-lc", "printf %s ${BASH_VERSINFO[0]}"], { encoding: "utf-8" }).trim() >= "4";
    } catch {
      return false;
    }
  });
  if (!realBash) {
    console.log("RACE_TEST_BASH_MISSING");
    process.exit(1);
  }
  fs.mkdirSync(`${raceDir}/fake-bin`, { recursive: true });
  fs.writeFileSync(`${raceDir}/fake-bin/bash`, `#!/bin/sh\nif [ "$1" = "-lc" ] && printf '%s' "$2" | grep -q BASH_VERSINFO; then printf '5'; exit 0; fi\nsleep 1\nexec ${realBash} "$@"\n`);
  fs.chmodSync(`${raceDir}/fake-bin/bash`, 0o755);

  const previousPath = process.env.PATH;
  process.env.PATH = `${raceDir}/fake-bin:${previousPath || ""}`;
  const raceStartIndex = calls.messages.length;
  await Promise.all([
    edcCmd.opts.handler("", { ...menuCtx("Review current branch vs main"), cwd: raceDir }),
    edcCmd.opts.handler("", { ...menuCtx("Review current branch vs main"), cwd: raceDir }),
  ]);
  process.env.PATH = previousPath;
  const raceMessages = calls.messages.slice(raceStartIndex).map((message) => message.content || "");
  const raceStartedCount = raceMessages.filter((message) => message.includes("Background review started.")).length;
  const raceBlockedCount = raceMessages.filter((message) => message.includes("already running")).length;
  if (raceStartedCount !== 1 || raceBlockedCount !== 1) {
    console.log("IMMEDIATE_DUPLICATE_REVIEW_FAIL:" + JSON.stringify(raceMessages));
    process.exit(1);
  }

  // 3e. dead running PID is marked failed and does not wedge future starts.
  const stalePidDir = `${cwd}/stale-pid-review`;
  fs.mkdirSync(`${stalePidDir}/.edc/scripts`, { recursive: true });
  childProcess.execFileSync("git", ["init"], { cwd: stalePidDir, stdio: "ignore" });
  fs.writeFileSync(`${stalePidDir}/tracked.txt`, "x\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: stalePidDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: stalePidDir, stdio: "ignore" });
  fs.writeFileSync(`${stalePidDir}/.edc/scripts/edc-review.sh`, `#!/usr/bin/env bash\nset -euo pipefail\necho "Verified: review-HEAD.md"\n`);
  fs.chmodSync(`${stalePidDir}/.edc/scripts/edc-review.sh`, 0o755);
  fs.mkdirSync(`${stalePidDir}/.git/edc`, { recursive: true });
  fs.writeFileSync(`${stalePidDir}/.git/edc/status`, "status=running\nrun_id=dead\npid=999999\nstarted_at=2000-01-01T00:00:00Z\n");
  await edcCmd.opts.handler("", { ...menuCtx("Review current branch vs main"), cwd: stalePidDir });
  const stalePidMessage = calls.messages.at(-1)?.content || "";
  if (!stalePidMessage.includes("Background review started.")) {
    console.log("STALE_PID_RECOVERY_FAIL:" + JSON.stringify(stalePidMessage));
    process.exit(1);
  }

  // 3f. direct script actions route from menu.
  await edcCmd.opts.handler("", menuCtx("Build context"));
  if (!calls.messages.at(-1)?.content?.includes("build args:  agent=pi")) {
    console.log("BUILD_DIRECT_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }
  await edcCmd.opts.handler("", menuCtx("Update context from main"));
  if (!calls.messages.at(-1)?.content?.includes("update args: --base main agent=pi")) {
    console.log("UPDATE_DIRECT_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }
  await edcCmd.opts.handler("", menuCtx("Audit complexity"));
  if (!calls.messages.at(-1)?.content?.includes("audit args:  agent=pi")) {
    console.log("AUDIT_DIRECT_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }
  await edcCmd.opts.handler("", menuCtx("Doctor / validate context"));
  if (!calls.messages.at(-1)?.content?.includes("doctor args:  agent=pi")) {
    console.log("DOCTOR_DIRECT_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }

  // 3g. /edc -h shows help directly instead of launching an agent turn.
  const userMessagesAfterCommand = calls.userMessages.length;
  await edcCmd.opts.handler("-h", { cwd });
  if (calls.userMessages.length !== userMessagesAfterCommand) {
    console.log("HELP_LAUNCHED_AGENT:" + JSON.stringify(calls.userMessages));
    process.exit(1);
  }
  if (!calls.messages.at(-1)?.content?.includes("Usage: /edc")) {
    console.log("HELP_MESSAGE_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }

  // 3h. /edc is interactive-only; non-interactive contexts are told to use the CLI.
  await edcCmd.opts.handler("", { cwd, hasUI: false });
  const nonInteractiveMessage = calls.messages.at(-1)?.content || "";
  if (!nonInteractiveMessage.includes("/edc is interactive-only") || !nonInteractiveMessage.includes("edc review --agent pi HEAD --base main")) {
    console.log("NON_INTERACTIVE_FAIL:" + JSON.stringify(nonInteractiveMessage));
    process.exit(1);
  }

  // 3i. missing context prompts before auto-build and carries state into start message.
  const missingDir = `${cwd}/missing-context`;
  fs.mkdirSync(`${missingDir}/.edc/scripts`, { recursive: true });
  childProcess.execFileSync("git", ["init"], { cwd: missingDir, stdio: "ignore" });
  fs.writeFileSync(`${missingDir}/tracked.txt`, "x\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: missingDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: missingDir, stdio: "ignore" });
  fs.writeFileSync(`${missingDir}/.edc/scripts/edc-review.sh`, `#!/usr/bin/env bash\nset -euo pipefail\nprintf "%s\\n" "$*" > review-args.txt\necho "Consolidated: review-HEAD.md"\necho "Verified: review-HEAD.md"\n`);
  fs.chmodSync(`${missingDir}/.edc/scripts/edc-review.sh`, 0o755);
  const missingCtx = {
    cwd: missingDir,
    hasUI: true,
    ui: {
      select: async () => "Review current branch vs main",
      confirm: async (title, message) => {
        calls.confirmations.push({ title, message });
        return true;
      },
    },
  };
  await edcCmd.opts.handler("", missingCtx);
  if (!calls.confirmations.at(-1)?.message?.includes("EDC context: missing/incomplete") || !calls.confirmations.at(-1)?.message?.includes("reason: manifest")) {
    console.log("MISSING_PROMPT_FAIL:" + JSON.stringify(calls.confirmations.at(-1)));
    process.exit(1);
  }
  const missingBackgroundMessage = calls.messages.at(-1)?.content || "";
  if (!missingBackgroundMessage.includes("Background review started.") || !missingBackgroundMessage.includes("EDC context: missing/incomplete") || !missingBackgroundMessage.includes("reason: manifest")) {
    console.log("MISSING_BACKGROUND_CONTEXT_FAIL:" + JSON.stringify(missingBackgroundMessage));
    process.exit(1);
  }

  // 3j. declining stale/missing context stops and teaches explicit CLI no-context modes.
  const staleDir = `${cwd}/stale-context`;
  fs.mkdirSync(`${staleDir}/edc-context`, { recursive: true });
  fs.writeFileSync(`${staleDir}/file.txt`, "x\n");
  childProcess.execFileSync("git", ["init"], { cwd: staleDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["add", "file.txt"], { cwd: staleDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: staleDir, stdio: "ignore" });
  const sourceCommit = childProcess.execFileSync("git", ["rev-parse", "HEAD"], { cwd: staleDir, encoding: "utf-8" }).trim();
  fs.writeFileSync(`${staleDir}/file.txt`, "y\n");
  childProcess.execFileSync("git", ["add", "file.txt"], { cwd: staleDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "change"], { cwd: staleDir, stdio: "ignore" });
  fs.writeFileSync(`${staleDir}/edc-context/index.md`, "# Repo\n## Modules\n");
  fs.writeFileSync(`${staleDir}/edc-context/manifest.json`, JSON.stringify({
    schemaVersion: 2,
    policy: { defaultMode: "inject" },
    sourceCommit,
    modules: [],
  }));
  await edcCmd.opts.handler("", {
    cwd: staleDir,
    hasUI: true,
    ui: {
      select: async () => "Review current branch vs main",
      confirm: async (title, message) => {
        calls.confirmations.push({ title, message });
        return false;
      },
    },
  });
  const stalePrompt = calls.confirmations.at(-1)?.message || "";
  if (!stalePrompt.includes("EDC context: stale") || !stalePrompt.includes("behind by: 1 commit")) {
    console.log("STALE_PROMPT_FAIL:" + JSON.stringify(calls.confirmations.at(-1)));
    process.exit(1);
  }
  const declineMessage = calls.messages.at(-1)?.content || "";
  if (!declineMessage.includes("edc review --agent pi HEAD --base main --no-context-refresh") || !declineMessage.includes("--ignore-context")) {
    console.log("DECLINE_GUIDANCE_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }

  // 4. resources_discover returns only human-facing review/audit skills
  const rd = calls.events.find(e => e.event === "resources_discover");
  const r = await rd.handler({ type: "resources_discover", cwd, reason: "startup" }, { cwd });
  if (!r || !Array.isArray(r.skillPaths) || r.skillPaths.length !== 2) {
    console.log("RD_FAIL:" + JSON.stringify(r));
    process.exit(1);
  }
  const skillNames = r.skillPaths.map(p => p.split("/").pop()).sort();
  const expectedSkills = ["edc-audit", "edc-review"];
  if (JSON.stringify(skillNames) !== JSON.stringify(expectedSkills)) {
    console.log("SKILLS_FAIL:" + skillNames.join(","));
    process.exit(1);
  }

  // 5. session_start injects edc-context/index.md when mode=inject
  const ss = calls.events.find(e => e.event === "session_start");
  const ssCtx = { cwd, sessionManager: { getSessionId: () => sid } };
  const messagesBeforeSessionStart = calls.messages.length;
  await ss.handler({ type: "session_start", cwd, reason: "startup" }, ssCtx);
  if (calls.messages.length !== messagesBeforeSessionStart + 1 || !calls.messages.at(-1).content.includes("Module Map")) {
    console.log("SESSION_START_FAIL:" + JSON.stringify(calls.messages));
    process.exit(1);
  }
  for (const requiredScript of ["edc-review.sh", "edc-lib.sh", "edc-assert-fresh.sh", "edc-recover-context.sh"]) {
    if (!fs.existsSync(`${cwd}/.edc/scripts/${requiredScript}`)) {
      console.log("SCRIPT_INSTALL_FAIL:" + requiredScript);
      process.exit(1);
    }
  }
  for (const requiredSkill of ["edc-review", "edc-audit", "edc-build-impl", "edc-update-impl", "edc-module-context-impl"]) {
    if (!fs.existsSync(`${cwd}/.edc/skills/${requiredSkill}/SKILL.md`)) {
      console.log("PRIVATE_SKILL_INSTALL_FAIL:" + requiredSkill);
      process.exit(1);
    }
  }

  // 6. tool_call extends bash timeout for long-running edc orchestrators
  const tc = calls.events.find(e => e.event === "tool_call");
  const fakeCtx = { cwd, sessionManager: { getSessionId: () => sid } };
  const edcBashEvent = {
    type: "tool_call",
    toolCallId: "bash-edc",
    toolName: "bash",
    input: { command: "export EDC_AGENT_CLI=pi\nbash .edc/scripts/edc-review.sh --base main", timeout: 1200 },
  };
  await tc.handler(edcBashEvent, fakeCtx);
  if (edcBashEvent.input.timeout < 7200) {
    console.log("EDC_BASH_TIMEOUT_FAIL:" + JSON.stringify(edcBashEvent.input));
    process.exit(1);
  }
  const absoluteEdcBashEvent = {
    type: "tool_call",
    toolCallId: "bash-edc-absolute",
    toolName: "bash",
    input: { command: `/opt/homebrew/bin/bash ${cwd}/.edc/scripts/edc-review.sh --base main`, timeout: 1200 },
  };
  await tc.handler(absoluteEdcBashEvent, fakeCtx);
  if (absoluteEdcBashEvent.input.timeout < 7200) {
    console.log("EDC_ABSOLUTE_BASH_TIMEOUT_FAIL:" + JSON.stringify(absoluteEdcBashEvent.input));
    process.exit(1);
  }

  // 7. tool_call injects context for a routed file
  const messagesBeforeToolCall = calls.messages.length;
  await tc.handler(
    { type: "tool_call", toolCallId: "x", toolName: "edit", input: { file_path: "src/foo.ts" } },
    fakeCtx
  );
  if (calls.messages.length !== messagesBeforeToolCall + 1 || !calls.messages.at(-1).content.includes("src-mod")) {
    console.log("INJECT_FAIL:" + JSON.stringify(calls.messages));
    process.exit(1);
  }

  // 8. duplicate tool_call for the same module → no second injection
  await tc.handler(
    { type: "tool_call", toolCallId: "y", toolName: "edit", input: { file_path: "src/bar.ts" } },
    fakeCtx
  );
  if (calls.messages.length !== messagesBeforeToolCall + 1) {
    console.log("DEDUP_FAIL:" + JSON.stringify(calls.messages));
    process.exit(1);
  }

  console.log("OK");
' 2>&1)

# clean up the per-session dedup file the test created (lives under os.tmpdir())
DEDUP_FILE=$(node -e "console.log(require('path').join(require('os').tmpdir(),'edc-injected-modules-'+process.argv[1]+'.json'))" "$SESSION_ID")
rm -f "$DEDUP_FILE"

if [ "$wiring" = "OK" ]; then
  say_pass "extension factory wires commands + events + injection"
else
  say_fail "extension factory wiring" "$wiring"
fi

echo
echo "t10-pi-extension: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
