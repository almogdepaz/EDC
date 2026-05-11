#!/usr/bin/env bash
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "edc-doctor: requires bash >= 4.0" >&2
  exit 2
}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
MANIFEST="$EDC_MANIFEST"
INDEX="$EDC_INDEX"
ROOT_AGENTS="AGENTS.md"
ROUTE_SH="$SCRIPT_DIR/edc-route.sh"
TMP_ERR="${TMPDIR:-/tmp}/edc-doctor-route.$$"

command -v jq >/dev/null 2>&1 || { echo "edc-doctor: jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "edc-doctor: git required" >&2; exit 2; }
[ -f "$ROUTE_SH" ] || { echo "edc-doctor: missing $ROUTE_SH" >&2; exit 2; }

failures=0

cleanup() {
  rm -f "$TMP_ERR"
}
trap cleanup EXIT

fail() {
  echo "edc-doctor: $*" >&2
  failures=$((failures + 1))
}

matches_allowed_glob() {
  local path="$1"
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    if [[ "$path" == $glob ]]; then
      return 0
    fi
  done < <(jq -r '.unmapped.allowedGlobs[]? // empty' "$MANIFEST")
  return 1
}

[ -f "$ROOT_AGENTS" ] || fail "missing $ROOT_AGENTS"
[ -f "$INDEX" ] || fail "missing $INDEX"
[ -f "$MANIFEST" ] || fail "missing $MANIFEST"

if [ -f "$INDEX" ] && ! grep -q '^##' "$INDEX"; then
  fail "$INDEX has no ## headings"
fi

if [ -f "$MANIFEST" ]; then
  if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
    fail "$MANIFEST is not valid JSON"
  else
    jq -e '.schemaVersion == 2' "$MANIFEST" >/dev/null 2>&1 \
      || fail "$MANIFEST schemaVersion must equal 2"
    jq -e '.policy.defaultMode | IN("advisory","inject")' "$MANIFEST" >/dev/null 2>&1 \
      || fail "policy.defaultMode must be advisory or inject"
    jq -e '.policy.unmatchedPathPolicy == "warn-allow"' "$MANIFEST" >/dev/null 2>&1 \
      || fail "policy.unmatchedPathPolicy must equal warn-allow"
    while IFS= read -r doc; do
      [ -n "$doc" ] || continue
      [ -f "$doc" ] || fail "missing module doc: $doc"
    done < <(jq -r '.modules[].doc // empty' "$MANIFEST")
  fi
fi

if [ "$failures" -eq 0 ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    set +e
    bash "$ROUTE_SH" "$MANIFEST" "$path" >/dev/null 2>"$TMP_ERR"
    rc=$?
    set -e
    case "$rc" in
      0)
        ;;
      1)
        if ! matches_allowed_glob "$path"; then
          fail "orphan tracked path not covered by manifest or unmapped.allowedGlobs: $path"
        fi
        ;;
      2)
        fail "ambiguous routing for $path: $(cat "$TMP_ERR")"
        ;;
      *)
        fail "routing helper failed for $path (rc=$rc)"
        ;;
    esac
  done < <(git ls-files)
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "edc-doctor: ok"
