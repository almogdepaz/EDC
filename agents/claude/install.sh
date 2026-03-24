#!/bin/bash
# Prepare Claude plugin by copying shared skills into the plugin structure
# Run this after cloning or after updating shared skills

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/plugins/edc/skills"

echo "Syncing shared skills into Claude plugin..."

rm -rf "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/edc-context/resources"
mkdir -p "$PLUGIN_DIR/edc-review"

cp "$REPO_ROOT/skills/edc-context/SKILL.md" "$PLUGIN_DIR/edc-context/"
cp "$REPO_ROOT/skills/edc-context/resources/"* "$PLUGIN_DIR/edc-context/resources/"
cp "$REPO_ROOT/skills/edc-review/"* "$PLUGIN_DIR/edc-review/"

echo "Done. Claude plugin skills synced."
