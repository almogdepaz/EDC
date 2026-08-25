#!/usr/bin/env bash
# Task 11 smoke test: end-to-end audit orchestrator with mocked agent.
#
# Exercises the same patterns as t6 (mocked claude, hermetic git env) but for
# the audit pipeline:
#
#   - missing context → orchestrator runs build recovery, then audit
#   - stale context  → orchestrator runs update recovery, then audit
#   - one audit worker runs per manifest module, then synthesis writes both reports
#   - synthesis writes only one report → missing coverage is marked explicitly
#   - substantive noncanonical synthesis output remains usable
#
# Run from repo root: bash tests/hardening/t11-audit-orchestrator.sh
set -euo pipefail


ORIG_DIR="$(pwd)"
SCRIPT="$ORIG_DIR/plugins/edc/scripts/edc-audit.sh"
TMPDIR_T11=$(mktemp -d)
MOCK_BIN="$TMPDIR_T11/bin"
export EDC_CONFIG_FILE="$TMPDIR_T11/missing-config"
unset EDC_PARALLEL
trap 'rm -rf "$TMPDIR_T11"' EXIT

echo "=== T11: audit orchestrator (mocked agent) ==="

# ── build the mock claude ────────────────────────────────────────────────────
#
# The mock writes whichever artifacts the prompt asks for. A "scenario file"
# at $TMPDIR_T11/scenario controls synthesis output (valid|missing-issues|stub).
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
prompt=\$(cat)
previous=""
for arg in "\$@"; do
  if [ "\$previous" = "--system-prompt-file" ]; then
    prompt=\$(cat "\$arg")
    break
  fi
  previous="\$arg"
done
SCENARIO_FILE="$TMPDIR_T11/scenario"
LOG_FILE="$TMPDIR_T11/audit-log"
scenario="valid"
[ -f "\$SCENARIO_FILE" ] && scenario=\$(cat "\$SCENARIO_FILE")

if [[ "\$prompt" == *"AUDIT WORKER TASK"* ]]; then
  module=\$(printf '%s\n' "\$prompt" | grep '^AUDIT_MODULE: ' | head -1 | sed 's/^AUDIT_MODULE: //')
  report_path=\$(printf '%s\n' "\$prompt" | grep '^AUDIT_REPORT_PATH: ' | head -1 | sed 's/^AUDIT_REPORT_PATH: //')
  capability=\$(printf '%s\n' "\$prompt" | awk -F': ' '/^OCTOCODE_STATUS: /{print \$2}')
  mkdir -p "\$(dirname "\$report_path")"
  printf 'worker:%s\n' "\$module" >> "\$LOG_FILE"
  printf 'capability:%s:%s\n' "\$module" "\$capability" >> "\$LOG_FILE"
  if [[ "\$prompt" == *"immutable candidate commit"* ]] \
    && [[ "\$prompt" == *"git show"* ]] \
    && [[ "\$prompt" == *"changed gitlink"* ]] \
    && [[ "\$prompt" == *"git -C <submodule-path> diff"* ]]; then
    printf 'candidate-contract:%s\n' "\$module" >> "\$LOG_FILE"
  fi
  if [ "\${AUDIT_PARALLEL_PROBE:-0}" = "1" ]; then
    mkdir -p "$TMPDIR_T11/active"
    : > "$TMPDIR_T11/active/\$module"
    active=\$(find "$TMPDIR_T11/active" -type f | wc -l | tr -d ' ')
    printf '%s\n' "\$active" >> "$TMPDIR_T11/overlap"
    sleep 0.4
    rm -f "$TMPDIR_T11/active/\$module"
  fi
  if [ "\$scenario" = "valid-worker-exit-fail" ]; then
    exit 1
  fi
  if [ "\$scenario" = "empty-worker-success" ]; then
    : > "\$report_path"
    exit 0
  fi
  printf 'module audit for %s completed without canonical headings\n' "\$module" > "\$report_path"
  exit 0
fi

