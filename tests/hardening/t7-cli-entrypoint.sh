#!/usr/bin/env bash
# Task 7 smoke test: terminal CLI wrapper for build/review
# Run from repo root: bash tests/hardening/t7-cli-entrypoint.sh
set -euo pipefail

SCRIPT="scripts/edc"
SCRIPT_ABS="$(pwd)/scripts/edc"
ROOT_INSTALL="install.sh"
CURSOR_INSTALL="agents/cursor/install.sh"
CODEX_INSTALL="agents/codex/install.sh"

echo "=== T7: CLI entrypoint ==="

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT missing"
  exit 1
fi
echo "PASS: $SCRIPT exists"

TMPDIR_T7=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T7"' EXIT

FAKE_BIN="$TMPDIR_T7/bin"
FAKE_HOME="$TMPDIR_T7/home"
PROJECT="$TMPDIR_T7/project"
CAPTURE="$TMPDIR_T7/capture"
mkdir -p "$FAKE_BIN" "$FAKE_HOME" "$PROJECT" "$CAPTURE"

make_fake_agent() {
  local name="$1"
  cat > "$FAKE_BIN/$name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
out="${EDC_TEST_CAPTURE_DIR:?}/$name"
mkdir -p "$out"
printf '%s\n' "$PWD" > "$out/cwd"
printf '%s\n' "$@" > "$out/args"
cat > "$out/stdin"
EOF
  chmod +x "$FAKE_BIN/$name"
}

make_fake_agent claude
make_fake_agent cursor
make_fake_agent codex

run_cli() {
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  EDC_TEST_CAPTURE_DIR="$CAPTURE" \
  bash "$SCRIPT_ABS" "$@"
}

# ── 7a: --agent mandatory for build ───────────────────────────────────────────
set +e
build_output=$(run_cli build "$PROJECT" 2>&1)
build_status=$?
set -e
if [ "$build_status" -eq 0 ]; then
  echo "FAIL: build succeeded without --agent"
  exit 1
fi
if echo "$build_output" | grep -q -- '--agent is required'; then
  echo "PASS: build rejects missing --agent"
else
  echo "FAIL: build missing-agent error unclear"
  echo "$build_output"
  exit 1
fi

# ── 7b: --agent mandatory for review ──────────────────────────────────────────
set +e
review_output=$(cd "$PROJECT" && run_cli review HEAD 2>&1)
review_status=$?
set -e
if [ "$review_status" -eq 0 ]; then
  echo "FAIL: review succeeded without --agent"
  exit 1
fi
if echo "$review_output" | grep -q -- '--agent is required'; then
  echo "PASS: review rejects missing --agent"
else
  echo "FAIL: review missing-agent error unclear"
  echo "$review_output"
  exit 1
fi

