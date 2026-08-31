#!/usr/bin/env bash
# Shared immutable candidate resolution for differential review orchestrators.
# Source only after edc_runtime_preflight_or_exit has validated the runtime.

edc_candidate_is_operational_untracked() {
  case "$1" in
    .edc|.edc/*|.edc.install.lock|.edc.install.lock/*|.pi/tasks|.pi/tasks/*|edc-context|edc-context/*|review-*.md|delivery-review-*.md) return 0 ;;
    *) return 1 ;;
  esac
}

edc_candidate_selected_untracked() {
  local path
  git ls-files --others --exclude-standard -z 2>/dev/null \
    | while IFS= read -r -d '' path; do
        [ -n "$path" ] || continue
        edc_candidate_is_operational_untracked "$path" && continue
        printf '%s\0' "$path"
      done
}

edc_candidate_gitlinks() {
  local entry mode path
  while IFS= read -r -d '' entry; do
    mode=${entry%% *}
    [ "$mode" = 160000 ] || continue
    path=${entry#*$'\t'}
    printf '%s\0' "$path"
  done < <(git ls-files --stage -z 2>/dev/null)
}

edc_candidate_has_selected_untracked_local() {
  local list
  list=$(mktemp "${TMPDIR:-/tmp}/edc-candidate-untracked-$$.XXXXXX") || return 1
  edc_candidate_selected_untracked > "$list"
  if [ -s "$list" ]; then
    rm -f "$list"
    return 0
  fi
  rm -f "$list"
  return 1
}

edc_candidate_is_initialized_submodule() {
  local path="$1" expected_root actual_root
  [ -d "$path" ] || return 1
  expected_root=$(cd -P "$path" 2>/dev/null && pwd) || return 1
  actual_root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  actual_root=$(cd -P "$actual_root" 2>/dev/null && pwd) || return 1
  [ "$actual_root" = "$expected_root" ]
}

edc_candidate_has_selected_untracked() {
  local gitlinks path result=1
  edc_candidate_has_selected_untracked_local && return 0
  gitlinks=$(mktemp "${TMPDIR:-/tmp}/edc-candidate-gitlinks-$$.XXXXXX") || return 1
  edc_candidate_gitlinks > "$gitlinks"
  while IFS= read -r -d '' path; do
    edc_candidate_is_initialized_submodule "$path" || continue
    if (cd "$path" && edc_candidate_has_selected_untracked); then
      result=0
      break
    fi
  done < "$gitlinks"
  rm -f "$gitlinks"
  return "$result"
}

edc_candidate_has_dirty_tracked() {
  ! git diff --quiet --ignore-submodules=untracked HEAD --
}

edc_candidate_repo_has_changes() {
  edc_candidate_has_dirty_tracked && return 0
  edc_candidate_has_selected_untracked && return 0
  return 1
}

edc_candidate_export_scope() {
  local kind="$1" commit="$2" target="$3" base="$4" dirty_included="$5" untracked_included="$6"
  export EDC_CANDIDATE_KIND="$kind"
  export EDC_CANDIDATE_COMMIT="$commit"
  export EDC_CANDIDATE_TARGET="$target"
  export EDC_CANDIDATE_BASE="$base"
  export EDC_CANDIDATE_DIRTY_TRACKED_INCLUDED="$dirty_included"
  export EDC_CANDIDATE_UNTRACKED_INCLUDED="$untracked_included"
  export EDC_RESULT_SCOPE=differential
  export EDC_RESULT_TARGET="$target"
  export EDC_RESULT_BASE="$base"
  export EDC_RESULT_CANDIDATE_KIND="$kind"
  export EDC_RESULT_CANDIDATE_COMMIT="$commit"
  export EDC_RESULT_DIRTY_TRACKED_INCLUDED="$dirty_included"
  export EDC_RESULT_UNTRACKED_INCLUDED="$untracked_included"
}

edc_candidate_export_full_scope() {
  unset EDC_CANDIDATE_KIND EDC_CANDIDATE_COMMIT EDC_CANDIDATE_TARGET EDC_CANDIDATE_BASE
  export EDC_RESULT_SCOPE=full
  export EDC_RESULT_TARGET="current working tree / HEAD"
  unset EDC_RESULT_BASE EDC_RESULT_CANDIDATE_KIND EDC_RESULT_CANDIDATE_COMMIT
  export EDC_RESULT_DIRTY_TRACKED_INCLUDED=1
  export EDC_RESULT_UNTRACKED_INCLUDED=0
}

edc_candidate_add_paths_from_nul_file() {
  local index_file="$1" paths_file="$2" path count=0
  local -a paths=()
  while IFS= read -r -d '' path; do
    # `git add -u` already represented tracked deletions by removing them from
    # the temporary index. Do not try to re-add a path absent from the worktree.
    [ -e "$path" ] || [ -L "$path" ] || continue
    paths+=("$path")
    count=$((count + 1))
    if [ "$count" -eq 100 ]; then
      GIT_INDEX_FILE="$index_file" git add -- "${paths[@]}" || return 1
      paths=()
      count=0
    fi
  done < "$paths_file"
  if [ "$count" -gt 0 ]; then
    GIT_INDEX_FILE="$index_file" git add -- "${paths[@]}" || return 1
  fi
}

edc_candidate_snapshot_repo() {
  local target_commit="$1" index_file paths_file gitlinks_file tree candidate
  local path sub_target sub_candidate submodule_rc=0
  index_file=$(mktemp "${TMPDIR:-/tmp}/edc-candidate-index-$$.XXXXXX") || return 1
  paths_file=$(mktemp "${TMPDIR:-/tmp}/edc-candidate-paths-$$.XXXXXX") || { rm -f "$index_file"; return 1; }
  gitlinks_file=$(mktemp "${TMPDIR:-/tmp}/edc-candidate-gitlinks-$$.XXXXXX") || { rm -f "$index_file" "$paths_file"; return 1; }
  rm -f "$index_file"

  if ! GIT_INDEX_FILE="$index_file" git read-tree "$target_commit" \
    || ! GIT_INDEX_FILE="$index_file" git add -u -- .; then
    rm -f "$index_file" "$paths_file" "$gitlinks_file"
    echo "ERROR: could not capture tracked working-tree content in the review candidate" >&2
    echo "next step: fix the Git index/worktree error above, then rerun with --include-working-tree" >&2
    return 1
  fi

  git ls-files --cached -z > "$paths_file"
  edc_candidate_selected_untracked >> "$paths_file"
  if ! edc_candidate_add_paths_from_nul_file "$index_file" "$paths_file"; then
    rm -f "$index_file" "$paths_file" "$gitlinks_file"
    echo "ERROR: could not add every selected path to the review candidate" >&2
    echo "next step: fix the unreadable path above, then rerun with --include-working-tree" >&2
    return 1
  fi

  # A superproject commit stores submodules as gitlinks. Dirty bytes inside an
  # initialized submodule therefore need their own immutable synthetic commit;
  # point the parent candidate's alternate index at that commit without moving
  # any submodule ref or touching any real index.
  edc_candidate_gitlinks > "$gitlinks_file"
  while IFS= read -r -d '' path; do
    edc_candidate_is_initialized_submodule "$path" || continue
    (cd "$path" && edc_candidate_repo_has_changes) || continue
    if ! sub_target=$(git -C "$path" rev-parse --verify HEAD); then
      submodule_rc=1
      break
    fi
    if ! sub_candidate=$(cd "$path" && edc_candidate_snapshot_repo "$sub_target"); then
      submodule_rc=1
      break
    fi
    if ! GIT_INDEX_FILE="$index_file" git update-index --add --cacheinfo "160000,$sub_candidate,$path"; then
      submodule_rc=1
      break
    fi
  done < "$gitlinks_file"
  if [ "$submodule_rc" -ne 0 ]; then
    rm -f "$index_file" "$paths_file" "$gitlinks_file"
    return 1
  fi

  tree=$(GIT_INDEX_FILE="$index_file" git write-tree) || { rm -f "$index_file" "$paths_file" "$gitlinks_file"; return 1; }
  candidate=$(printf '%s\n' 'EDC immutable working-tree review candidate' \
    | GIT_AUTHOR_NAME=EDC GIT_AUTHOR_EMAIL=edc@localhost \
      GIT_COMMITTER_NAME=EDC GIT_COMMITTER_EMAIL=edc@localhost \
      git -c commit.gpgsign=false commit-tree "$tree" -p "$target_commit") \
    || { rm -f "$index_file" "$paths_file" "$gitlinks_file"; return 1; }
  rm -f "$index_file" "$paths_file" "$gitlinks_file"

  if [ "$(git rev-parse "${candidate}^{tree}")" != "$tree" ]; then
    echo "ERROR: immutable review candidate verification failed" >&2
    echo "next step: do not continue this review; inspect repository object integrity and rerun" >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}

edc_candidate_snapshot_working_tree() {
  edc_candidate_snapshot_repo "$1"
}

# External PR/patch targets cannot absorb local working-tree content. Require an
# explicit committed-only exclusion when local reviewable changes exist.
edc_candidate_resolve_external() {
  local requested_target="$1" base="${2:-}" policy="${3:-}"
  local dirty_tracked=0 selected_untracked=0

  edc_candidate_has_dirty_tracked && dirty_tracked=1
  edc_candidate_has_selected_untracked && selected_untracked=1
  if [ "$policy" = include-working-tree ]; then
    echo "ERROR: --include-working-tree is incompatible with an external PR or patch target" >&2
    echo "next step: use --committed-only to exclude local changes, or review HEAD --include-working-tree" >&2
    return 2
  fi
  if [ -z "$policy" ] && { [ "$dirty_tracked" -eq 1 ] || [ "$selected_untracked" -eq 1 ]; }; then
    echo "ERROR: working tree contains local changes outside the external review target" >&2
    echo "next step: rerun with --committed-only to exclude every local working-tree change" >&2
    return 2
  fi

  export EDC_CANDIDATE_KIND=external
  unset EDC_CANDIDATE_COMMIT
  export EDC_CANDIDATE_TARGET="$requested_target"
  export EDC_CANDIDATE_BASE="$base"
  export EDC_CANDIDATE_DIRTY_TRACKED_INCLUDED=0
  export EDC_CANDIDATE_UNTRACKED_INCLUDED=0
  export EDC_RESULT_SCOPE=differential
  export EDC_RESULT_TARGET="$requested_target"
  export EDC_RESULT_BASE="$base"
  export EDC_RESULT_CANDIDATE_KIND=external
  unset EDC_RESULT_CANDIDATE_COMMIT
  export EDC_RESULT_DIRTY_TRACKED_INCLUDED=0
  export EDC_RESULT_UNTRACKED_INCLUDED=0
}

# edc_candidate_resolve <target> <base> <policy>
# policy is empty, include-working-tree, or committed-only.
edc_candidate_resolve() {
  local requested_target="${1:-HEAD}" base="${2:-}" policy="${3:-}"
  local target_commit head_commit dirty_tracked=0 selected_untracked=0 candidate_commit

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "ERROR: differential review requires a Git working tree" >&2
    echo "next step: run this command from the repository you want to review" >&2
    return 2
  }
  target_commit=$(git rev-parse --verify "${requested_target}^{commit}" 2>/dev/null) || {
    echo "ERROR: review target is not a commit: $requested_target" >&2
    echo "next step: choose a commit/ref that exists and rerun" >&2
    return 2
  }
  head_commit=$(git rev-parse --verify HEAD)
  if [ -n "$base" ]; then
    git rev-parse --verify "${base}^{commit}" >/dev/null 2>&1 || {
      echo "ERROR: review base is not a commit: $base" >&2
      echo "next step: choose a base commit/ref that exists and rerun" >&2
      return 2
    }
  fi
  edc_candidate_has_dirty_tracked && dirty_tracked=1
  edc_candidate_has_selected_untracked && selected_untracked=1

  case "$policy" in
    "")
      if [ "$dirty_tracked" -eq 1 ] || [ "$selected_untracked" -eq 1 ]; then
        echo "ERROR: working tree contains changes that are not part of the committed target" >&2
        echo "excluded content: staged, unstaged, deleted, and non-ignored untracked files would not all be reviewed" >&2
        echo "next step: rerun with --include-working-tree to review the complete candidate, or --committed-only to exclude every working-tree change" >&2
        return 2
      fi
      ;;
    committed-only) ;;
    include-working-tree)
      if [ "$target_commit" != "$head_commit" ]; then
        echo "ERROR: --include-working-tree requires target HEAD; the requested target resolves to a historical commit" >&2
        echo "next step: rerun with HEAD --include-working-tree, or use $requested_target --committed-only" >&2
        return 2
      fi
      ;;
    *)
      echo "ERROR: invalid differential review policy: $policy" >&2
      return 2
      ;;
  esac

  if [ "$policy" = include-working-tree ] && { [ "$dirty_tracked" -eq 1 ] || [ "$selected_untracked" -eq 1 ]; }; then
    candidate_commit=$(edc_candidate_snapshot_working_tree "$target_commit") || return $?
    edc_candidate_export_scope working-tree-snapshot "$candidate_commit" "$requested_target" "$base" "$dirty_tracked" "$selected_untracked"
  else
    candidate_commit="$target_commit"
    edc_candidate_export_scope committed "$candidate_commit" "$requested_target" "$base" 0 0
  fi
  printf '%s\n' "$candidate_commit"
}
