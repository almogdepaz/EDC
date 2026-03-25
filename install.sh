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

# Canonical skill files (single source of truth: plugins/edc/skills/)
SKILLS=(
  "plugins/edc/skills/edc-context/SKILL.md"
  "plugins/edc/skills/edc-context/resources/COMPLETENESS_CHECKLIST.md"
  "plugins/edc/skills/edc-context/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md"
  "plugins/edc/skills/edc-context/resources/OUTPUT_REQUIREMENTS.md"
  "plugins/edc/skills/edc-review/SKILL.md"
  "plugins/edc/skills/edc-review/methodology.md"
  "plugins/edc/skills/edc-review/adversarial.md"
  "plugins/edc/skills/edc-review/reporting.md"
  "plugins/edc/skills/edc-review/patterns.md"
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
    echo "Installing EDC skills globally for Cursor..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/skills/$(skill_rel "$f")"
    done
    download "agents/cursor/.cursor/commands/edc-run-build.md" "$TARGET/commands/edc-run-build.md"
    download "agents/cursor/.cursor/commands/edc-run-review.md" "$TARGET/commands/edc-run-review.md"
    echo "Done. Skills at $TARGET/skills/, commands at $TARGET/commands/"
    ;;

  codex)
    TARGET="$HOME/.codex/skills"
    echo "Installing EDC skills globally for Codex..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/$(skill_rel "$f")"
    done
    echo "Done. Use \$edc-context or \$edc-review to invoke."
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