if [[ "\$prompt" == *"AUDIT SYNTHESIS TASK"* ]]; then
  if [[ "\$prompt" == *"OCTOCODE_STATUS:"* ]]; then
    echo "MOCK ERROR: synthesis prompt received source-research capability guidance" >&2
    exit 31
  fi
  printf 'synthesis\n' >> "\$LOG_FILE"
  complexity_path=\$(printf '%s\n' "\$prompt" | grep '^CANONICAL_COMPLEXITY_REPORT: ' | head -1 | sed 's/^CANONICAL_COMPLEXITY_REPORT: //')
  issues_path=\$(printf '%s\n' "\$prompt" | grep '^CANONICAL_ISSUES_REPORT: ' | head -1 | sed 's/^CANONICAL_ISSUES_REPORT: //')
  mkdir -p "\$(dirname "\$complexity_path")" "\$(dirname "\$issues_path")"
  case "\$scenario" in
    valid|valid-worker-exit-fail|empty-worker-success)
      printf '## Summary\n\nSynthesized findings.\n' > "\$complexity_path"
      printf '## Known Issues\n\nSynthesized findings.\n' > "\$issues_path"
      ;;
    missing-issues)
      printf '## Summary\n\nSynthesized findings.\n' > "\$complexity_path"
      # deliberately do NOT write issues.md
      ;;
    stub-complexity)
      printf 'no headings here just plain text\n' > "\$complexity_path"
      printf '## Known Issues\n\nSynthesized findings.\n' > "\$issues_path"
      ;;
    valid-synthesis-exit-fail)
      printf '## Summary\n\nSynthesized findings.\n' > "\$complexity_path"
      printf '## Known Issues\n\nSynthesized findings.\n' > "\$issues_path"
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "\$prompt" == *"name: edc-audit"* ]]; then
  printf 'single\n' >> "\$LOG_FILE"
  mkdir -p edc-context/reports
  printf '## Summary\n\nLegacy single-pass findings.\n' > edc-context/reports/complexity.md
  printf '## Known Issues\n\nLegacy single-pass findings.\n' > edc-context/reports/issues.md
  exit 0
fi

if [[ "\$prompt" == *"name: edc-update-impl"* ]] || [[ "\$prompt" == *"# Update Context"* ]]; then
  head=\$(git rev-parse HEAD)
  sed -i.bak 's/"sourceCommit":"[^"]*"/"sourceCommit":"'"\$head"'"/' edc-context/manifest.json
  rm -f edc-context/manifest.json.bak
  exit 0
fi

if [[ "\$prompt" == *"edc-build"* ]]; then
  mkdir -p edc-context/modules edc-context/reports
  printf '<!-- generated by t11 mock -->\n# Stub\n\n## Module Map\n\n- root\n- lib\n' > edc-context/index.md
  head=\$(git rev-parse HEAD)
  printf '{"schemaVersion":2,"sourceCommit":"%s","modules":[{"name":"root","doc":"edc-context/modules/root.md","match":{"exactFiles":["src.py"]}},{"name":"lib","doc":"edc-context/modules/lib.md","match":{"exactFiles":["lib.py"]}}]}\n' "\$head" > edc-context/manifest.json
  printf '<!-- generated by t11 mock -->\n# root\n\n## Files\n\n- src.py\n' > edc-context/modules/root.md
  printf '<!-- generated by t11 mock -->\n# lib\n\n## Files\n\n- lib.py\n' > edc-context/modules/lib.md
  exit 0
fi

echo "MOCK ERROR: unrecognized prompt: \$prompt" >&2
exit 1
MOCK
chmod +x "$MOCK_BIN/claude"
cat > "$MOCK_BIN/octocode" <<MOCK
#!/usr/bin/env bash
printf 'probe\n' >> "$TMPDIR_T11/octocode-log"
[ "\${1:-}" = "--version" ] || exit 2
printf 'octocode v-test\n'
MOCK
chmod +x "$MOCK_BIN/octocode"

