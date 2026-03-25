#!/bin/bash
# Install EDC skills for Cursor
# Usage: ./install.sh [--global (default) | --project <dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_SRC="$REPO_ROOT/plugins/edc/skills"

if [ "$1" = "--project" ]; then
  TARGET="${2:-.}/.cursor"
  echo "Installing EDC skills into ${2:-.} for Cursor..."
else
  TARGET="$HOME/.cursor"
  echo "Installing EDC skills globally for Cursor at ~/.cursor/..."
fi

mkdir -p "$TARGET/skills/edc-context/resources"
mkdir -p "$TARGET/skills/edc-review"
mkdir -p "$TARGET/commands"

cp "$SKILL_SRC/edc-context/SKILL.md" "$TARGET/skills/edc-context/"
cp "$SKILL_SRC/edc-context/resources/"* "$TARGET/skills/edc-context/resources/"
cp "$SKILL_SRC/edc-review/"* "$TARGET/skills/edc-review/"
cp "$SCRIPT_DIR/.cursor/commands/"* "$TARGET/commands/"

echo "Done. Skills at $TARGET/skills/, commands at $TARGET/commands/"