# ── 7c: claude build dispatches slash command prompt ──────────────────────────
rm -rf "$CAPTURE/claude"
run_cli build "$PROJECT" --agent claude --force --ignore generated/**

if [ "$(cat "$CAPTURE/claude/cwd")" = "$PROJECT" ]; then
  echo "PASS: claude build runs in target project"
else
  echo "FAIL: claude build cwd mismatch"
  exit 1
fi

if grep -Fx -- '-p' "$CAPTURE/claude/args" >/dev/null \
  && grep -Fx -- '--allowed-tools' "$CAPTURE/claude/args" >/dev/null; then
  echo "PASS: claude build passes expected CLI flags"
else
  echo "FAIL: claude build flags missing"
  cat "$CAPTURE/claude/args"
  exit 1
fi

if grep -q '^/edc:edc-build --force --ignore generated/\*\*$' "$CAPTURE/claude/stdin"; then
  echo "PASS: claude build prompt uses slash command wrapper"
else
  echo "FAIL: claude build prompt incorrect"
  cat "$CAPTURE/claude/stdin"
  exit 1
fi

# ── 7d: cursor build dispatches installed skill content ───────────────────────
mkdir -p "$FAKE_HOME/.cursor/skills/edc-build-impl"
cat > "$FAKE_HOME/.cursor/skills/edc-build-impl/SKILL.md" <<'EOF'
CURSOR_BUILD_SKILL
EOF

rm -rf "$CAPTURE/cursor"
run_cli build --agent cursor "$PROJECT" --focus parser --ignore generated/**

if [ "$(cat "$CAPTURE/cursor/cwd")" = "$PROJECT" ]; then
  echo "PASS: cursor build runs in target project"
else
  echo "FAIL: cursor build cwd mismatch"
  exit 1
fi

if grep -Fx -- 'agent' "$CAPTURE/cursor/args" >/dev/null \
  && grep -Fx -- '-p' "$CAPTURE/cursor/args" >/dev/null \
  && grep -Fx -- '--force' "$CAPTURE/cursor/args" >/dev/null \
  && grep -Fx -- '--trust' "$CAPTURE/cursor/args" >/dev/null; then
  echo "PASS: cursor build passes expected CLI flags"
else
  echo "FAIL: cursor build flags missing"
  cat "$CAPTURE/cursor/args"
  exit 1
fi

if grep -q 'use these CLI arguments: --focus parser --ignore generated/\*\*' "$CAPTURE/cursor/stdin" \
  && grep -q 'name: edc-build-impl' "$CAPTURE/cursor/stdin"; then
  echo "PASS: cursor build prompt includes args and skill content"
else
  echo "FAIL: cursor build prompt incorrect"
  cat "$CAPTURE/cursor/stdin"
  exit 1
fi

# ── 7e: codex build dispatches installed skill content ────────────────────────
mkdir -p "$FAKE_HOME/.codex/skills/edc-build-impl"
cat > "$FAKE_HOME/.codex/skills/edc-build-impl/SKILL.md" <<'EOF'
CODEX_BUILD_SKILL
EOF

rm -rf "$CAPTURE/codex"
run_cli build --agent codex "$PROJECT" --force --ignore generated/**

if [ "$(cat "$CAPTURE/codex/cwd")" = "$PROJECT" ]; then
  echo "PASS: codex build runs in target project"
else
  echo "FAIL: codex build cwd mismatch"
  exit 1
fi

if grep -Fx -- 'exec' "$CAPTURE/codex/args" >/dev/null \
  && grep -Fx -- '--sandbox' "$CAPTURE/codex/args" >/dev/null \
  && grep -Fx -- 'workspace-write' "$CAPTURE/codex/args" >/dev/null \
  && grep -Fx -- '-' "$CAPTURE/codex/args" >/dev/null; then
  echo "PASS: codex build passes expected CLI flags"
else
  echo "FAIL: codex build flags missing"
  cat "$CAPTURE/codex/args"
  exit 1
fi

if grep -q 'use these CLI arguments: --force --ignore generated/\*\*' "$CAPTURE/codex/stdin" \
  && grep -q 'name: edc-build-impl' "$CAPTURE/codex/stdin"; then
  echo "PASS: codex build prompt includes args and skill content"
else
  echo "FAIL: codex build prompt incorrect"
  cat "$CAPTURE/codex/stdin"
  exit 1
fi

# ── 7f: review delegates to local orchestrator with EDC_AGENT_CLI ─────────────
mkdir -p "$PROJECT/.edc/scripts"
cat > "$PROJECT/.edc/scripts/edc-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="${EDC_TEST_CAPTURE_DIR:?}/review"
mkdir -p "$out"
printf '%s\n' "$EDC_AGENT_CLI" > "$out/agent"
printf '%s\n' "$@" > "$out/args"
EOF
chmod +x "$PROJECT/.edc/scripts/edc-review.sh"

rm -rf "$CAPTURE/review"
(cd "$PROJECT" && run_cli review --agent codex HEAD --base main --ignore generated/**)

if [ "$(cat "$CAPTURE/review/agent")" = "codex" ]; then
  echo "PASS: review exports EDC_AGENT_CLI to orchestrator"
else
  echo "FAIL: review did not export EDC_AGENT_CLI"
  exit 1
fi

if grep -Fx -- 'HEAD' "$CAPTURE/review/args" >/dev/null \
  && grep -Fx -- '--base' "$CAPTURE/review/args" >/dev/null \
  && grep -Fx -- 'main' "$CAPTURE/review/args" >/dev/null \
  && grep -Fx -- '--ignore' "$CAPTURE/review/args" >/dev/null \
  && grep -Fx -- 'generated/**' "$CAPTURE/review/args" >/dev/null; then
  echo "PASS: review forwards target and base args"
else
  echo "FAIL: review args not forwarded correctly"
  cat "$CAPTURE/review/args"
  exit 1
fi

# ── 7g: install scripts copy the shared CLI ───────────────────────────────────
if grep -q 'scripts/edc' "$ROOT_INSTALL" \
  && grep -q 'cp "\$REPO_ROOT/scripts/edc"' "$CURSOR_INSTALL" \
  && grep -q 'cp "\$REPO_ROOT/scripts/edc"' "$CODEX_INSTALL"; then
  echo "PASS: install scripts copy the shared CLI"
else
  echo "FAIL: install scripts do not copy the shared CLI"
  exit 1
fi

echo ""
echo "All T7 checks passed."
