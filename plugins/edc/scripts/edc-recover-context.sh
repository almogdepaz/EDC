#!/usr/bin/env bash
# edc-recover-context: shared context recovery state machine.
#
# Sourced (not exec'd) by orchestrators that need fresh context dir before
# proceeding. Defines `recover_context_if_needed` which:
#
#   1. If context already fresh (via assert_context_fresh) → return 0 immediately.
#   2. Otherwise classify state: MISSING (no manifest / no index.md / structureless)
#      vs STALE (manifest sourceCommit != HEAD).
#   3. Update from a valid manifest sourceCommit to HEAD, even if histories diverge.
#      Missing or invalid provenance refuses with an explicit force-rebuild hint.
#   4. For MISSING, or STALE with a malformed manifest: run the coordinator
#      build (edc-build.sh --force) as a child process.
#   5. For STALE: spawn the update agent via edc_spawn.
#   6. Re-check freshness. If still not fresh, run the coordinator build once.
#      The build keeps the previous context until the new context is staged.
#   7. Re-check. Return 0 on success, 1 with a copy-pasteable hint on failure.
#
# Caller contract:
#   - EDC_AGENT_CLI, edc_spawn, assert_context_fresh, run_with_timeout,
#     stream_filter must be defined/sourced first.
#
# resolve_prompt is auto-sourced from this directory if not already defined.
#   - Pass build/update args (e.g. --ignore) as positional arguments.
#     Build args are forwarded unchanged. For stale context, the canonical
#     manifest sourceCommit is appended as --context-source. Legacy update
#     --base arguments are discarded so review scope cannot control freshness.
#
# Args layout:
#   recover_context_if_needed [build_args... -- update_args...]
#
# `--` separator is OPTIONAL. If absent, all positional args are passed to
# both build and update prompts (typical case: --ignore applies to both).
# If present, args before `--` go to build only, args after to update only.

# Auto-source edc-lib.sh (paths + runtime + spawn + prompt resolution)
# if caller didn't.
_edc_recover_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${EDC_CONTEXT_DIR:-}" ] || ! command -v resolve_prompt >/dev/null 2>&1; then
  # shellcheck source=edc-lib.sh
  . "$_edc_recover_dir/edc-lib.sh"
fi
if ! command -v read_canonical_context_source_commit >/dev/null 2>&1; then
  # shellcheck source=edc-assert-fresh.sh
  . "$_edc_recover_dir/edc-assert-fresh.sh"
fi

# Report consent failures through the active orchestrator's existing result API.
# Security retains its older result writer; the other lenses use edc_result_failure.
_edc_context_choice_failure() {
  local reason="$1" message="$2" hint="$3"
  echo "$message" >&2
  echo "next step: $hint" >&2
  if [ "${EDC_REVIEW_RESULT_ACTIVE:-0}" = 1 ]; then
    edc_write_review_result 2 "$reason" "$message" "$hint" "" ""
  else
    edc_result_failure 2 "$reason" "$message" "$hint"
  fi
  return 2
}

