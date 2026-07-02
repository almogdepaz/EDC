#!/usr/bin/env bash
# edc-manifest: deterministic post-step generator.
#
# Reads a partial manifest from stdin, validates it, fills in deterministic
# fields, and writes the complete manifest to stdout.
#
# Fills:
#   .generatedAt
#   .sourceCommit
#   .coverage.contextMappedFileCount
#   .coverage.contextlessFileCount
#   .coverage.uncoveredFileCount
#   .coverage.ambiguousPathCount
#   .coverage.ignoredFileCount
#   .coverage.ignoreSource
#   .coverage.ignoreGlobs
#   legacy .coverage.mappedFileCount / .coverage.unmappedFileCount aliases
#
# Coverage walks `git ls-files` and classifies paths through the Node batch classifier.
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
command -v node >/dev/null 2>&1 || { echo "edc-manifest: node required" >&2; exit 64; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classify_cli="$script_dir/../hooks/lib/classify-cli.mjs"
[ -f "$classify_cli" ] || { echo "edc-manifest: classify-cli.mjs not found at $classify_cli" >&2; exit 64; }

ignore_source="none"
ignore_globs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ignore)
      [ "$#" -ge 2 ] || { echo "edc-manifest: --ignore requires a glob pattern" >&2; exit 64; }
      ignore_globs+=("$2")
      ignore_source="flags"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "edc-manifest: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

if [ "${#ignore_globs[@]}" -eq 0 ] && [ -f .edcignore ]; then
  ignore_source="file"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac
    ignore_globs+=("$line")
  done < .edcignore
fi

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

jq -e '(.contextless.entries? // []) | type == "array"' "$input" >/dev/null \
  || reject "contextless.entries must be an array when present"

invalid_contextless=$(jq -r '
  [(.contextless.entries // [])[]? |
    select(
      (.id | type != "string" or (test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)) or
      (.globs | type != "array" or length == 0) or
      (.reason | type != "string" or length == 0) or
      (.reviewPolicy | IN("account-only", "promotion-check", "no-context-review") | not)
    ) |
    (.id // "<missing-id>")
  ] | join(",")
' "$input")
[ -z "$invalid_contextless" ] || reject "contextless.entries invalid id/globs/reason/reviewPolicy: $invalid_contextless"

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

# Reject if deterministic fields are already populated. Use raw `has` so we
# distinguish "field present with any value" (LLM tried to author it) from
# "field absent" (the expected case before post-step fills it).
jq -e 'has("generatedAt")  | not' "$input" >/dev/null \
  || reject "generatedAt must not be authored by the LLM; the post-step fills it"
jq -e 'has("sourceCommit") | not' "$input" >/dev/null \
  || reject "sourceCommit must not be authored by the LLM; the post-step fills it"
jq -e '(has("coverage") | not) or (.coverage | length == 0)' "$input" >/dev/null \
  || reject "coverage.* must not be authored by the LLM; the post-step fills it"

# Walk tracked files, classify each through one Node process, tally coverage.
context_mapped=0
contextless=0
uncovered=0
ambiguous=0
ignored=0
ignore_args=()
for glob in "${ignore_globs[@]}"; do
  ignore_args+=(--ignore "$glob")
done

paths_file="$tmp_dir/paths.txt"
states_file="$tmp_dir/states.tsv"
git ls-files > "$paths_file"
if ! node "$classify_cli" "${ignore_args[@]}" "$input" < "$paths_file" > "$states_file"; then
  echo "edc-manifest: classify-cli.mjs failed" >&2
  exit 1
fi

while IFS=$'\t' read -r path state; do
  [ -n "$path" ] || continue
  case "$state" in
    ignored) ignored=$((ignored + 1)) ;;
    context-module:*) context_mapped=$((context_mapped + 1)) ;;
    contextless:*) contextless=$((contextless + 1)) ;;
    uncovered) uncovered=$((uncovered + 1)) ;;
    ambiguous) ambiguous=$((ambiguous + 1)) ;;
    *) echo "edc-manifest: invalid classifier state for path $path: $state" >&2; exit 1 ;;
  esac
done < "$states_file"

generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
source_commit="$(git rev-parse HEAD)"

if [ "${#ignore_globs[@]}" -eq 0 ]; then
  ignore_globs_json='[]'
else
  ignore_globs_json=$(printf '%s\n' "${ignore_globs[@]}" | jq -R . | jq -s .)
fi
legacy_unmapped=$((contextless + uncovered))

jq \
  --arg ga "$generated_at" \
  --arg sc "$source_commit" \
  --arg ignoreSource "$ignore_source" \
  --argjson ignoreGlobs "$ignore_globs_json" \
  --argjson cm "$context_mapped" \
  --argjson cl "$contextless" \
  --argjson u "$uncovered" \
  --argjson a "$ambiguous" \
  --argjson i "$ignored" \
  --argjson legacyUnmapped "$legacy_unmapped" \
  '.generatedAt = $ga
   | .sourceCommit = $sc
   | .coverage.contextMappedFileCount = $cm
   | .coverage.contextlessFileCount = $cl
   | .coverage.uncoveredFileCount = $u
   | .coverage.ambiguousPathCount = $a
   | .coverage.ignoredFileCount = $i
   | .coverage.ignoreSource = $ignoreSource
   | .coverage.ignoreGlobs = $ignoreGlobs
   | .coverage.mappedFileCount = $cm
   | .coverage.unmappedFileCount = $legacyUnmapped' "$input"
