#!/usr/bin/env bash
# edc-review orchestrator
# All deterministic control flow for edc-review lives here.
#
# Usage: edc-review.sh <target> [--baseline <ref>]
#   target: PR URL, commit SHA, or diff file path
#
# Exit codes:
#   0 — review-tasks/ written, proceed with skill
#   1 — context not ready (CONTEXT_MISSING or CONTEXT_STALE), see stdout
#   2 — bad arguments or environment error

set -euo pipefail

TARGET="${1:-}"
BASELINE=""

if [ -z "$TARGET" ]; then
  echo "ERROR: target required (PR URL, commit SHA, or diff path)" >&2
  exit 2
fi
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="$2"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Step 1: Context gate ─────────────────────────────────────────────────────

META=".context/.meta.json"
HEAD=$(git rev-parse HEAD 2>/dev/null || { echo "ERROR: not a git repo" >&2; exit 2; })

if [ ! -f "$META" ]; then
  echo "CONTEXT_MISSING"
  echo "No .context/.meta.json found. Run edc-build before reviewing."
  exit 1
fi

LAST_COMMIT=$(grep -o '"lastCommit"[[:space:]]*:[[:space:]]*"[^"]*"' "$META" \
  | head -1 \
  | sed 's/.*"lastCommit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

if [ "$LAST_COMMIT" != "$HEAD" ]; then
  echo "CONTEXT_STALE"
  echo "Context is stale (built at: $LAST_COMMIT, HEAD: $HEAD). Run edc-update before reviewing."
  exit 1
fi

# ── Step 2: Get changed files ────────────────────────────────────────────────

if [[ "$TARGET" == https://* ]]; then
  FILES=$(gh pr diff "$TARGET" --name-only 2>/dev/null)
elif [ -f "$TARGET" ]; then
  FILES=$(grep '^+++ b/' "$TARGET" | sed 's|^+++ b/||')
else
  BASE="${BASELINE:-${TARGET}^}"
  FILES=$(git diff "${BASE}..${TARGET}" --name-only)
fi

if [ -z "$FILES" ]; then
  echo "ERROR: no changed files found for target: $TARGET" >&2
  exit 2
fi

# ── Step 3: Group files by top-level directory ───────────────────────────────

declare -A MODULE_FILES

while IFS= read -r file; do
  [ -z "$file" ] && continue
  dir=$(dirname "$file" | cut -d'/' -f1)
  [ "$dir" = "." ] && dir="root"
  MODULE_FILES["$dir"]+="${file}"$'\n'
done <<< "$FILES"

# ── Step 4: Write review-tasks/ ──────────────────────────────────────────────

rm -rf review-tasks
mkdir -p review-tasks

MODULES_LIST=$(printf '%s\n' "${!MODULE_FILES[@]}" | sort | tr '\n' ' ')

# manifest.json
{
  echo "{"
  echo "  \"target\": \"$TARGET\","
  echo "  \"baseline\": \"$BASELINE\","
  echo "  \"head\": \"$HEAD\","
  echo "  \"modules\": ["
  first=1
  for module in $(printf '%s\n' "${!MODULE_FILES[@]}" | sort); do
    [ $first -eq 0 ] && echo "    ,"
    echo -n "    { \"module\": \"$module\", \"files\": ["
    file_json=$(echo "${MODULE_FILES[$module]}" \
      | grep -v '^$' \
      | sed 's/^/"/;s/$/"/' \
      | tr '\n' ',' \
      | sed 's/,$//')
    echo -n "$file_json"
    echo -n "] }"
    first=0
  done
  echo ""
  echo "  ]"
  echo "}"
} > review-tasks/manifest.json

# per-module task files
for module in "${!MODULE_FILES[@]}"; do
  file_list=$(echo "${MODULE_FILES[$module]}" | grep -v '^$' | sed 's/^/- /')
  baseline_line=""
  [ -n "$BASELINE" ] && baseline_line=$'\n'"## Baseline"$'\n'"${BASELINE}"

  cat > "review-tasks/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${TARGET}${baseline_line}

## Files to review
${file_list}

## Instructions

1. Read \`.context/context.md\` — module map, invariants, trust boundaries
2. Read \`.context/issues.md\` if it exists — cross-reference known issues against the files above
3. Read \`.context/${module}.md\` if it exists — deep per-module context, invariants, call graphs
4. Use the edc-review skill to perform the full review on the files listed above
5. Write your report to \`review-tasks/report-${module}.md\`

DO NOT write your own review methodology.
DO NOT skip reading the context files.
USE the edc-review skill.
TASK

done

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Review tasks ready."
echo "Modules: ${MODULES_LIST}"
echo ""
echo "Process each review-tasks/{module}.md file sequentially using the edc-review skill."
echo "Consolidate reports into review-$(echo "$TARGET" | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-40).md when all modules are done."
