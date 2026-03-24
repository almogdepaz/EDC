#!/bin/bash
# Install EDC skills for Cursor
# Usage: ./install.sh [--global (default) | --project <dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

cp "$REPO_ROOT/skills/edc-context/SKILL.md" "$TARGET/skills/edc-context/"
cp "$REPO_ROOT/skills/edc-context/resources/"* "$TARGET/skills/edc-context/resources/"
cp "$REPO_ROOT/skills/edc-review/"* "$TARGET/skills/edc-review/"
cp "$SCRIPT_DIR/.cursor/commands/"* "$TARGET/commands/"

echo "Done. Skills at $TARGET/skills/, commands at $TARGET/commands/"
