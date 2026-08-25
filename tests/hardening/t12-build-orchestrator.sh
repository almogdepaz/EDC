#!/usr/bin/env bash
# Task 12 smoke test: end-to-end build orchestrator routing + validation.
#
# Pins the contract that scripts/edc-build.sh:
#   - routes to a full BUILD when no edc-context/ exists
#   - routes to UPDATE when v2 context is healthy and --force is NOT passed
#   - routes to a wipe + BUILD when --force is passed on healthy v2
#   - routes to a wipe + BUILD when v2 is partial / malformed
#   - REFUSES to act and prints a migration hint when v1 markers present
#   - runs edc-doctor.sh after the subprocess and fails non-zero if invalid
#
# Run from repo root: bash tests/hardening/t12-build-orchestrator.sh
set -euo pipefail


ORIG_DIR="$(pwd)"
SCRIPT="$ORIG_DIR/plugins/edc/scripts/edc-build.sh"
TMPDIR_T12=$(mktemp -d)
MOCK_BIN="$TMPDIR_T12/bin"
export EDC_CONFIG_FILE="$TMPDIR_T12/missing-config"
unset EDC_PARALLEL
trap 'rm -rf "$TMPDIR_T12"' EXIT

echo "=== T12: build orchestrator (mocked agent) ==="

# ── mock claude that records which action it was asked to perform ────────────
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
prompt=$(cat)
previous=""
for arg in "$@"; do
  if [ "$previous" = "--system-prompt-file" ]; then
    prompt=$(cat "$arg")
    break
  fi
  previous="$arg"
done
LOG="${EDC_T12_LOG:?}"

if [[ "$prompt" == *"BUILD DISCOVERY TASK"* ]]; then
  echo "build" >> "$LOG"
  output=$(printf '%s\n' "$prompt" | grep '^DISCOVERY_OUTPUT: ' | sed 's/^DISCOVERY_OUTPUT: //')
  mkdir -p "$(dirname "$output")"
  if [ "${EDC_T12_DISCOVERY_MODE:-}" = "duplicate" ]; then
    printf '{"modules":[{"name":"root","paths":["src/"],"approxLoc":1},{"name":"root","paths":["lib/"],"approxLoc":1}]}\n' > "$output"
  elif [ "${EDC_T12_PARALLEL:-0}" = "1" ]; then
    printf '{"modules":[{"name":"root","paths":["src/"],"approxLoc":1},{"name":"lib","paths":["lib/"],"approxLoc":1},{"name":"api","paths":["api/"],"approxLoc":1}]}\n' > "$output"
  else
    printf '{"modules":[{"name":"root","paths":["src/"],"approxLoc":1}]}\n' > "$output"
  fi
  exit 0
fi

if [[ "$prompt" == *"MODULE CONTEXT TASK"* ]]; then
  if [ -n "${EDC_T12_MODULE_PROMPT_LOG:-}" ]; then
    printf '%s\n' "$prompt" > "$EDC_T12_MODULE_PROMPT_LOG"
  fi
  if [ -n "${EDC_T12_MANIFEST_CONCURRENCY_LOG:-}" ]; then
    manifest="$(git rev-parse --absolute-git-dir)/edc/runs/${EDC_RUN_ID:?}/module-manifest.json"
    node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.maxConcurrency))' "$manifest" > "$EDC_T12_MANIFEST_CONCURRENCY_LOG"
  fi
  output=$(printf '%s\n' "$prompt" | grep '^OUTPUT: ' | head -1 | sed 's/^OUTPUT: //')
  module=$(printf '%s\n' "$prompt" | grep '^MODULE: ' | head -1 | sed 's/^MODULE: //')
  if [ "${EDC_T12_PARALLEL:-0}" = "1" ]; then
    mkdir -p .git/t12-active
    : > ".git/t12-active/$module"
    active=$(find .git/t12-active -type f | wc -l | tr -d ' ')
    printf '%s\n' "$active" >> .git/t12-overlap
    sleep 0.4
    rm -f ".git/t12-active/$module"
  fi
  if [ "${EDC_T12_FAIL_MODULE:-}" = "$module" ]; then
    exit 17
  fi
  if [ "${EDC_T12_MUTATE_MODULE:-}" = "$module" ]; then
    printf 'worker mutation\n' > src/main.py
  fi
  mkdir -p "$(dirname "$output")"
  printf '# %s\n\n## Ownership\n\nMock module context.\n' "$module" > "$output"
  if [ "${EDC_T12_EXTRA_MODULE_OUTPUT:-0}" = "1" ] && [ "$module" = "root" ]; then
    printf '# Extra\n\n## Ownership\n\nUndeclared.\n' > "$(dirname "$output")/extra.md"
  fi
  exit 0
