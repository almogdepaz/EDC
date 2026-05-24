#!/usr/bin/env bash
# Task 7 smoke test: terminal CLI wrapper for build/review
# Run from repo root: bash tests/hardening/t7-cli-entrypoint.sh
set -euo pipefail

SCRIPT="plugins/edc/scripts/edc"
SCRIPT_ABS="$(pwd)/plugins/edc/scripts/edc"
BASH_BIN="$(command -v bash)"
ROOT_INSTALL="install.sh"

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
  edc-build.sh)  bucket=build  ;;
  edc-review.sh) bucket=review ;;
  edc-audit.sh)  bucket=audit  ;;
  *)             bucket=other  ;;
esac
out="${EDC_TEST_CAPTURE_DIR:?}/$bucket"
mkdir -p "$out"
printf '%s\n' "${EDC_AGENT_CLI:-}" > "$out/agent"
printf '%s\n' "$1" > "$out/script"
shift
printf '%s\n' "$@" > "$out/args"
EOF
chmod +x "$FAKE_BIN/bash"

run_cli() {
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  EDC_BUILD_MODEL="t7-model" \
  EDC_REVIEW_MODEL="t7-model" \
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

# ── 7c: build delegates to edc-build.sh with EDC_AGENT_CLI + forwarded args ──
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

# ── 7f: review delegates to local orchestrator with EDC_AGENT_CLI ─────────────
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

rm -rf "$CAPTURE/review"
(cd "$PROJECT" && run_cli review --agent codex HEAD --base main --ignore generated/**)

if [ "$(cat "$CAPTURE/review/agent")" = "codex" ]; then
  echo "PASS: review exports EDC_AGENT_CLI to orchestrator"
else
  echo "FAIL: review did not export EDC_AGENT_CLI"
  exit 1
fi

if [ "$(cat "$CAPTURE/review/script")" = "$SCRIPT_DIR/edc-review.sh" ]; then
  echo "PASS: review invokes repo edc-review.sh"
else
  echo "FAIL: review invoked the wrong edc-review.sh"
  cat "$CAPTURE/review/script"
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
