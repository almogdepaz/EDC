#!/usr/bin/env bash
# edc-spawn: shared subprocess-spawning helper for orchestrators.
#
# Sourced (not exec'd) by orchestrators that need to spawn an agent CLI
# subprocess. Encapsulates the per-CLI dispatch (claude / cursor / codex),
# the timeout wrapper, the stream-json filter pipe, and the consistent
# tool-lockdown for claude.
#
# Caller contract:
#   - EDC_AGENT_CLI must be set to "claude", "cursor", or "codex".
#   - run_with_timeout, stream_filter, and CODEX_EXEC_HOME (codex only) must
#     be defined / set in the caller's shell before calling edc_spawn. These
#     all live in edc-review.sh today and are sourced together.
#   - On error the function returns non-zero; caller decides whether to exit.
#
# Why a shell function (not a separate script): timeout/gtimeout wraps the
# REAL agent binary inside the function, so the "timeout can't exec a shell
# function" caveat doesn't apply — the function is the dispatcher, not the
# thing being timed.
#
# Usage:
#   edc_spawn <phase-label> <timeout-secs> <prompt-string>
#
# Examples:
#   edc_spawn "edc-build" "${EDC_BUILD_TIMEOUT:-3600}" "$build_prompt" \
#     || { echo "ERROR: edc-build invocation failed" >&2; exit 1; }
#
#   edc_spawn "edc-review/$module" "${EDC_REVIEW_TIMEOUT:-1800}" "$review_prompt" \
#     || { echo "ERROR: review invocation failed for module $module" >&2; exit 1; }

edc_spawn() {
  local phase="$1" timeout_secs="$2" prompt="$3"

  case "$EDC_AGENT_CLI" in
    claude)
      run_with_timeout "$timeout_secs" "$phase" \
        claude -p --output-format stream-json --verbose \
          --allowed-tools "Skill,Bash,Read,Write,Edit,Grep,Glob" \
        <<< "$prompt" \
        | stream_filter
      ;;
    cursor)
      run_with_timeout "$timeout_secs" "$phase" \
        cursor agent -p --output-format stream-json --force --trust \
        <<< "$prompt" \
        | stream_filter
      ;;
    codex)
      run_with_timeout "$timeout_secs" "$phase" \
        env CODEX_HOME="$CODEX_EXEC_HOME" codex exec --json --color never --sandbox workspace-write - \
        <<< "$prompt" \
        | stream_filter
      ;;
    *)
      echo "ERROR: edc_spawn: unknown EDC_AGENT_CLI=$EDC_AGENT_CLI" >&2
      return 2
      ;;
  esac
}
