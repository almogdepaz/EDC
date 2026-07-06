#!/usr/bin/env bash
# Task 7 smoke test: terminal CLI wrapper for build/review
# Run from repo root: bash tests/hardening/t7-cli-entrypoint.sh
set -euo pipefail

SCRIPT="plugins/edc/scripts/edc"
SCRIPT_ABS="$(pwd)/plugins/edc/scripts/edc"
BASH_BIN="$(command -v bash)"
NODE_BIN="$(command -v node)"
NODE_DIR="$(dirname "$NODE_BIN")"
ROOT_INSTALL="install.sh"

echo "=== T7: CLI entrypoint ==="

if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT missing"
  exit 1
fi
echo "PASS: $SCRIPT exists"

if grep -q '^parse_agent_context_args()' "$SCRIPT" \
  && grep -q '^finalize_agent_context()' "$SCRIPT" \
  && [ "$(grep -c '^      --agent)' "$SCRIPT")" -le 1 ]; then
  echo "PASS: CLI shares agent/context option parsing"
else
  echo "FAIL: CLI still duplicates agent/context option parsing"
  exit 1
fi

if grep -q 'mktemp "${manifest}.tmp.XXXXXX"' "$SCRIPT"; then
  echo "PASS: edc mode temp file is created beside manifest for atomic rename"
else
  echo "FAIL: edc mode should create temp file beside manifest before mv"
  exit 1
fi

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
#!/bin/sh
set -eu
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
make_fake_agent pi

# Fake bash captures `bash <orchestrator-script> [args...]` invocations,
# bucketed by which orchestrator was invoked. Lets us assert that plugins/edc/scripts/edc
# delegates to the right deterministic orchestrator with the right env + args.
cat > "$FAKE_BIN/bash" <<'EOF'
#!/bin/sh
set -eu
script_name=$(basename "$1")
case "$script_name" in
  edc-build.sh)          bucket=build ;;
  edc-review.sh)         bucket=review ;;
  edc-review-all.sh)     bucket=review_all ;;
  edc-delivery-review.sh) bucket=delivery ;;
  edc-audit.sh)          bucket=audit ;;
  *)             bucket=other  ;;
esac
out="${EDC_TEST_CAPTURE_DIR:?}/$bucket"
mkdir -p "$out"
printf '%s\n' "${EDC_AGENT_CLI:-}" > "$out/agent"
printf '%s\n' "${EDC_BUILD_MODEL:-}" > "$out/build_model"
printf '%s\n' "${EDC_REVIEW_MODEL:-}" > "$out/review_model"
printf '%s\n' "${EDC_PI_MODEL:-}" > "$out/pi_model"
printf '%s\n' "$1" > "$out/script"
shift
printf '%s\n' "$@" > "$out/args"
EOF
chmod +x "$FAKE_BIN/bash"

run_cli() {
  PATH="$FAKE_BIN:$NODE_DIR:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  EDC_BUILD_MODEL="t7-model" \
  EDC_REVIEW_MODEL="t7-model" \
  EDC_TEST_CAPTURE_DIR="$CAPTURE" \
  "$BASH_BIN" "$SCRIPT_ABS" "$@"
}

run_cli_pi_model_only() {
  PATH="$FAKE_BIN:$NODE_DIR:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  EDC_PI_MODEL="t7-pi-model" \
  EDC_TEST_CAPTURE_DIR="$CAPTURE" \
  "$BASH_BIN" "$SCRIPT_ABS" "$@"
}

eval "$(awk '/^find_script\(\)/{found=1} found{print} /^}$/{if(found){exit}}' "$SCRIPT")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_ABS")" && pwd)"

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

# ── 7b2: --agent mandatory for delivery-review ───────────────────────────────
set +e
delivery_output=$(cd "$PROJECT" && run_cli delivery-review HEAD 2>&1)
delivery_status=$?
set -e
if [ "$delivery_status" -eq 0 ]; then
  echo "FAIL: delivery-review succeeded without --agent"
  exit 1
fi
if echo "$delivery_output" | grep -q -- '--agent is required'; then
  echo "PASS: delivery-review rejects missing --agent"
else
  echo "FAIL: delivery-review missing-agent error unclear"
  echo "$delivery_output"
  exit 1
