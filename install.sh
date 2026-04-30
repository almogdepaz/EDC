#!/bin/bash
# EDC — Every Day Carry Skills installer
# Legacy usage:
#   curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s cursor
# Local/runtime-mode usage:
#   bash install.sh --agent claude --context-mode advisory|inject

set -euo pipefail

REPO="almogdepaz/EDC"
BRANCH="main"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PLUGIN_ROOT="$SCRIPT_DIR/plugins/edc"

AGENT=""
CONTEXT_MODE=""

usage() {
  cat <<EOF
Usage:
  curl -fsSL $BASE/install.sh | bash -s <agent>
  bash install.sh --agent claude --context-mode advisory|inject

Agents: claude, cursor, codex, gemini
EOF
}

die() {
  echo "edc: $*" >&2
  exit 1
}

not_implemented() {
  echo "edc: $1 not yet implemented" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      [ "$#" -ge 2 ] || die "--agent requires a value"
      AGENT="$2"
      shift 2
      ;;
    --context-mode)
      [ "$#" -ge 2 ] || die "--context-mode requires a value"
      CONTEXT_MODE="$2"
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

if [ -n "$CONTEXT_MODE" ]; then
  case "$CONTEXT_MODE" in
    advisory|inject) ;;
    *) die "--context-mode must be advisory or inject" ;;
  esac
fi

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

set_manifest_mode() {
  local mode="$1"
  local manifest=".context/manifest.json"
  [ -f "$manifest" ] || die ".context/manifest.json not found in $(pwd)"
  command -v jq > /dev/null 2>&1 || die "jq is required to update .context/manifest.json"
  local tmp
  tmp="$(mktemp)"
  jq --arg mode "$mode" '.policy.defaultMode = $mode' "$manifest" > "$tmp"
  mv "$tmp" "$manifest"
}

install_claude_runtime() {
  local mode="$1"
  local target="$HOME/.claude/plugins/edc"
  local hooks_target="$target/hooks/hooks.json"

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
    copy_or_download "plugins/edc/hooks/session-start.mjs" "$target/hooks/session-start.mjs"
    copy_or_download "plugins/edc/hooks/pretooluse-context-inject.mjs" "$target/hooks/pretooluse-context-inject.mjs"
    copy_or_download "plugins/edc/scripts/edc-review.sh" "$target/scripts/edc-review.sh"
    copy_or_download "plugins/edc/scripts/edc-route.sh" "$target/scripts/edc-route.sh"
  fi

  if [ "$mode" = "inject" ]; then
    cat > "$hooks_target" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.mjs\""
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/pretooluse-context-inject.mjs\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF
  else
    cat > "$hooks_target" <<'EOF'
{
  "hooks": {}
}
EOF
  fi

  set_manifest_mode "$mode"
  echo "Installed EDC Claude runtime in $target ($mode mode)."
}

case "$AGENT" in
  claude)
    if [ -z "$CONTEXT_MODE" ]; then
      echo "For Claude Code, use the marketplace:"
      echo "  claude plugins marketplace add $REPO"
      echo "  claude plugins install edc@edc"
      exit 0
    fi
    install_claude_runtime "$CONTEXT_MODE"
    ;;

  cursor)
    if [ -n "$CONTEXT_MODE" ]; then
      not_implemented "cursor/$CONTEXT_MODE"
    fi
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
    if [ -n "$CONTEXT_MODE" ]; then
      not_implemented "codex/$CONTEXT_MODE"
    fi
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

  gemini)
    if [ -n "$CONTEXT_MODE" ]; then
      not_implemented "gemini/$CONTEXT_MODE"
    fi
    TARGET="$HOME/.gemini/skills"
    echo "Installing EDC skills globally for Gemini..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/$(skill_rel "$f")"
    done
    echo "Done. Skills at $TARGET/"
    ;;

  *)
    die "unknown agent: $AGENT (supported: claude, cursor, codex, gemini)"
    ;;
esac
