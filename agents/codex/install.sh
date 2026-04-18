#!/bin/bash
# Install EDC skills for Codex
# Usage: ./install.sh [--global (default) | --project <dir>]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_SRC="$REPO_ROOT/plugins/edc/skills"

if [ "$1" = "--project" ]; then
  PROJECT="${2:-.}"
  TARGET="$PROJECT/.codex/skills"
  SCRIPTS_TARGET="$PROJECT/.edc/scripts"
  echo "Installing EDC skills into $PROJECT for Codex..."
else
  PROJECT=""
  TARGET="$HOME/.codex/skills"
  SCRIPTS_TARGET="$HOME/.edc/scripts"
  echo "Installing EDC skills globally for Codex at ~/.codex/skills/..."
fi

mkdir -p "$TARGET/edc-context/resources"
mkdir -p "$TARGET/edc-review"
mkdir -p "$SCRIPTS_TARGET"

cp "$SKILL_SRC/edc-context/SKILL.md" "$TARGET/edc-context/"
cp "$SKILL_SRC/edc-context/resources/"* "$TARGET/edc-context/resources/"
cp "$SKILL_SRC/edc-review/"* "$TARGET/edc-review/"
cp "$REPO_ROOT/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
chmod +x "$SCRIPTS_TARGET/edc-review.sh"

echo "Done. Skills at $TARGET/, orchestrator at $SCRIPTS_TARGET/. Use \$edc-context or \$edc-review to invoke."