# Public wrappers set ask (terminal), check (Pi fresh/no consent), or refresh
# (explicit consent). Unset retains the internal orchestrator recovery contract.
# Call after scope/candidate validation and before any model work. The result is
# a policy, not a context mode; callers must pass ignored through to every lens.
edc_resolve_review_context_choice() {
  EDC_RESOLVED_CONTEXT_POLICY="$1"
  local choice="${EDC_REVIEW_CONTEXT_CHOICE:-}" state answer=""
  [ "$1" = context ] || return 0
  [ "${EDC_REVIEW_CONTEXT_PREPARED:-0}" != 1 ] || return 0
  case "$choice" in
    ""|refresh) return 0 ;;
    ask|check) ;;
    *)
      _edc_context_choice_failure context-policy-invalid "Invalid public review context choice." \
        "rerun through edc with --refresh-context, --ignore-context, or --no-context-refresh"
      return 2
      ;;
  esac
  # Reuse contained JS reads for the UX state and the recovery gate for freshness.
  state=$(node --input-type=module -e '
    const { pathToFileURL } = await import("node:url");
    const { getContextFreshness } = await import(pathToFileURL(process.argv[1]).href);
    process.stdout.write(getContextFreshness(process.cwd()).state);
  ' "$_edc_recover_dir/../hooks/lib/route.mjs") || {
    _edc_context_choice_failure context-freshness-unknown "Could not determine context freshness." \
      "check repository access, then choose --refresh-context, --ignore-context, or --no-context-refresh"
    return 2
  }
  if [ "$state" = fresh ] && assert_context_fresh 2>/dev/null; then return 0; fi
  case "$state" in
    missing|stale) ;;
    *)
      _edc_context_choice_failure context-freshness-unknown "Context freshness is unknown; no review work was started." \
        "check the repository, then choose --refresh-context, --ignore-context, or --no-context-refresh"
      return 2
      ;;
  esac
  if [ "$choice" = check ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    _edc_context_choice_failure context-policy-required "Context is $state; refresh consent is required before reviewing." \
      "rerun with --refresh-context, --ignore-context, or --no-context-refresh (non-interactive runs never refresh implicitly)"
    return 2
  fi
  local action=build
  [ "$state" != stale ] || action=update
  printf 'EDC context: %s.\n1) %s context then review (may spawn agents)\n2) review without generated context\n3) cancel\ncontext choice [1/2/3]: ' "$state" "$action" >&2
  if ! IFS= read -r answer; then
    _edc_context_choice_failure review-cancelled "Review cancelled; context was not refreshed." \
      "rerun review and choose --refresh-context, --ignore-context, or --no-context-refresh"
    return 2
  fi
  case "$answer" in
    1) export EDC_REVIEW_CONTEXT_CHOICE=refresh; return 0 ;;
    2) EDC_RESOLVED_CONTEXT_POLICY=ignored; return 0 ;;
    *)
      _edc_context_choice_failure review-cancelled "Review cancelled; context was not refreshed." \
        "rerun review and choose --refresh-context, --ignore-context, or --no-context-refresh"
      return 2
      ;;
  esac
}

# Internal: classify why context is not fresh.
# Echoes "MISSING" or "STALE". Returns 0 on success.
_edc_classify_context_state() {
  # Missing, unreadable, corrupt, and non-object manifests need a rebuild.
  # Object manifests still pass through the canonical update-provenance guard.
  if ! node "$EDC_JSON_CLI" context-manifest-is-object "$MANIFEST" "$EDC_CONTEXT_DIR" >/dev/null 2>&1; then
    echo "MISSING"; return 0
  fi
  local ctx="$EDC_INDEX"
  if [ ! -f "$ctx" ] || ! grep -q '^##' "$ctx"; then
    echo "MISSING"; return 0
  fi
  local head source_commit
  head=$(git rev-parse HEAD 2>/dev/null) || { echo "MISSING"; return 0; }
  source_commit=$(read_manifest_source_commit 2>/dev/null || true)
  if [ -z "$source_commit" ] || [ "$source_commit" != "$head" ]; then
    echo "STALE"; return 0
  fi
  # Shouldn't happen — caller should only invoke us when assert_context_fresh failed.
  echo "MISSING"; return 0
}

# Internal: split args at `--` into build_args / update_args arrays. If no `--`
# present, both arrays receive all args.
_edc_split_recovery_args() {
  _edc_build_args=()
  _edc_update_args=()
  local seen_sep=0 a
  for a in "$@"; do
    if [ "$a" = "--" ]; then
      seen_sep=1
      continue
    fi
    if [ "$seen_sep" -eq 0 ]; then
      _edc_build_args+=("$a")
    else
      _edc_update_args+=("$a")
    fi
  done
  if [ "$seen_sep" -eq 0 ]; then
    # No separator: same args go to both phases.
    _edc_update_args=(${_edc_build_args[@]+"${_edc_build_args[@]}"})
  fi
}

