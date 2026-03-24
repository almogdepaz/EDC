#!/bin/bash
# Install EDC skills for Codex
# Usage: ./install.sh [--global (default) | --project <dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "$1" = "--project" ]; then
  TARGET="${2:-.}/.codex/skills"
  echo "Installing EDC skills into ${2:-.} for Codex..."
else
  TARGET="$HOME/.codex/skills"
  echo "Installing EDC skills globally for Codex at ~/.codex/skills/..."
fi

mkdir -p "$TARGET/edc-context/resources"
mkdir -p "$TARGET/edc-review"

cp "$REPO_ROOT/skills/edc-context/SKILL.md" "$TARGET/edc-context/"
cp "$REPO_ROOT/skills/edc-context/resources/"* "$TARGET/edc-context/resources/"
cp "$REPO_ROOT/skills/edc-review/"* "$TARGET/edc-review/"

echo "Done. Use \$edc-context or \$edc-review to invoke."