# ── helper: set up a minimal git repo + optionally pre-existing context ──────
setup_repo() {
  local with_context="$1"
  rm -rf "$TMPDIR_T11/repo"
  rm -f "$TMPDIR_T11/audit-log" "$TMPDIR_T11/octocode-log"
  mkdir -p "$TMPDIR_T11/repo"
  cd "$TMPDIR_T11/repo"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email "t@t.com"
  git config user.name "T"
  git config commit.gpgsign false
  echo "src" > src.py
  echo "lib" > lib.py
  git add src.py lib.py
  git commit -q -m "init"
  if [ "$with_context" = "fresh" ]; then
    mkdir -p edc-context/modules
    head=$(git rev-parse HEAD)
    printf '<!-- t11 -->\n# Stub\n\n## Module Map\n\n- root\n- lib\n' > edc-context/index.md
    printf '{"schemaVersion":2,"sourceCommit":"%s","modules":[{"name":"root","doc":"edc-context/modules/root.md","match":{"exactFiles":["src.py"]}},{"name":"lib","doc":"edc-context/modules/lib.md","match":{"exactFiles":["lib.py"]}}]}\n' "$head" > edc-context/manifest.json
    printf '<!-- t11 -->\n# root\n\n## Files\n\n- src.py\n' > edc-context/modules/root.md
    printf '<!-- t11 -->\n# lib\n\n## Files\n\n- lib.py\n' > edc-context/modules/lib.md
  elif [ "$with_context" = "stale" ]; then
    mkdir -p edc-context/modules
    printf '<!-- t11 -->\n# Stub\n\n## Module Map\n\n- root\n- lib\n' > edc-context/index.md
    printf '{"schemaVersion":2,"sourceCommit":"deadbeef","modules":[{"name":"root","doc":"edc-context/modules/root.md","match":{"exactFiles":["src.py"]}},{"name":"lib","doc":"edc-context/modules/lib.md","match":{"exactFiles":["lib.py"]}}]}\n' > edc-context/manifest.json
    printf '<!-- t11 -->\n# root\n\n## Files\n\n- src.py\n' > edc-context/modules/root.md
    printf '<!-- t11 -->\n# lib\n\n## Files\n\n- lib.py\n' > edc-context/modules/lib.md
  fi
}

export PATH="$MOCK_BIN:$PATH"
export EDC_AGENT_CLI=claude

# Sanity check.
which_claude=$(command -v claude)
[ "$which_claude" = "$MOCK_BIN/claude" ] || { echo "FAIL: mock not on PATH (got $which_claude)"; exit 1; }

# ── 11a: missing context → build recovery → audit succeeds ──────────────────
setup_repo "none"
echo "valid" > "$TMPDIR_T11/scenario"
result=0
out=$(/bin/bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ] && [ -f edc-context/reports/complexity.md ] && [ -f edc-context/reports/issues.md ] \
   && [ "$(grep -c '^worker:' "$TMPDIR_T11/audit-log" 2>/dev/null || true)" -eq 2 ] \
   && grep -q '^synthesis$' "$TMPDIR_T11/audit-log" \
   && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "audit" && j.exitCode === 0 && j.reasonCode === "success" ? 0 : 1)'; then
  echo "PASS: missing-context recovery → per-module audit + synthesis produced both reports"
else
  echo "FAIL (11a): missing-context path. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11b: stale context → update recovery → audit succeeds ───────────────────
setup_repo "stale"
echo "valid" > "$TMPDIR_T11/scenario"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ] && [ -f edc-context/reports/complexity.md ] && [ -f edc-context/reports/issues.md ] \
   && [ "$(grep -c '^worker:' "$TMPDIR_T11/audit-log" 2>/dev/null || true)" -eq 2 ] \
   && grep -q '^synthesis$' "$TMPDIR_T11/audit-log"; then
  echo "PASS: stale-context recovery → per-module audit + synthesis produced both reports"
else
  echo "FAIL (11b): stale-context path. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11b2: one immutable Octocode capability state per coordinator run ──────
setup_repo "fresh"
echo "valid" > "$TMPDIR_T11/scenario"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
probe_count=$(wc -l < "$TMPDIR_T11/octocode-log" 2>/dev/null | tr -d ' ' || echo 0)
capabilities=$(grep '^capability:' "$TMPDIR_T11/audit-log" 2>/dev/null | sort || true)
expected_capabilities=$(printf 'capability:lib:available\ncapability:root:available')
if [ "$result" -eq 0 ] && [ "$probe_count" -eq 1 ] && [ "$capabilities" = "$expected_capabilities" ]; then
  echo "PASS: multi-prompt audit probes Octocode once and shares immutable capability state"