_edc_set_context_update_source() {
  local source_commit idx
  source_commit=$(read_canonical_context_source_commit 2>/dev/null || true)
  [ -n "$source_commit" ] || return 1

  local -a normalized_args=()
  idx=0
  while [ "$idx" -lt "${#_edc_update_args[@]}" ]; do
    case "${_edc_update_args[$idx]}" in
      --base)
        [ $((idx + 1)) -lt "${#_edc_update_args[@]}" ] || return 1
        idx=$((idx + 2))
        ;;
      --ignore)
        [ $((idx + 1)) -lt "${#_edc_update_args[@]}" ] || return 1
        normalized_args+=("${_edc_update_args[$idx]}" "${_edc_update_args[$((idx + 1))]}")
        idx=$((idx + 2))
        ;;
      *)
        normalized_args+=("${_edc_update_args[$idx]}")
        idx=$((idx + 1))
        ;;
    esac
  done
  _edc_update_args=(${normalized_args[@]+"${normalized_args[@]}"} "--context-source" "$source_commit")
}

_edc_recovery_outputs_complete() {
  assert_context_fresh 2>/dev/null || return 1
  edc_entrypoint_valid || return 1

  local required_file
  for required_file in "$EDC_ISSUES" "$EDC_COMPLEXITY" "$EDC_BUILD_INFO"; do
    [ -f "$required_file" ] || return 1
  done
  grep -q '^##' "$EDC_ISSUES" || return 1
  grep -q '^##' "$EDC_COMPLEXITY" || return 1
  node "$EDC_JSON_CLI" valid-json "$EDC_BUILD_INFO" >/dev/null 2>&1 || return 1
  bash "$_edc_recover_dir/edc-doctor.sh" >/dev/null 2>&1 || return 1
}

_edc_recovery_success_with_warning_if_complete() {
  local phase="$1"
  if _edc_recovery_outputs_complete; then
    echo "EDC context recovery succeeded with warning: $phase subprocess reported failure, but complete build output validation passed." >&2
    echo "HINT: treating validated durable context as success; inspect the agent log for transport/provider diagnostics." >&2
    return 0
  fi
  return 1
}

_edc_recovery_failed_after_spawn() {
  local phase="$1"
  echo "EDC context recovery failed." >&2
  echo "reason: $phase subprocess failed and complete build output validation did not pass" >&2
  echo "next step: inspect the agent log above, then rerun context recovery after fixing the reported issue" >&2
  echo "hint: if the agent wrote partial context, run edc doctor or rebuild with edc build --agent <agent> --force" >&2
}

_edc_recovery_handle_failed_spawn() {
  local phase="$1" spawn_rc="$2"
  if [ "$spawn_rc" -eq 124 ]; then
    echo "EDC context recovery failed." >&2
    echo "reason: $phase subprocess timed out; refusing to continue because worker cleanup cannot be proven" >&2
    echo "next step: confirm no build workers remain, then rerun context recovery" >&2
    return 1
  fi
  _edc_recovery_success_with_warning_if_complete "$phase" \
    || { _edc_recovery_failed_after_spawn "$phase"; return 1; }
}

# Internal: run the coordinator-owned full build as a child process.
# The child owns routing, the worker dag, staging, promotion, doctor, and the
# curator passes. --force makes the child rebuild even when it classifies the
# layout as healthy. The child removes the previous context only after the new
# context is staged. The private result file keeps the child from overwriting
# the result file of the calling orchestrator.
_edc_recovery_run_coordinator_build() {
  local phase="$1"; shift
  local result_file rc=0
  result_file=$(mktemp "${TMPDIR:-/tmp}/edc-recovery-build-result-$$.XXXXXX") || return 1
  echo "→ running the coordinator build for context recovery ($phase)..." >&2
  EDC_AGENT_CLI="$EDC_AGENT_CLI" EDC_RESULT_FILE="$result_file" \
    bash "$_edc_recover_dir/edc-build.sh" --force "$@" < /dev/null || rc=$?
  rm -f "$result_file"
  return "$rc"
}

