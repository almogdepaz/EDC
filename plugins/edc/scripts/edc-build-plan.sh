#!/usr/bin/env bash
# edc-build-plan: deterministic task planner for edc full builds.
#
# Usage: edc-build-plan.sh [--changed <name>[,<name>...]] < input.json
#
# Input (stdin): JSON with .modules[] each having .name, .paths, .approxLoc
# Output (stdout): JSON task list
# Prompt contract: subagents must "Write distilled high-signal context" for module docs.
#
# Exit codes:
#   0   success
#   1   validation failure (input rejected)
#   64  setup error

set -uo pipefail

reject() { echo "edc-build-plan: $1" >&2; exit 1; }

_edc_build_plan_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$_edc_build_plan_dir/edc-lib.sh"
json_cli="$_edc_build_plan_dir/../hooks/lib/json-cli.mjs"
[ -f "$json_cli" ] || { echo "edc-build-plan: json-cli.mjs not found at $json_cli" >&2; exit 64; }
command -v node >/dev/null 2>&1 || { echo "edc-build-plan: node required" >&2; exit 64; }

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

node "$json_cli" build-plan "$EDC_MODULES_DIR" "$changed_filter" < "$input"
