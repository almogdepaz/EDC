#!/bin/bash
# Install EDC skills for Gemini CLI
# Usage: ./install.sh [--global | <project-dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_SRC="$REPO_ROOT/plugins/edc/skills"

if [ "${1:-}" = "--context-mode" ]; then
  mode="${2:-}"
  case "$mode" in
    advisory|inject)
      echo "edc: gemini/$mode not yet implemented" >&2
      exit 2
      ;;
    *)
      echo "ERROR: --context-mode must be advisory or inject" >&2
      exit 2
      ;;
  esac
fi

if [ "$1" = "--global" ]; then
  TARGET="$HOME/.gemini/skills"
  SCRIPTS_TARGET="$HOME/.edc/scripts"
  echo "Installing EDC skills globally for Gemini at ~/.gemini/skills/..."
else
  PROJECT="${1:-.}"
  TARGET="$PROJECT/.gemini/skills"
  SCRIPTS_TARGET="$PROJECT/.edc/scripts"
  echo "Installing EDC skills into $PROJECT for Gemini..."
fi

mkdir -p "$TARGET/edc-context/resources"
mkdir -p "$TARGET/edc-review-impl"
mkdir -p "$TARGET/edc-build-impl"
mkdir -p "$TARGET/edc-update-impl"
mkdir -p "$TARGET/edc-audit-impl"
mkdir -p "$SCRIPTS_TARGET"

cp "$SKILL_SRC/edc-context/SKILL.md" "$TARGET/edc-context/"
cp "$SKILL_SRC/edc-context/resources/"* "$TARGET/edc-context/resources/"
cp "$SKILL_SRC/edc-review-impl/"* "$TARGET/edc-review-impl/"
cp "$SKILL_SRC/edc-build-impl/SKILL.md" "$TARGET/edc-build-impl/"
cp "$SKILL_SRC/edc-update-impl/SKILL.md" "$TARGET/edc-update-impl/"
cp "$SKILL_SRC/edc-audit-impl/SKILL.md" "$TARGET/edc-audit-impl/"
cp "$REPO_ROOT/scripts/edc" "$SCRIPTS_TARGET/"
cp "$REPO_ROOT/plugins/edc/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
cp "$REPO_ROOT/plugins/edc/scripts/edc-doctor.sh" "$SCRIPTS_TARGET/edc-doctor.sh"
chmod +x "$SCRIPTS_TARGET/edc" "$SCRIPTS_TARGET/edc-review.sh" "$SCRIPTS_TARGET/edc-doctor.sh"

echo "Done. Skills at $TARGET/, terminal CLI + orchestrator at $SCRIPTS_TARGET/"
