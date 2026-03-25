#!/bin/bash
# Install EDC skills for Codex
# Usage: ./install.sh [--global (default) | --project <dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_SRC="$REPO_ROOT/plugins/edc/skills"

if [ "$1" = "--project" ]; then
  TARGET="${2:-.}/.codex/skills"
  echo "Installing EDC skills into ${2:-.} for Codex..."
else
  TARGET="$HOME/.codex/skills"
  echo "Installing EDC skills globally for Codex at ~/.codex/skills/..."
fi

mkdir -p "$TARGET/edc-context/resources"
mkdir -p "$TARGET/edc-review"

cp "$SKILL_SRC/edc-context/SKILL.md" "$TARGET/edc-context/"
cp "$SKILL_SRC/edc-context/resources/"* "$TARGET/edc-context/resources/"
cp "$SKILL_SRC/edc-review/"* "$TARGET/edc-review/"

echo "Done. Use \$edc-context or \$edc-review to invoke."
