#!/usr/bin/env bash
# bash >= 4 required
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
# edc-build-plan: deterministic task planner for edc full builds.
#
# Usage: edc-build-plan.sh [--changed <name>[,<name>...]] < input.json
#
# Input (stdin): JSON with .modules[] each having .name, .paths, .approxLoc
# Output (stdout): JSON task list
#
# Exit codes:
#   0   success
#   1   validation failure (input rejected)
#   2   bash version too low
#   64  setup error

set -uo pipefail

reject() { echo "edc-build-plan: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "edc-build-plan: jq required" >&2; exit 64; }

changed_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changed)
      [[ $# -ge 2 ]] || { echo "edc-build-plan: --changed requires an argument" >&2; exit 64; }
      changed_filter="$2"
      shift 2
      ;;
    *)
      echo "edc-build-plan: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
input="$tmp_dir/in.json"
cat > "$input"

jq -e . "$input" >/dev/null 2>&1 || reject "input is not valid JSON"

jq -e 'has("modules")' "$input" >/dev/null 2>&1 || reject "missing required field: modules"
jq -e '.modules | type == "array" and length > 0' "$input" >/dev/null 2>&1 || reject "modules must be a non-empty array"

# Validate each module has name and paths
invalid_modules=$(jq -r '
  .modules[] |
  select((has("name") | not) or (has("paths") | not)) |
  (.name // "<unnamed>")
' "$input")
[[ -z "$invalid_modules" ]] || reject "modules missing required fields (name/paths): $invalid_modules"

# Validate names are unique
dup_names=$(jq -r '[.modules[].name] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$input")
[[ -z "$dup_names" ]] || reject "duplicate module names: $dup_names"

# Build set of allowed names for --changed filter validation
if [[ -n "$changed_filter" ]]; then
  all_names=$(jq -r '[.modules[].name] | join("\n")' "$input")
  IFS=',' read -ra changed_names <<< "$changed_filter"
  for name in "${changed_names[@]}"; do
    if ! echo "$all_names" | grep -qxF "$name"; then
      reject "--changed references unknown module: $name"
    fi
  done
fi

# Produce task list via jq
changed_arg="$changed_filter"

jq -r \
  --arg changed "$changed_arg" \
  '
  # Convert module name to kebab-case (lowercase, spaces/underscores to hyphens)
  def kebab: gsub("[_ ]+"; "-") | ascii_downcase;

  # Build allowed-set for filter (empty string = no filter = all allowed)
  ($changed | if . == "" then [] else split(",") end) as $allowed |

  .modules
  | if ($allowed | length) > 0 then
      map(select(.name as $n | $allowed | index($n) != null))
    else
      .
    end
  | {
      "tasks": map({
        "kind": "module-context",
        "module": .name,
        "paths": .paths,
        "out": (".context/modules/" + (.name | kebab) + ".md"),
        "prompt": (
          "Build deep architectural context for module `" + .name + "`. " +
          "Files in scope: `" + (.paths | join(", ")) + "`. " +
          "Invoke the `edc-context` skill on these files. " +
          "You may read sibling-module source if it materially improves this module'\''s context. " +
          "Write the deep doc directly to `.context/modules/" + (.name | kebab) + ".md`. " +
          "In the module doc, include a `## Per-Function Risk Inventory` section. For each non-trivial function, COPY VERBATIM the edc-context skill's section-5.1 outputs: purpose, inputs/assumptions, error-path memory safety (UAF/double-free/dangling/cleanup ordering), integer arithmetic & size calc, flag/boolean variable tracing, recursive call analysis, state machine analysis. Do NOT summarize these into prose — the downstream reviewer needs the raw per-function checklist outputs. " +
          "Return a ≤500-token summary for the orchestrator."
        )
      })
    }
  ' "$input"
