#!/usr/bin/env bash
# t31-context-curator-contract: report-only whole-context curator is available
# and build/update invoke it without granting manifest/module mutation authority.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/hardening/lib/check.sh"
check_init

CURATOR="$ROOT/plugins/edc/prompt-bundles/edc-context-curator-impl/SKILL.md"
CURATOR_EDIT="$ROOT/plugins/edc/prompt-bundles/edc-context-curator-edit-impl/SKILL.md"
BUILD_PROMPT="$ROOT/plugins/edc/prompt-bundles/edc-build-impl/SKILL.md"
UPDATE_PROMPT="$ROOT/plugins/edc/prompt-bundles/edc-update-impl/SKILL.md"
PACKAGE_JSON="$ROOT/package.json"

contains() {
  local file="$1" text="$2"
  grep -Fq "$text" "$file"
}

not_contains() {
  local file="$1" text="$2"
  ! grep -Fq "$text" "$file"
}

echo "=== T31: context curator contract ==="

check "curator prompt exists" \
  "$([ -f "$CURATOR" ] && echo 1 || echo 0)"
check "curator is report-only and writes context-curation report" \
  "$(contains "$CURATOR" "report-only" && contains "$CURATOR" "edc-context/reports/context-curation.md" && echo 1 || echo 0)"
check "curator forbids manifest/index/module mutation in phase a" \
  "$(contains "$CURATOR" 'Do not edit `edc-context/manifest.json`' && contains "$CURATOR" 'Do not edit `edc-context/index.md`' && contains "$CURATOR" 'Do not edit `edc-context/modules/*.md`' && echo 1 || echo 0)"
check "curator flags generic quality failures" \
  "$(contains "$CURATOR" "bloated index" && contains "$CURATOR" "copied constants" && contains "$CURATOR" "generic test buckets" && contains "$CURATOR" "low-signal support/tooling modules" && echo 1 || echo 0)"
check "curator flags exact literal reference material" \
  "$(contains "$CURATOR" "service lists" && contains "$CURATOR" "file modes" && contains "$CURATOR" "source-owned snapshot" && echo 1 || echo 0)"
check "curator flags submodule boundary overreach" \
  "$(contains "$CURATOR" "submodule/gitlink" && contains "$CURATOR" "boundary-only" && contains "$CURATOR" "internal architecture" && echo 1 || echo 0)"
check "curator prefers internal routing before oversized module split" \
  "$(contains "$CURATOR" "large modules are not automatically bad" && contains "$CURATOR" "internal sub-routing" && contains "$CURATOR" "recommend splitting only after" && echo 1 || echo 0)"
check "curator treats comparator docs as optional non-authoritative guidance" \
  "$(contains "$CURATOR" "optional curated comparator" && contains "$CURATOR" "never authoritative" && echo 1 || echo 0)"

check "build prompt delegates curator to deterministic coordinator" \
  "$(contains "$BUILD_PROMPT" "coordinator owns" && contains "$BUILD_PROMPT" "Do not run doctor or curator" && echo 1 || echo 0)"
check "update prompt delegates curator to shell runtime step" \
  "$(contains "$UPDATE_PROMPT" 'shell orchestrator runs `edc-context-curator-impl` as a separate runtime report-only step' && contains "$UPDATE_PROMPT" "Do not invoke the curator from inside this update skill" && echo 1 || echo 0)"
check "package allowlist ships private curator prompt bundle" \
  "$(contains "$PACKAGE_JSON" "plugins/edc/prompt-bundles/**" && echo 1 || echo 0)"
check "curator report agent knows routing mutation belongs to update" \
  "$(contains "$CURATOR" "Creating, deleting, renaming, splitting, merging, or promoting modules is routing mutation" && contains "$CURATOR" "must be handled by the update/routing flow" && echo 1 || echo 0)"
check "curator report agent stays report-only" \
  "$(not_contains "$CURATOR" "apply patches" && not_contains "$CURATOR" "edit mode" && echo 1 || echo 0)"
check "curator edit prompt exists and is constrained" \
  "$([ -f "$CURATOR_EDIT" ] && contains "$CURATOR_EDIT" "You may edit only" && contains "$CURATOR_EDIT" 'Do not edit `edc-context/manifest.json`' && contains "$CURATOR_EDIT" "shell orchestrator snapshots" && echo 1 || echo 0)"
check "curator edit agent knows why existing files only" \
  "$(contains "$CURATOR_EDIT" "Creating, deleting, renaming, splitting, merging, or promoting modules is routing mutation" && contains "$CURATOR_EDIT" "existing files only" && contains "$CURATOR_EDIT" "must be handled by the update/routing flow" && echo 1 || echo 0)"

check_summary "T31"
