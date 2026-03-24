#!/bin/bash
# Install EDC skills for Gemini CLI
# Usage: ./install.sh [--global | <project-dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "$1" = "--global" ]; then
  TARGET="$HOME/.gemini/skills"
  echo "Installing EDC skills globally for Gemini at ~/.gemini/skills/..."
else
  PROJECT="${1:-.}"
  TARGET="$PROJECT/.gemini/skills"
  echo "Installing EDC skills into $PROJECT for Gemini..."
fi

mkdir -p "$TARGET/deep-context-building/resources"
mkdir -p "$TARGET/differential-review"

cp "$REPO_ROOT/skills/deep-context-building/SKILL.md" "$TARGET/deep-context-building/"
cp "$REPO_ROOT/skills/deep-context-building/resources/"* "$TARGET/deep-context-building/resources/"
cp "$REPO_ROOT/skills/differential-review/"* "$TARGET/differential-review/"

echo "Done. Skills installed at $TARGET/"
