#!/usr/bin/env bash
# t10-pi-extension: smoke-test the pi extension wiring.
#
# Verifies:
#   - root package.json has the pi.extensions entry pointing at agents/pi/index.mjs
#   - agents/pi/index.mjs parses (node --check)
#   - shared lib (plugins/edc/hooks/lib/route.mjs) exports the expected names
#   - the extension factory runs end-to-end against a fake ExtensionAPI
#     (registers all 6 commands, subscribes to the expected events,
#     buildToolCallInjection produces module docs through the same code path)
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
    *"./agents/pi/index.mjs"*) say_pass "package.json declares pi.extensions" ;;
    *) say_fail "package.json pi.extensions entry" "got: $ext" ;;
  esac
fi

# --- 2. extension entry parses ----------------------------------------------
if node --check agents/pi/index.mjs 2>/dev/null; then
  say_pass "agents/pi/index.mjs parses"
else
  say_fail "agents/pi/index.mjs parses"
fi

# --- 3. shared lib exports --------------------------------------------------
exports_check=$(node --input-type=module -e '
  import("./plugins/edc/hooks/lib/route.mjs").then(m => {
    const required = [
      "loadManifest","manifestPath","checkStaleness",
      "extractFilePaths","extractFilePathsFromBash","normalizePath",
      "routeFile","moduleDocPath","dedupPath","isDuplicate",
      "isEdcProject","installOrchestratorScript","resolvePluginRoot",
      "buildSessionStartContent","buildToolCallInjection"
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

# Unique session id per test run so the file-based dedup (rooted in os.tmpdir())
# doesn't poison a re-run.
SESSION_ID="t10-$$-$(date +%s%N 2>/dev/null || date +%s)"

wiring=$(EDC_TEST_CWD="$TMP" EDC_TEST_SID="$SESSION_ID" node --input-type=module -e '
  const cwd = process.env.EDC_TEST_CWD;
  const sid = process.env.EDC_TEST_SID;
  const calls = { commands: [], events: [], messages: [] };
  const fakePi = {
    on: (event, handler) => { calls.events.push({ event, handler }); },
    registerCommand: (name, opts) => { calls.commands.push({ name, opts }); },
    sendMessage: (m) => { calls.messages.push(m); },
  };
  const factory = (await import("./agents/pi/index.mjs")).default;
  await factory(fakePi);
  // 1. all 6 commands registered
  const expectedCmds = ["edc-build","edc-update","edc-audit","edc-run-review","edc-doctor","edc-review"];
  const got = calls.commands.map(c => c.name).sort();
  if (JSON.stringify(got) !== JSON.stringify(expectedCmds.sort())) {
    console.log("CMDS_FAIL:" + got.join(","));
    process.exit(1);
  }
  // 2. expected events subscribed
  const evs = calls.events.map(e => e.event).sort();
  // Note: session_shutdown is no longer needed — dedup is file-based, not
  // in-process (see plugins/edc/hooks/lib/route.mjs::isDuplicate).
  for (const want of ["resources_discover","session_start","tool_call"]) {
    if (!evs.includes(want)) { console.log("MISSING_EVENT:" + want); process.exit(1); }
  }
  // 3. resources_discover returns skill paths
  const rd = calls.events.find(e => e.event === "resources_discover");
  const r = await rd.handler({ type: "resources_discover", cwd, reason: "startup" }, { cwd });
  if (!r || !Array.isArray(r.skillPaths) || r.skillPaths.length === 0) {
    console.log("RD_FAIL:" + JSON.stringify(r));
    process.exit(1);
  }
  // 4. session_start injects edc-context/index.md when mode=inject
  const ss = calls.events.find(e => e.event === "session_start");
  const ssCtx = { cwd, sessionManager: { getSessionId: () => sid } };
  await ss.handler({ type: "session_start", cwd, reason: "startup" }, ssCtx);
  if (calls.messages.length !== 1 || !calls.messages[0].content.includes("Module Map")) {
    console.log("SESSION_START_FAIL:" + JSON.stringify(calls.messages));
    process.exit(1);
  }
  // 5. tool_call injects context for a routed file
  const tc = calls.events.find(e => e.event === "tool_call");
  const fakeCtx = { cwd, sessionManager: { getSessionId: () => sid } };
  await tc.handler(
    { type: "tool_call", toolCallId: "x", toolName: "edit", input: { file_path: "src/foo.ts" } },
    fakeCtx
  );
  if (calls.messages.length !== 2 || !calls.messages[1].content.includes("src-mod")) {
    console.log("INJECT_FAIL:" + JSON.stringify(calls.messages));
    process.exit(1);
  }
  // 6. duplicate tool_call for the same module → no second injection
  await tc.handler(
    { type: "tool_call", toolCallId: "y", toolName: "edit", input: { file_path: "src/bar.ts" } },
    fakeCtx
  );
  if (calls.messages.length !== 2) {
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