fi

if [[ "$prompt" == *"CROSS-MODULE SYNTHESIS TASK"* ]]; then
  output=$(printf '%s\n' "$prompt" | grep '^OUTPUT: ' | sed 's/^OUTPUT: //')
  printf '## Cross-module flows\n\nMock flow.\n' > "$output"
  exit 0
fi

if [[ "$prompt" == *"BUILD ASSEMBLY TASK"* ]]; then
  index_output=$(printf '%s\n' "$prompt" | grep '^INDEX_OUTPUT: ' | sed 's/^INDEX_OUTPUT: //')
  partial_output=$(printf '%s\n' "$prompt" | grep '^PARTIAL_MANIFEST_OUTPUT: ' | sed 's/^PARTIAL_MANIFEST_OUTPUT: //')
  build_output=$(printf '%s\n' "$prompt" | grep '^BUILD_INFO_OUTPUT: ' | sed 's/^BUILD_INFO_OUTPUT: //')
  agents_output=$(printf '%s\n' "$prompt" | grep '^AGENT_ENTRYPOINT_OUTPUT: ' | sed 's/^AGENT_ENTRYPOINT_OUTPUT: //')
  mkdir -p "$(dirname "$index_output")" "$(dirname "$build_output")" "$(dirname "$agents_output")"
  printf '# Stub context\n\n## How to use\n\nRead routes.\n\n## Route by path/task\n\n- src: root\n\n## Critical global invariants\n\n- mock\n\n## Cross-module coupling / blast radius\n\n- mock\n' > "$index_output"
  metadata=$(printf '%s\n' "$prompt" | grep '^MODULE_METADATA: ' | head -1 | sed 's/^MODULE_METADATA: //')
  node - "$metadata" "$partial_output" <<'NODE'
const fs = require('fs');
const [metadataPath, outputPath] = process.argv.slice(2);
const metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
const modules = metadata.modules.map((entry, index) => ({
  name: entry.module,
  doc: `edc-context/modules/${entry.module}.md`,
  summary: 'mock',
  priority: 100 - index,
  match: { prefixes: [entry.module === 'root' ? 'src/' : `${entry.module}/`] },
}));
const manifest = {schemaVersion:2,edcVersion:'1.1.0',repoContextFile:'edc-context/index.md',reports:{issues:'edc-context/reports/issues.md',complexity:'edc-context/reports/complexity.md'},build:{buildInfoFile:'edc-context/build/build.json'},policy:{defaultMode:'advisory',unmatchedPathPolicy:'warn-allow'},modules,unmapped:{allowedGlobs:['*']}};
fs.writeFileSync(outputPath, `${JSON.stringify(manifest)}\n`);
NODE
  printf '{}\n' > "$build_output"
  printf '# Agent Instructions\n\nThis repo ships deep architectural context generated by EDC.\n\nSee [`edc-context/index.md`](edc-context/index.md).\nSee [`edc-context/manifest.json`](edc-context/manifest.json).\n' > "$agents_output"
  exit 0
fi

