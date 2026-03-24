#!/bin/bash
# EDC — Every Day Carry Skills installer
# Usage: curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s <agent>
# Agents: cursor, codex, gemini (claude uses marketplace)

set -e

REPO="almogdepaz/edc"
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

# Shared skill files to download
SKILLS=(
  "skills/deep-context-building/SKILL.md"
  "skills/deep-context-building/resources/COMPLETENESS_CHECKLIST.md"
  "skills/deep-context-building/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md"
  "skills/deep-context-building/resources/OUTPUT_REQUIREMENTS.md"
  "skills/differential-review/SKILL.md"
  "skills/differential-review/methodology.md"
  "skills/differential-review/adversarial.md"
  "skills/differential-review/reporting.md"
  "skills/differential-review/patterns.md"
)

download() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "$BASE/$src" -o "$dst"
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
      download "$f" "$TARGET/$f"
    done
    download "agents/cursor/.cursor/commands/build-context.md" "$TARGET/commands/build-context.md"
    download "agents/cursor/.cursor/commands/review.md" "$TARGET/commands/review.md"
    echo "Done. Skills at $TARGET/skills/, commands at $TARGET/commands/"
    ;;

  codex)
    TARGET="$HOME/.codex/skills"
    echo "Installing EDC skills globally for Codex..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/${f#skills/}"
    done
    echo "Done. Use \$deep-context-building or \$differential-review to invoke."
    ;;

  gemini)
    TARGET="$HOME/.gemini/skills"
    echo "Installing EDC skills globally for Gemini..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/${f#skills/}"
    done
    echo "Done. Skills at $TARGET/"
    ;;

  *)
    echo "Unknown agent: $AGENT"
    echo "Supported: cursor, codex, gemini (claude uses marketplace)"
    exit 1
    ;;
esac
