#!/bin/bash
# Install EDC skills for Cursor
# Usage: ./install.sh [--global (default) | --project <dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_SRC="$REPO_ROOT/plugins/edc/skills"

if [ "$1" = "--project" ]; then
  PROJECT="${2:-.}"
  TARGET="$PROJECT/.cursor"
  SCRIPTS_TARGET="$PROJECT/.edc/scripts"
  echo "Installing EDC skills into $PROJECT for Cursor..."
else
  PROJECT=""
  TARGET="$HOME/.cursor"
  SCRIPTS_TARGET="$HOME/.edc/scripts"
  echo "Installing EDC skills globally for Cursor at ~/.cursor/..."
fi

mkdir -p "$TARGET/skills/edc-context/resources"
mkdir -p "$TARGET/skills/edc-review-impl"
mkdir -p "$TARGET/commands"
mkdir -p "$SCRIPTS_TARGET"

cp "$SKILL_SRC/edc-context/SKILL.md" "$TARGET/skills/edc-context/"
cp "$SKILL_SRC/edc-context/resources/"* "$TARGET/skills/edc-context/resources/"
cp "$SKILL_SRC/edc-review-impl/"* "$TARGET/skills/edc-review-impl/"
cp "$SCRIPT_DIR/.cursor/commands/"* "$TARGET/commands/"
cp "$REPO_ROOT/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
chmod +x "$SCRIPTS_TARGET/edc-review.sh"

echo "Done. Skills at $TARGET/skills/, commands at $TARGET/commands/, orchestrator at $SCRIPTS_TARGET/"
