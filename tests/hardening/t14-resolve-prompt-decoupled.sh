#!/usr/bin/env bash
# t14-resolve-prompt-decoupled: pin the contract that resolve_prompt is
# self-contained — emits SKILL.md content for all agents, never slash
# commands like `/edc:edc-build`. This guarantees the CLI works without
# any agent-side plugin/slash-command system installed.
#
# Also pins that review prompts embed the FULL skill bundle inline
# (SKILL.md + methodology + adversarial + reporting + patterns) so the
# subagent has zero room to improvise its own methodology.
#
# Run from repo root: bash tests/hardening/t14-resolve-prompt-decoupled.sh
set -uo pipefail

SCRIPT="plugins/edc/scripts/edc-lib.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

# shellcheck source=lib/check.sh
. "$(dirname "$0")/lib/check.sh"
check_init

echo "=== T14: resolve_prompt CLI/plugin decoupling ==="

# Set up a hermetic skills tree so we don't depend on the user's install state.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SKILLS_DIR="$TMP/skills"
mkdir -p "$SKILLS_DIR/edc-build-impl" "$SKILLS_DIR/edc-update-impl" \
         "$SKILLS_DIR/edc-audit" "$SKILLS_DIR/edc-review"

echo "BUILD_SKILL_MARKER" > "$SKILLS_DIR/edc-build-impl/SKILL.md"
echo "UPDATE_SKILL_MARKER" > "$SKILLS_DIR/edc-update-impl/SKILL.md"
echo "AUDIT_SKILL_MARKER" > "$SKILLS_DIR/edc-audit/SKILL.md"
echo "REVIEW_SKILL_MARKER" > "$SKILLS_DIR/edc-review/SKILL.md"
echo "METHODOLOGY_MARKER" > "$SKILLS_DIR/edc-review/methodology.md"
echo "ADVERSARIAL_MARKER" > "$SKILLS_DIR/edc-review/adversarial.md"
echo "REPORTING_MARKER" > "$SKILLS_DIR/edc-review/reporting.md"
echo "PATTERNS_MARKER" > "$SKILLS_DIR/edc-review/patterns.md"

TASK_FILE="$TMP/task.md"
echo "TASK_CONTENT_MARKER" > "$TASK_FILE"

# Override HOME so find_*_skill resolves into our hermetic tree.
# All three agents look at $HOME/.<runtime>/skills (claude also at .edc/skills)
# or $HOME/.edc/skills. Symlink each into our temp tree.
mkdir -p "$TMP/home"
ln -s "$SKILLS_DIR" "$TMP/home/.edc-skills-real"
mkdir -p "$TMP/home/.edc" "$TMP/home/.cursor" "$TMP/home/.codex"
ln -s "$TMP/home/.edc-skills-real" "$TMP/home/.edc/skills"
ln -s "$TMP/home/.edc-skills-real" "$TMP/home/.cursor/skills"
ln -s "$TMP/home/.edc-skills-real" "$TMP/home/.codex/skills"

run_resolve() {
  local agent="$1"; shift
  HOME="$TMP/home" EDC_AGENT_CLI="$agent" \
    bash -c ". $PWD/$SCRIPT && resolve_prompt $*" 2>&1
}

# ── 14.1: claude branch never emits slash commands ──────────────────────────
for action in build update audit; do
  out=$(run_resolve claude "$action")
  if echo "$out" | grep -q '^/edc:'; then
    check "claude $action: no slash command in output" 0
    echo "  output preview: $(echo "$out" | head -3)"
  else
    check "claude $action: no slash command in output" 1
  fi
done

# review prompt should also not contain slash commands
out=$(run_resolve claude review "$TASK_FILE")
if echo "$out" | grep -q '/edc:'; then
  check "claude review: no slash command in output" 0
else
  check "claude review: no slash command in output" 1
fi

