#!/usr/bin/env bash
# bash >= 4 required: uses declare -A (assoc arrays) and set -u with empty arrays
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
# edc-review orchestrator
# All deterministic control flow for edc-review lives here.
#
# Usage:
#   edc-review.sh [--agent <cli>] [--model <slug>] <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
#                                                     full review pipeline (default - spawns agent subprocesses via EDC_AGENT_CLI)
#   edc-review.sh --base <ref>                         shorthand for: HEAD --base <ref>
#   edc-review.sh --pr <number-or-url> [extras...]      shorthand for: pr:<number-or-url> [extras...]
#   edc-review.sh --build <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
#                                                     task-generation only (emit TASK lines, no subprocess spawning)
#   edc-review.sh --build --pr <number-or-url> [extras...]
#                                                     task-generation for a PR without a full URL
#   edc-review.sh --check-context                      assert <EDC_CONTEXT_DIR>/manifest.json fresh (no diff, no task gen)
#   edc-review.sh --consolidate                        merge per-module reports into final review file
#   edc-review.sh --verify                             assert context fresh + reports + final file exist
#
# --build exit codes:
#   0 - $EDC_REVIEW_TASKS_DIR/ written, TASK lines on stdout, proceed with skill
#   1 - context not ready (CONTEXT_MISSING or CONTEXT_STALE), see stdout
#   2 - bad arguments or environment error
#
# Consolidate / verify exit codes:
#   0 - all assertions pass
#   1 - assertion failed (missing report, missing final file, stale context)
#   2 - bad arguments or environment error

set -euo pipefail

# ── dependency check ─────────────────────────────────────────────────────────

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required (brew install jq / apt install jq)" >&2
  exit 2
fi

# Resolve SCRIPT_DIR through symlinks so sibling helpers (edc-assert-fresh.sh,
# edc-clean-slate.sh) are found relative to the real script location, not the
# invocation path. Defensive - the installer copies (not symlinks) into
# ~/.edc/scripts/, but users may symlink manually.
_edc_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_edc_resolve_script_dir)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
MANIFEST="$EDC_MANIFEST"
CLEAN_SLATE_SH="$SCRIPT_DIR/edc-clean-slate.sh"
ROUTE_SH="$SCRIPT_DIR/edc-route.sh"

# ── agent CLI configuration ──────────────────────────────────────────────────
#
# EDC_AGENT_CLI selects which CLI spawns subprocess agents for the review pipeline.
#   "claude"  → claude -p  (default, backward-compatible)
#   "cursor"  → cursor agent -p
#   "codex"   → codex exec

EDC_AGENT_CLI="${EDC_AGENT_CLI:-claude}"
CODEX_EXEC_HOME=""
CODEX_EXEC_HOME_OWNED=0

final_review_filename() {
  # derive consolidated review filename from a target string
  local target="$1"
  echo "review-$(echo "$target" | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-40).md"
}

# read_manifest_source_commit + assert_context_fresh come from edc-assert-fresh.sh.
# recover_context_if_needed (freshness gate + spawn build/update + force-retry)
# comes from edc-recover-context.sh. Both sourced (not exec'd) so functions
# run in this shell. edc_spawn, run_with_timeout, stream_filter,
# resolve_prompt, and the EDC_* path vars come from edc-lib.sh, sourced above.
# shellcheck source=edc-assert-fresh.sh
. "$SCRIPT_DIR/edc-assert-fresh.sh"
# shellcheck source=edc-recover-context.sh
. "$SCRIPT_DIR/edc-recover-context.sh"

manifest_target() {
  local val
  val=$(jq -r '.target // empty' "$EDC_REVIEW_TASKS_MANIFEST" 2>/dev/null || true)
  if [ -z "$val" ]; then
    echo "ERROR: could not read target from $EDC_REVIEW_TASKS_MANIFEST" >&2
    return 1
  fi
  echo "$val"
}

manifest_modules() {
  # one module name per line
  local val
  val=$(jq -r '.modules[]?.name // empty' "$EDC_REVIEW_TASKS_MANIFEST" 2>/dev/null || true)
  if [ -z "$val" ]; then
    echo "ERROR: could not read modules from $EDC_REVIEW_TASKS_MANIFEST" >&2
    return 1
  fi
  echo "$val"
}

