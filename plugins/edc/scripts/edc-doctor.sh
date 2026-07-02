#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
MANIFEST="$EDC_MANIFEST"
INDEX="$EDC_INDEX"
ROOT_AGENTS="$EDC_ROOT_AGENTS"
ALT_AGENTS="$EDC_ALT_AGENTS"
CLASSIFY_CLI="$SCRIPT_DIR/../hooks/lib/classify-cli.mjs"

command -v jq >/dev/null 2>&1 || { echo "edc-doctor: jq required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "edc-doctor: git required" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "edc-doctor: node required" >&2; exit 2; }
[ -f "$CLASSIFY_CLI" ] || { echo "edc-doctor: missing $CLASSIFY_CLI" >&2; exit 2; }

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
    jq -e '.policy.unmatchedPathPolicy | IN("warn-allow","allow","fail")' "$MANIFEST" >/dev/null 2>&1 \
      || fail "policy.unmatchedPathPolicy must be warn-allow, allow, or fail"
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

  tmp_dir=$(mktemp -d)
  paths_file="$tmp_dir/paths.txt"
  states_file="$tmp_dir/states.tsv"
  git ls-files > "$paths_file"
  set +e
  node "$CLASSIFY_CLI" "${ignore_args[@]}" "$MANIFEST" < "$paths_file" > "$states_file" 2> "$tmp_dir/classify.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail "classifier failed (rc=$rc): $(cat "$tmp_dir/classify.err")"
  else
    while IFS=$'\t' read -r path state; do
      [ -n "$path" ] || continue
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
    done < "$states_file"
  fi
  rm -rf "$tmp_dir"
fi

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "edc-doctor: ok"
