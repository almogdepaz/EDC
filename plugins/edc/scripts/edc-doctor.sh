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
ROOT_AGENTS="$EDC_ROOT_AGENTS"
ALT_AGENTS="$EDC_ALT_AGENTS"
CLASSIFY_SH="$SCRIPT_DIR/edc-classify-path.sh"

command -v jq >/dev/null 2>&1 || { echo "edc-doctor: jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "edc-doctor: git required" >&2; exit 2; }
[ -f "$CLASSIFY_SH" ] || { echo "edc-doctor: missing $CLASSIFY_SH" >&2; exit 2; }

failures=0

fail() {
  echo "edc-doctor: $*" >&2
  failures=$((failures + 1))
}

edc_entrypoint_valid || fail "missing valid EDC agent entrypoint: expected generated $ROOT_AGENTS, or generated $ALT_AGENTS referenced from $ROOT_AGENTS/$EDC_CLAUDE_AGENTS"
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
  ignore_args=()
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    ignore_args+=(--ignore "$glob")
  done < <(jq -r '.coverage.ignoreGlobs[]? // empty' "$MANIFEST")

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    set +e
    state=$("$EDC_BASH" "$CLASSIFY_SH" "${ignore_args[@]}" "$MANIFEST" "$path" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      fail "classifier failed for $path (rc=$rc): $state"
      continue
    fi
    case "$state" in
      ignored|context-module:*|contextless:*)
        ;;
      uncovered)
        fail "uncovered tracked path not covered by manifest modules or contextless.entries: $path"
        ;;
      ambiguous)
        fail "ambiguous routing for $path"
        ;;
      *)
        fail "classifier returned invalid state for $path: $state"
        ;;
    esac
  done < <(git ls-files)
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "edc-doctor: ok"