if [[ "$prompt" == *"AUDIT WORKER TASK"* ]]; then
  report_path=$(printf '%s\n' "$prompt" | grep '^AUDIT_REPORT_PATH: ' | head -1 | sed 's/^AUDIT_REPORT_PATH: //')
  mkdir -p "$(dirname "$report_path")"
  printf '## Module audit\n\nMock audit.\n' > "$report_path"
  exit 0
fi

if [[ "$prompt" == *"AUDIT SYNTHESIS TASK"* ]]; then
  if [[ "$prompt" == *"OCTOCODE_STATUS:"* ]]; then
    echo "MOCK ERROR: synthesis prompt received source-research capability guidance" >&2
    exit 31
  fi
  complexity=$(printf '%s\n' "$prompt" | grep '^CANONICAL_COMPLEXITY_REPORT: ' | head -1 | sed 's/^CANONICAL_COMPLEXITY_REPORT: //')
  issues=$(printf '%s\n' "$prompt" | grep '^CANONICAL_ISSUES_REPORT: ' | head -1 | sed 's/^CANONICAL_ISSUES_REPORT: //')
  mkdir -p "$(dirname "$complexity")" "$(dirname "$issues")"
  printf '## Summary\n\nMock complexity.\n' > "$complexity"
  printf '## Known Issues\n\nMock issues.\n' > "$issues"
  exit 0
fi

# Order matters: prompts now embed full SKILL.md content. The update skill
# references "edc-build" too, so check update FIRST via its unique heading.
if [[ "$prompt" == *"name: edc-update-impl"* ]] || [[ "$prompt" == *"# Update Context"* ]]; then
  echo "update" >> "$LOG"
  head=$(git rev-parse HEAD)
  sed -i.bak 's/"sourceCommit":"[^"]*"/"sourceCommit":"'"$head"'"/' edc-context/manifest.json
  rm -f edc-context/manifest.json.bak
  exit 0
fi

if [[ "$prompt" == *"name: edc-build-impl"* ]] || [[ "$prompt" == *"# Build Context"* ]]; then
  echo "build" >> "$LOG"
  agents_target="AGENTS.md"
  if grep -qx 'EDC_AGENTS_TARGET: EDC_AGENTS.md' <<< "$prompt"; then
    agents_target="EDC_AGENTS.md"
  fi
  mkdir -p edc-context/modules edc-context/reports edc-context/build
  printf '<!-- t12 -->\n# Stub\n\n## Module Map\n\n- root\n' > edc-context/index.md
  head=$(git rev-parse HEAD)
  cat > edc-context/manifest.json <<EOF
{"schemaVersion":2,"sourceCommit":"$head","modules":[{"name":"root","doc":"edc-context/modules/root.md","match":{"prefixes":["src/"]}}],"unmapped":{"allowedGlobs":["*"]},"policy":{"defaultMode":"advisory","unmatchedPathPolicy":"warn-allow"},"repoContextFile":"edc-context/index.md","reports":{"issues":"edc-context/reports/issues.md","complexity":"edc-context/reports/complexity.md"},"build":{"buildInfoFile":"edc-context/build/build.json"},"coverage":{"mappedFileCount":0,"unmappedFileCount":0,"ambiguousPathCount":0}}
EOF
  printf '<!-- t12 -->\n# root\n\n## Files\n\n- src.py\n' > edc-context/modules/root.md
  printf '## Known Issues\n' > edc-context/reports/issues.md
  printf '## Summary\n' > edc-context/reports/complexity.md
  printf '{}' > edc-context/build/build.json
  printf '# Agent Instructions\n\nThis repo ships deep architectural context generated by EDC.\n\nSee [`edc-context/index.md`](edc-context/index.md).\nSee [`edc-context/manifest.json`](edc-context/manifest.json).\n' > "$agents_target"
  exit 0
fi

if [[ "$prompt" == *"name: edc-context-curator-edit-impl"* ]]; then
  echo "curator-edit" >> "$LOG"
  exit 0
