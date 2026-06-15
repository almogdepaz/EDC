#!/usr/bin/env bash
# edc-recover-context: shared context recovery state machine.
#
# Sourced (not exec'd) by orchestrators that need fresh context dir before
# proceeding. Defines `recover_context_if_needed` which:
#
#   1. If context already fresh (via assert_context_fresh) → return 0 immediately.
#   2. Otherwise classify state: MISSING (no manifest / no index.md / structureless)
#      vs STALE (manifest sourceCommit != HEAD).
#   3. Clean-slate any v1 / partial-v2 leftovers.
#   4. Spawn build (for MISSING) or update (for STALE) via edc_spawn.
#   5. Re-check freshness. If still not fresh, wipe + force-rebuild once.
#   6. Re-check. Return 0 on success, 1 with a copy-pasteable hint on failure.
#
# Caller contract:
#   - EDC_AGENT_CLI, edc_spawn, assert_context_fresh, run_with_timeout,
#     stream_filter must be defined/sourced first.
#   - CLEAN_SLATE_SH must point at edc-clean-slate.sh.
#
# resolve_prompt is auto-sourced from this directory if not already defined.
#   - Pass build/update args (e.g. --ignore, --base) as positional arguments;
#     they are forwarded to the spawned build/update prompts.
#
# Args layout:
#   recover_context_if_needed [build_args... -- update_args...]
#
# `--` separator is OPTIONAL. If absent, all positional args are passed to
# both build and update prompts (typical case: --ignore applies to both).
# If present, args before `--` go to build only, args after to update only.
# Review-style callers that want --base on update only use the `--` form.

# Auto-source edc-lib.sh (paths + runtime + spawn + prompt resolution)
# if caller didn't.
_edc_recover_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${EDC_CONTEXT_DIR:-}" ] || ! command -v resolve_prompt >/dev/null 2>&1; then
  # shellcheck source=edc-lib.sh
  . "$_edc_recover_dir/edc-lib.sh"
fi

# Internal: classify why context is not fresh.
# Echoes "MISSING" or "STALE". Returns 0 on success.
_edc_classify_context_state() {
  if [ ! -f "$MANIFEST" ]; then
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
    _edc_update_args=("${_edc_build_args[@]}")
  fi
}

recover_context_if_needed() {
  if assert_context_fresh 2>/dev/null; then
    return 0
  fi

  _edc_split_recovery_args "$@"

  local state
  state=$(_edc_classify_context_state)

  # Pre-clean v1/partial-v2 leftovers so the build skill doesn't see ambiguous
  # state and route to update by mistake.
  if [ -x "$CLEAN_SLATE_SH" ]; then
    "$EDC_BASH" "$CLEAN_SLATE_SH" >&2 || true
  fi

  case "$state" in
    MISSING)
      echo "→ context missing, spawning $EDC_AGENT_CLI for edc-build..." >&2
      local build_prompt
      build_prompt=$(resolve_prompt build "${_edc_build_args[@]}") || return 1
      edc_spawn "edc-build" "${EDC_BUILD_TIMEOUT:-3600}" "$build_prompt" \
        || { echo "ERROR: edc-build invocation failed" >&2; return 1; }
      ;;
    STALE)
      echo "→ context stale, spawning $EDC_AGENT_CLI for edc-update..." >&2
      local update_prompt
      update_prompt=$(resolve_prompt update "${_edc_update_args[@]}") || return 1
      edc_spawn "edc-update" "${EDC_UPDATE_TIMEOUT:-1800}" "$update_prompt" \
        || { echo "ERROR: edc-update invocation failed" >&2; return 1; }
      ;;
  esac

  if assert_context_fresh 2>/dev/null; then
    return 0
  fi

  # First-pass recovery didn't produce a fresh manifest. Most common cause:
  # subagent invoked legacy skills and wrote v1-shaped output. Wipe and retry
  # the build with --force exactly once before giving up.
  if [ -x "$CLEAN_SLATE_SH" ]; then
    echo "→ context still not ready — wiping partial output and retrying with --force..." >&2
    "$EDC_BASH" "$CLEAN_SLATE_SH" --force >&2 || true
    local force_build_prompt
    force_build_prompt=$(resolve_prompt build --force "${_edc_build_args[@]}") || return 1
    edc_spawn "edc-build-retry" "${EDC_BUILD_TIMEOUT:-3600}" "$force_build_prompt" \
      || { echo "ERROR: edc-build retry failed" >&2; return 1; }
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