manifest_context_mode() {
  jq -r '.contextMode // "context"' "$EDC_REVIEW_TASKS_MANIFEST" 2>/dev/null || echo "context"
}

load_ignore_patterns() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
    return 0
  fi

  if [ ! -f ".edcignore" ]; then
    return 0
  fi

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac
    printf '%s\n' "$line"
  done < ".edcignore"
}

path_matches_ignore() {
  local path="$1" pattern="$2"
  if [[ "$pattern" == */ ]]; then
    [[ "$path" == ${pattern}* ]]
    return
  fi

  [[ "$path" == "$pattern" ]] \
    || [[ "$path" == "$pattern/"* ]] \
    || [[ "$path" == $pattern ]]
}

filter_ignored_files() {
  local files="$1"
  shift
  local patterns
  patterns=$(load_ignore_patterns "$@")
  if [ -z "$patterns" ]; then
    printf '%s' "$files"
    return 0
  fi

  local filtered=""
  local file pattern ignored
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    ignored=0
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if path_matches_ignore "$file" "$pattern"; then
        ignored=1
        break
      fi
    done <<< "$patterns"
    [ "$ignored" -eq 1 ] && continue
    filtered+="${file}"$'\n'
  done <<< "$files"

  printf '%s' "$filtered"
}

# assert_report_valid <module>: require report with at least one ## heading
# (edc-review skill always emits ## What Changed, ## Findings, etc. per reporting.md)
assert_report_valid() {
  local module="$1"
  local report="$EDC_REVIEW_TASKS_DIR/report-${module}.md"
  if [ ! -f "$report" ]; then
    echo "ERROR: missing $report - edc-review skill did not produce output for module '$module'" >&2
    return 1
  fi
  if ! grep -q '^##' "$report"; then
    echo "ERROR: $report has no '## ' headings (module: $module) - expected sections like ## What Changed, ## Findings" >&2
    echo "HINT: this usually means the edc-review skill was bypassed or wrote a stub. check the subprocess output above." >&2
    return 1
  fi
}

write_allowed_unmapped_report() {
  local files="$1"
  local report="$EDC_REVIEW_TASKS_DIR/report-allowed-unmapped.md"

  {
    echo "# Differential Review Report: allowed-unmapped"
    echo ""
    echo "## What Changed"
    echo ""
    echo "The following changed paths match \`$MANIFEST\` \`unmapped.allowedGlobs\` and are intentionally outside module ownership:"
    echo ""
    echo "$files" | grep -v '^$' | sed 's/^/- `/' | sed 's/$/`/'
    echo ""
    echo "## Findings"
    echo ""
    echo "No module review was spawned for these paths. They are explicitly allowed as unmapped, so they are intentionally skipped but still accounted for in the final review."
    echo ""
    echo "## Coverage Notes"
    echo ""
    echo "Unexpected unmapped source files are still routed through the synthetic \`unmapped\` review task according to \`policy.unmatchedPathPolicy\`."
  } > "$report"
}

# ── check-context mode ───────────────────────────────────────────────────────

check_context_mode() {
  assert_context_fresh || exit 1
  echo "OK"
}

# ── consolidate mode ─────────────────────────────────────────────────────────

consolidate_mode() {
  if [ ! -f "$EDC_REVIEW_TASKS_MANIFEST" ]; then
    echo "ERROR: $EDC_REVIEW_TASKS_MANIFEST missing - run build mode first" >&2
    exit 1
  fi

  local target final modules missing=0
  target=$(manifest_target)
  final=$(final_review_filename "$target")
  modules=$(manifest_modules)

  if [ -z "$modules" ]; then
    echo "ERROR: no modules in manifest.json" >&2
    exit 1
  fi

  # verify every expected report is present and non-trivial before writing final file
  while IFS= read -r module; do
    [ -z "$module" ] && continue
    assert_report_valid "$module" || missing=1
  done <<< "$modules"

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi

  # write final file
  {
    echo "# Review: ${target}"
    echo ""
    echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "**HEAD:** $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "**Modules reviewed:** $(echo "$modules" | tr '\n' ' ')"
    echo ""
    echo "---"
    echo ""
    while IFS= read -r module; do
      [ -z "$module" ] && continue
      echo "## Module: \`${module}\`"
      echo ""
      cat "$EDC_REVIEW_TASKS_DIR/report-${module}.md"
      echo ""
      echo "---"
      echo ""
    done <<< "$modules"
  } > "$final"

  echo "Consolidated: $final"
}