fi

if [[ "$prompt" == *"edc-context-curator-impl"* ]] || [[ "$prompt" == *"Context Curator"* ]]; then
  echo "curator" >> "$LOG"
  mkdir -p edc-context/reports
  printf '# Context Curation Report\n\n## Summary\n- t12 curator\n' > edc-context/reports/context-curation.md
  exit 0
fi

echo "MOCK ERROR: unrecognized prompt: $prompt" >&2
exit 1
MOCK
chmod +x "$MOCK_BIN/claude"
cat > "$MOCK_BIN/octocode" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] || exit 2
printf 'octocode v-test\n'
MOCK
chmod +x "$MOCK_BIN/octocode"

context_semantic_digest() {
  node -e '
    const crypto = require("crypto");
    const fs = require("fs");
    const path = require("path");
    const files = [];
    const walk = (dir) => {
      for (const name of fs.readdirSync(dir).sort()) {
        const file = path.join(dir, name);
        if (fs.statSync(file).isDirectory()) walk(file); else files.push(file);
      }
    };
    walk("edc-context");
    const hash = crypto.createHash("sha256");
    for (const file of files) {
      const relative = path.relative("edc-context", file);
      if (relative === "build/last-run.json") continue;
      hash.update(relative);
      if (file.endsWith("manifest.json")) {
        const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
        delete manifest.generatedAt;
        delete manifest.sourceCommit;
        hash.update(JSON.stringify(manifest));
      } else {
        hash.update(fs.readFileSync(file));
      }
    }
    process.stdout.write(hash.digest("hex"));
  '
}

setup_repo() {
  rm -rf "$TMPDIR_T12/repo"
  mkdir -p "$TMPDIR_T12/repo/src"
  cd "$TMPDIR_T12/repo"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email "t@t.com"
  git config user.name "T"
  git config commit.gpgsign false
  echo "src" > src/main.py
  git add src/main.py
  git commit -q -m "init"
  echo "" > "$TMPDIR_T12/log"
}

write_healthy_v2() {
  mkdir -p edc-context/modules edc-context/reports edc-context/build
  head=$(git rev-parse HEAD)
  cat > edc-context/manifest.json <<EOF
{"schemaVersion":2,"sourceCommit":"$head","modules":[{"name":"root","doc":"edc-context/modules/root.md","match":{"prefixes":["src/"]}}],"unmapped":{"allowedGlobs":["*"]},"policy":{"defaultMode":"advisory","unmatchedPathPolicy":"warn-allow"},"repoContextFile":"edc-context/index.md","reports":{"issues":"edc-context/reports/issues.md","complexity":"edc-context/reports/complexity.md"},"build":{"buildInfoFile":"edc-context/build/build.json"},"coverage":{"mappedFileCount":0,"unmappedFileCount":0,"ambiguousPathCount":0}}
EOF
  printf '<!-- t12 -->\n# Stub\n\n## Module Map\n\n- root\n' > edc-context/index.md
  printf '<!-- t12 -->\n# root\n\n## Files\n\n- src.py\n' > edc-context/modules/root.md
  printf '## Known Issues\n' > edc-context/reports/issues.md
  printf '## Summary\n' > edc-context/reports/complexity.md
  printf '{}' > edc-context/build/build.json
  printf '# Agent Instructions\n\nThis repo ships deep architectural context generated by EDC.\n\nSee [`edc-context/index.md`](edc-context/index.md).\nSee [`edc-context/manifest.json`](edc-context/manifest.json).\n' > AGENTS.md
}

export PATH="$MOCK_BIN:$PATH"
export EDC_AGENT_CLI=claude
export EDC_T12_LOG="$TMPDIR_T12/log"
export EDC_T12_MODULE_PROMPT_LOG="$TMPDIR_T12/module-prompt"
export EDC_T12_MANIFEST_CONCURRENCY_LOG="$TMPDIR_T12/manifest-concurrency"

