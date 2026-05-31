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

if [ -n "${EDC_BASH:-}" ]; then
  export PATH="$(dirname "$EDC_BASH"):$PATH"
fi

ORIG_DIR="$(pwd)"
SCRIPT="$ORIG_DIR/plugins/edc/scripts/edc-build.sh"
TMPDIR_T12=$(mktemp -d)
MOCK_BIN="$TMPDIR_T12/bin"
trap 'rm -rf "$TMPDIR_T12"' EXIT

echo "=== T12: build orchestrator (mocked agent) ==="

# ── mock claude that records which action it was asked to perform ────────────
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
prompt=$(cat)
LOG="${EDC_T12_LOG:?}"

# Order matters: prompts now embed full SKILL.md content. The update skill
# references "edc-build" too, so check update FIRST via its unique heading.
if [[ "$prompt" == *"name: edc-update-impl"* ]] || [[ "$prompt" == *"# Update Context"* ]]; then
  echo "update" >> "$LOG"
  head=$(git rev-parse HEAD)
  sed -i.bak 's/"sourceCommit":"[^"]*"/"sourceCommit":"'"$head"'"/' edc-context/manifest.json
  rm -f edc-context/manifest.json.bak
  exit 0
fi

if [[ "$prompt" == *"edc-build"* ]]; then
  echo "build" >> "$LOG"
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
  printf '# Repo\n\nSee edc-context/index.md\n' > AGENTS.md
  exit 0
fi

echo "MOCK ERROR: unrecognized prompt: $prompt" >&2
exit 1
MOCK
chmod +x "$MOCK_BIN/claude"

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
  printf '# Repo\n\nSee edc-context/index.md\n' > AGENTS.md
}

export PATH="$MOCK_BIN:$PATH"
export EDC_AGENT_CLI=claude
export EDC_T12_LOG="$TMPDIR_T12/log"

# ── 12a: no edc-context/ → BUILD path ───────────────────────────────────────────
setup_repo
result=0
out=$("${EDC_BASH:-bash}" "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12a): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "build" "$EDC_T12_LOG"; then
  echo "PASS: no edc-context/ → BUILD"
else
  echo "FAIL (12a): expected 'build' action, log:"; cat "$EDC_T12_LOG"; exit 1
fi

# ── 12b: healthy v2, no --force → UPDATE path ────────────────────────────────
setup_repo
write_healthy_v2
# add a new commit so HEAD differs (more realistic — though update mock just refreshes commit)
echo "more" > src/extra.py && git add src/extra.py && git commit -q -m "more"
echo "" > "$EDC_T12_LOG"
result=0
out=$("${EDC_BASH:-bash}" "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12b): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "update" "$EDC_T12_LOG"; then
  echo "PASS: healthy v2 → UPDATE"
else
  echo "FAIL (12b): expected 'update' action, log:"; cat "$EDC_T12_LOG"; exit 1
fi

# ── 12c: healthy v2, --force → wipe + BUILD ──────────────────────────────────
setup_repo
write_healthy_v2
echo "" > "$EDC_T12_LOG"
result=0
out=$("${EDC_BASH:-bash}" "$SCRIPT" --force 2>&1) || result=$?
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
out=$("${EDC_BASH:-bash}" "$SCRIPT" 2>&1) || result=$?
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
out=$("${EDC_BASH:-bash}" "$SCRIPT" 2>&1) || result=$?
if [ "$result" -ne 0 ]; then
  echo "FAIL (12e/missing-agents): orchestrator exited $result"
  echo "$out"; exit 1
fi
if grep -qx "build" "$EDC_T12_LOG"; then
  echo "PASS: missing AGENTS.md → BUILD (not update)"
else
  echo "FAIL (12e/missing-agents): expected 'build' action, log:"; cat "$EDC_T12_LOG"; exit 1
fi

# ── 12f: v1 layout → REFUSE with migration hint ──────────────────────────────
setup_repo
mkdir -p edc-context
printf '{}' > edc-context/.meta.json     # v1 marker
echo "" > "$EDC_T12_LOG"
result=0
out=$("${EDC_BASH:-bash}" "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ]; then
  echo "FAIL (12f): expected non-zero exit on v1 layout, got 0"; echo "$out"; exit 1
fi
if echo "$out" | grep -q "legacy v1" && echo "$out" | grep -q "rm -rf edc-context"; then
  echo "PASS: v1 layout refused with migration hint"
else
  echo "FAIL (12f): expected migration hint mentioning 'legacy v1' and 'rm -rf edc-context'"
  echo "$out"; exit 1
fi
# also assert the agent was NOT spawned (log only contains the empty-line
# we wrote at setup; no "build" or "update" entries)
if grep -qE '^(build|update)$' "$EDC_T12_LOG"; then
  echo "FAIL (12f): agent was spawned despite v1 detection:"
  cat "$EDC_T12_LOG"; exit 1
fi

cd "$ORIG_DIR"
echo ""
echo "All T12 checks passed."