# ── 14.2: claude branch emits skill content for build/update/audit ──────────
for action_skill in "build:BUILD_SKILL_MARKER" \
                    "update:UPDATE_SKILL_MARKER" \
                    "audit:AUDIT_SKILL_MARKER"; do
  action="${action_skill%%:*}"
  marker="${action_skill##*:}"
  out=$(run_resolve claude "$action")
  if echo "$out" | grep -qF "$marker"; then
    check "claude $action: emits SKILL.md content ($marker)" 1
  else
    check "claude $action: emits SKILL.md content ($marker)" 0
  fi
done

# ── 14.3: build/update arg-string forwarding ────────────────────────────────
out=$(run_resolve claude build --force --focus broker)
if echo "$out" | grep -qF "CLI ARGUMENTS: --force --focus broker"; then
  check "claude build: arg-string prefixed when args provided" 1
else
  check "claude build: arg-string prefixed when args provided" 0
fi

out=$(run_resolve claude build)
if echo "$out" | grep -q "CLI ARGUMENTS:"; then
  check "claude build: NO arg-string prefix when no args" 0
else
  check "claude build: NO arg-string prefix when no args" 1
fi

# ── 14.4: review prompt embeds the FULL skill bundle ────────────────────────
out=$(run_resolve claude review "$TASK_FILE")
for marker in "TASK_CONTENT_MARKER" \
              "REVIEW_SKILL_MARKER" \
              "METHODOLOGY_MARKER" \
              "ADVERSARIAL_MARKER" \
              "REPORTING_MARKER" \
              "PATTERNS_MARKER"; do
  if echo "$out" | grep -qF "$marker"; then
    check "claude review: embeds $marker" 1
  else
    check "claude review: embeds $marker" 0
  fi
done

# ── 14.5: review prompt has the strict no-improvise prefix ──────────────────
if echo "$out" | grep -qF "Do not improvise"; then
  check "claude review: includes 'Do not improvise' directive" 1
else
  check "claude review: includes 'Do not improvise' directive" 0
fi

# ── 14.6: cursor and codex follow the same contract ─────────────────────────
for agent in cursor codex; do
  for action_skill in "build:BUILD_SKILL_MARKER" \
                      "update:UPDATE_SKILL_MARKER" \
                      "audit:AUDIT_SKILL_MARKER"; do
    action="${action_skill%%:*}"
    marker="${action_skill##*:}"
    out=$(run_resolve "$agent" "$action")
    if echo "$out" | grep -qF "$marker"; then
      check "$agent $action: emits SKILL.md content ($marker)" 1
    else
      check "$agent $action: emits SKILL.md content ($marker)" 0
    fi
  done

  out=$(run_resolve "$agent" review "$TASK_FILE")
  all_present=1
  for marker in "TASK_CONTENT_MARKER" "REVIEW_SKILL_MARKER" \
                "METHODOLOGY_MARKER" "ADVERSARIAL_MARKER" \
                "REPORTING_MARKER" "PATTERNS_MARKER"; do
    echo "$out" | grep -qF "$marker" || all_present=0
  done
  check "$agent review: embeds full skill bundle (6 markers)" "$all_present"
done

# ── 14.7: missing skill produces clear error ────────────────────────────────
rm "$SKILLS_DIR/edc-build-impl/SKILL.md"
out=$(run_resolve claude build 2>&1 || true)
if echo "$out" | grep -q "skill 'edc-build-impl' not found"; then
  check "claude build: missing skill produces clear error" 1
else
  check "claude build: missing skill produces clear error" 0
fi

# ── 14.8: missing review supporting file produces clear error ───────────────
echo "REVIEW_SKILL_MARKER" > "$SKILLS_DIR/edc-review/SKILL.md"  # restore
echo "BUILD_SKILL_MARKER" > "$SKILLS_DIR/edc-build-impl/SKILL.md"   # restore
rm "$SKILLS_DIR/edc-review/methodology.md"
out=$(run_resolve claude review "$TASK_FILE" 2>&1 || true)
if echo "$out" | grep -q "review skill bundle incomplete"; then
  check "claude review: missing methodology.md produces clear error" 1
else
  check "claude review: missing methodology.md produces clear error" 0
fi

check_summary "T14"
