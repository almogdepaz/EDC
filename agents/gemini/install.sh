#!/bin/bash
# Install EDC skills for Gemini CLI
# Usage: ./install.sh [--global | <project-dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_SRC="$REPO_ROOT/plugins/edc/skills"

if [ "$1" = "--global" ]; then
  TARGET="$HOME/.gemini/skills"
  echo "Installing EDC skills globally for Gemini at ~/.gemini/skills/..."
else
  PROJECT="${1:-.}"
  TARGET="$PROJECT/.gemini/skills"
  echo "Installing EDC skills into $PROJECT for Gemini..."
fi

mkdir -p "$TARGET/edc-context/resources"
mkdir -p "$TARGET/edc-review"

cp "$SKILL_SRC/edc-context/SKILL.md" "$TARGET/edc-context/"
cp "$SKILL_SRC/edc-context/resources/"* "$TARGET/edc-context/resources/"
cp "$SKILL_SRC/edc-review/"* "$TARGET/edc-review/"

echo "Done. Skills installed at $TARGET/"
