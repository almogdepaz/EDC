#!/bin/bash
# Prepare Claude plugin by copying shared skills into the plugin structure
# Run this after cloning or after updating shared skills

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/plugins/edc/skills"

echo "Syncing shared skills into Claude plugin..."

rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/deep-context-building/resources"
mkdir -p "$PLUGIN_DIR/differential-review"

cp "$REPO_ROOT/skills/deep-context-building/SKILL.md" "$PLUGIN_DIR/deep-context-building/"
cp "$REPO_ROOT/skills/deep-context-building/resources/"* "$PLUGIN_DIR/deep-context-building/resources/"
cp "$REPO_ROOT/skills/differential-review/"* "$PLUGIN_DIR/differential-review/"

echo "Done. Claude plugin skills synced."
