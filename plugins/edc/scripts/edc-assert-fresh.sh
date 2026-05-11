#!/usr/bin/env bash
# edc-assert-fresh: shared freshness gate for any orchestrator that needs to
# verify the context dir is present, structurally valid, and built at HEAD.
#
# Dual-use:
#   1. exec'd directly: `bash edc-assert-fresh.sh` → exit 0 if fresh, non-zero
#      with descriptive stderr otherwise.
#   2. sourced from another script: defines `assert_context_fresh` and
#      `read_manifest_source_commit` functions; caller can invoke them
#      without spawning a subshell.
#
# Sourcing convention: the caller may pre-set the MANIFEST variable (e.g.
# review's orchestrator does). If unset, defaults to $EDC_MANIFEST from
# edc-lib.sh (auto-sourced if not already loaded).
#
# Exit codes (when exec'd):
#   0  context is fresh and valid
#   1  missing, stale, or structureless
#   2  not a git repo / setup error

set -uo pipefail

# Auto-source edc-lib.sh if caller didn't.
if [ -z "${EDC_CONTEXT_DIR:-}" ]; then
  _edc_assert_fresh_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=edc-lib.sh
  . "$_edc_assert_fresh_dir/edc-lib.sh"
fi

: "${MANIFEST:=$EDC_MANIFEST}"

read_manifest_source_commit() {
  local val
  val=$(grep -o '"sourceCommit"[[:space:]]*:[[:space:]]*"[^"]*"' "$MANIFEST" \
    | head -1 \
    | sed 's/.*"sourceCommit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
  if [ -z "$val" ]; then
    echo "ERROR: could not read sourceCommit from $MANIFEST" >&2
    return 1
  fi
  echo "$val"
}

assert_context_fresh() {
  if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: context missing ($MANIFEST not found)" >&2
    return 1
  fi
  local head source_commit
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "ERROR: not a git repo" >&2; return 1; }
  source_commit=$(read_manifest_source_commit)
  if [ "$source_commit" != "$head" ]; then
    echo "ERROR: context stale (built at: $source_commit, HEAD: $head)" >&2
    return 1
  fi
  # content validation: index.md must have at least one ## heading (edc-build
  # emits module map, invariants, trust boundaries as ## sections)
  local ctx="$EDC_INDEX"
  if [ ! -f "$ctx" ]; then
    echo "ERROR: context file missing ($ctx) — run /edc:edc-build" >&2
    return 1
  fi
  if ! grep -q '^##' "$ctx"; then
    echo "ERROR: $ctx has no '## ' headings — expected module map, invariants, trust boundaries" >&2
    echo "HINT: this usually means edc-build failed to run or wrote a stub. re-run /edc:edc-build." >&2
    return 1
  fi
}

# When exec'd directly, run the gate. When sourced, just define functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  assert_context_fresh
fi
