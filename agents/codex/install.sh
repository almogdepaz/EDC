#!/bin/bash
# Install EDC skills for Codex
# Usage: ./install.sh [--global (default) | --project <dir>]
#
# IMPORTANT: when adding/removing Codex wrapper skills, update BOTH installers:
#   - the explicit cp lines below
#   - the codex case in ../../install.sh
# Keep them aligned so local and remote installs expose the same user-facing
# Codex flow.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_SRC="$REPO_ROOT/plugins/edc/skills"
WRAPPER_SRC="$SCRIPT_DIR/.codex/skills"

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
mkdir -p "$TARGET/edc-review-impl"
mkdir -p "$TARGET/edc-build-impl"
mkdir -p "$TARGET/edc-update-impl"
mkdir -p "$TARGET/edc-split-impl"
mkdir -p "$TARGET/edc-audit-impl"
mkdir -p "$TARGET/edc-build"
mkdir -p "$TARGET/edc-update"
mkdir -p "$TARGET/edc-split"
mkdir -p "$TARGET/edc-audit"
mkdir -p "$TARGET/edc-run-review"
mkdir -p "$SCRIPTS_TARGET"

cp "$SKILL_SRC/edc-context/SKILL.md" "$TARGET/edc-context/"
cp "$SKILL_SRC/edc-context/resources/COMPLETENESS_CHECKLIST.md" "$TARGET/edc-context/resources/"
cp "$SKILL_SRC/edc-context/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md" "$TARGET/edc-context/resources/"
cp "$SKILL_SRC/edc-context/resources/OUTPUT_REQUIREMENTS.md" "$TARGET/edc-context/resources/"
cp "$SKILL_SRC/edc-review-impl/SKILL.md" "$TARGET/edc-review-impl/"
cp "$SKILL_SRC/edc-review-impl/methodology.md" "$TARGET/edc-review-impl/"
cp "$SKILL_SRC/edc-review-impl/adversarial.md" "$TARGET/edc-review-impl/"
cp "$SKILL_SRC/edc-review-impl/reporting.md" "$TARGET/edc-review-impl/"
cp "$SKILL_SRC/edc-review-impl/patterns.md" "$TARGET/edc-review-impl/"
cp "$SKILL_SRC/edc-build-impl/SKILL.md" "$TARGET/edc-build-impl/"
cp "$SKILL_SRC/edc-update-impl/SKILL.md" "$TARGET/edc-update-impl/"
cp "$SKILL_SRC/edc-split-impl/SKILL.md" "$TARGET/edc-split-impl/"
cp "$SKILL_SRC/edc-audit-impl/SKILL.md" "$TARGET/edc-audit-impl/"
cp "$WRAPPER_SRC/edc-build/SKILL.md" "$TARGET/edc-build/"
cp "$WRAPPER_SRC/edc-update/SKILL.md" "$TARGET/edc-update/"
cp "$WRAPPER_SRC/edc-split/SKILL.md" "$TARGET/edc-split/"
cp "$WRAPPER_SRC/edc-audit/SKILL.md" "$TARGET/edc-audit/"
cp "$WRAPPER_SRC/edc-run-review/SKILL.md" "$TARGET/edc-run-review/"
cp "$REPO_ROOT/scripts/edc" "$SCRIPTS_TARGET/"
cp "$REPO_ROOT/plugins/edc/scripts/edc-review.sh" "$SCRIPTS_TARGET/edc-review.sh"
chmod +x "$SCRIPTS_TARGET/edc"
chmod +x "$SCRIPTS_TARGET/edc-review.sh"

echo "Done. Skills at $TARGET/, terminal CLI + orchestrator at $SCRIPTS_TARGET/. Use \$edc-build, \$edc-update, \$edc-split, \$edc-audit, or \$edc-run-review."