else
  echo "FAIL (11b2): expected one Octocode probe and identical available state. exit=$result probes=$probe_count"
  echo "capabilities=$capabilities"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11c: valid worker report + failed worker rc → warning, not failure ─────
setup_repo "fresh"
echo "valid-worker-exit-fail" > "$TMPDIR_T11/scenario"
result=0
out=$(EDC_KEEP_AUDIT_TASKS=1 bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ] && echo "$out" | grep -q "audit subprocess for module root reported status failed" \
   && grep -Rq 'Quality review unavailable for module' .git/edc/runs/*/staged/audit-tasks \
   && [ -f edc-context/reports/complexity.md ] && [ -f edc-context/reports/issues.md ] \
   && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "audit" && j.status === "success-with-warning" && j.exitCode === 0 && j.reasonCode === "success-with-warning" ? 0 : 1)'; then
  echo "PASS: missing failed-worker reports become explicit unavailable coverage"
else
  echo "FAIL (11c): missing worker reports should succeed with warning. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11c2: empty successful worker output → explicit coverage gap ────────────
setup_repo "fresh"
echo "empty-worker-success" > "$TMPDIR_T11/scenario"
result=0
out=$(EDC_KEEP_AUDIT_TASKS=1 bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ] \
   && echo "$out" | grep -q 'module root produced no substantive report' \
   && grep -Rq 'Quality review unavailable for module' .git/edc/runs/*/staged/audit-tasks \
   && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.status === "success-with-warning" ? 0 : 1)'; then
  echo "PASS: empty successful-worker audit becomes explicit unavailable coverage"
else
  echo "FAIL (11c2): empty successful-worker audit aborted or hid incomplete coverage. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11d: valid synthesis reports + failed synthesis rc → warning, not failure ─
setup_repo "fresh"
echo "valid-synthesis-exit-fail" > "$TMPDIR_T11/scenario"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ] && echo "$out" | grep -q "audit synthesis subprocess reported failure, but its substantive reports were preserved" \
   && [ -f edc-context/reports/complexity.md ] && [ -f edc-context/reports/issues.md ] \
   && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "audit" && j.status === "success-with-warning" && j.exitCode === 0 && j.reasonCode === "success-with-warning" ? 0 : 1)'; then
  echo "PASS: valid audit synthesis accepted after failed synthesis rc"
else
  echo "FAIL (11d): valid synthesis reports + failed rc should succeed with warning. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11e: diff scope audits only modules owning changed files ────────────────
setup_repo "fresh"
base_ref=$(git rev-parse HEAD)
printf 'lib changed\n' > lib.py
git add lib.py
git commit -q -m "change lib"
echo "valid" > "$TMPDIR_T11/scenario"
result=0
out=$(bash "$SCRIPT" HEAD --base "$base_ref" 2>&1) || result=$?
workers=$(grep '^worker:' "$TMPDIR_T11/audit-log" 2>/dev/null || true)
if [ "$result" -eq 0 ] && [ "$workers" = "worker:lib" ] \
   && grep -q '^candidate-contract:lib$' "$TMPDIR_T11/audit-log" \
   && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.scope === "differential" && j.base && j.target === "HEAD" ? 0 : 1)'; then
  echo "PASS: diff-scoped quality review audits only changed modules"
else
  echo "FAIL (11e): diff-scoped audit should only audit lib. exit=$result"
  echo "workers=$workers"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11e1: explicit dirty candidate includes deleted-file module scope ──────
setup_repo "fresh"
base_ref=$(git rev-parse HEAD)
rm lib.py
rm -f "$TMPDIR_T11/audit-log"
echo "valid" > "$TMPDIR_T11/scenario"
set +e
dirty_out=$(bash "$SCRIPT" HEAD --base "$base_ref" 2>&1)
dirty_rc=$?
set -e
if [ "$dirty_rc" -eq 2 ] && [ ! -s "$TMPDIR_T11/audit-log" ] && grep -q -- '--include-working-tree' <<<"$dirty_out"; then
  echo "PASS: standalone dirty quality review fails before agent execution"
