#!/usr/bin/env bash
# t10-pi-extension: smoke-test the pi extension wiring.
#
# Verifies:
#   - root package.json has the pi.extensions entry pointing at pi/index.mjs
#   - pi/index.mjs parses (node --check)
#   - shared lib (plugins/edc/hooks/lib/route.mjs) exports only routing/context helpers
#   - the extension factory runs end-to-end against a fake ExtensionAPI
#     (registers only the interactive /edc command, exposes only human-useful
#     review/audit/delivery skills, subscribes to the expected events, and buildToolCallInjection
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


# --- 3. shared lib exports --------------------------------------------------
exports_check=$(node --input-type=module -e '
  import("./plugins/edc/hooks/lib/route.mjs").then(m => {
    // Public API — see plugins/edc/hooks/lib/route.mjs. Internal helpers
    // (loadManifest, routeFile, dedupPath, etc.) are intentionally unexported.
    const required = [
      "buildSessionStartContent",
      "buildToolCallInjection",
      "getContextFreshness",
      "normalizePath",
      "routeFileSync"
    ];
    const missing = required.filter(n => typeof m[n] !== "function");
    const forbidden = ["resolvePluginRoot", "installOrchestratorScript", "isEdcProject"]
      .filter(n => Object.prototype.hasOwnProperty.call(m, n));
    if (missing.length) { console.log("MISSING:" + missing.join(",")); process.exit(1); }
    if (forbidden.length) { console.log("FORBIDDEN:" + forbidden.join(",")); process.exit(1); }
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

source_preflight=$(node "$ROOT/plugins/edc/hooks/lib/runtime-manifest.mjs" source-preflight "$ROOT/plugins/edc" 2>&1)
if echo "$source_preflight" | grep -q '"reasonCode":"success"'; then
  say_pass "trusted package runtime source passes preflight"
else
  say_fail "trusted package runtime source passes preflight" "$source_preflight"
fi

# Use a copied package as the trusted Pi/plugin source so dispatch can exercise
# real package preflight while the orchestrator bodies remain deterministic.
TRUSTED_PACKAGE="$TMP/trusted-package"
mkdir -p "$TRUSTED_PACKAGE/plugins"
cp -R "$ROOT/pi" "$TRUSTED_PACKAGE/pi"
cp -R "$ROOT/plugins/edc" "$TRUSTED_PACKAGE/plugins/edc"
cat >"$TRUSTED_PACKAGE/plugins/edc/scripts/edc-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f "$PWD/worker-run/tasks.json" ]; then
  SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec node "$SCRIPT_DIR/../hooks/lib/worker-pool.mjs" --runner "$PWD/term-resistant-worker.sh" "$PWD/worker-run/tasks.json"
fi
if [ -n "${EDC_TEST_REVIEW_ARGS_FILE:-}" ]; then
  : > "$EDC_TEST_REVIEW_ARGS_FILE"
  for arg in "$@"; do printf '%s\0' "$arg" >> "$EDC_TEST_REVIEW_ARGS_FILE"; done
fi
if [ -n "${EDC_TEST_STRUCTURED_STATUS_VALUE:-}" ]; then
  node -e 'const fs=require("fs"); const value=process.env.EDC_TEST_STRUCTURED_STATUS_VALUE; fs.writeFileSync(process.env.EDC_RESULT_FILE, JSON.stringify({status:"success", reasonCode:value, message:value, outputs:[value]}));'
fi
sleep 0.2
echo "agent=$EDC_AGENT_CLI model=${EDC_PI_MODEL:-}"
echo "review args: $*"
echo "Consolidated: review-HEAD.md"
echo "Verified: review-HEAD.md"
EOF
cat >"$TRUSTED_PACKAGE/plugins/edc/scripts/edc-review-all.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 1.2
echo "agent=$EDC_AGENT_CLI model=${EDC_PI_MODEL:-}"
echo "review-all args: $*"
echo "Review-all complete"
EOF
cat >"$TRUSTED_PACKAGE/plugins/edc/scripts/edc-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/edc-lib.sh"
echo "build args: $* agent=$EDC_AGENT_CLI"
EOF
cat >"$TRUSTED_PACKAGE/plugins/edc/scripts/edc-update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "update args: $* agent=$EDC_AGENT_CLI"
EOF
cat >"$TRUSTED_PACKAGE/plugins/edc/scripts/edc-audit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "audit args: $* agent=$EDC_AGENT_CLI"
EOF
cat >"$TRUSTED_PACKAGE/plugins/edc/scripts/edc-delivery-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "delivery args: $* agent=$EDC_AGENT_CLI"
EOF
cat >"$TRUSTED_PACKAGE/plugins/edc/scripts/edc-doctor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${EDC_TEST_FOREGROUND_MODE:-}" in
  oversized)
    printf 'output-start%050000doutput-end\n' 0
    exit 0
    ;;
  hang)
    printf '%s\n' "$$" > "${EDC_TEST_FOREGROUND_PID_FILE:?}"
    sleep 30 &
    child=$!
    printf '%s\n' "$child" > "${EDC_TEST_FOREGROUND_CHILD_PID_FILE:?}"
    wait "$child"
    ;;
esac
echo "doctor args: $* agent=$EDC_AGENT_CLI"
EOF
chmod +x "$TRUSTED_PACKAGE/plugins/edc/scripts/edc-"*.sh

# Build a minimal fake ctx environment with a real edc-context/manifest.json so
# buildToolCallInjection has something to chew on.
mkdir -p "$TMP/edc-context/modules"
cat > "$TMP/edc-context/manifest.json" <<'EOF'
{
  "schemaVersion": 2,
  "policy": { "defaultMode": "inject" },
  "modules": [
    { "name": "src-mod", "priority": 50, "match": { "prefixes": ["src/"] }, "doc": "edc-context/modules/src-mod.md" },
    { "name": "api-mod", "priority": 50, "match": { "prefixes": ["api/"] }, "doc": "edc-context/modules/api-mod.md" },
    { "name": "lib-mod", "priority": 50, "match": { "prefixes": ["lib/"] }, "doc": "edc-context/modules/lib-mod.md" }
  ]
}
EOF
echo "# src-mod docs" > "$TMP/edc-context/modules/src-mod.md"
echo "# api-mod docs" > "$TMP/edc-context/modules/api-mod.md"
echo "# lib-mod docs" > "$TMP/edc-context/modules/lib-mod.md"
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
  printf '/*/\n' > .gitignore
  git add tracked.txt .gitignore
  git -c commit.gpgsign=false commit -q -m init
  git branch -M master
  head_commit=$(git rev-parse HEAD)
  tmp_manifest=$(mktemp)
  jq --arg head "$head_commit" '.sourceCommit = $head' edc-context/manifest.json > "$tmp_manifest"
  mv "$tmp_manifest" edc-context/manifest.json
)

# Unique session id per test run so the file-based dedup (rooted in os.tmpdir())
# doesn't poison a re-run.
SESSION_ID="t10-$$-$(date +%s%N 2>/dev/null || date +%s)"