recover_context_if_needed() {
  if assert_context_fresh 2>/dev/null; then
    return 0
  fi
  # Freshness can change after the public wrapper checks it. An observation of
  # fresh context is not consent to start recovery later in the same run.
  case "${EDC_REVIEW_CONTEXT_CHOICE:-}" in
    ask|check)
      _edc_context_choice_failure context-policy-required "Context changed after preflight; refresh was not authorized." \
        "rerun with --refresh-context, --ignore-context, or --no-context-refresh"
      return 2
      ;;
  esac

  _edc_split_recovery_args "$@"

  local state spawn_rc=0
  state=$(_edc_classify_context_state)

  if [ "$state" = "STALE" ] && ! _edc_set_context_update_source; then
    echo "ERROR: context update requires a canonical, locally available manifest sourceCommit." >&2
    echo "next step: run edc build --agent $EDC_AGENT_CLI --force explicitly, then retry this command." >&2
    return 1
  fi

  # A stale context with a malformed manifest is never updated in place.
  # Rebuild it through the coordinator instead.
  if [ "$state" = "STALE" ] && ! node "$EDC_JSON_CLI" schema-version-is-2 "$MANIFEST" >/dev/null 2>&1; then
    echo "→ stale context has a malformed manifest; rebuilding instead of updating..." >&2
    state="MISSING"
  fi

  case "$state" in
    MISSING)
      echo "→ context missing, running the coordinator build via $EDC_AGENT_CLI..." >&2
      _edc_recovery_run_coordinator_build "edc-build" ${_edc_build_args[@]+"${_edc_build_args[@]}"} || spawn_rc=$?
      if [ "$spawn_rc" -ne 0 ]; then
        _edc_recovery_handle_failed_spawn "edc-build" "$spawn_rc" || return 1
      fi
      ;;
    STALE)
      echo "→ context stale, spawning $EDC_AGENT_CLI for edc-update..." >&2
      local update_prompt
      if update_prompt=$(resolve_prompt update ${_edc_update_args[@]+"${_edc_update_args[@]}"}); then
        spawn_rc=0
        edc_spawn "edc-update" "${EDC_UPDATE_TIMEOUT:-1800}" "$update_prompt" || spawn_rc=$?
        if [ "$spawn_rc" -eq 124 ]; then
          _edc_recovery_handle_failed_spawn "edc-update" "$spawn_rc" || return 1
        elif [ "$spawn_rc" -ne 0 ]; then
          if _edc_recovery_success_with_warning_if_complete "edc-update"; then
            return 0
          fi
          echo "→ edc-update failed; retrying context recovery with a force build..." >&2
        fi
      else
        echo "→ edc-update prompt resolution failed; retrying context recovery with a force build..." >&2
      fi
      ;;
  esac

  if assert_context_fresh 2>/dev/null; then
    return 0
  fi

  # Incremental recovery did not produce fresh, valid context or could not run
  # safely. Run the coordinator build exactly once. The build child keeps the
  # previous context until the new context is staged.
  echo "→ context still not ready — retrying with a coordinator build..." >&2
  spawn_rc=0
  _edc_recovery_run_coordinator_build "edc-build retry" ${_edc_build_args[@]+"${_edc_build_args[@]}"} || spawn_rc=$?
  if [ "$spawn_rc" -ne 0 ]; then
    _edc_recovery_handle_failed_spawn "edc-build retry" "$spawn_rc" || return 1
  fi

  if assert_context_fresh 2>/dev/null; then
    return 0
  fi

  echo "ERROR: context still not ready after recovery (manifest.json missing or invalid)." >&2
  echo "HINT: the build agent likely failed to produce a valid v2 layout." >&2
  echo "      check the build agent output above; you can also try:" >&2
  echo "      rm -rf $EDC_CONTEXT_DIR AGENTS.md EDC_AGENTS.md && edc build --agent <agent>" >&2
  return 1
}