# ── 12a: no edc-context/ → BUILD path ───────────────────────────────────────────
setup_repo
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12a): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "build" "$EDC_T12_LOG" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "build" && j.exitCode === 0 && j.reasonCode === "success" && Array.isArray(j.outputs) && j.outputs.includes("edc-context/manifest.json") && Array.isArray(j.checks) && j.checks.some(c => c.name === "edc-doctor" && c.status === "success") ? 0 : 1)'; then
  echo "PASS: no edc-context/ → BUILD"
else
  echo "FAIL (12a): expected 'build' action, log:"; cat "$EDC_T12_LOG"; exit 1
fi
if grep -qF 'OCTOCODE_STATUS: available' "$EDC_T12_MODULE_PROMPT_LOG" \
  && grep -qF 'octocode tools localViewStructure --queries' "$EDC_T12_MODULE_PROMPT_LOG" \
  && grep -qF 'octocode tools localSearchCode --queries' "$EDC_T12_MODULE_PROMPT_LOG"; then
  echo "PASS: build module worker receives coordinator-detected Octocode guidance"
else
  echo "FAIL: build module worker missing coordinator-detected Octocode guidance"
  exit 1
fi

# ── 12b: healthy v2, no --force → UPDATE path ────────────────────────────────
setup_repo
write_healthy_v2
# add a new commit so HEAD differs (more realistic — though update mock just refreshes commit)
echo "more" > src/extra.py && git add src/extra.py && git commit -q -m "more"
echo "" > "$EDC_T12_LOG"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12b): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "update" "$EDC_T12_LOG" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "build" && j.exitCode === 0 && j.reasonCode === "success" ? 0 : 1)'; then
  echo "PASS: healthy v2 → UPDATE"
else
  echo "FAIL (12b): expected 'update' action, log:"; cat "$EDC_T12_LOG"; exit 1
fi

# ── 12c: healthy v2, --force → wipe + BUILD ──────────────────────────────────
setup_repo
write_healthy_v2
echo "" > "$EDC_T12_LOG"
result=0
out=$(bash "$SCRIPT" --force 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12c): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "build" "$EDC_T12_LOG"; then
  echo "PASS: healthy v2 + --force → BUILD"
else
  echo "FAIL (12c): expected 'build' action, log:"; cat "$EDC_T12_LOG"; exit 1
fi

# ── 12d: partial v2 (manifest missing) → wipe + BUILD ────────────────────────
setup_repo
mkdir -p edc-context/modules
printf '# stub\n' > edc-context/modules/foo.md
echo "" > "$EDC_T12_LOG"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12d): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "build" "$EDC_T12_LOG"; then
  echo "PASS: partial v2 → BUILD"
else
  echo "FAIL (12d): expected 'build' action, log:"; cat "$EDC_T12_LOG"; exit 1
fi

# ── 12e: missing AGENTS.md → wipe + BUILD (not update) ─────────────────
setup_repo
write_healthy_v2
rm -f AGENTS.md
echo "" > "$EDC_T12_LOG"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12e/missing-agents): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "build" "$EDC_T12_LOG"; then
  echo "PASS: missing AGENTS.md → BUILD (not update)"
else
  echo "FAIL (12e/missing-agents): expected 'build' action, log:"; cat "$EDC_T12_LOG"; exit 1
fi

# ── 12f: existing user AGENTS.md → safe EDC_AGENTS.md default ───────────────
setup_repo
printf '# Existing Instructions\n\nkeep this\n' > AGENTS.md
echo "" > "$EDC_T12_LOG"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12f/existing-agents-safe): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "build" "$EDC_T12_LOG" \
  && [ -f EDC_AGENTS.md ] \
  && grep -q 'keep this' AGENTS.md \
  && ! grep -q 'EDC_AGENTS.md' AGENTS.md \
  && grep -q 'edc-context/index.md' EDC_AGENTS.md \
  && echo "$out" | grep -q 'replace AGENTS.md with EDC_AGENTS.md' \
  && echo "$out" | grep -q 'append the relevant EDC section' \
  && echo "$out" | grep -q 'reference from AGENTS.md / CLAUDE.md'; then
  echo "PASS: existing AGENTS.md → EDC_AGENTS.md with user instructions"
