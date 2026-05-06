#!/bin/bash
# EDC — Every Day Carry Skills installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s <agent>
#   bash install.sh --agent <agent>
#
# Agents: claude, cursor, codex
#
# Runtime mode (advisory vs inject) is controlled by `.context/manifest.json`'s
# `policy.defaultMode` field. Flip it with: `edc mode advisory|inject`.

set -euo pipefail

REPO="almogdepaz/EDC"
BRANCH="main"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PLUGIN_ROOT="$SCRIPT_DIR/plugins/edc"

AGENT=""

usage() {
  cat <<EOF
Usage:
  curl -fsSL $BASE/install.sh | bash -s <agent>
  bash install.sh --agent <agent>

Agents: claude, cursor, codex

After install, toggle runtime mode in any repo with:
  edc mode advisory   # docs only (default), hooks no-op
  edc mode inject     # claude PreToolUse hook auto-injects module docs
EOF
}

die() {
  echo "edc: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      [ "$#" -ge 2 ] || die "--agent requires a value"
      AGENT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      if [ -n "$AGENT" ]; then
        die "unexpected argument: $1"
      fi
      AGENT="$1"
      shift
      ;;
  esac
done

[ -n "$AGENT" ] || {
  usage
  exit 1
}

SKILLS=(
  "plugins/edc/skills/edc-context/SKILL.md"
  "plugins/edc/skills/edc-context/resources/COMPLETENESS_CHECKLIST.md"
  "plugins/edc/skills/edc-context/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md"
  "plugins/edc/skills/edc-context/resources/OUTPUT_REQUIREMENTS.md"
  "plugins/edc/skills/edc-review-impl/SKILL.md"
  "plugins/edc/skills/edc-review-impl/methodology.md"
  "plugins/edc/skills/edc-review-impl/adversarial.md"
  "plugins/edc/skills/edc-review-impl/reporting.md"
  "plugins/edc/skills/edc-review-impl/patterns.md"
  "plugins/edc/skills/edc-build-impl/SKILL.md"
  "plugins/edc/skills/edc-update-impl/SKILL.md"
  "plugins/edc/skills/edc-audit-impl/SKILL.md"
)

download() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "$BASE/$src" -o "$dst"
}

copy_or_download() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$SCRIPT_DIR/$src" ]; then
    cp "$SCRIPT_DIR/$src" "$dst"
  else
    download "$src" "$dst"
  fi
}

copy_tree_or_fail() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  rm -rf "$dst"
  cp -R "$src" "$dst"
}

skill_rel() {
  echo "${1#plugins/edc/skills/}"
}

install_terminal_cli() {
  local scripts_target="$HOME/.edc/scripts"
  mkdir -p "$scripts_target"
  copy_or_download "scripts/edc"                            "$scripts_target/edc"
  copy_or_download "plugins/edc/scripts/edc-review.sh"      "$scripts_target/edc-review.sh"
  copy_or_download "plugins/edc/scripts/edc-doctor.sh"      "$scripts_target/edc-doctor.sh"
  copy_or_download "plugins/edc/scripts/edc-route.sh"       "$scripts_target/edc-route.sh"
  copy_or_download "plugins/edc/scripts/edc-manifest.sh"    "$scripts_target/edc-manifest.sh"
  copy_or_download "plugins/edc/scripts/edc-clean-slate.sh" "$scripts_target/edc-clean-slate.sh"
  chmod +x \
    "$scripts_target/edc" \
    "$scripts_target/edc-review.sh" \
    "$scripts_target/edc-doctor.sh" \
    "$scripts_target/edc-route.sh" \
    "$scripts_target/edc-manifest.sh" \
    "$scripts_target/edc-clean-slate.sh"
}

print_path_hint() {
  case ":$PATH:" in
    *":$HOME/.edc/scripts:"*) ;;
    *)
      echo
      echo "NOTE: $HOME/.edc/scripts is not on PATH. Add this to your shell rc to call 'edc' from anywhere:"
      echo "  export PATH=\"\$HOME/.edc/scripts:\$PATH\""
      ;;
  esac
}

