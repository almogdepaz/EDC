#!/bin/bash
# Install EDC skills into a Cursor project
# Usage: ./install.sh <project-dir>

set -e

PROJECT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "Installing EDC skills into $PROJECT for Cursor..."

mkdir -p "$PROJECT/.cursor/skills/deep-context-building/resources"
mkdir -p "$PROJECT/.cursor/skills/differential-review"
mkdir -p "$PROJECT/.cursor/commands"

# Copy shared skills
cp "$REPO_ROOT/skills/deep-context-building/SKILL.md" "$PROJECT/.cursor/skills/deep-context-building/"
cp "$REPO_ROOT/skills/deep-context-building/resources/"* "$PROJECT/.cursor/skills/deep-context-building/resources/"
cp "$REPO_ROOT/skills/differential-review/"* "$PROJECT/.cursor/skills/differential-review/"

# Copy cursor-specific commands
cp "$SCRIPT_DIR/.cursor/commands/"* "$PROJECT/.cursor/commands/"

echo "Done. EDC skills installed at $PROJECT/.cursor/"