else
  echo "FAIL (12f/existing-agents-safe): expected preserved AGENTS.md plus EDC_AGENTS.md and user instructions"
  echo "--- out ---"; echo "$out"
  echo "--- AGENTS.md ---"; cat AGENTS.md 2>/dev/null || true
  echo "--- EDC_AGENTS.md ---"; cat EDC_AGENTS.md 2>/dev/null || true
  exit 1
fi

# ── 12g: existing user AGENTS.md + overwrite override → AGENTS.md ───────────
setup_repo
printf '# Existing Instructions\n\nreplace this\n' > AGENTS.md
echo "" > "$EDC_T12_LOG"
result=0
out=$(EDC_AGENTS_MODE=overwrite bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12g/existing-agents-overwrite): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "build" "$EDC_T12_LOG" \
  && [ ! -f EDC_AGENTS.md ] \
  && grep -q 'edc-context/index.md' AGENTS.md \
  && ! grep -q 'replace this' AGENTS.md; then
  echo "PASS: existing AGENTS.md + overwrite → AGENTS.md"
else
  echo "FAIL (12g/existing-agents-overwrite): expected AGENTS.md overwrite"
  echo "--- out ---"; echo "$out"
  echo "--- AGENTS.md ---"; cat AGENTS.md 2>/dev/null || true
  echo "--- EDC_AGENTS.md ---"; cat EDC_AGENTS.md 2>/dev/null || true
  exit 1
fi

# ── 12h: v1 layout → REFUSE with migration hint ──────────────────────────────
setup_repo
mkdir -p edc-context
printf '{}' > edc-context/.meta.json     # v1 marker
echo "" > "$EDC_T12_LOG"
result=0
out=$(bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ]; then
  echo "FAIL (12h): expected non-zero exit on v1 layout, got 0"; echo "$out"; exit 1
fi
if echo "$out" | grep -q "legacy v1" && echo "$out" | grep -q "rm -rf edc-context" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "build" && j.exitCode === 12 && j.reasonCode === "legacy-v1-layout" ? 0 : 1)'; then
  echo "PASS: v1 layout refused with migration hint"
else
  echo "FAIL (12h): expected migration hint mentioning 'legacy v1' and 'rm -rf edc-context'"
  echo "$out"; exit 1
fi
# also assert the agent was NOT spawned (log only contains the empty-line
# we wrote at setup; no "build" or "update" entries)
if grep -qE '^(build|update)$' "$EDC_T12_LOG"; then
  echo "FAIL (12h): agent was spawned despite v1 detection:"
  cat "$EDC_T12_LOG"; exit 1
fi