# ── verify mode ──────────────────────────────────────────────────────────────

verify_mode() {
  if [ ! -f "$EDC_REVIEW_TASKS_MANIFEST" ]; then
    echo "ERROR: $EDC_REVIEW_TASKS_MANIFEST missing" >&2
    exit 1
  fi

  if [ "$(manifest_context_mode)" = "context" ]; then
    assert_context_fresh || exit 1
  fi

  local target final modules missing=0
  target=$(manifest_target)
  final=$(final_review_filename "$target")
  modules=$(manifest_modules)

  while IFS= read -r module; do
    [ -z "$module" ] && continue
    if [ ! -f "$EDC_REVIEW_TASKS_DIR/report-${module}.md" ]; then
      echo "ERROR: missing $EDC_REVIEW_TASKS_DIR/report-${module}.md" >&2
      missing=1
    fi
  done <<< "$modules"

  if [ ! -f "$final" ]; then
    echo "ERROR: missing final review file ($final)" >&2
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi

  echo "Verified: $final"
}

# ── auto mode ────────────────────────────────────────────────────────────────
#
# Self-driving pipeline: detect context state, spawn agent subprocesses for each
# phase, verify outputs, consolidate, verify. The orchestrator script owns every
# decision; the spawned agents have one job each.
# Set EDC_AGENT_CLI=claude|cursor|codex|pi before invoking.

auto_mode() {
  edc_require_agent_cli

  local target="$1"; shift
  local extra_args=("$@")
  local -a build_args=() update_args=()
  local no_context_refresh=0
  local ignore_context=0
  local idx=0
  while [ "$idx" -lt "${#extra_args[@]}" ]; do
    case "${extra_args[$idx]}" in
      --base)
        [ $((idx + 1)) -lt "${#extra_args[@]}" ] || { echo "ERROR: --base requires a ref" >&2; exit 2; }
        update_args+=("${extra_args[$idx]}" "${extra_args[$((idx + 1))]}")
        idx=$((idx + 2))
        ;;
      --ignore)
        [ $((idx + 1)) -lt "${#extra_args[@]}" ] || { echo "ERROR: --ignore requires a glob pattern" >&2; exit 2; }
        build_args+=("${extra_args[$idx]}" "${extra_args[$((idx + 1))]}")
        update_args+=("${extra_args[$idx]}" "${extra_args[$((idx + 1))]}")
        idx=$((idx + 2))
        ;;
      --context-mode)
        [ $((idx + 1)) -lt "${#extra_args[@]}" ] || { echo "ERROR: --context-mode requires a value" >&2; exit 2; }
        idx=$((idx + 2))
        ;;
      --no-context-refresh)
        no_context_refresh=1
        idx=$((idx + 1))
        ;;
      --ignore-context)
        ignore_context=1
        idx=$((idx + 1))
        ;;
      *)
        idx=$((idx + 1))
        ;;
    esac
  done

  # Gate on freshness; recover (build/update + force-retry) unless the caller
  # explicitly requested a no-refresh run. --no-context-refresh may still use
  # existing context; it just refuses to create/update it. --ignore-context is
  # the stronger pure-baseline mode.
  if [ "$no_context_refresh" -ne 1 ] && [ "$ignore_context" -ne 1 ]; then
    recover_context_if_needed "${build_args[@]}" -- "${update_args[@]}" \
      || exit 1
  fi

  # Build review tasks now that context is fresh.
  local out
  out=$("$EDC_BASH" "$0" --build "$target" "${extra_args[@]}" 2>&1) || true

  if ! echo "$out" | grep -q "^Review tasks ready"; then
    echo "ERROR: script did not produce review tasks. Output:" >&2
    echo "$out" >&2
    exit 1
  fi

  # Parse TASK lines. allowed-unmapped is satisfied by a deterministic
  # prewritten report and intentionally emits no subprocess task.
  local tasks
  tasks=$(echo "$out" | grep '^TASK ' | sed 's/^TASK //' || true)
  if [ -z "$tasks" ]; then
    local module prewritten_missing=0
    while IFS= read -r module; do
      [ -z "$module" ] && continue
      assert_report_valid "$module" || prewritten_missing=1
    done <<< "$(manifest_modules)"
    if [ "$prewritten_missing" -ne 0 ]; then
      echo "ERROR: no TASK lines in script output and no complete prewritten reports" >&2
      exit 1
    fi
  fi

  # Spawn one agent subprocess per module.
  # The here-string on each spawn provides the prompt via stdin, overriding
  # the loop's <<< "$tasks" so it doesn't leak into the subprocess.
  while IFS= read -r task_path; do
    [ -z "$task_path" ] && continue
    local module
    module=$(basename "$task_path" .md)
    echo "→ reviewing module: $module"
    local review_prompt
    review_prompt=$(resolve_prompt review "$task_path") || exit 1
    edc_spawn "edc-review/$module" "${EDC_REVIEW_TIMEOUT:-1800}" "$review_prompt" \
      || { echo "ERROR: review invocation failed for module $module" >&2; exit 1; }
    assert_report_valid "$module" \
      || { echo "ERROR: report validation failed for module $module" >&2; exit 1; }
  done <<< "$tasks"

  # Consolidate + verify
  "$EDC_BASH" "$0" --consolidate || { echo "ERROR: consolidation failed" >&2; exit 1; }
  "$EDC_BASH" "$0" --verify     || { echo "ERROR: verification failed" >&2; exit 1; }

  # Auto-cleanup: review tasks are pure IPC scaffolding; the consolidated
  # review-<target>.md at the repo root is the durable artifact. On success,
  # remove $EDC_REVIEW_TASKS_DIR/ so it doesn't clutter the tree. Failures
  # exit non-zero above and leave the directory in place for inspection.
  # Override with EDC_KEEP_REVIEW_TASKS=1 to keep the dir on success too.
  if [ "${EDC_KEEP_REVIEW_TASKS:-0}" != "1" ]; then
    rm -rf "$EDC_REVIEW_TASKS_DIR"
  fi

  # Explicit exit so any late-arriving subprocess output can't poison our
  # exit code after the pipeline succeeded.
  exit 0
}