fi

# ── 7c: pi accepts EDC_PI_MODEL without phase model variables ───────────────
rm -rf "$CAPTURE/build"
run_cli_pi_model_only build "$PROJECT" --agent pi --force
if [ "$(cat "$CAPTURE/build/agent")" = "pi" ]; then
  echo "PASS: pi build accepts EDC_PI_MODEL-only configuration"
else
  echo "FAIL: pi build rejected EDC_PI_MODEL-only configuration"
  exit 1
fi

# ── 7c2: pi model slugs are forwarded exactly ───────────────────────────────
rm -rf "$CAPTURE/review_all"
(cd "$PROJECT" && run_cli --model gpt-5.5 review --agent pi HEAD --base main)
if [ "$(cat "$CAPTURE/review_all/review_model")" = "gpt-5.5" ]; then
  echo "PASS: pi review forwards model slug without mutation"
else
  echo "FAIL: pi review mutated model slug"
  cat "$CAPTURE/review_all/review_model"
  exit 1
fi

# ── 7d: build delegates to edc-build.sh with EDC_AGENT_CLI + forwarded args ──
#
# Per-agent CLI dispatch (claude -p / cursor agent -p / codex exec) lives in
# edc-spawn.sh and is exercised end-to-end by t6/t7-codex with real mocks.
# Here we only check that plugins/edc/scripts/edc routes to the orchestrator correctly.

for agent in claude cursor codex pi; do
  rm -rf "$CAPTURE/build"
  run_cli build "$PROJECT" --agent "$agent" --force --ignore generated/**

  if [ "$(cat "$CAPTURE/build/agent")" != "$agent" ]; then
    echo "FAIL: $agent build did not export EDC_AGENT_CLI=$agent"
    cat "$CAPTURE/build/agent"
    exit 1
  fi

  case "$(cat "$CAPTURE/build/script")" in
    */edc-build.sh) ;;
    *)
      echo "FAIL: $agent build did not invoke edc-build.sh"
      cat "$CAPTURE/build/script"
      exit 1
      ;;
  esac

  if grep -Fx -- '--force' "$CAPTURE/build/args" >/dev/null \
    && grep -Fx -- '--ignore' "$CAPTURE/build/args" >/dev/null \
    && grep -Fx -- 'generated/**' "$CAPTURE/build/args" >/dev/null; then
    : # ok
  else
    echo "FAIL: $agent build did not forward --force / --ignore"
    cat "$CAPTURE/build/args"
    exit 1
  fi
done
echo "PASS: build delegates to edc-build.sh with EDC_AGENT_CLI + forwarded args (claude/cursor/codex/pi)"

# ── 7f: review/security-review delegation ───────────────────────────────────
mkdir -p "$PROJECT/.edc/scripts"
cat > "$PROJECT/.edc/scripts/edc-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stale project copy"
EOF
chmod +x "$PROJECT/.edc/scripts/edc-review.sh"

# The wrapper should prefer the sibling script next to itself over a stale
# project-local .edc/scripts copy when invoked from the repo checkout.
selected_review_script="$(cd "$PROJECT" && find_script edc-review.sh)"
if [ "$selected_review_script" = "$SCRIPT_DIR/edc-review.sh" ]; then
  echo "PASS: wrapper prefers sibling edc-review.sh over stale project copy"
else
  echo "FAIL: wrapper selected stale project .edc/scripts/edc-review.sh"
  echo "$selected_review_script"
  exit 1
fi

