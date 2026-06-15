#!/usr/bin/env bash
# edc-clean-slate: detect partial-v2 build state and wipe the context dir for a fresh build.
#
# v2-only. Earlier revisions detected legacy v1 layouts (.meta.json,
# top-level context.md, etc.) and auto-wiped them. v1 is no longer
# supported; if v1 markers are present this script fails with a
# copy-pasteable migration message instead of silently wiping.
#
# Modes:
#   --check       exit 11 if healthy v2 / exit 0 if no context dir /
#                 exit 10 if partial or malformed v2 / exit 12 if v1 layout.
#   --force       unconditionally wipe the context dir and EDC-generated agent entrypoint files.
#   (default)     wipe only if partial v2 detected. Refuse to wipe v1 layouts.
#
# Partial-v2 indicators (any of):
#   context dir exists but manifest.json missing
#   manifest.json exists but doesn't parse, or schemaVersion != 2
#
# v1 indicators (any of) → script refuses to act, prints migration hint:
#   <ctx>/.meta.json
#   <ctx>/context.md
#   <ctx>/full-context.md
#   <ctx>/issues.md     (v1 top-level; v2 puts it under reports/)
#   <ctx>/complexity.md (v1 top-level; v2 under reports/)
#
# Exit codes:
#   0   action taken (wiped) or nothing-to-do
#   10  --check: partial / malformed v2 (caller should wipe + rebuild)
#   11  --check: layout is healthy v2
#   12  --check or auto: v1 layout detected; user must manually wipe
#   2   bash version too low / usage error
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "edc-clean-slate: requires bash >= 4.0" >&2
  exit 2
}

set -uo pipefail

_edc_clean_slate_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$_edc_clean_slate_dir/edc-lib.sh"

CTX="$EDC_CONTEXT_DIR"
MANIFEST="$EDC_MANIFEST"
AGENTS="$EDC_ROOT_AGENTS"
ALT_AGENTS="$EDC_ALT_AGENTS"

mode="auto"
case "${1:-}" in
  --check) mode="check" ;;
  --force) mode="force" ;;
  "")      mode="auto" ;;
  *) echo "usage: edc-clean-slate.sh [--check|--force]" >&2; exit 2 ;;
esac

has_v1_markers() {
  [ -d "$CTX" ] || return 1
  [ -f "$CTX/.meta.json" ] && return 0
  [ -f "$CTX/context.md" ] && return 0
  [ -f "$CTX/full-context.md" ] && return 0
  [ -f "$CTX/issues.md" ] && return 0
  [ -f "$CTX/complexity.md" ] && return 0
  return 1
}

print_v1_migration_hint() {
  cat >&2 <<EOF
ERROR: legacy v1 ${CTX}/ layout detected.

v1 is no longer supported. To migrate, run:

  rm -rf ${CTX} AGENTS.md EDC_AGENTS.md
  /edc:edc-build      # or: edc build --agent <claude|cursor|codex>

This will produce a fresh v2 layout (${EDC_INDEX}, ${MANIFEST},
${EDC_MODULES_DIR}/<name>.md, ${EDC_REPORTS_DIR}/{issues,complexity}.md).
EOF
}

has_partial_v2() {
  [ -d "$CTX" ] || return 1
  if [ ! -f "$MANIFEST" ]; then
    # context dir exists but no manifest → partial
    if find "$CTX" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e '.schemaVersion == 2' "$MANIFEST" >/dev/null 2>&1 || return 0
  fi
  return 1
}

is_healthy_v2() {
  [ -f "$MANIFEST" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.schemaVersion == 2' "$MANIFEST" >/dev/null 2>&1 || return 1
  # The EDC entrypoint is part of the v2 layout. It can be either a generated
  # AGENTS.md, or a generated EDC_AGENTS.md referenced from AGENTS.md/CLAUDE.md
  # when a repo already owns its AGENTS.md.
  edc_entrypoint_valid || return 1
}

wipe() {
  rm -rf "$CTX" "$ALT_AGENTS"
  if edc_is_generated_agents_file "$AGENTS"; then
    rm -f "$AGENTS"
  else
    edc_remove_alt_agents_reference "$AGENTS"
  fi
  edc_remove_alt_agents_reference "$EDC_CLAUDE_AGENTS"
  echo "edc-clean-slate: wiped ${CTX}/ and EDC-generated agent entrypoint files"
}

case "$mode" in
  check)
    if [ ! -d "$CTX" ]; then
      # no context dir = clean enough for a full build
      exit 0
    fi
    if has_v1_markers; then
      print_v1_migration_hint
      exit 12
    fi
    if has_partial_v2; then
      echo "edc-clean-slate: partial v2 build detected" >&2
      exit 10
    fi
    if is_healthy_v2; then
      exit 11
    fi
    # exists but no recognizable signal — treat as partial
    exit 10
    ;;
  force)
    if has_v1_markers; then
      print_v1_migration_hint
      exit 12
    fi
    wipe
    exit 0
    ;;
  auto)
    if has_v1_markers; then
      print_v1_migration_hint
      exit 12
    fi
    if has_partial_v2; then
      echo "edc-clean-slate: partial v2 build — wiping for fresh v2 build" >&2
      wipe
      exit 0
    fi
    # nothing to do
    exit 0
    ;;
esac