else
  echo "FAIL (11e1): dirty quality review did not fail before workers. exit=$dirty_rc"
  echo "$dirty_out"
  exit 1
fi
result=0
out=$(bash "$SCRIPT" HEAD --base "$base_ref" --include-working-tree 2>&1) || result=$?
workers=$(grep '^worker:' "$TMPDIR_T11/audit-log" 2>/dev/null || true)
if [ "$result" -eq 0 ] && [ "$workers" = "worker:lib" ]; then
  echo "PASS: include-working-tree routes a deleted file to its quality module"
else
  echo "FAIL (11e1): deleted dirty file did not select its quality module. exit=$result workers=$workers"
  echo "$out"
  exit 1
fi

# ── 11e2: ignore rules filter changed files before module routing ───────────
setup_repo "fresh"
base_ref=$(git rev-parse HEAD)
printf 'src changed\n' > src.py
printf 'lib changed\n' > lib.py
git add src.py lib.py
git commit -q -m "change both modules"
echo "valid" > "$TMPDIR_T11/scenario"
result=0
out=$(bash "$SCRIPT" HEAD --base "$base_ref" --ignore 'lib.py' 2>&1) || result=$?
workers=$(grep '^worker:' "$TMPDIR_T11/audit-log" 2>/dev/null || true)
if [ "$result" -eq 0 ] && [ "$workers" = "worker:root" ]; then
  echo "PASS: quality-review ignore rules filter files before module routing"
else
  echo "FAIL (11e2): ignored lib.py still selected an audit module. exit=$result"
  echo "workers=$workers"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11f: missing synthesis output becomes explicit unavailable coverage ───────
setup_repo "fresh"
echo "missing-issues" > "$TMPDIR_T11/scenario"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ] \
   && grep -q 'Quality review unavailable' edc-context/reports/issues.md \
   && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "audit" && j.status === "success-with-warning" && j.exitCode === 0 && j.reasonCode === "success-with-warning" ? 0 : 1)'; then
  echo "PASS: missing synthesis report becomes explicit unavailable coverage"
else
  echo "FAIL (11f): missing synthesis report aborted or hid incomplete coverage. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11g: substantive noncanonical synthesis output is accepted ────────────────
setup_repo "fresh"
echo "stub-complexity" > "$TMPDIR_T11/scenario"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ] \
   && grep -q 'no headings here just plain text' edc-context/reports/complexity.md; then
  echo "PASS: substantive noncanonical synthesis output accepted"
else
  echo "FAIL (11g): substantive synthesis output was rejected. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

# ── 11h: module workers use the bounded pool and stage outside the checkout ─
setup_repo "fresh"
rm -rf "$TMPDIR_T11/active"
rm -f "$TMPDIR_T11/overlap"
echo "valid" > "$TMPDIR_T11/scenario"
result=0
out=$(AUDIT_PARALLEL_PROBE=1 EDC_PARALLEL=1 EDC_MAX_CONCURRENCY=2 EDC_KEEP_AUDIT_TASKS=1 bash "$SCRIPT" 2>&1) || result=$?
max_overlap=$(sort -nr "$TMPDIR_T11/overlap" 2>/dev/null | head -1 || echo 0)
run_reports=0
if [ -d .git/edc/runs ]; then
  run_reports=$(find .git/edc/runs -path '*/staged/audit-tasks/*.md' -type f | wc -l | tr -d ' ')
fi
if [ "$result" -eq 0 ] && [ "$max_overlap" -eq 2 ] && [ "$run_reports" -eq 2 ] && [ ! -d edc-context/audit-tasks ]; then
  echo "PASS: audit workers overlap at configured bound and stage under git state"
else
  echo "FAIL (11h): expected two-worker overlap and git-state staging. exit=$result overlap=$max_overlap staged=$run_reports"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

cd "$ORIG_DIR"
echo ""
echo "All T11 checks passed."
