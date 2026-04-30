#!/usr/bin/env bash
# bash >= 4 required: uses arrays with set -u
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
# edc-route: shared path -> module routing helper
#
# Usage: edc-route.sh <manifest-path> <file-path>
#
# Exit codes:
#   0  single module wins; module name on stdout
#   1  no module matches; stdout empty
#   2  ambiguous; stdout empty; "ambiguous: <m1> <m2> ..." on stderr
#  64  usage / setup error
#
# Algorithm (modules with higher .priority break ties at any tier):
#   T1. exactFiles equality wins
#   T2. else longest prefix in match.prefixes wins
#   T3. else any glob in match.globs matches
set -uo pipefail

usage() {
  echo "usage: edc-route.sh <manifest-path> <file-path>" >&2
  exit 64
}

[ "$#" -eq 2 ] || usage
manifest="$1"
file="$2"

[ -f "$manifest" ] || { echo "manifest not found: $manifest" >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 64; }

# Pick winners from parallel arrays (names, priorities). Higher priority wins;
# ties at top priority are reported as ambiguous on stderr (exit 2).
# Stdin: not used. Args: name1 prio1 name2 prio2 ...
pick_winner() {
  local -a names=()
  local -a prios=()
  while [ "$#" -gt 0 ]; do
    names+=("$1"); prios+=("$2"); shift 2
  done

  local n=${#names[@]}
  if (( n == 0 )); then return 3; fi

  local max_p=${prios[0]}
  local i
  for ((i=1; i<n; i++)); do
    (( prios[i] > max_p )) && max_p=${prios[i]}
  done

  local -a winners=()
  for ((i=0; i<n; i++)); do
    (( prios[i] == max_p )) && winners+=("${names[i]}")
  done

  if (( ${#winners[@]} == 1 )); then
    echo "${winners[0]}"
    return 0
  fi
  echo "ambiguous: ${winners[*]}" >&2
  return 2
}

mod_count=$(jq '.modules | length' "$manifest")

# Tier 1: exactFiles
t1_args=()
for ((i=0; i<mod_count; i++)); do
  hit=$(jq -r --argjson i "$i" --arg f "$file" \
    '(.modules[$i].match.exactFiles // []) | any(. == $f)' "$manifest")
  if [ "$hit" = "true" ]; then
    name=$(jq -r --argjson i "$i" '.modules[$i].name' "$manifest")
    prio=$(jq -r --argjson i "$i" '.modules[$i].priority // 0' "$manifest")
    t1_args+=("$name" "$prio")
  fi
done

if (( ${#t1_args[@]} > 0 )); then
  pick_winner "${t1_args[@]}"
  exit $?
fi

# Tier 2: longest prefix wins
t2_names=()
t2_prios=()
t2_lens=()
for ((i=0; i<mod_count; i++)); do
  best_len=-1
  while IFS= read -r prefix; do
    [ -z "$prefix" ] && continue
    case "$file" in
      "$prefix"*)
        len=${#prefix}
        (( len > best_len )) && best_len=$len
        ;;
    esac
  done < <(jq -r --argjson i "$i" '.modules[$i].match.prefixes // [] | .[]' "$manifest")
  if (( best_len >= 0 )); then
    name=$(jq -r --argjson i "$i" '.modules[$i].name' "$manifest")
    prio=$(jq -r --argjson i "$i" '.modules[$i].priority // 0' "$manifest")
    t2_names+=("$name")
    t2_prios+=("$prio")
    t2_lens+=("$best_len")
  fi
done

if (( ${#t2_names[@]} > 0 )); then
  max_len=${t2_lens[0]}
  for l in "${t2_lens[@]}"; do
    (( l > max_len )) && max_len=$l
  done
  t2_args=()
  for j in "${!t2_names[@]}"; do
    if (( t2_lens[j] == max_len )); then
      t2_args+=("${t2_names[j]}" "${t2_prios[j]}")
    fi
  done
  pick_winner "${t2_args[@]}"
  exit $?
fi

# Tier 3: globs (any match)
t3_args=()
for ((i=0; i<mod_count; i++)); do
  matched=0
  while IFS= read -r glob; do
    [ -z "$glob" ] && continue
    # shellcheck disable=SC2053
    if [[ "$file" == $glob ]]; then
      matched=1
      break
    fi
  done < <(jq -r --argjson i "$i" '.modules[$i].match.globs // [] | .[]' "$manifest")
  if (( matched == 1 )); then
    name=$(jq -r --argjson i "$i" '.modules[$i].name' "$manifest")
    prio=$(jq -r --argjson i "$i" '.modules[$i].priority // 0' "$manifest")
    t3_args+=("$name" "$prio")
  fi
done

if (( ${#t3_args[@]} > 0 )); then
  pick_winner "${t3_args[@]}"
  exit $?
fi

exit 1
