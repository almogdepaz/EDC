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
#   64  setup error (missing tool / sibling script)

set -uo pipefail

reject() { echo "edc-manifest: $1" >&2; exit 1; }

command -v git >/dev/null 2>&1 || { echo "edc-manifest: git required" >&2; exit 64; }
command -v node >/dev/null 2>&1 || { echo "edc-manifest: node required" >&2; exit 64; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classify_cli="$script_dir/../hooks/lib/classify-cli.mjs"
json_cli="$script_dir/../hooks/lib/json-cli.mjs"
[ -f "$classify_cli" ] || { echo "edc-manifest: classify-cli.mjs not found at $classify_cli" >&2; exit 64; }
[ -f "$json_cli" ] || { echo "edc-manifest: json-cli.mjs not found at $json_cli" >&2; exit 64; }

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

node "$json_cli" valid-json "$input" >/dev/null 2>&1 || reject "input is not valid JSON"

# Walk tracked files, classify each through one Node process, tally coverage.
context_mapped=0
contextless=0
uncovered=0
ambiguous=0
ignored=0
ignore_args=()
for glob in ${ignore_globs[@]+"${ignore_globs[@]}"}; do
  ignore_args+=(--ignore "$glob")
done

paths_file="$tmp_dir/paths.txt"
states_file="$tmp_dir/states.tsv"
git ls-files > "$paths_file"
if ! node "$classify_cli" ${ignore_args[@]+"${ignore_args[@]}"} "$input" < "$paths_file" > "$states_file"; then
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

node "$json_cli" manifest-finalize \
  "$generated_at" \
  "$source_commit" \
  "$ignore_source" \
  "$context_mapped" \
  "$contextless" \
  "$uncovered" \
  "$ambiguous" \
  "$ignored" \
  ${ignore_globs[@]+"${ignore_globs[@]}"} \
  < "$input"