wiring=$(EDC_TEST_CWD="$TMP" EDC_TEST_SID="$SESSION_ID" EDC_TEST_EXTENSION="$TRUSTED_PACKAGE/pi/index.mjs" EDC_TEST_PLUGIN_ROOT="$TRUSTED_PACKAGE/plugins/edc" node --input-type=module -e '
  delete process.env.EDC_PI_SUBPROCESS;
  const cwd = process.env.EDC_TEST_CWD;
  const sid = process.env.EDC_TEST_SID;
  const calls = { commands: [], events: [], messages: [], userMessages: [], notifications: [], confirmations: [], selections: [], statuses: [], widgets: [] };
  const fakePi = {
    on: (event, handler) => { calls.events.push({ event, handler }); },
    registerCommand: (name, opts) => { calls.commands.push({ name, opts }); },
    sendMessage: (m) => { calls.messages.push(m); },
    sendUserMessage: (m) => { calls.userMessages.push(m); },
  };
  const { pathToFileURL } = await import("node:url");
  const factory = (await import(pathToFileURL(process.env.EDC_TEST_EXTENSION).href)).default;
  const { BACKGROUND_JOB_TERMINATION_GRACE_MS } = await import(pathToFileURL(`${process.env.EDC_TEST_PLUGIN_ROOT}/hooks/lib/termination-policy.mjs`).href);
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

  const menuCtx = (selection, extra = {}) => {
    const selections = Array.isArray(selection) ? [...selection] : [selection];
    return {
    cwd,
    hasUI: true,
    model: { provider: "test-provider", id: "test-model" },
    ui: {
      select: async (title, items) => {
        calls.selections.push({ title, items });
        return selections.shift();
      },
      confirm: extra.confirm || (async (title, message) => {
        calls.confirmations.push({ title, message });
        return true;
      }),
      setStatus: (key, value) => { calls.statuses.push({ key, value }); },
      input: extra.input,
      setWidget: (key, value, options) => { calls.widgets.push({ key, value, options }); },
    },
  };
  };

  // Pi execution must ignore stale repo-local runtime state, including a live
  // install lock, without repairing or executing it.
  const tamperedRuntimeDir = `${cwd}/busy-tampered-runtime`;
  const tamperedLibMarker = `${tamperedRuntimeDir}/local-edc-lib-executed`;
  fs.mkdirSync(tamperedRuntimeDir, { recursive: true });
  childProcess.execFileSync("git", ["init", "-q"], { cwd: tamperedRuntimeDir });
  fs.writeFileSync(`${tamperedRuntimeDir}/tracked.txt`, "tracked\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: tamperedRuntimeDir });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], { cwd: tamperedRuntimeDir });
  const tamperedLib = `${tamperedRuntimeDir}/.edc/scripts/edc-lib.sh`;
  fs.mkdirSync(`${tamperedRuntimeDir}/.edc/scripts`, { recursive: true });
  fs.writeFileSync(tamperedLib, `printf executed > ${JSON.stringify(tamperedLibMarker)}\n`);
  fs.mkdirSync(`${tamperedRuntimeDir}/.edc.install.lock`, { recursive: true });
  fs.writeFileSync(`${tamperedRuntimeDir}/.edc.install.lock/owner.json`, JSON.stringify({ pid: process.pid, token: "busy-test", startedAt: new Date().toISOString() }));
  const tamperedLibBefore = fs.readFileSync(tamperedLib, "utf-8");
  const tamperedMessagesBefore = calls.messages.length;
  await edcCmd.opts.handler("", { ...menuCtx("build context"), cwd: tamperedRuntimeDir });
  const tamperedStartMessage = calls.messages.slice(tamperedMessagesBefore).at(-1)?.content || "";
  const tamperedStatusFile = `${tamperedRuntimeDir}/.git/edc/status`;
  // CI observed terminal status projection at ~3.4s after repeated result-field
  // node startups; keep the condition-driven poll but give it a 10s hang guard.
  for (let i = 0; i < 400; i++) {
    const status = fs.existsSync(tamperedStatusFile) ? fs.readFileSync(tamperedStatusFile, "utf-8") : "";
    if (/^status=(?:failed|success|success-with-warning|cancelled)$/m.test(status)) break;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  const tamperedStatus = fs.existsSync(tamperedStatusFile) ? fs.readFileSync(tamperedStatusFile, "utf-8") : "missing";
  if (!tamperedStartMessage.includes("Background EDC build started.")
    || fs.existsSync(tamperedLibMarker)
    || !tamperedStatus.includes("status=success")
    || fs.readFileSync(tamperedLib, "utf-8") !== tamperedLibBefore
    || !fs.existsSync(`${tamperedRuntimeDir}/.edc.install.lock/owner.json`)) {
    console.log("PI_REPO_RUNTIME_IGNORE_FAIL:" + JSON.stringify({ start: tamperedStartMessage, markerExecuted: fs.existsSync(tamperedLibMarker), status: tamperedStatus }));
    process.exit(1);
  }
  fs.rmSync(`${tamperedRuntimeDir}/.edc.install.lock`, { recursive: true, force: true });

  // Foreground doctor uses the same package/global gate and ignores malicious
  // repo-local doctor and library files.
  const foregroundTamperedDir = `${cwd}/foreground-busy-tampered-runtime`;
  const foregroundDoctorMarker = `${foregroundTamperedDir}/local-doctor-executed`;
  const foregroundLibMarker = `${foregroundTamperedDir}/local-edc-lib-executed`;
  fs.mkdirSync(foregroundTamperedDir, { recursive: true });
  childProcess.execFileSync("git", ["init", "-q"], { cwd: foregroundTamperedDir });
  fs.writeFileSync(`${foregroundTamperedDir}/tracked.txt`, "tracked\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: foregroundTamperedDir });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], { cwd: foregroundTamperedDir });
  fs.mkdirSync(`${foregroundTamperedDir}/.edc/scripts`, { recursive: true });
  fs.writeFileSync(`${foregroundTamperedDir}/.edc/scripts/edc-lib.sh`, `printf executed > ${JSON.stringify(foregroundLibMarker)}\n`);
  fs.writeFileSync(`${foregroundTamperedDir}/.edc/scripts/edc-doctor.sh`, `#!/usr/bin/env bash\n. "$(dirname "\${BASH_SOURCE[0]}")/edc-lib.sh"\nprintf executed > ${JSON.stringify(foregroundDoctorMarker)}\n`);
  fs.chmodSync(`${foregroundTamperedDir}/.edc/scripts/edc-doctor.sh`, 0o755);
  fs.mkdirSync(`${foregroundTamperedDir}/.edc.install.lock`, { recursive: true });
  fs.writeFileSync(`${foregroundTamperedDir}/.edc.install.lock/owner.json`, JSON.stringify({ pid: process.pid, token: "foreground-busy-test", startedAt: new Date().toISOString() }));
  const foregroundMessagesBefore = calls.messages.length;
  await edcCmd.opts.handler("", { ...menuCtx("doctor / validate context"), cwd: foregroundTamperedDir });
  const foregroundMessages = calls.messages.slice(foregroundMessagesBefore);
  const foregroundResult = foregroundMessages.at(-1);
  if (foregroundMessages.length !== 2
    || foregroundResult?.customType !== "edc-command-result"
    || !foregroundResult.content.includes("doctor args:  agent=pi")
    || fs.existsSync(foregroundDoctorMarker)
    || fs.existsSync(foregroundLibMarker)) {
    console.log("PI_FOREGROUND_BUSY_TAMPER_GATE_FAIL:" + JSON.stringify({ messages: foregroundMessages, doctorExecuted: fs.existsSync(foregroundDoctorMarker), libExecuted: fs.existsSync(foregroundLibMarker) }));
    process.exit(1);
  }
  fs.rmSync(`${foregroundTamperedDir}/.edc.install.lock`, { recursive: true, force: true });

  // 3. /edc menu primary review starts combined review-all against HEAD --base <detected default branch> with a compact colored command result.
  const messagesBeforeReviewStart = calls.messages.length;
  await edcCmd.opts.handler("", menuCtx(["changes vs default branch", "combined review"]));
  if (calls.userMessages.length !== 0) {
    console.log("DIRECT_COMMAND_USED_MODEL_FAIL:" + JSON.stringify(calls.userMessages));
    process.exit(1);
  }
  const reviewStartMessage = calls.messages.slice(messagesBeforeReviewStart).at(-1);
  if (calls.messages.length !== messagesBeforeReviewStart + 1 || reviewStartMessage?.customType !== "edc-background" || !reviewStartMessage.content.includes("Background EDC review-all started.") || !reviewStartMessage.content.includes("Log: .git/edc/review-all.log")) {
    console.log("MENU_REVIEW_START_MESSAGE_FAIL:" + JSON.stringify(calls.messages.slice(messagesBeforeReviewStart)));
    process.exit(1);
  }
  const runningStatus = [...calls.statuses].reverse().find((entry) => entry.key === "edc-review")?.value || "";
  if (!runningStatus.includes("running")) {
    console.log("REVIEW_UI_RUNNING_STATUS_FAIL:" + JSON.stringify(calls.statuses));
    process.exit(1);
  }
  const runningWidget = [...calls.widgets].reverse().find((entry) => entry.key === "edc-review")?.value;
  if (runningWidget !== undefined) {
    console.log("REVIEW_UI_RUNNING_WIDGET_DUPLICATE_FAIL:" + JSON.stringify(calls.widgets));
    process.exit(1);
  }
  const statusFile = `${cwd}/.git/edc/status`;
  const logFile = `${cwd}/.git/edc/review-all.log`;
  const runId = (fs.readFileSync(statusFile, "utf-8").match(/^run_id=(\S+)$/m) || [])[1];
  if (!runId) {
    console.log("RUN_ID_FAIL:" + fs.readFileSync(statusFile, "utf-8"));
    process.exit(1);
  }
  for (let i = 0; i < 100; i++) {
    if (fs.existsSync(statusFile) && fs.readFileSync(statusFile, "utf-8").includes("status=success")) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  if (!fs.readFileSync(statusFile, "utf-8").includes("status=success")) {
    console.log("REVIEW_COMPLETION_TIMEOUT_FAIL:" + fs.readFileSync(statusFile, "utf-8"));
    process.exit(1);
  }
  if (!fs.existsSync(logFile) || !fs.readFileSync(logFile, "utf-8").includes("Review-all complete")) {
    console.log("REVIEW_LOG_FAIL:" + (fs.existsSync(logFile) ? fs.readFileSync(logFile, "utf-8") : "missing"));
    process.exit(1);
  }
  const reviewArgs = (fs.readFileSync(statusFile, "utf-8").match(/^args=(.+)$/m) || [])[1] || "";
  if (reviewArgs !== "HEAD --base master") {
    console.log("MENU_REVIEW_ARGS_FAIL:" + reviewArgs);
    process.exit(1);
  }

  // 3a2. Detected git refs are untrusted metadata and must not be shell-evaluated.
  const maliciousDir = `${cwd}/malicious-default-ref`;
  const maliciousPwned = `/tmp/edc-pwned-t10-${process.pid}`;
  const maliciousShortRef = `origin/evil$(touch\${IFS}${maliciousPwned})`;
  const maliciousFullRef = `refs/remotes/${maliciousShortRef}`;
  try { fs.unlinkSync(maliciousPwned); } catch {}
  fs.mkdirSync(maliciousDir, { recursive: true });
  childProcess.execFileSync("git", ["init"], { cwd: maliciousDir, stdio: "ignore" });
  fs.writeFileSync(`${maliciousDir}/tracked.txt`, "x\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: maliciousDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: maliciousDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["update-ref", maliciousFullRef, "HEAD"], { cwd: maliciousDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["symbolic-ref", "refs/remotes/origin/HEAD", maliciousFullRef], { cwd: maliciousDir, stdio: "ignore" });
  const maliciousMessagesBefore = calls.messages.length;
  await edcCmd.opts.handler("", { ...menuCtx(["changes vs default branch", "security review"]), cwd: maliciousDir });
  const maliciousStartMessage = calls.messages.slice(maliciousMessagesBefore).at(-1);
  if (calls.messages.length !== maliciousMessagesBefore + 1 || !maliciousStartMessage?.content?.includes("Background EDC review started.")) {
    console.log("MALICIOUS_REF_START_FAIL:" + JSON.stringify(calls.messages.slice(maliciousMessagesBefore)));
    process.exit(1);
  }
  const maliciousStatusFile = `${maliciousDir}/.git/edc/status`;
  for (let i = 0; i < 20; i++) {
    if (fs.existsSync(maliciousStatusFile) && fs.readFileSync(maliciousStatusFile, "utf-8").includes("status=success")) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const maliciousStatus = fs.existsSync(maliciousStatusFile) ? fs.readFileSync(maliciousStatusFile, "utf-8") : "";
  if (!maliciousStatus.includes(`args=HEAD --base ${maliciousShortRef}`)) {
    console.log("MALICIOUS_REF_ARGS_FAIL:" + JSON.stringify(maliciousStatus));
    process.exit(1);
  }
  if (fs.existsSync(maliciousPwned)) {
    console.log("MALICIOUS_REF_EXECUTED_FAIL:" + maliciousPwned);
    process.exit(1);
  }

  // 3a3. Status values sanitize controls without changing literal child argv.
  for (let i = 0; i < 100; i++) {
    if (fs.readFileSync(maliciousStatusFile, "utf-8").includes("status=success")) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  if (!fs.readFileSync(maliciousStatusFile, "utf-8").includes("status=success")) {
    console.log("CONTROL_PREVIOUS_JOB_TIMEOUT_FAIL:" + JSON.stringify(fs.readFileSync(maliciousStatusFile, "utf-8")));
    process.exit(1);
  }
  const controlMarker = `/tmp/edc-control-pwned-t10-${process.pid}`;
  const controlTarget = `HEAD\ninjected_key=owned\tsegment\u0001tail$(touch\${IFS}${controlMarker})`;
  const controlBase = `origin/base\tpart\nsecond_key=owned\u007fend$()`;
  const structuredStatusValue = `structured\ninjected_structured=owned\tvalue\u0002tail`;
  const controlArgsFile = `${maliciousDir}/control-argv.bin`;
  const controlReleaseFile = `${maliciousDir}/control-bash-release`;
  const controlFakeBin = `${maliciousDir}/control-fake-bin`;
  const controlRealBash = childProcess.execFileSync("sh", ["-c", "command -v bash"], { encoding: "utf-8" }).trim();
  try { fs.unlinkSync(controlMarker); } catch {}
  fs.appendFileSync(`${maliciousDir}/.git/info/exclude`, "control-fake-bin/\ncontrol-argv.bin\ncontrol-bash-release\n");
  fs.mkdirSync(controlFakeBin, { recursive: true });
  fs.writeFileSync(`${controlFakeBin}/bash`, `#!/bin/sh\nwhile [ ! -f ${JSON.stringify(controlReleaseFile)} ]; do sleep 0.01; done\nexec ${JSON.stringify(controlRealBash)} "$@"\n`);
  fs.chmodSync(`${controlFakeBin}/bash`, 0o755);
  const controlPreviousPath = process.env.PATH;
  process.env.PATH = `${controlFakeBin}:${controlPreviousPath}`;
  process.env.EDC_TEST_REVIEW_ARGS_FILE = controlArgsFile;
  process.env.EDC_TEST_STRUCTURED_STATUS_VALUE = structuredStatusValue;
  const controlInputs = [controlBase, controlTarget];
  try {
    await edcCmd.opts.handler("", {
      ...menuCtx(["changes vs custom base", "security review"], { input: async () => controlInputs.shift() }),
      cwd: maliciousDir,
    });
  } finally {
    process.env.PATH = controlPreviousPath;
  }
  const sanitizeStatusValue = (value) => value.replace(/[\x00-\x1f\x7f]+/g, " ");
  const assertStatusValues = (status, phase) => {
    const lines = status.split("\n").filter(Boolean);
    const parsed = Object.fromEntries(lines.map((line) => {
      const separator = line.indexOf("=");
      if (separator <= 0) throw new Error(`invalid status line during ${phase}: ${JSON.stringify(line)}`);
      return [line.slice(0, separator), line.slice(separator + 1)];
    }));
    if (/[\x00-\x09\x0b-\x1f\x7f]/.test(status.replace(/\n/g, "")) || parsed.injected_key || parsed.second_key || parsed.injected_structured) {
      console.log("CONTROL_STATUS_PROTOCOL_FAIL:" + JSON.stringify({ phase, status }));
      process.exit(1);
    }
    return parsed;
  };
  const initialControlStatus = fs.readFileSync(maliciousStatusFile, "utf-8");
  const initialControlFields = assertStatusValues(initialControlStatus, "initial");
  const expectedControlArgs = `${sanitizeStatusValue(controlTarget)} --base ${sanitizeStatusValue(controlBase)}`;
  if (initialControlFields.args !== expectedControlArgs || !initialControlFields.args.includes(`$(touch\${IFS}${controlMarker})`) || !initialControlFields.args.includes("$()")) {
    console.log("CONTROL_INITIAL_STATUS_FAIL:" + JSON.stringify({ fields: initialControlFields, messages: calls.messages.slice(-3), selections: calls.selections.slice(-5), remainingInputs: controlInputs }));
    process.exit(1);
  }
  fs.writeFileSync(controlReleaseFile, "go");
  for (let i = 0; i < 100; i++) {
    if (fs.readFileSync(maliciousStatusFile, "utf-8").includes("status=success")) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  delete process.env.EDC_TEST_REVIEW_ARGS_FILE;
  delete process.env.EDC_TEST_STRUCTURED_STATUS_VALUE;
  const finalControlStatus = fs.readFileSync(maliciousStatusFile, "utf-8");
  const finalControlFields = assertStatusValues(finalControlStatus, "final");
  const expectedStructuredStatusValue = sanitizeStatusValue(structuredStatusValue);
  const expectedControlArgv = Buffer.concat([
    Buffer.from(controlTarget), Buffer.from([0]),
    Buffer.from("--base"), Buffer.from([0]),
    Buffer.from(controlBase), Buffer.from([0]),
  ]);
  if (finalControlFields.status !== "success" || finalControlFields.args !== expectedControlArgs || finalControlFields.reason_code !== expectedStructuredStatusValue || finalControlFields.failure_reason !== expectedStructuredStatusValue || finalControlFields.outputs !== expectedStructuredStatusValue || !fs.readFileSync(controlArgsFile).equals(expectedControlArgv) || fs.existsSync(controlMarker)) {
    console.log("CONTROL_FINAL_STATUS_FAIL:" + JSON.stringify({ fields: finalControlFields, argv: fs.readFileSync(controlArgsFile).toString("hex"), expectedArgv: expectedControlArgv.toString("hex"), marker: fs.existsSync(controlMarker) }));
    process.exit(1);
  }

  // 3b. /edc menu can show status for latest run without pinning completed status in the UI.
  const statusesBeforeStatusCommand = calls.statuses.length;
  const widgetsBeforeStatusCommand = calls.widgets.length;
  await edcCmd.opts.handler("", menuCtx("job status"));
  const statusMessage = calls.messages.at(-1)?.content || "";
  if (!statusMessage.includes("status: success") || !statusMessage.includes("log: .git/edc/review-all.log")) {
    console.log("STATUS_CMD_FAIL:" + JSON.stringify(statusMessage));
    process.exit(1);
  }
  const pinnedCompletedStatus = calls.statuses.slice(statusesBeforeStatusCommand)
    .find((entry) => entry.key === "edc-review" && String(entry.value || "").includes("complete"));
  if (pinnedCompletedStatus) {
    console.log("REVIEW_UI_COMPLETED_PINNED_FAIL:" + JSON.stringify(calls.statuses.slice(statusesBeforeStatusCommand)));
    process.exit(1);
  }
  const pinnedCompletedWidget = calls.widgets.slice(widgetsBeforeStatusCommand)
    .find((entry) => entry.key === "edc-review" && Array.isArray(entry.value) && entry.value.some((line) => String(line).includes("edc review success")));
  if (pinnedCompletedWidget) {
    console.log("REVIEW_UI_COMPLETED_WIDGET_FAIL:" + JSON.stringify(calls.widgets.slice(widgetsBeforeStatusCommand)));
    process.exit(1);
  }

  // 3c. single-active-run guard refuses duplicate background reviews.
  // The trusted bootstrap adds one supervised process layer; wait for the
  // completed shell to exit before replacing its status with this live fixture.
  await new Promise(resolve => setTimeout(resolve, 100));
  fs.writeFileSync(statusFile, fs.readFileSync(statusFile, "utf-8")
    .replace("status=success", "status=running")
    .replace(/^pid=.*$/m, `pid=${process.pid}`));
  await edcCmd.opts.handler("", menuCtx(["changes vs default branch", "security review"]));
  const alreadyRunningMessage = calls.messages.at(-1)?.content || "";
  if (!alreadyRunningMessage.includes("already running") || !alreadyRunningMessage.includes("Check progress: `/edc` → Job status.")) {
    console.log("ALREADY_RUNNING_FAIL:" + JSON.stringify(alreadyRunningMessage));
    process.exit(1);
  }
  fs.writeFileSync(statusFile, fs.readFileSync(statusFile, "utf-8").replace("status=running", "status=success"));

  // 3d. immediate duplicate starts are rejected before the child writes status.
  const raceDir = `${cwd}/race-review`;
  fs.mkdirSync(raceDir, { recursive: true });
  childProcess.execFileSync("git", ["init"], { cwd: raceDir, stdio: "ignore" });
  fs.writeFileSync(`${raceDir}/tracked.txt`, "x\n");
  fs.writeFileSync(`${raceDir}/.gitignore`, "fake-bin/\nworker-run/\nterm-resistant-worker.sh\n");
  childProcess.execFileSync("git", ["add", "tracked.txt", ".gitignore"], { cwd: raceDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: raceDir, stdio: "ignore" });
  const workerRunDir = `${raceDir}/worker-run`;
  const workerRunner = `${raceDir}/term-resistant-worker.sh`;
  const workerManifest = `${workerRunDir}/tasks.json`;
  const workerPgidFile = `${raceDir}/.git/edc/worker-pgid`;
  const workerPoolPidFile = `${raceDir}/.git/edc/worker-pool-pid`;
  const workerTermFile = `${raceDir}/.git/edc/worker-term`;
  fs.mkdirSync(`${workerRunDir}/prompts`, { recursive: true });
  fs.mkdirSync(`${workerRunDir}/staged`, { recursive: true });
  fs.writeFileSync(`${workerRunDir}/prompts/worker.md`, "nested worker\n");
  fs.writeFileSync(workerManifest, JSON.stringify({
    schemaVersion: 1,
    runId: "t10-nested-kill",
    runDir: workerRunDir,
    maxConcurrency: 1,
    tasks: [{
      id: "nested-worker",
      phase: "test/nested-worker",
      promptFile: `${workerRunDir}/prompts/worker.md`,
      timeoutSeconds: 30,
      outputs: [`${workerRunDir}/staged/worker.txt`],
    }],
  }));
  fs.writeFileSync(workerRunner, `#!/usr/bin/env bash\nset -uo pipefail\non_term() { printf term > .git/edc/worker-term; }\ntrap on_term TERM\nprintf "%s\\n" "$$" > .git/edc/worker-pgid\nprintf "%s\\n" "$PPID" > .git/edc/worker-pool-pid\nprintf ready > .git/edc/race-ready\nwhile :; do\n  sleep 30 &\n  wait "$!" || true\ndone\n`);
  fs.chmodSync(workerRunner, 0o755);
  const { WORKER_PROCESS_GROUP_TERMINATION_GRACE_MS } = await import("./plugins/edc/hooks/lib/termination-policy.mjs");
  const realBash = childProcess.execFileSync("/usr/bin/env", ["bash", "-lc", "command -v bash"], { encoding: "utf-8" }).trim();
  if (!realBash) {
    console.log("RACE_TEST_BASH_MISSING");
    process.exit(1);
  }
  fs.mkdirSync(`${raceDir}/fake-bin`, { recursive: true });
  fs.writeFileSync(`${raceDir}/fake-bin/bash`, `#!/bin/sh\nwhile [ ! -f .git/edc/fake-bash-release ]; do sleep 0.01; done\nexec ${realBash} "$@"\n`);
  fs.chmodSync(`${raceDir}/fake-bin/bash`, 0o755);

  const raceStatusFile = `${raceDir}/.git/edc/status`;
  const raceBashReleaseFile = `${raceDir}/.git/edc/fake-bash-release`;
  let racePidsForCleanup = [];
  let workerPgidForCleanup = 0;
  const readPositivePid = (path) => {
    if (!fs.existsSync(path)) return 0;
    const pid = Number(fs.readFileSync(path, "utf-8").trim());
    return Number.isInteger(pid) && pid > 0 ? pid : 0;
  };
  const cleanupRaceProcessGroups = () => {
    const poolPid = readPositivePid(workerPoolPidFile);
    if (poolPid) {
      try { process.kill(poolPid, "SIGCONT"); } catch {}
    }
    const status = fs.existsSync(raceStatusFile) ? fs.readFileSync(raceStatusFile, "utf-8") : "";
    const statusPid = Number((status.match(/^pid=(\d+)$/m) || [])[1]) || 0;
    const workerPgid = workerPgidForCleanup || readPositivePid(workerPgidFile);
    for (const pgid of new Set([...racePidsForCleanup, statusPid, workerPgid].filter(Boolean))) {
      try { process.kill(-pgid, "SIGKILL"); } catch {}
    }
  };
  process.once("exit", cleanupRaceProcessGroups);

  const previousPath = process.env.PATH;
  process.env.PATH = `${raceDir}/fake-bin:${previousPath || ""}`;
  const raceStartIndex = calls.messages.length;
  await Promise.all([
    edcCmd.opts.handler("", { ...menuCtx(["changes vs default branch", "security review"]), cwd: raceDir }),
    edcCmd.opts.handler("", { ...menuCtx(["changes vs default branch", "security review"]), cwd: raceDir }),
  ]);
  process.env.PATH = previousPath;
  const raceMessages = calls.messages.slice(raceStartIndex).map((message) => message.content || "");
  racePidsForCleanup = raceMessages
    .filter((message) => message.includes("Background EDC review started."))
    .map((message) => Number((message.match(/^PID: (\d+)$/m) || [])[1]) || 0)
    .filter(Boolean);
  const raceStartedCount = racePidsForCleanup.length;
  const raceBlockedCount = raceMessages.filter((message) => message.includes("already running")).length;
  if (raceStartedCount !== 1 || raceBlockedCount !== 1) {
    console.log("IMMEDIATE_DUPLICATE_REVIEW_FAIL:" + JSON.stringify(raceMessages));
    process.exit(1);
  }
  const preReleaseRaceStatus = fs.existsSync(raceStatusFile) ? fs.readFileSync(raceStatusFile, "utf-8") : "missing";
  if (!preReleaseRaceStatus.includes("status=running") || !preReleaseRaceStatus.includes("pid=starting")) {
    console.log("RACE_DUPLICATE_PRE_CHILD_STATUS_FAIL:" + JSON.stringify({ status: preReleaseRaceStatus, messages: raceMessages }));
    process.exit(1);
  }
  fs.writeFileSync(raceBashReleaseFile, "go");

  const raceReadyFile = `${raceDir}/.git/edc/race-ready`;
  for (let i = 0; i < 100; i++) {
    const raceStatus = fs.existsSync(raceStatusFile) ? fs.readFileSync(raceStatusFile, "utf-8") : "";
    if (raceStatus.includes("status=running") && /^pid=\d+$/m.test(raceStatus) && fs.existsSync(raceReadyFile) && readPositivePid(workerPgidFile) && readPositivePid(workerPoolPidFile)) break;
    if (/^status=(?:success|failed|cancelled)$/m.test(raceStatus)) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const synchronizedRaceStatus = fs.existsSync(raceStatusFile) ? fs.readFileSync(raceStatusFile, "utf-8") : "missing";
  workerPgidForCleanup = readPositivePid(workerPgidFile);
  const workerPoolPid = readPositivePid(workerPoolPidFile);
  if (!synchronizedRaceStatus.includes("status=running") || !/^pid=\d+$/m.test(synchronizedRaceStatus) || !fs.existsSync(raceReadyFile) || !workerPgidForCleanup || !workerPoolPid) {
    const raceLogFile = `${raceDir}/.git/edc/review.log`;
    const raceLog = fs.existsSync(raceLogFile) ? fs.readFileSync(raceLogFile, "utf-8") : "missing";
    console.log("RACE_REVIEW_READY_FAIL:" + JSON.stringify({ status: synchronizedRaceStatus, log: raceLog, workerPgid: workerPgidForCleanup, workerPoolPid }));
    process.exit(1);
  }
  racePidsForCleanup = [Number((synchronizedRaceStatus.match(/^pid=(\d+)$/m) || [])[1]) || 0];
  const killRequest = edcCmd.opts.handler("kill", { cwd: raceDir, hasUI: false });
  for (let i = 0; i < 100 && !fs.existsSync(workerTermFile); i++) {
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  if (!fs.existsSync(workerTermFile)) {
    console.log("KILL_REVIEW_WORKER_TERM_FAIL:" + workerPgidForCleanup);
    process.exit(1);
  }
  // Expose equal parent/child deadlines deterministically: pause the pool after
  // it arms child escalation, then resume just beyond one child grace window.
  process.kill(workerPoolPid, "SIGSTOP");
  const resumeWorkerPool = setTimeout(() => {
    try { process.kill(workerPoolPid, "SIGCONT"); } catch {}
  }, WORKER_PROCESS_GROUP_TERMINATION_GRACE_MS + 100);
  await new Promise(resolve => setTimeout(resolve, 100));
  const terminatingStatus = fs.readFileSync(raceStatusFile, "utf-8");
  if (!terminatingStatus.includes("status=running")) {
    console.log("KILL_REVIEW_PREMATURE_STATUS_FAIL:" + JSON.stringify(terminatingStatus));
    process.exit(1);
  }
  await killRequest;
  clearTimeout(resumeWorkerPool);
  const killMessage = calls.messages.at(-1)?.content || "";
  if (!killMessage.includes("Background EDC review killed.") || !killMessage.includes("Run ID:")) {
    console.log("KILL_REVIEW_MESSAGE_FAIL:" + JSON.stringify(killMessage));
    process.exit(1);
  }
  const killedStatus = fs.readFileSync(raceStatusFile, "utf-8");
  if (!killedStatus.includes("status=cancelled") || !killedStatus.includes("exit_code=130") || !killedStatus.includes("failure_reason=cancelled by user")) {
    console.log("KILL_REVIEW_STATUS_FAIL:" + JSON.stringify(killedStatus));
    process.exit(1);
  }
  const killedPid = Number((killedStatus.match(/^pid=(\d+)$/m) || [])[1]);
  const processGroupAlive = (pgid) => {
    try {
      process.kill(-pgid, 0);
      return true;
    } catch (error) {
      if (error?.code === "ESRCH") return false;
      throw error;
    }
  };
  const killedGroupAlive = processGroupAlive(killedPid);
  const killedWorkerGroupAlive = processGroupAlive(workerPgidForCleanup);
  if (killedGroupAlive || killedWorkerGroupAlive) {
    console.log("KILL_REVIEW_GROUP_SURVIVED_FAIL:" + JSON.stringify({ topPgid: killedPid, topAlive: killedGroupAlive, workerPgid: workerPgidForCleanup, workerAlive: killedWorkerGroupAlive }));
    process.exit(1);
  }
  racePidsForCleanup = [];
  workerPgidForCleanup = 0;
  process.removeListener("exit", cleanupRaceProcessGroups);
  await edcCmd.opts.handler("", { ...menuCtx("job status"), cwd: raceDir });
  const killedStatusMessage = calls.messages.at(-1)?.content || "";
  if (!killedStatusMessage.includes("status: cancelled") || !killedStatusMessage.includes("EDC review cancelled.")) {
    console.log("KILL_REVIEW_STATUS_MESSAGE_FAIL:" + JSON.stringify(killedStatusMessage));
    process.exit(1);
  }

  // 3e1. failed force-kill keeps the truthful running status and footer active.
  const killFailureDir = `${cwd}/kill-failure-review`;
  const killFailurePid = 42424242;
  fs.mkdirSync(killFailureDir, { recursive: true });
  childProcess.execFileSync("git", ["init"], { cwd: killFailureDir, stdio: "ignore" });
  fs.mkdirSync(`${killFailureDir}/.git/edc`, { recursive: true });
  fs.mkdirSync(`${killFailureDir}/.edc.install.lock`, { recursive: true });
  fs.writeFileSync(`${killFailureDir}/.git/edc/status`, `kind=review\nstatus=running\nstarted_at=2026-01-01T00:00:00Z\nrun_id=force-kill-failure\npid=${killFailurePid}\nlog=.git/edc/review.log\n`);
  const killFailureCtx = {
    cwd: killFailureDir,
    hasUI: true,
    ui: {
      setStatus: (key, value) => { calls.statuses.push({ key, value }); },
      setWidget: (key, value, options) => { calls.widgets.push({ key, value, options }); },
    },
  };
  const killFailureStatusesBefore = calls.statuses.length;
  const realProcessKill = process.kill;
  process.kill = (pid, signal) => {
    if (Math.abs(pid) !== killFailurePid) return realProcessKill(pid, signal);
    if (signal === "SIGKILL" || (pid < 0 && signal === 0)) {
      const error = new Error("operation not permitted");
      error.code = "EPERM";
      throw error;
    }
    return true;
  };
  try {
    await edcCmd.opts.handler("kill", killFailureCtx);
  } finally {
    process.kill = realProcessKill;
  }
  const killFailureMessage = calls.messages.at(-1)?.content || "";
  const killFailureStatus = fs.readFileSync(`${killFailureDir}/.git/edc/status`, "utf-8");
  const killFailureFooter = calls.statuses.slice(killFailureStatusesBefore).at(-1)?.value || "";
  if (!killFailureMessage.includes("Failed to force-kill background EDC review force-kill-failure") || !killFailureStatus.includes("status=running") || !killFailureFooter.includes("running")) {
    console.log("KILL_FAILURE_UI_STATUS_FAIL:" + JSON.stringify({ message: killFailureMessage, status: killFailureStatus, footer: killFailureFooter }));
    process.exit(1);
  }
  fs.writeFileSync(`${killFailureDir}/.git/edc/status`, killFailureStatus.replace("status=running", "status=failed"));
  const terminalKillStatusesBefore = calls.statuses.length;
  await edcCmd.opts.handler("kill", killFailureCtx);
  const terminalKillMessage = calls.messages.at(-1)?.content || "";
  const terminalKillFooter = calls.statuses.slice(terminalKillStatusesBefore).at(-1);
  if (!terminalKillMessage.includes("Current review status: failed") || !terminalKillFooter || terminalKillFooter.value !== undefined) {
    console.log("TERMINAL_KILL_UI_CLEAR_FAIL:" + JSON.stringify({ message: terminalKillMessage, footer: terminalKillFooter }));
    process.exit(1);
  }

  // 3e2. dead running PID is marked failed and does not wedge future starts.
  const stalePidDir = `${cwd}/stale-pid-review`;
  fs.mkdirSync(stalePidDir, { recursive: true });
  childProcess.execFileSync("git", ["init"], { cwd: stalePidDir, stdio: "ignore" });
  fs.writeFileSync(`${stalePidDir}/tracked.txt`, "x\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: stalePidDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: stalePidDir, stdio: "ignore" });
  fs.mkdirSync(`${stalePidDir}/.git/edc`, { recursive: true });
  fs.writeFileSync(`${stalePidDir}/.git/edc/status`, "status=running\nrun_id=dead\npid=999999\nstarted_at=2000-01-01T00:00:00Z\n");
  const stalePidMessagesBefore = calls.messages.length;
  await edcCmd.opts.handler("", { ...menuCtx(["changes vs default branch", "security review"]), cwd: stalePidDir });
  const stalePidStartMessage = calls.messages.slice(stalePidMessagesBefore).at(-1);
  if (calls.messages.length !== stalePidMessagesBefore + 1 || !stalePidStartMessage?.content?.includes("Background EDC review started.")) {
    console.log("STALE_PID_RECOVERY_START_MESSAGE_FAIL:" + JSON.stringify(calls.messages.slice(stalePidMessagesBefore)));
    process.exit(1);
  }
  const stalePidStatus = fs.readFileSync(`${stalePidDir}/.git/edc/status`, "utf-8");
  if (!stalePidStatus.includes("run_id=") || stalePidStatus.includes("run_id=dead")) {
    console.log("STALE_PID_RECOVERY_FAIL:" + JSON.stringify(stalePidStatus));
    process.exit(1);
  }

  // 3f. build/update/audit run as background jobs using the shared status slot.
  fs.writeFileSync(statusFile, fs.readFileSync(statusFile, "utf-8").replace("status=running", "status=success"));
  const backgroundCases = [
    { selection: ["changes vs default branch", "security review"], kind: "review", log: ".git/edc/review.log", expect: "review args: HEAD --base master" },
    { selection: "build context", kind: "build", log: ".git/edc/build.log", expect: "build args:  agent=pi" },
    { selection: "force rebuild context", kind: "build", log: ".git/edc/build.log", expect: "build args: --force agent=pi" },
    { selection: "update context", kind: "update", log: ".git/edc/update.log", expect: "update args:  agent=pi" },
    { selection: ["changes vs default branch", "quality review"], kind: "audit", log: ".git/edc/audit.log", expect: "audit args: HEAD --base master agent=pi" },
    { selection: ["changes vs default branch", "delivery review"], kind: "delivery-review", log: ".git/edc/delivery-review.log", expect: "delivery args: HEAD --base master agent=pi" },
  ];
  const runBackgroundCase = async (testCase) => {
    const beforeMessages = calls.messages.length;
    await edcCmd.opts.handler("", menuCtx(testCase.selection));
    const jobStartMessage = calls.messages.slice(beforeMessages).at(-1);
    if (calls.messages.length !== beforeMessages + 1 || jobStartMessage?.customType !== "edc-background" || !jobStartMessage.content.includes(`Background EDC ${testCase.kind} started.`) || !jobStartMessage.content.includes(`Log: ${testCase.log}`)) {
      console.log("BACKGROUND_JOB_START_MESSAGE_FAIL:" + JSON.stringify({ kind: testCase.kind, messages: calls.messages.slice(beforeMessages) }));
      process.exit(1);
    }
    const jobStatus = fs.readFileSync(statusFile, "utf-8");
    if (!jobStatus.includes(`kind=${testCase.kind}`) || !jobStatus.includes("status=running") || !jobStatus.includes(`log=${testCase.log}`)) {
      console.log("BACKGROUND_JOB_STATUS_FAIL:" + JSON.stringify({ kind: testCase.kind, status: jobStatus }));
      process.exit(1);
    }
    const statusLine = [...calls.statuses].reverse().find((entry) => entry.key === "edc-review")?.value || "";
    if (!statusLine.includes(`edc ${testCase.kind}: running`)) {
      console.log("BACKGROUND_JOB_UI_STATUS_FAIL:" + JSON.stringify({ kind: testCase.kind, statuses: calls.statuses }));
      process.exit(1);
    }
    for (let i = 0; i < 100; i++) {
      if (fs.readFileSync(statusFile, "utf-8").includes("status=success")) break;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (!fs.readFileSync(statusFile, "utf-8").includes("status=success")) {
      console.log("BACKGROUND_JOB_COMPLETION_TIMEOUT_FAIL:" + JSON.stringify({ kind: testCase.kind, status: fs.readFileSync(statusFile, "utf-8") }));
      process.exit(1);
    }
    if (!fs.existsSync(`${cwd}/${testCase.log}`) || !fs.readFileSync(`${cwd}/${testCase.log}`, "utf-8").includes(testCase.expect)) {
      console.log("BACKGROUND_JOB_LOG_FAIL:" + JSON.stringify({ kind: testCase.kind, log: fs.existsSync(`${cwd}/${testCase.log}`) ? fs.readFileSync(`${cwd}/${testCase.log}`, "utf-8") : "missing" }));
      process.exit(1);
    }
  };

  for (const testCase of backgroundCases) {
    await runBackgroundCase(testCase);
  }

  const fullScopeCases = [
    { selection: ["full repo review", "combined review"], kind: "review-all", log: ".git/edc/review-all.log", expect: "review-all args: --full" },
    { selection: ["full repo review", "security review"], kind: "review", log: ".git/edc/review.log", expect: "review args: --full" },
    { selection: ["full repo review", "delivery review"], kind: "delivery-review", log: ".git/edc/delivery-review.log", expect: "delivery args: --full" },
    { selection: ["full repo review", "quality review"], kind: "audit", log: ".git/edc/audit.log", expect: "audit args:  agent=pi" },
  ];
  for (const testCase of fullScopeCases) {
    await runBackgroundCase(testCase);
  }
  await edcCmd.opts.handler("", menuCtx("doctor / validate context"));
  if (!calls.messages.at(-1)?.content?.includes("doctor args:  agent=pi")) {
    console.log("DOCTOR_DIRECT_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }

  process.env.EDC_TEST_FOREGROUND_MODE = "oversized";
  await edcCmd.opts.handler("", menuCtx("doctor / validate context"));
  delete process.env.EDC_TEST_FOREGROUND_MODE;
  const oversizedForeground = calls.messages.at(-1)?.content || "";
  if (oversizedForeground.length > 14000 || !oversizedForeground.includes("output-start") || !oversizedForeground.includes("output-end")) {
    console.log("FOREGROUND_OUTPUT_BOUND_FAIL:" + JSON.stringify({ length: oversizedForeground.length, start: oversizedForeground.includes("output-start"), end: oversizedForeground.includes("output-end") }));
    process.exit(1);
  }

  const foregroundHangPidFile = `${cwd}/foreground-hang.pid`;
  const foregroundHangChildPidFile = `${cwd}/foreground-hang-child.pid`;
  const foregroundTimeoutMs = 1000;
  process.env.EDC_TEST_FOREGROUND_MODE = "hang";
  process.env.EDC_TEST_FOREGROUND_PID_FILE = foregroundHangPidFile;
  process.env.EDC_TEST_FOREGROUND_CHILD_PID_FILE = foregroundHangChildPidFile;
  process.env.EDC_FOREGROUND_COMMAND_TIMEOUT_MS = String(foregroundTimeoutMs);
  const foregroundHangStarted = Date.now();
  await edcCmd.opts.handler("", menuCtx("doctor / validate context"));
  const foregroundHangDuration = Date.now() - foregroundHangStarted;
  delete process.env.EDC_TEST_FOREGROUND_MODE;
  delete process.env.EDC_TEST_FOREGROUND_PID_FILE;
  delete process.env.EDC_TEST_FOREGROUND_CHILD_PID_FILE;
  delete process.env.EDC_FOREGROUND_COMMAND_TIMEOUT_MS;
  const foregroundHangResult = calls.messages.at(-1)?.content || "";
  const foregroundHangPids = [foregroundHangPidFile, foregroundHangChildPidFile]
    .map((path) => Number(fs.readFileSync(path, "utf-8").trim()));
  const foregroundHangAlive = foregroundHangPids.filter((pid) => {
    try { process.kill(pid, 0); return true; } catch (error) { if (error?.code === "ESRCH") return false; throw error; }
  });
  const foregroundTimeoutBoundMs = foregroundTimeoutMs + BACKGROUND_JOB_TERMINATION_GRACE_MS;
  if (foregroundHangDuration > foregroundTimeoutBoundMs || foregroundHangAlive.length > 0 || !foregroundHangResult.includes("edc doctor failed with exit code 124") || !foregroundHangResult.includes("foreground EDC command timed out")) {
    console.log("FOREGROUND_TIMEOUT_FAIL:" + JSON.stringify({ duration: foregroundHangDuration, bound: foregroundTimeoutBoundMs, alive: foregroundHangAlive, result: foregroundHangResult }));
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
  if (!nonInteractiveMessage.includes("/edc is interactive-only") || !nonInteractiveMessage.includes("edc review diff --agent pi") || !nonInteractiveMessage.includes("edc security full --agent pi") || !nonInteractiveMessage.includes("edc quality full --agent pi")) {
    console.log("NON_INTERACTIVE_FAIL:" + JSON.stringify(nonInteractiveMessage));
    process.exit(1);
  }

  // 3i. missing context prompts before auto-build and emits a compact start message.
  const missingDir = `${cwd}/missing-context`;
  fs.mkdirSync(missingDir, { recursive: true });
  childProcess.execFileSync("git", ["init"], { cwd: missingDir, stdio: "ignore" });
  fs.writeFileSync(`${missingDir}/tracked.txt`, "x\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: missingDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: missingDir, stdio: "ignore" });
  const missingSelections = ["changes vs default branch", "combined review"];
  const missingCtx = {
    cwd: missingDir,
    hasUI: true,
    ui: {
      select: async (title, items) => {
        calls.selections.push({ title, items });
        return missingSelections.shift();
      },
      confirm: async (title, message) => {
        calls.confirmations.push({ title, message });
        return true;
      },
    },
  };
  const missingMessagesBefore = calls.messages.length;
  await edcCmd.opts.handler("", missingCtx);
  if (!calls.confirmations.at(-1)?.message?.includes("EDC context: missing/incomplete") || !calls.confirmations.at(-1)?.message?.includes("reason: manifest")) {
    console.log("MISSING_PROMPT_FAIL:" + JSON.stringify(calls.confirmations.at(-1)));
    process.exit(1);
  }
  const missingStartMessage = calls.messages.slice(missingMessagesBefore).at(-1);
  if (calls.messages.length !== missingMessagesBefore + 1 || !missingStartMessage?.content?.includes("Background EDC review-all started.")) {
    console.log("MISSING_BACKGROUND_CONTEXT_START_MESSAGE_FAIL:" + JSON.stringify(calls.messages.slice(missingMessagesBefore)));
    process.exit(1);
  }

  // 3j. declining stale/missing context stops and teaches explicit CLI no-context modes.
  const staleDir = `${cwd}/stale-context`;
  fs.mkdirSync(`${staleDir}/edc-context`, { recursive: true });
  fs.writeFileSync(`${staleDir}/file.txt`, "x\n");
  childProcess.execFileSync("git", ["init"], { cwd: staleDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["add", "file.txt"], { cwd: staleDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["-c", "user.email=a@example.com", "-c", "user.name=a", "-c", "commit.gpgsign=false", "commit", "-m", "init"], { cwd: staleDir, stdio: "ignore" });
  childProcess.execFileSync("git", ["branch", "-M", "master"], { cwd: staleDir, stdio: "ignore" });
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
  const staleSelections = ["changes vs default branch", "combined review"];
  await edcCmd.opts.handler("", {
    cwd: staleDir,
    hasUI: true,
    ui: {
      select: async (title, items) => {
        calls.selections.push({ title, items });
        return staleSelections.shift();
      },
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
  if (!declineMessage.includes("edc review diff master --agent pi") || !declineMessage.includes("edc security diff master --agent pi --ignore-context")) {
    console.log("DECLINE_GUIDANCE_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }

  const qualityFullSelections = ["full repo review", "quality review"];
  await edcCmd.opts.handler("", {
    cwd: staleDir,
    hasUI: true,
    ui: {
      select: async () => qualityFullSelections.shift(),
      confirm: async () => false,
    },
  });
  const qualityDeclineMessage = calls.messages.at(-1)?.content || "";
  if (!qualityDeclineMessage.includes("edc quality full --agent pi")) {
    console.log("QUALITY_FULL_DECLINE_GUIDANCE_FAIL:" + JSON.stringify(calls.messages.at(-1)));
    process.exit(1);
  }

  // 4. resources_discover returns only human-facing review/audit/delivery skills
  const rd = calls.events.find(e => e.event === "resources_discover");
  const r = await rd.handler({ type: "resources_discover", cwd, reason: "startup" }, { cwd });
  if (!r || !Array.isArray(r.skillPaths) || r.skillPaths.length !== 3) {
    console.log("RD_FAIL:" + JSON.stringify(r));
    process.exit(1);
  }
  const skillNames = r.skillPaths.map(p => p.split("/").pop()).sort();
  const expectedSkills = ["edc-audit", "edc-delivery-review", "edc-review"];
  if (JSON.stringify(skillNames) !== JSON.stringify(expectedSkills)) {
    console.log("SKILLS_FAIL:" + skillNames.join(","));
    process.exit(1);
  }

  // 4a. installed EDC pi skills are globally discoverable, even in plain repos.
  const plainSkillRepo = `${cwd}/plain-skill-repo`;
  fs.mkdirSync(plainSkillRepo, { recursive: true });
  childProcess.execFileSync("git", ["init", "-q"], { cwd: plainSkillRepo });
  const plainResources = await rd.handler({ type: "resources_discover", cwd: plainSkillRepo, reason: "startup" }, { cwd: plainSkillRepo });
  const plainSkillNames = (plainResources.skillPaths || []).map(p => p.split("/").pop()).sort();
  if (JSON.stringify(plainSkillNames) !== JSON.stringify(expectedSkills)) {
    console.log("PLAIN_GLOBAL_SKILLS_FAIL:" + plainSkillNames.join(","));
    process.exit(1);
  }

  // 5. session_start injects edc-context/index.md when mode=inject
  const ss = calls.events.find(e => e.event === "session_start");
  const sessionStatusesBefore = calls.statuses.length;
  const sessionWidgetsBefore = calls.widgets.length;
  const ssCtx = {
    cwd,
    hasUI: true,
    sessionManager: { getSessionId: () => sid },
    ui: {
      setStatus: (key, value) => { calls.statuses.push({ key, value }); },
      setWidget: (key, value, options) => { calls.widgets.push({ key, value, options }); },
    },
  };
  const messagesBeforeSessionStart = calls.messages.length;
  await ss.handler({ type: "session_start", cwd, reason: "startup" }, ssCtx);
  if (calls.messages.length !== messagesBeforeSessionStart + 1 || !calls.messages.at(-1).content.includes("Module Map")) {
    console.log("SESSION_START_FAIL:" + JSON.stringify(calls.messages));
    process.exit(1);
  }
  const sessionPinnedStatus = calls.statuses.slice(sessionStatusesBefore)
    .find((entry) => entry.key === "edc-review" && entry.value);
  if (sessionPinnedStatus) {
    console.log("SESSION_START_COMPLETED_STATUS_FAIL:" + JSON.stringify(calls.statuses.slice(sessionStatusesBefore)));
    process.exit(1);
  }
  const sessionPinnedWidget = calls.widgets.slice(sessionWidgetsBefore)
    .find((entry) => entry.key === "edc-review" && entry.value);
  if (sessionPinnedWidget) {
    console.log("SESSION_START_COMPLETED_WIDGET_FAIL:" + JSON.stringify(calls.widgets.slice(sessionWidgetsBefore)));
    process.exit(1);
  }

  // 5a. session_start in a plain git repo is quiet and does not contaminate the repo with .edc.
  const plainRepo = `${cwd}/plain-git-repo`;
  fs.mkdirSync(plainRepo, { recursive: true });
  childProcess.execFileSync("git", ["init", "-q"], { cwd: plainRepo });
  childProcess.execFileSync("git", ["config", "user.email", "a@example.com"], { cwd: plainRepo });
  childProcess.execFileSync("git", ["config", "user.name", "a"], { cwd: plainRepo });
  fs.writeFileSync(`${plainRepo}/tracked.txt`, "tracked\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: plainRepo });
  childProcess.execFileSync("git", ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], { cwd: plainRepo });
  const plainMessagesBefore = calls.messages.length;
  await ss.handler({ type: "session_start", cwd: plainRepo, reason: "startup" }, { ...ssCtx, cwd: plainRepo });
  const plainSessionMessages = calls.messages.slice(plainMessagesBefore).filter((message) => message.customType === "edc-session-context");
  if (plainSessionMessages.length !== 0 || fs.existsSync(`${plainRepo}/.edc`)) {
    console.log("PLAIN_SESSION_CONTAMINATION_FAIL:" + JSON.stringify({ messages: plainSessionMessages, hasEdc: fs.existsSync(`${plainRepo}/.edc`) }));
    process.exit(1);
  }
  await edcCmd.opts.handler("-h", { cwd: plainRepo, hasUI: false });
  if (fs.existsSync(`${plainRepo}/.edc`)) {
    console.log("HELP_PREPARED_RUNTIME_FAIL:" + JSON.stringify({ hasEdc: true }));
    process.exit(1);
  }
  await edcCmd.opts.handler("", {
    cwd: plainRepo,
    hasUI: true,
    model: { provider: "test-provider", id: "test-model" },
    ui: { select: async () => "doctor / validate context" },
  });
  if (fs.existsSync(`${plainRepo}/.edc`) || !calls.messages.at(-1)?.content?.includes("doctor args:  agent=pi")) {
    console.log("EXECUTION_CREATED_REPO_RUNTIME_FAIL:" + JSON.stringify({ hasEdc: fs.existsSync(`${plainRepo}/.edc`), message: calls.messages.at(-1) }));
    process.exit(1);
  }

  const shutdown = calls.events.find(e => e.event === "session_shutdown");
  const shutdownStatusesBefore = calls.statuses.length;
  const shutdownWidgetsBefore = calls.widgets.length;
  await shutdown.handler({ type: "session_shutdown", reason: "reload" }, ssCtx);
  const shutdownClearedStatus = calls.statuses.slice(shutdownStatusesBefore)
    .some((entry) => entry.key === "edc-review" && entry.value === undefined);
  const shutdownClearedWidget = calls.widgets.slice(shutdownWidgetsBefore)
    .some((entry) => entry.key === "edc-review" && entry.value === undefined);
  if (!shutdownClearedStatus || !shutdownClearedWidget) {
    console.log("SESSION_SHUTDOWN_CLEAR_FAIL:" + JSON.stringify({ statuses: calls.statuses.slice(shutdownStatusesBefore), widgets: calls.widgets.slice(shutdownWidgetsBefore) }));
    process.exit(1);
  }
  // 6. tool_call extends bash timeout for long-running edc orchestrators
  const tc = calls.events.find(e => e.event === "tool_call");
  const fakeCtx = { cwd, sessionManager: { getSessionId: () => sid } };
  const edcBashEvent = {
    type: "tool_call",
    toolCallId: "bash-edc",
    toolName: "bash",
    input: { command: "edc security diff main --agent pi", timeout: 1200 },
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
    input: { command: `bash $HOME/.edc/scripts/edc-review.sh --base main`, timeout: 1200 },
  };
  await tc.handler(absoluteEdcBashEvent, fakeCtx);
  if (absoluteEdcBashEvent.input.timeout < 7200) {
    console.log("EDC_ABSOLUTE_BASH_TIMEOUT_FAIL:" + JSON.stringify(absoluteEdcBashEvent.input));
    process.exit(1);
  }
  const multilineEdcBashEvent = {
    type: "tool_call",
    toolCallId: "bash-edc-multiline",
    toolName: "bash",
    input: { command: "printf ready\nedc review diff main --agent pi", timeout: 1200 },
  };
  await tc.handler(multilineEdcBashEvent, fakeCtx);
  if (multilineEdcBashEvent.input.timeout < 7200) {
    console.log("EDC_MULTILINE_BASH_TIMEOUT_FAIL:" + JSON.stringify(multilineEdcBashEvent.input));
    process.exit(1);
  }

  // 7. detached background spawn failure marks status failed instead of crashing or staying running.
  const spawnFailDir = `${cwd}/spawn-fail`;
  fs.mkdirSync(spawnFailDir, { recursive: true });
  childProcess.execFileSync("git", ["init", "-q"], { cwd: spawnFailDir });
  childProcess.execFileSync("git", ["config", "user.email", "a@example.com"], { cwd: spawnFailDir });
  childProcess.execFileSync("git", ["config", "user.name", "a"], { cwd: spawnFailDir });
  fs.writeFileSync(`${spawnFailDir}/tracked.txt`, "tracked\n");
  childProcess.execFileSync("git", ["add", "tracked.txt"], { cwd: spawnFailDir });
  childProcess.execFileSync("git", ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], { cwd: spawnFailDir });
  // A stale repo runtime decoy must remain ignored even when trusted dispatch cannot spawn.
  fs.mkdirSync(`${spawnFailDir}/.edc/scripts`, { recursive: true });
  fs.writeFileSync(`${spawnFailDir}/.edc/scripts/edc-review-all.sh`, "#!/usr/bin/env bash\necho should-not-run\n");
  fs.chmodSync(`${spawnFailDir}/.edc/scripts/edc-review-all.sh`, 0o755);
  const noBashDir = `${cwd}/no-bash-path`;
  fs.mkdirSync(noBashDir, { recursive: true });
  const realGit = childProcess.execFileSync("which", ["git"], { encoding: "utf8" }).trim();
  fs.symlinkSync(realGit, `${noBashDir}/git`);
  const previousSpawnPath = process.env.PATH;
  process.env.PATH = noBashDir;
  try {
    await edcCmd.opts.handler("", { ...menuCtx(["full repo review", "combined review"]), cwd: spawnFailDir });
  } finally {
    process.env.PATH = previousSpawnPath;
  }
  await new Promise((resolve) => setTimeout(resolve, 100));
  const spawnFailStatus = fs.readFileSync(`${spawnFailDir}/.git/edc/status`, "utf8");
  if (!spawnFailStatus.includes("status=failed") || !spawnFailStatus.includes("failed to start background review-all")) {
    console.log("SPAWN_ERROR_STATUS_FAIL:" + spawnFailStatus);
    process.exit(1);
  }

  // 8. tool_call injects context for a routed file
  const messagesBeforeToolCall = calls.messages.length;
  await tc.handler(
    { type: "tool_call", toolCallId: "x", toolName: "edit", input: { file_path: "src/foo.ts" } },
    fakeCtx
  );
  if (calls.messages.length !== messagesBeforeToolCall + 1 || !calls.messages.at(-1).content.includes("src-mod")) {
    console.log("INJECT_FAIL:" + JSON.stringify(calls.messages));
    process.exit(1);
  }

  // 9. duplicate tool_call for the same module → no second injection
  await tc.handler(
    { type: "tool_call", toolCallId: "y", toolName: "edit", input: { file_path: "src/bar.ts" } },
    fakeCtx
  );
  if (calls.messages.length !== messagesBeforeToolCall + 1) {
    console.log("DEDUP_FAIL:" + JSON.stringify(calls.messages));
    process.exit(1);
  }

  // 10. one bash tool_call touching multiple routed modules injects one combined payload in path order.
  const multiSession = `${sid}-multi`;
  const messagesBeforeMulti = calls.messages.length;
  await tc.handler(
    { type: "tool_call", toolCallId: "multi", toolName: "bash", input: { command: "cat api/foo.ts lib/bar.ts" } },
    { ...fakeCtx, sessionManager: { getSessionId: () => multiSession } }
  );
  const multiMessages = calls.messages.slice(messagesBeforeMulti);
  const multiContent = multiMessages.at(-1)?.content || "";
  const apiHeader = "[edc] Auto-injected context for module \"api-mod\" (touching api/foo.ts)";
  const libHeader = "[edc] Auto-injected context for module \"lib-mod\" (touching lib/bar.ts)";
  if (multiMessages.length !== 1
    || !multiContent.includes(apiHeader)
    || !multiContent.includes("# api-mod docs")
    || !multiContent.includes(libHeader)
    || !multiContent.includes("# lib-mod docs")
    || multiContent.indexOf(apiHeader) > multiContent.indexOf(libHeader)) {
    console.log("MULTI_MODULE_INJECT_FAIL:" + JSON.stringify(multiMessages));
    process.exit(1);
  }
  await tc.handler(
    { type: "tool_call", toolCallId: "multi-api-again", toolName: "edit", input: { file_path: "api/again.ts" } },
    { ...fakeCtx, sessionManager: { getSessionId: () => multiSession } }
  );
  await tc.handler(
    { type: "tool_call", toolCallId: "multi-lib-again", toolName: "edit", input: { file_path: "lib/again.ts" } },
    { ...fakeCtx, sessionManager: { getSessionId: () => multiSession } }
  );
  if (calls.messages.length !== messagesBeforeMulti + 1) {
    console.log("MULTI_MODULE_DEDUP_FAIL:" + JSON.stringify(calls.messages.slice(messagesBeforeMulti)));
    process.exit(1);
  }

  // 11. bash commands can provide explicit context path hints for complex shell syntax.
  const hintSession = `${sid}-hint`;
  const messagesBeforeHint = calls.messages.length;
  await tc.handler(
    { type: "tool_call", toolCallId: "hint", toolName: "bash", input: { command: "printf ok\n# edc-context-path: src/path with spaces.ts" } },
    { ...fakeCtx, sessionManager: { getSessionId: () => hintSession } }
  );
  if (calls.messages.length !== messagesBeforeHint + 1 || !calls.messages.at(-1).content.includes("touching src/path with spaces.ts")) {
    console.log("BASH_HINT_INJECT_FAIL:" + JSON.stringify(calls.messages.slice(messagesBeforeHint)));
    process.exit(1);
  }

  console.log("OK");
' 2>&1)

# clean up the per-session dedup files the test created (live under os.tmpdir())
for dedup_session_id in "$SESSION_ID" "$SESSION_ID-multi" "$SESSION_ID-hint"; do
  DEDUP_FILE=$(node -e "console.log(require('path').join(require('os').tmpdir(),'edc-injected-modules-'+process.argv[1]+'.json'))" "$dedup_session_id")
  rm -f "$DEDUP_FILE"
done

if echo "$wiring" | tail -1 | grep -qx 'OK'; then
  say_pass "extension factory wires commands + events + injection"
else
  say_fail "extension factory wiring" "$wiring"
fi

echo
echo "t10-pi-extension: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
