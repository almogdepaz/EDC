#!/bin/bash
# Install EDC skills for Cursor
# Usage: ./install.sh [--global (default) | --project <dir>]
#
# IMPORTANT: when adding/removing a skill file, update BOTH installers:
#   - the SKILLS array in ../../install.sh (remote `curl | bash` install)
#   - the explicit cp lines below (local clone install)
# Both enumerate files explicitly so adding a new file without registering
# it fails loudly in both paths instead of one.

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
mkdir -p "$TARGET/skills/edc-build-impl"
mkdir -p "$TARGET/skills/edc-update-impl"
mkdir -p "$TARGET/skills/edc-split-impl"
mkdir -p "$TARGET/skills/edc-audit-impl"
mkdir -p "$TARGET/commands"
mkdir -p "$SCRIPTS_TARGET"

cp "$SKILL_SRC/edc-context/SKILL.md" "$TARGET/skills/edc-context/"
cp "$SKILL_SRC/edc-context/resources/COMPLETENESS_CHECKLIST.md" "$TARGET/skills/edc-context/resources/"
cp "$SKILL_SRC/edc-context/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md" "$TARGET/skills/edc-context/resources/"
cp "$SKILL_SRC/edc-context/resources/OUTPUT_REQUIREMENTS.md" "$TARGET/skills/edc-context/resources/"
cp "$SKILL_SRC/edc-review-impl/SKILL.md" "$TARGET/skills/edc-review-impl/"
cp "$SKILL_SRC/edc-review-impl/methodology.md" "$TARGET/skills/edc-review-impl/"
cp "$SKILL_SRC/edc-review-impl/adversarial.md" "$TARGET/skills/edc-review-impl/"
cp "$SKILL_SRC/edc-review-impl/reporting.md" "$TARGET/skills/edc-review-impl/"
cp "$SKILL_SRC/edc-review-impl/patterns.md" "$TARGET/skills/edc-review-impl/"
cp "$SKILL_SRC/edc-build-impl/SKILL.md" "$TARGET/skills/edc-build-impl/"
cp "$SKILL_SRC/edc-update-impl/SKILL.md" "$TARGET/skills/edc-update-impl/"
cp "$SKILL_SRC/edc-split-impl/SKILL.md" "$TARGET/skills/edc-split-impl/"
cp "$SKILL_SRC/edc-audit-impl/SKILL.md" "$TARGET/skills/edc-audit-impl/"
cp "$SCRIPT_DIR/.cursor/commands/edc-run-build.md" "$TARGET/commands/"
cp "$SCRIPT_DIR/.cursor/commands/edc-run-review.md" "$TARGET/commands/"
cp "$SCRIPT_DIR/.cursor/commands/edc-run-update.md" "$TARGET/commands/"
cp "$SCRIPT_DIR/.cursor/commands/edc-run-split.md" "$TARGET/commands/"
cp "$SCRIPT_DIR/.cursor/commands/edc-run-audit.md" "$TARGET/commands/"
cp "$REPO_ROOT/plugins/edc/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
chmod +x "$SCRIPTS_TARGET/edc-review.sh"

echo "Done. Skills at $TARGET/skills/, commands at $TARGET/commands/, orchestrator at $SCRIPTS_TARGET/"
