#!/usr/bin/env bash
# bash >= 4 required: uses arrays and process substitution
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
# edc-classify-path: shared path -> coverage state classifier.
#
# Usage: edc-classify-path.sh [--ignore <glob>]... <manifest-path> <file-path>
#
# States printed on stdout:
#   ignored
#   context-module:<module>
#   contextless:<entryId>:<reviewPolicy>
#   uncovered
#   ambiguous
#
# Exit codes:
#   0  classified successfully
#   64 usage / setup error
set -uo pipefail

usage() {
  echo "usage: edc-classify-path.sh [--ignore <glob>]... <manifest-path> <file-path>" >&2
  exit 64
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
route_sh="$script_dir/edc-route.sh"
[ -f "$route_sh" ] || { echo "edc-classify-path: missing $route_sh" >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "edc-classify-path: jq required" >&2; exit 64; }

ignore_patterns=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ignore)
      [ "$#" -ge 2 ] || usage
      ignore_patterns+=("$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -eq 2 ] || usage
manifest="$1"
file="$2"
[ -f "$manifest" ] || { echo "edc-classify-path: manifest not found: $manifest" >&2; exit 64; }

path_matches_glob() {
  local path="$1" pattern="$2"
  if [[ "$pattern" == */ ]]; then
    [[ "$path" == ${pattern}* ]]
    return
  fi

  [[ "$path" == "$pattern" ]] \
    || [[ "$path" == "$pattern/"* ]] \
    || [[ "$path" == $pattern ]]
}

for pattern in "${ignore_patterns[@]}"; do
  if path_matches_glob "$file" "$pattern"; then
    echo "ignored"
    exit 0
  fi
done

explicit_contextless_matches=()
legacy_contextless_matches=()
while IFS=$'\t' read -r source id policy glob; do
  [ -n "$id" ] || continue
  if path_matches_glob "$file" "$glob"; then
    if [ "$source" = "explicit" ]; then
      explicit_contextless_matches+=("$id:$policy")
    else
      legacy_contextless_matches+=("$id:$policy")
    fi
  fi
done < <(jq -r '
  ((.contextless.entries // [])[]? |
    .id as $id |
    (.reviewPolicy // "account-only") as $policy |
    (.globs // [])[]? |
    "explicit\t\($id)\t\($policy)\t\(.)"),
  ((.unmapped.allowedGlobs // [])[]? |
    "legacy\tlegacy-unmapped\taccount-only\t\(.)")
' "$manifest")

_make_contextless_state() {
  local matches=("$@")
  if [ "${#matches[@]}" -eq 0 ]; then
    echo ""
    return
  fi
  local first="${matches[0]}" unique_count=0 seen="" match
  for match in "${matches[@]}"; do
    case "\n$seen\n" in
      *$'\n'"$match"$'\n'*) ;;
      *)
        seen+="$match"$'\n'
        unique_count=$((unique_count + 1))
        ;;
    esac
  done
  if [ "$unique_count" -eq 1 ]; then
    echo "contextless:$first"
  else
    echo "ambiguous"
  fi
}

explicit_contextless_state="$(_make_contextless_state "${explicit_contextless_matches[@]}")"
legacy_contextless_state="$(_make_contextless_state "${legacy_contextless_matches[@]}")"

EDC_BASH="${EDC_BASH:-$BASH}"
route_err="$(mktemp)"
module=$("$EDC_BASH" "$route_sh" "$manifest" "$file" 2>"$route_err")
route_rc=$?
rm -f "$route_err"

case "$route_rc" in
  0)
    if [ -n "$explicit_contextless_state" ]; then
      echo "ambiguous"
    else
      echo "context-module:$module"
    fi
    ;;
  1)
    if [ -n "$explicit_contextless_state" ]; then
      echo "$explicit_contextless_state"
    elif [ -n "$legacy_contextless_state" ]; then
      echo "$legacy_contextless_state"
    else
      echo "uncovered"
    fi
    ;;
  2)
    echo "ambiguous"
    ;;
  *)
    echo "edc-classify-path: edc-route.sh failed (rc=$route_rc) for path: $file" >&2
    exit 64
    ;;
esac