# ── 12i: coordinator fans out module work at the configured bound ───────────
setup_repo
result=0
out=$(EDC_T12_PARALLEL=1 EDC_PARALLEL=1 EDC_MAX_CONCURRENCY=2 bash "$SCRIPT" 2>&1) || result=$?
max_overlap=$(sort -nr .git/t12-overlap 2>/dev/null | head -1 || echo 0)
module_docs=$(find edc-context/modules -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 0 ] && [ "$max_overlap" -eq 2 ] && [ "$module_docs" -eq 3 ] && ! grep -R -qE '(^|[[:space:]])(pi|claude|codex)[[:space:]].*(--print|-p|exec)' .git/edc/runs/*/prompts; then
  echo "PASS: build coordinator owns bounded three-module fanout"
else
  echo "FAIL (12i): expected bounded three-module coordinator fanout. exit=$result overlap=$max_overlap docs=$module_docs"
  echo "$out"
  exit 1
fi
parallel_digest=$(context_semantic_digest)
rm -rf "$TMPDIR_T12/parallel-context"
cp -R edc-context "$TMPDIR_T12/parallel-context"

# ── 12j: absent opt-in stays serial and preserves the validated layout ──────
setup_repo
rm -f "$EDC_T12_MANIFEST_CONCURRENCY_LOG"
result=0
out=$(env -u EDC_PARALLEL EDC_T12_PARALLEL=1 EDC_MAX_CONCURRENCY=2 bash "$SCRIPT" 2>&1) || result=$?
serial_overlap=$(sort -nr .git/t12-overlap 2>/dev/null | head -1 || echo 0)
serial_digest=$(context_semantic_digest 2>/dev/null || true)
serial_manifest_concurrency=$(cat "$EDC_T12_MANIFEST_CONCURRENCY_LOG" 2>/dev/null || true)
if [ "$result" -eq 0 ] && [ "$serial_overlap" -eq 1 ] && [ "$serial_manifest_concurrency" = "1" ] && [ "$serial_digest" = "$parallel_digest" ]; then
  echo "PASS: absent EDC_PARALLEL ignores legacy max concurrency and preserves the parallel build layout"
else
  echo "FAIL (12j): default serial and opt-in parallel build layouts differ. exit=$result overlap=$serial_overlap manifest=$serial_manifest_concurrency"
  echo "$out"
  diff -ru "$TMPDIR_T12/parallel-context" edc-context || true
  exit 1
fi

# ── 12k: failed module blocks assembly and canonical promotion ──────────────
setup_repo
result=0
out=$(EDC_T12_PARALLEL=1 EDC_T12_FAIL_MODULE=lib EDC_PARALLEL=1 EDC_MAX_CONCURRENCY=2 bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ] && [ ! -f edc-context/manifest.json ] && [ ! -f edc-context/index.md ] && [ ! -d edc-context/modules ] && echo "$out" | grep -q 'coordinator-owned edc-build dag failed'; then
  echo "PASS: failed build module blocks canonical promotion"
else
  echo "FAIL (12k): module failure should leave canonical context absent. exit=$result"
  echo "$out"
  find edc-context -maxdepth 3 -type f 2>/dev/null || true
  exit 1
fi

# ── 12l: build cohort containment runs before canonical promotion ───────────
setup_repo
result=0
out=$(EDC_T12_MUTATE_MODULE=root bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ] && [ ! -f edc-context/manifest.json ] && echo "$out" | grep -q 'forbidden paths changed during the build worker dag' && echo "$out" | grep -q 'src/main.py'; then
  echo "PASS: build worker mutation blocks canonical promotion"
else
  echo "FAIL (12l): build worker mutation should fail containment before promotion. exit=$result"
  echo "$out"
  exit 1
fi

# ── 12m: duplicate discovery modules fail before fanout ─────────────────────
setup_repo
result=0
out=$(EDC_T12_DISCOVERY_MODE=duplicate bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ] && [ ! -f edc-context/manifest.json ] && echo "$out" | grep -qi 'duplicate'; then
  echo "PASS: duplicate discovery modules fail deterministically"
else
  echo "FAIL (12m): duplicate module plan should fail before promotion. exit=$result"
  echo "$out"
  exit 1
fi

# ── 12n: undeclared module docs fail before canonical promotion ─────────────
setup_repo
result=0
out=$(EDC_T12_EXTRA_MODULE_OUTPUT=1 bash "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ] && [ ! -f edc-context/manifest.json ] && echo "$out" | grep -q 'unexpected module output'; then
  echo "PASS: undeclared module output blocks canonical promotion"
else
  echo "FAIL (12n): undeclared module output should fail before promotion. exit=$result"
  echo "$out"
  find edc-context -maxdepth 3 -type f 2>/dev/null || true
  exit 1
fi

cd "$ORIG_DIR"
echo ""
echo "All T12 checks passed."