install_claude_runtime() {
  local target="$HOME/.claude/plugins/edc"

  if [ -d "$LOCAL_PLUGIN_ROOT" ]; then
    mkdir -p "$HOME/.claude/plugins"
    copy_tree_or_fail "$LOCAL_PLUGIN_ROOT" "$target"
  else
    mkdir -p "$target/.claude-plugin" "$target/commands" "$target/hooks" "$target/scripts"
    copy_or_download "plugins/edc/.claude-plugin/plugin.json" "$target/.claude-plugin/plugin.json"
    copy_or_download "plugins/edc/commands/edc-build.md" "$target/commands/edc-build.md"
    copy_or_download "plugins/edc/commands/edc-update.md" "$target/commands/edc-update.md"
    copy_or_download "plugins/edc/commands/edc-audit.md" "$target/commands/edc-audit.md"
    copy_or_download "plugins/edc/commands/edc-review.md" "$target/commands/edc-review.md"
    copy_or_download "plugins/edc/commands/edc-run-review.md" "$target/commands/edc-run-review.md"
    copy_or_download "plugins/edc/commands/edc-doctor.md" "$target/commands/edc-doctor.md"
    copy_or_download "plugins/edc/hooks/hooks.json" "$target/hooks/hooks.json"
    copy_or_download "plugins/edc/hooks/session-start.mjs" "$target/hooks/session-start.mjs"
    copy_or_download "plugins/edc/hooks/pretooluse-context-inject.mjs" "$target/hooks/pretooluse-context-inject.mjs"
    copy_or_download "plugins/edc/scripts/edc-review.sh" "$target/scripts/edc-review.sh"
    copy_or_download "plugins/edc/scripts/edc-route.sh" "$target/scripts/edc-route.sh"
    copy_or_download "plugins/edc/scripts/edc-clean-slate.sh" "$target/scripts/edc-clean-slate.sh"
  fi

  install_terminal_cli
  echo "Installed EDC Claude runtime in $target."
  echo "Terminal CLI installed at $HOME/.edc/scripts/edc."
  echo "Runtime mode is read from .context/manifest.json (defaults to advisory)."
  echo "Flip with: edc mode inject"
  print_path_hint
}

case "$AGENT" in
  claude)
    install_claude_runtime
    ;;

  cursor)
    TARGET="$HOME/.cursor"
    SCRIPTS_TARGET="$HOME/.edc/scripts"
    echo "Installing EDC skills globally for Cursor..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/skills/$(skill_rel "$f")"
    done
    download "agents/cursor/.cursor/commands/edc-run-build.md" "$TARGET/commands/edc-run-build.md"
    download "agents/cursor/.cursor/commands/edc-run-review.md" "$TARGET/commands/edc-run-review.md"
    download "agents/cursor/.cursor/commands/edc-run-update.md" "$TARGET/commands/edc-run-update.md"
    download "agents/cursor/.cursor/commands/edc-run-audit.md" "$TARGET/commands/edc-run-audit.md"
    download "agents/cursor/.cursor/rules/edc-session-start.mdc" "$TARGET/rules/edc-session-start.mdc"
    download "scripts/edc" "$SCRIPTS_TARGET/edc"
    download "plugins/edc/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
    download "plugins/edc/scripts/edc-doctor.sh" "$SCRIPTS_TARGET/edc-doctor.sh"
    chmod +x "$SCRIPTS_TARGET/edc"
    chmod +x "$SCRIPTS_TARGET/edc-review.sh"
    chmod +x "$SCRIPTS_TARGET/edc-doctor.sh"
    echo "Done. Skills at $TARGET/skills/, commands at $TARGET/commands/, terminal CLI + orchestrator at $SCRIPTS_TARGET/"
    ;;

  codex)
    TARGET="$HOME/.codex/skills"
    SCRIPTS_TARGET="$HOME/.edc/scripts"
    echo "Installing EDC skills globally for Codex..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/$(skill_rel "$f")"
    done
    download "agents/codex/.codex/skills/edc-build/SKILL.md" "$TARGET/edc-build/SKILL.md"
    download "agents/codex/.codex/skills/edc-update/SKILL.md" "$TARGET/edc-update/SKILL.md"
    download "agents/codex/.codex/skills/edc-audit/SKILL.md" "$TARGET/edc-audit/SKILL.md"
    download "agents/codex/.codex/skills/edc-run-review/SKILL.md" "$TARGET/edc-run-review/SKILL.md"
    download "scripts/edc" "$SCRIPTS_TARGET/edc"
    download "plugins/edc/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
    download "plugins/edc/scripts/edc-doctor.sh" "$SCRIPTS_TARGET/edc-doctor.sh"
    chmod +x "$SCRIPTS_TARGET/edc"
    chmod +x "$SCRIPTS_TARGET/edc-review.sh"
    chmod +x "$SCRIPTS_TARGET/edc-doctor.sh"
    echo "Done. Skills at $TARGET/, terminal CLI + orchestrator at $SCRIPTS_TARGET/. Use \$edc-build, \$edc-update, \$edc-audit, or \$edc-run-review."
    ;;

  *)
    die "unknown agent: $AGENT (supported: claude, cursor, codex)"
    ;;
esac
