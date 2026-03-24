#!/bin/bash
# Install EDC skills for Codex
# Usage: ./install.sh [--global | <project-dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "$1" = "--global" ]; then
  TARGET="$HOME/.codex/skills"
  echo "Installing EDC skills globally for Codex at ~/.codex/skills/..."
else
  PROJECT="${1:-.}"
  TARGET="$PROJECT/.codex/skills"
  echo "Installing EDC skills into $PROJECT for Codex..."
fi

mkdir -p "$TARGET/deep-context-building/resources"
mkdir -p "$TARGET/differential-review"

cp "$REPO_ROOT/skills/deep-context-building/SKILL.md" "$TARGET/deep-context-building/"
cp "$REPO_ROOT/skills/deep-context-building/resources/"* "$TARGET/deep-context-building/resources/"
cp "$REPO_ROOT/skills/differential-review/"* "$TARGET/differential-review/"

echo "Done. Use \$deep-context-building or \$differential-review to invoke."