# ── build mode ───────────────────────────────────────────────────────────────

build_mode() {
  local target="$1"; shift
  local baseline=""
  local no_context_refresh=0
  local ignore_context=0
  local context_available=1
  local -a ignore_patterns=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) baseline="$2"; shift 2 ;;
      --ignore)
        [ $# -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; exit 2; }
        ignore_patterns+=("$2")
        shift 2
        ;;
      --context-mode)
        [ $# -ge 2 ] || { echo "ERROR: --context-mode requires a value" >&2; exit 2; }
        shift 2
        ;;
      --no-context-refresh)
        no_context_refresh=1
        shift
        ;;
      --ignore-context)
        ignore_context=1
        shift
        ;;
      *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
  done

  # Step 1: context gate
  local head
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "ERROR: not a git repo" >&2; exit 2; }

  if [ "$ignore_context" -ne 1 ]; then
    if [ ! -f "$MANIFEST" ]; then
      if [ "$no_context_refresh" -eq 1 ]; then
        context_available=0
      else
        echo "CONTEXT_MISSING"
        echo "No $MANIFEST found. Run edc-build before reviewing."
        exit 1
      fi
    fi

    # Structural check: index.md must exist and contain ## headings. Absent or
    # stubbed index.md means edc-build never finished (or wrote junk). In
    # --no-context-refresh mode, do not recover; fall back to a direct review
    # task instead.
    local ctx="$EDC_INDEX"
    if [ "$context_available" -eq 1 ] && { [ ! -f "$ctx" ] || ! grep -q '^##' "$ctx"; }; then
      if [ "$no_context_refresh" -eq 1 ]; then
        context_available=0
      else
        echo "CONTEXT_MISSING"
        echo "$ctx is missing or has no '## ' headings (stub). Run edc-build before reviewing."
        exit 1
      fi
    fi

    local source_commit=""
    if [ "$context_available" -eq 1 ]; then
      source_commit=$(read_manifest_source_commit)
      if [ "$source_commit" != "$head" ] && [ "$no_context_refresh" -ne 1 ]; then
        echo "CONTEXT_STALE"
        echo "Context is stale (built at: $source_commit, HEAD: $head). Run edc-update before reviewing."
        exit 1
      fi
      if [ "$source_commit" != "$head" ] && [ "$no_context_refresh" -eq 1 ]; then
        echo "WARNING: context is stale (built at: $source_commit, HEAD: $head); using it because --no-context-refresh was requested" >&2
      fi
    fi
  fi

  # Step 2: get changed files
  local files
  if [[ "$target" == https://* ]]; then
    files=$(gh pr diff "$target" --name-only 2>/dev/null)
  elif [[ "$target" == pr:* ]]; then
    files=$(gh pr diff "${target#pr:}" --name-only 2>/dev/null)
  elif [ -f "$target" ]; then
    files=$(grep '^+++ b/' "$target" | sed 's|^+++ b/||' || true)
    if [ -z "$files" ]; then
      echo "ERROR: no '+++ b/' lines found in diff file: $target" >&2
      exit 2
    fi
  else
    local base="${baseline:-${target}^}"
    files=$(git diff "${base}..${target}" --name-only)
  fi

  if [ -z "$files" ]; then
    echo "ERROR: no changed files found for target: $target" >&2
    exit 2
  fi

  # Filter out tool-internal paths. These are edc scratch state - reviewing
  # them would make the tool eat its own tail (review the context dir,
  # $EDC_REVIEW_TASKS_DIR/ - itself under $EDC_CONTEXT_DIR/ - or prior
  # review-*.md files as if they were source).
  files=$(echo "$files" | grep -Ev "^(${EDC_CONTEXT_DIR}/|review-[^/]+\.md$)" || true)
  files=$(filter_ignored_files "$files" "${ignore_patterns[@]}")

  if [ -z "$files" ]; then
    echo "ERROR: no reviewable files after filtering tool output and ignore rules" >&2
    echo "HINT: target may contain only edc scratch files or files matched by --ignore/.edcignore." >&2
    exit 2
  fi

  if [ "$ignore_context" -eq 1 ] || [ "$context_available" -eq 0 ]; then
    rm -rf "$EDC_REVIEW_TASKS_DIR"
    mkdir -p "$EDC_REVIEW_TASKS_DIR"

    local file_json file_list context_mode direct_module instruction_1 extra_instruction
    file_json=$(echo "$files" \
      | grep -v '^$' \
      | sed 's/^/"/;s/$/"/' \
      | tr '\n' ',' \
      | sed 's/,$//')
    file_list=$(echo "$files" | grep -v '^$' | sed 's/^/- /')

    if [ "$ignore_context" -eq 1 ]; then
      context_mode="ignored"
      direct_module="ignore-context"
      instruction_1="Do not read \`${EDC_INDEX}\`, \`${EDC_ISSUES}\`, or any \`${EDC_CONTEXT_DIR}/\` module docs."
      extra_instruction=$'DO NOT use prebuilt EDC context, even if it exists in this repository.'
    else
      context_mode="no-refresh"
      direct_module="no-context-refresh"
      instruction_1="No usable EDC context was available without building/updating. Review the changed files directly."
      extra_instruction=""
    fi

    cat > "$EDC_REVIEW_TASKS_MANIFEST" <<TASK_MANIFEST
{
  "target": "$target",
  "baseline": "$baseline",
  "head": "$head",
  "contextMode": "$context_mode",
  "modules": [
    { "name": "$direct_module", "doc": "", "files": [$file_json] }
  ]
}
TASK_MANIFEST

    cat > "$EDC_REVIEW_TASKS_DIR/${direct_module}.md" <<TASK
# Review Task: \`${direct_module}\`

## Target
${target}

## Files to review
${file_list}

## Instructions

1. ${instruction_1}
2. Review only the changed files listed above and whatever adjacent source files are necessary to understand the diff.
3. Use the embedded edc-review methodology to perform the full review on the files listed above.
4. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${direct_module}.md\`

DO NOT build or update EDC context.
${extra_instruction}
TASK

    echo "routing summary: context=$context_mode files=$(echo "$files" | grep -cve '^$') modules=1" >&2
    echo ""
    echo "Review tasks ready."
    echo ""
    echo "TASK $EDC_REVIEW_TASKS_DIR/${direct_module}.md"
    return 0
  fi

  # Step 3: group by module via $EDC_MANIFEST routing.
  # Use edc-route.sh - single source of truth, same logic the hooks use.
  # Files with no module match go into a synthetic "unmapped" bucket and
  # are surfaced according to policy.unmatchedPathPolicy. Ambiguous routing
  # is a hard error (manifest bug, refuse to silently pick a winner).
  if [ ! -x "$ROUTE_SH" ] && [ ! -f "$ROUTE_SH" ]; then
    echo "ERROR: edc-route.sh not found at $ROUTE_SH" >&2
    exit 2
  fi

  local unmatched_policy
  unmatched_policy=$(jq -r '.policy.unmatchedPathPolicy // "warn-allow"' "$MANIFEST")
  case "$unmatched_policy" in
    warn-allow|allow|fail) ;;
    *)
      echo "ERROR: invalid policy.unmatchedPathPolicy in $MANIFEST: '$unmatched_policy'" >&2
      echo "HINT: must be one of: warn-allow, allow, fail" >&2
      exit 2
      ;;
  esac

  # Pre-compile allowedGlobs so we can suppress per-file warnings for paths
  # the manifest already declared as expected-unmapped (README, package.json,
  # docs/*, etc).
  local -a allowed_globs=()
  while IFS= read -r g; do
    [ -n "$g" ] && allowed_globs+=("$g")
  done < <(jq -r '.unmapped.allowedGlobs // [] | .[]' "$MANIFEST")

  _is_expected_unmapped() {
    local path="$1" g
    for g in "${allowed_globs[@]}"; do
      # shellcheck disable=SC2053
      [[ "$path" == $g ]] && return 0
    done
    return 1
  }

  declare -A MODULE_FILES
  local ambiguous_count=0 unmapped_count=0 mapped_count=0 allowed_unmapped_count=0
  local allowed_unmapped_files=""
  local -a unmapped_unexpected=()
  local -a ambiguous_lines=()

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    local module route_err route_rc=0
    route_err=$(mktemp)
    module=$("$EDC_BASH" "$ROUTE_SH" "$MANIFEST" "$file" 2>"$route_err") || route_rc=$?

    case "$route_rc" in
      0)
        MODULE_FILES["$module"]+="${file}"$'\n'
        mapped_count=$((mapped_count + 1))
        ;;
      1)
        # No module match. Expected unmapped paths are intentionally outside
        # module ownership, so they get a deterministic skipped report instead
        # of a fragile spawned reviewer task. Unexpected ones still route to
        # the synthetic "unmapped" module for policy enforcement/review.
        unmapped_count=$((unmapped_count + 1))
        if _is_expected_unmapped "$file"; then
          allowed_unmapped_files+="${file}"$'\n'
          allowed_unmapped_count=$((allowed_unmapped_count + 1))
        else
          MODULE_FILES["unmapped"]+="${file}"$'\n'
          unmapped_unexpected+=("$file")
        fi
        ;;
      2)
        ambiguous_count=$((ambiguous_count + 1))
        ambiguous_lines+=("$file: $(cat "$route_err")")
        ;;
      *)
        echo "ERROR: edc-route.sh failed (rc=$route_rc) for path: $file" >&2
        cat "$route_err" >&2
        rm -f "$route_err"
        exit 2
        ;;
    esac
    rm -f "$route_err"
  done <<< "$files"

  # Ambiguous routing is always fatal - manifest bug, not a runtime concern.
  if [ "$ambiguous_count" -gt 0 ]; then
    echo "ERROR: $ambiguous_count file(s) match multiple modules at top priority:" >&2
    local line
    for line in "${ambiguous_lines[@]}"; do
      echo "  $line" >&2
    done
    echo "HINT: edit $MANIFEST - bump priority on the intended" >&2
    echo "      module or tighten its match.{exactFiles,prefixes,globs} rules" >&2
    exit 2
  fi

  # Unmapped policy enforcement.
  if [ "${#unmapped_unexpected[@]}" -gt 0 ]; then
    case "$unmatched_policy" in
      fail)
        echo "ERROR: ${#unmapped_unexpected[@]} changed file(s) not mapped to any module (policy=fail):" >&2
        local f
        for f in "${unmapped_unexpected[@]}"; do
          echo "  $f" >&2
        done
        echo "HINT: add a module rule in $MANIFEST or list the path" >&2
        echo "      in unmapped.allowedGlobs, then re-run." >&2
        exit 2
        ;;
      warn-allow)
        echo "WARNING: ${#unmapped_unexpected[@]} changed file(s) not mapped to any module (will review under 'unmapped'):" >&2
        local f
        for f in "${unmapped_unexpected[@]}"; do
          echo "  $f" >&2
        done
        ;;
      allow)
        : # silent - counted in summary below only
        ;;
    esac
  fi

  if [ "$allowed_unmapped_count" -gt 0 ]; then
    MODULE_FILES["allowed-unmapped"]="$allowed_unmapped_files"
  fi

  echo "routing summary: mapped=$mapped_count unmapped=$unmapped_count allowed-unmapped=$allowed_unmapped_count modules=${#MODULE_FILES[@]}" >&2

  # Step 4: write $EDC_REVIEW_TASKS_DIR/
  rm -rf "$EDC_REVIEW_TASKS_DIR"
  mkdir -p "$EDC_REVIEW_TASKS_DIR"

  local sorted_modules
  sorted_modules=$(printf '%s\n' "${!MODULE_FILES[@]}" | sort)

  # manifest.json (script-internal source of truth for consolidate/verify)
  {
    echo "{"
    echo "  \"target\": \"$target\","
    echo "  \"baseline\": \"$baseline\","
    echo "  \"head\": \"$head\","
    if [ "$no_context_refresh" -eq 1 ]; then
      echo "  \"contextMode\": \"no-refresh\","
    else
      echo "  \"contextMode\": \"context\","
    fi
    echo "  \"modules\": ["
    local first=1
    while IFS= read -r module; do
      [ "$first" -eq 0 ] && echo "    ,"
      # Synthetic accounting/review buckets have no per-module doc; emit empty
      # doc field so review subprocesses do not read nonexistent module context.
      local module_doc="${EDC_MODULES_DIR}/${module}.md"
      case "$module" in
        unmapped|allowed-unmapped) module_doc="" ;;
      esac
      echo -n "    { \"name\": \"$module\", \"doc\": \"${module_doc}\", \"files\": ["
      local file_json
      file_json=$(echo "${MODULE_FILES[$module]}" \
        | grep -v '^$' \
        | sed 's/^/"/;s/$/"/' \
        | tr '\n' ',' \
        | sed 's/,$//')
      echo -n "$file_json"
      echo -n "] }"
      first=0
    done <<< "$sorted_modules"
    echo ""
    echo "  ]"
    echo "}"
  } > "$EDC_REVIEW_TASKS_MANIFEST"

  # per-module task files
  while IFS= read -r module; do
    local file_list baseline_line module_context_line
    file_list=$(echo "${MODULE_FILES[$module]}" | grep -v '^$' | sed 's/^/- /')

    if [ "$module" = "allowed-unmapped" ]; then
      write_allowed_unmapped_report "${MODULE_FILES[$module]}"
      continue
    fi

    baseline_line=""
    [ -n "$baseline" ] && baseline_line=$'\n'"## Baseline"$'\n'"${baseline}"

    if [ "$module" = "unmapped" ]; then
      module_context_line="3. NOTE: these files are not matched by the current ${EDC_MANIFEST} routing. Use only \`${EDC_INDEX}\` for repo-level context; there is no per-module deep context for these paths. State this limitation clearly in the report."
    else
      module_context_line="3. Read \`${EDC_MODULES_DIR}/${module}.md\` if it exists - deep per-module context, invariants, call graphs"
    fi

    cat > "$EDC_REVIEW_TASKS_DIR/${module}.md" <<TASK
# Review Task: \`${module}\`

## Target
${target}${baseline_line}

## Files to review
${file_list}

## Instructions

1. Read \`${EDC_INDEX}\` - module map, invariants, trust boundaries
2. Read \`${EDC_ISSUES}\` if it exists - cross-reference known issues against the files above
${module_context_line}
4. Use the edc-review skill to perform the full review on the files listed above
5. Write your report to \`$EDC_REVIEW_TASKS_DIR/report-${module}.md\`

DO NOT write your own review methodology.
DO NOT skip reading the context files.
USE the edc-review skill.
TASK
  done <<< "$sorted_modules"

  # Done - emit TASK lines for the agent to iterate. Deterministic skipped
  # reports are already complete and must not spawn an agent subprocess.
  echo ""
  echo "Review tasks ready."
  echo ""
  while IFS= read -r module; do
    if [ "$module" = "allowed-unmapped" ]; then
      continue
    fi
    echo "TASK $EDC_REVIEW_TASKS_DIR/${module}.md"
  done <<< "$sorted_modules"
}

review_usage() {
  cat <<EOF
Usage: edc-review.sh [--agent <cli>] [--model <slug>] <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
                                                     full review pipeline (default)
       edc-review.sh --base <ref> [--no-context-refresh|--ignore-context]
                                                     shorthand for HEAD --base <ref>
       edc-review.sh --pr <number-or-url> [--base <ref>] [--no-context-refresh|--ignore-context]
                                                     shorthand for PR review without full URL
       edc-review.sh --no-context-refresh [--base <ref>]  shorthand for HEAD --no-context-refresh
       edc-review.sh --ignore-context [--base <ref>]      shorthand for HEAD --ignore-context
       edc-review.sh --build <target> [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject] [--no-context-refresh|--ignore-context]
                                                     generate $EDC_REVIEW_TASKS_DIR/ only (no subprocess spawning)
       edc-review.sh --build --pr <number-or-url> [--ignore-context|--no-context-refresh]
                                                     generate PR review tasks without full URL
       edc-review.sh --check-context
       edc-review.sh --consolidate
       edc-review.sh --verify
EOF
}

# ── dispatch ─────────────────────────────────────────────────────────────────

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --agent requires an agent cli" >&2
        exit 2
      fi
      EDC_AGENT_CLI="$2"
      export EDC_AGENT_CLI
      shift 2
      ;;
    --agent=*)
      EDC_AGENT_CLI="${1#--agent=}"
      export EDC_AGENT_CLI
      shift
      ;;
    --model)
      if [ -z "${2:-}" ]; then
        echo "ERROR: --model requires a model slug" >&2
        exit 2
      fi
      export EDC_BUILD_MODEL="$2"
      export EDC_REVIEW_MODEL="$2"
      shift 2
      ;;
    --model=*)
      export EDC_BUILD_MODEL="${1#--model=}"
      export EDC_REVIEW_MODEL="${1#--model=}"
      shift
      ;;
    *)
      break
      ;;
  esac
done
case "${1:-}" in
  --build)
    shift
    if [ "${1:-}" = "--pr" ]; then
      if [ -z "${2:-}" ]; then
        echo "ERROR: --build --pr requires a PR number or URL (e.g. --build --pr 147)" >&2
        exit 2
      fi
      pr_target="$2"
      shift 2
      build_mode "pr:$pr_target" "$@"
      exit $?
    fi
    if [ -z "${1:-}" ]; then
      echo "ERROR: --build requires a target" >&2
      exit 2
    fi
    build_mode "$@"
    ;;
  --base)
    # Shorthand: --base <ref> [extras...] → HEAD --base <ref> [extras...]
    if [ -z "${2:-}" ]; then
      echo "ERROR: --base requires a ref (e.g. --base main)" >&2
      exit 2
    fi
    auto_mode HEAD --base "$2" "${@:3}"
    ;;
  --pr)
    # Shorthand: --pr <number-or-url> [extras...] → pr:<number-or-url> [extras...]
    if [ -z "${2:-}" ]; then
      echo "ERROR: --pr requires a PR number or URL (e.g. --pr 147)" >&2
      exit 2
    fi
    auto_mode "pr:$2" "${@:3}"
    ;;
  pr|PR)
    # Shorthand: pr <number-or-url> [extras...] → pr:<number-or-url> [extras...]
    if [ -z "${2:-}" ]; then
      echo "ERROR: pr requires a PR number or URL (e.g. pr 147)" >&2
      exit 2
    fi
    auto_mode "pr:$2" "${@:3}"
    ;;
  --no-context-refresh)
    # Shorthand: --no-context-refresh [extras...] → HEAD --no-context-refresh [extras...]
    auto_mode HEAD --no-context-refresh "${@:2}"
    ;;
  --ignore-context)
    # Shorthand: --ignore-context [extras...] → HEAD --ignore-context [extras...]
    auto_mode HEAD --ignore-context "${@:2}"
    ;;
  --check-context)
    check_context_mode
    ;;
  --consolidate)
    consolidate_mode
    ;;
  --verify)
    verify_mode
    ;;
  -h|--help)
    review_usage
    exit 0
    ;;
  "")
    echo "ERROR: target required (PR URL, commit SHA, or diff path)" >&2
    review_usage >&2
    exit 2
    ;;
  --*)
    echo "ERROR: unknown flag: $1" >&2
    echo "Run 'edc-review.sh' with no args for usage." >&2
    exit 2
    ;;
  *)
    auto_mode "$@"
    ;;
esac
