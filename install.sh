#!/bin/bash
# EDC — Every Day Carry Skills installer
# Usage: curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s <agent>
# Agents: cursor, codex, gemini (claude uses marketplace)

set -e

REPO="almogdepaz/EDC"
BRANCH="main"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
AGENT="${1:-}"

if [ -z "$AGENT" ]; then
  echo "Usage: curl -fsSL $BASE/install.sh | bash -s <agent>"
  echo ""
  echo "Agents: cursor, codex, gemini"
  echo "For Claude Code: claude plugins marketplace add $REPO && claude plugins install edc@edc"
  exit 1
fi

# Canonical skill files.
# IMPORTANT: when adding/removing a skill file, update BOTH lists:
#   - this SKILLS array (used by `curl | bash` remote install)
#   - agents/cursor/install.sh (used by local clone install)
# The two installers intentionally enumerate files explicitly so adding a new
# file without registering it fails loudly in both paths instead of one.
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
  "plugins/edc/skills/edc-split-impl/SKILL.md"
  "plugins/edc/skills/edc-audit-impl/SKILL.md"
)

download() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "$BASE/$src" -o "$dst"
}

# Strip prefix to get relative skill path for destination
skill_rel() {
  echo "${1#plugins/edc/skills/}"
}

case "$AGENT" in
  claude)
    echo "For Claude Code, use the marketplace:"
    echo "  claude plugins marketplace add $REPO"
    echo "  claude plugins install edc@edc"
    exit 0
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
    download "agents/cursor/.cursor/commands/edc-run-split.md" "$TARGET/commands/edc-run-split.md"
    download "agents/cursor/.cursor/commands/edc-run-audit.md" "$TARGET/commands/edc-run-audit.md"
    download "agents/cursor/.cursor/rules/edc-session-start.mdc" "$TARGET/rules/edc-session-start.mdc"
    download "scripts/edc" "$SCRIPTS_TARGET/edc"
    download "plugins/edc/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
    chmod +x "$SCRIPTS_TARGET/edc"
    chmod +x "$SCRIPTS_TARGET/edc-review.sh"
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
    download "agents/codex/.codex/skills/edc-split/SKILL.md" "$TARGET/edc-split/SKILL.md"
    download "agents/codex/.codex/skills/edc-audit/SKILL.md" "$TARGET/edc-audit/SKILL.md"
    download "agents/codex/.codex/skills/edc-run-review/SKILL.md" "$TARGET/edc-run-review/SKILL.md"
    download "scripts/edc" "$SCRIPTS_TARGET/edc"
    download "plugins/edc/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
    chmod +x "$SCRIPTS_TARGET/edc"
    chmod +x "$SCRIPTS_TARGET/edc-review.sh"
    echo "Done. Skills at $TARGET/, terminal CLI + orchestrator at $SCRIPTS_TARGET/. Use \$edc-build, \$edc-update, \$edc-split, \$edc-audit, or \$edc-run-review."
    ;;

  gemini)
    TARGET="$HOME/.gemini/skills"
    echo "Installing EDC skills globally for Gemini..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/$(skill_rel "$f")"
    done
    echo "Done. Skills at $TARGET/"
    ;;

  *)
    echo "Unknown agent: $AGENT"
    echo "Supported: cursor, codex, gemini (claude uses marketplace)"
    exit 1
    ;;
esac
