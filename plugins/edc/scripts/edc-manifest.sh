#!/usr/bin/env bash
# bash >= 4 required
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
# edc-manifest: deterministic post-step generator.
#
# Reads a partial manifest from stdin, validates it, fills in deterministic
# fields, and writes the complete manifest to stdout.
#
# Fills:
#   .generatedAt              (UTC ISO8601)
#   .sourceCommit             (git rev-parse HEAD)
#   .coverage.mappedFileCount
#   .coverage.unmappedFileCount
#   .coverage.ambiguousPathCount
#
# Coverage walks `git ls-files` and routes each path via edc-route.sh.
#
# Exit codes:
#   0   success
#   1   validation failure (input rejected)
#   2   bash version too low
#   64  setup error (missing tool / sibling script)

set -uo pipefail

reject() { echo "edc-manifest: $1" >&2; exit 1; }

command -v jq  >/dev/null 2>&1 || { echo "edc-manifest: jq required"  >&2; exit 64; }
command -v git >/dev/null 2>&1 || { echo "edc-manifest: git required" >&2; exit 64; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
route_sh="$script_dir/edc-route.sh"
[ -f "$route_sh" ] || { echo "edc-manifest: edc-route.sh not found at $route_sh" >&2; exit 64; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
input="$tmp_dir/in.json"
cat > "$input"

jq -e . "$input" >/dev/null 2>&1 || reject "input is not valid JSON"

# Required top-level fields (LLM-authored portion).
for f in schemaVersion edcVersion repoContextFile reports build policy modules; do
  jq -e --arg f "$f" 'has($f)' "$input" >/dev/null \
    || reject "missing required field: $f"
done

jq -e '.unmapped.allowedGlobs | type == "array"' "$input" >/dev/null \
  || reject "missing required field: unmapped.allowedGlobs"

jq -e '.modules | (type == "array") and (length > 0)' "$input" >/dev/null \
  || reject "modules must be a non-empty array"

# Policy fields.
jq -e '.policy | has("defaultMode")' "$input" >/dev/null \
  || reject "missing policy.defaultMode"
jq -e '.policy | has("unmatchedPathPolicy")' "$input" >/dev/null \
  || reject "missing policy.unmatchedPathPolicy"

mode=$(jq -r '.policy.defaultMode' "$input")
case "$mode" in
  advisory|inject) ;;
  *) reject "policy.defaultMode must be one of: advisory, inject (got: $mode)" ;;
esac

# Every module must declare a priority.
missing_prio=$(jq -r '[.modules[] | select(has("priority") | not) | (.name // "<unnamed>")] | join(",")' "$input")
[ -z "$missing_prio" ] || reject "modules missing priority: $missing_prio"

# Reject if deterministic fields are already populated.
ga=$(jq -r '.generatedAt // ""' "$input")
sc=$(jq -r '.sourceCommit // ""' "$input")
[ -z "$ga" ] || reject "generatedAt is already populated"
[ -z "$sc" ] || reject "sourceCommit is already populated"

mfc=$(jq -r '.coverage.mappedFileCount   // 0' "$input")
ufc=$(jq -r '.coverage.unmappedFileCount // 0' "$input")
afc=$(jq -r '.coverage.ambiguousPathCount // 0' "$input")
[ "$mfc" = "0" ] || reject "coverage.mappedFileCount is already populated"
[ "$ufc" = "0" ] || reject "coverage.unmappedFileCount is already populated"
[ "$afc" = "0" ] || reject "coverage.ambiguousPathCount is already populated"

# Walk tracked files, route each via edc-route.sh, tally coverage.
mapped=0
unmapped=0
ambiguous=0

while IFS= read -r path; do
  [ -z "$path" ] && continue
  bash "$route_sh" "$input" "$path" >/dev/null 2>&1
  rc=$?
  case $rc in
    0) mapped=$((mapped + 1)) ;;
    1) unmapped=$((unmapped + 1)) ;;
    2) ambiguous=$((ambiguous + 1)) ;;
    *) echo "edc-manifest: edc-route.sh failed (rc=$rc) for path: $path" >&2; exit 1 ;;
  esac
done < <(git ls-files)

generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
source_commit="$(git rev-parse HEAD)"

jq \
  --arg ga "$generated_at" \
  --arg sc "$source_commit" \
  --argjson m "$mapped" \
  --argjson u "$unmapped" \
  --argjson a "$ambiguous" \
  '.generatedAt = $ga
   | .sourceCommit = $sc
   | .coverage.mappedFileCount   = $m
   | .coverage.unmappedFileCount = $u
   | .coverage.ambiguousPathCount = $a' "$input"