rm -rf "$CAPTURE/review_all"
(cd "$PROJECT" && run_cli review --agent codex HEAD --base main --ignore generated/**)

if [ "$(cat "$CAPTURE/review_all/agent")" = "codex" ]; then
  echo "PASS: review exports EDC_AGENT_CLI to combined orchestrator"
else
  echo "FAIL: review did not export EDC_AGENT_CLI"
  exit 1
fi

# Repos with an existing manifest default to policy.defaultMode. Advisory mode
# must not block non-Claude backends from reaching the deterministic review
# orchestrator.
mkdir -p "$PROJECT/edc-context"
printf '{"policy":{"defaultMode":"advisory"}}\n' > "$PROJECT/edc-context/manifest.json"
rm -rf "$CAPTURE/review_all"
(cd "$PROJECT" && run_cli review --agent pi HEAD --base main --ignore generated/**)
if [ "$(cat "$CAPTURE/review_all/agent")" = "pi" ]; then
  echo "PASS: review allows pi with manifest advisory mode"
else
  echo "FAIL: pi review was blocked before orchestrator dispatch"
  exit 1
fi

if [ "$(cat "$CAPTURE/review_all/script")" = "$SCRIPT_DIR/edc-review-all.sh" ]; then
  echo "PASS: review invokes repo edc-review-all.sh"
else
  echo "FAIL: review invoked the wrong review orchestrator"
  cat "$CAPTURE/review_all/script"
  exit 1
fi

if grep -Fx -- 'HEAD' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- '--base' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- 'main' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- '--ignore' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- 'generated/**' "$CAPTURE/review_all/args" >/dev/null; then
  echo "PASS: review forwards target and base args to combined orchestrator"
else
  echo "FAIL: review args not forwarded correctly"
  cat "$CAPTURE/review_all/args"
  exit 1
fi

# ── 7f1b: explicit security-review delegates to security orchestrator ───────
rm -rf "$CAPTURE/review"
(cd "$PROJECT" && run_cli security-review --agent codex HEAD --base main)
if [ "$(cat "$CAPTURE/review/agent")" = "codex" ] \
  && [ "$(cat "$CAPTURE/review/script")" = "$SCRIPT_DIR/edc-review.sh" ] \
  && grep -Fx -- 'HEAD' "$CAPTURE/review/args" >/dev/null \
  && grep -Fx -- '--base' "$CAPTURE/review/args" >/dev/null \
  && grep -Fx -- 'main' "$CAPTURE/review/args" >/dev/null; then
  echo "PASS: security-review invokes repo edc-review.sh with args"
else
  echo "FAIL: security-review did not delegate correctly"
  cat "$CAPTURE/review/agent" "$CAPTURE/review/script" "$CAPTURE/review/args" 2>/dev/null || true
  exit 1
fi

# ── 7f1c: review-all delegates to combined orchestrator with args ───────────
rm -rf "$CAPTURE/review_all"
(cd "$PROJECT" && run_cli review-all --agent codex HEAD --base main --ignore generated/**)
if [ "$(cat "$CAPTURE/review_all/agent")" = "codex" ] \
  && [ "$(cat "$CAPTURE/review_all/script")" = "$SCRIPT_DIR/edc-review-all.sh" ] \
  && grep -Fx -- 'HEAD' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- '--base' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- 'main' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- '--ignore' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- 'generated/**' "$CAPTURE/review_all/args" >/dev/null; then
  echo "PASS: review-all invokes repo edc-review-all.sh with args"
else
  echo "FAIL: review-all did not delegate correctly"
  cat "$CAPTURE/review_all/agent" "$CAPTURE/review_all/script" "$CAPTURE/review_all/args" 2>/dev/null || true
  exit 1
fi

# ── 7f1d: quality-review delegates to audit orchestrator; audit stays alias ─
rm -rf "$CAPTURE/audit"
(cd "$PROJECT" && run_cli quality-review --agent codex --ignore generated/**)
if [ "$(cat "$CAPTURE/audit/agent")" = "codex" ] \
  && [ "$(cat "$CAPTURE/audit/script")" = "$SCRIPT_DIR/edc-audit.sh" ] \
  && grep -Fx -- '--ignore' "$CAPTURE/audit/args" >/dev/null \
  && grep -Fx -- 'generated/**' "$CAPTURE/audit/args" >/dev/null; then
  echo "PASS: quality-review invokes repo edc-audit.sh with args"
else
  echo "FAIL: quality-review did not delegate correctly"
  cat "$CAPTURE/audit/agent" "$CAPTURE/audit/script" "$CAPTURE/audit/args" 2>/dev/null || true
  exit 1
fi

rm -rf "$CAPTURE/audit"
(cd "$PROJECT" && run_cli audit --agent codex)
if [ "$(cat "$CAPTURE/audit/script")" = "$SCRIPT_DIR/edc-audit.sh" ]; then
  echo "PASS: audit remains deprecated alias for quality-review"
else
  echo "FAIL: audit alias did not delegate to edc-audit.sh"
  exit 1
fi

rm -rf "$CAPTURE/audit"
(cd "$PROJECT" && run_cli quality-review --agent codex --diff origin/main...HEAD)
if grep -Fx -- 'HEAD' "$CAPTURE/audit/args" >/dev/null \
  && grep -Fx -- '--base' "$CAPTURE/audit/args" >/dev/null \
  && grep -Fx -- 'origin/main' "$CAPTURE/audit/args" >/dev/null; then
  echo "PASS: quality-review --diff normalizes to target and base args"
else
  echo "FAIL: quality-review --diff did not normalize correctly"
  cat "$CAPTURE/audit/args" 2>/dev/null || true
  exit 1
fi

# ── 7f1e: --diff normalizes to target + --base for diff-capable reviews ─────
rm -rf "$CAPTURE/review_all"
(cd "$PROJECT" && run_cli review --agent codex --diff origin/main...HEAD --ignore generated/**)
if grep -Fx -- 'HEAD' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- '--base' "$CAPTURE/review_all/args" >/dev/null \
  && grep -Fx -- 'origin/main' "$CAPTURE/review_all/args" >/dev/null; then
  echo "PASS: review --diff normalizes to target and base args"
else
  echo "FAIL: review --diff did not normalize correctly"
  cat "$CAPTURE/review_all/args"
  exit 1
fi

rm -rf "$CAPTURE/review"
(cd "$PROJECT" && run_cli security-review --agent codex --diff origin/main...HEAD)
if grep -Fx -- 'HEAD' "$CAPTURE/review/args" >/dev/null \
  && grep -Fx -- '--base' "$CAPTURE/review/args" >/dev/null \
  && grep -Fx -- 'origin/main' "$CAPTURE/review/args" >/dev/null; then
  echo "PASS: security-review --diff normalizes to target and base args"
else
  echo "FAIL: security-review --diff did not normalize correctly"
  cat "$CAPTURE/review/args"
  exit 1
fi

set +e
conflict_output=$(cd "$PROJECT" && run_cli review --agent codex --full HEAD --base main 2>&1)
conflict_status=$?
set -e
if [ "$conflict_status" -ne 0 ] && echo "$conflict_output" | grep -q -- '--full cannot be combined'; then
  echo "PASS: conflicting review scope args are rejected"
else
  echo "FAIL: conflicting review scope args were not rejected clearly"
  echo "$conflict_output"
  exit 1
fi

# ── 7f2: delivery-review delegates to local orchestrator with args ───────────
rm -rf "$CAPTURE/delivery"
(cd "$PROJECT" && run_cli delivery-review --agent codex HEAD --base main)
if [ "$(cat "$CAPTURE/delivery/agent")" = "codex" ] \
  && [ "$(cat "$CAPTURE/delivery/script")" = "$SCRIPT_DIR/edc-delivery-review.sh" ] \
  && grep -Fx -- 'HEAD' "$CAPTURE/delivery/args" >/dev/null \
  && grep -Fx -- '--base' "$CAPTURE/delivery/args" >/dev/null \
  && grep -Fx -- 'main' "$CAPTURE/delivery/args" >/dev/null; then
  echo "PASS: delivery-review invokes repo edc-delivery-review.sh with args"
else
  echo "FAIL: delivery-review did not delegate correctly"
  cat "$CAPTURE/delivery/agent" "$CAPTURE/delivery/script" "$CAPTURE/delivery/args" 2>/dev/null || true
  exit 1
fi

# ── 7g: root install ships shared CLI + auto-generates cursor/codex wrappers ─
if grep -q 'install_terminal_cli' "$ROOT_INSTALL" \
  && grep -q 'write_cursor_commands' "$ROOT_INSTALL" \
  && grep -q 'write_codex_skills' "$ROOT_INSTALL"; then
  echo "PASS: install ships shared CLI + generates cursor/codex wrappers"
else
  echo "FAIL: install missing terminal-cli or wrapper-generation hooks"
  exit 1
fi

echo ""
echo "All T7 checks passed."
