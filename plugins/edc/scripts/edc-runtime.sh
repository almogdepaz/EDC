#!/usr/bin/env bash
# edc-runtime: shared subprocess runtime helpers for orchestrators.
#
# Sourced (not exec'd). Provides:
#   - TIMEOUT_BIN                                detected timeout/gtimeout binary (or "")
#   - run_with_timeout <secs> <label> <cmd...>   timeout wrapper (native or watchdog)
#   - cleanup_codex_exec_home                    EXIT-trap cleanup for owned codex home
#   - ensure_codex_exec_home                     creates / reuses CODEX_HOME for codex
#   - stream_filter                              folds claude/cursor/codex stream-json
#                                                into readable text (stdout) and errors
#                                                (stderr); plain passthrough if jq missing
#
# Caller contract:
#   - jq is recommended (most edc orchestrators already hard-fail without it).
#   - CODEX_EXEC_HOME / CODEX_EXEC_HOME_OWNED are caller-owned shell vars; the
#     codex helpers read/write them. The caller must initialize:
#         CODEX_EXEC_HOME=""
#         CODEX_EXEC_HOME_OWNED=0
#     before sourcing this file.

# ── timeout detection ────────────────────────────────────────────────────────
#
# Prefer GNU timeout (Linux) or gtimeout (macOS via coreutils). Fall back to a
# background watchdog implemented in run_with_timeout().

if command -v timeout > /dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  TIMEOUT_BIN=""
  # Print once per top-level invocation, but only when we'll actually spawn
  # subprocesses (i.e. the default auto_mode path). Skip for phase-internal
  # flags and usage errors. EDC_TIMEOUT_WARNED is exported so nested
  # `bash "$0" --build ...` calls inherit it and stay silent.
  if [ "${EDC_TIMEOUT_WARNED:-}" != "1" ]; then
    case "${1:-}" in
      --build|--check-context|--consolidate|--verify|"") ;;
      *)
        echo "WARNING: neither 'timeout' nor 'gtimeout' found; using background watchdog (brew install coreutils for native timeout)" >&2
        export EDC_TIMEOUT_WARNED=1
        ;;
    esac
  fi
fi

# run_with_timeout <secs> <phase-label> <cmd> [args...]
# Run cmd with a timeout. Uses $TIMEOUT_BIN if available, otherwise a
# background watchdog: spawns cmd, starts a sleep watchdog; if watchdog
# fires first it kills cmd and exits non-zero.
run_with_timeout() {
  local secs="$1" label="$2"; shift 2
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
    local rc=$?
    if [ $rc -eq 124 ]; then
      echo "ERROR: phase '$label' timed out after ${secs}s" >&2
      return 1
    fi
    return $rc
  fi
  # watchdog fallback: the watchdog subshell prints the timeout message itself
  # when it fires; we just forward the command's exit code.
  # Preserve stdin via fd 3: bash redirects async cmds' stdin to /dev/null in
  # non-interactive scripts, which swallows here-strings passed to the caller.
  exec 3<&0
  "$@" <&3 &
  local cmd_pid=$!
  exec 3<&-
  # NOTE: >/dev/null on the subshell so its forked `sleep` child doesn't inherit
  # the pipe write-end. If it did, the sleep (reparented to init when the
  # subshell dies on kill) would keep the downstream `stream_filter` reader
  # blocked for the full watchdog duration after the real command already exited.
  (sleep "$secs" && kill "$cmd_pid" 2>/dev/null && \
    echo "ERROR: phase '$label' timed out after ${secs}s (watchdog)" >&2) >/dev/null &
  local watchdog_pid=$!
  wait "$cmd_pid"
  local rc=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return $rc
}

# ── codex isolation ──────────────────────────────────────────────────────────

cleanup_codex_exec_home() {
  if [ "${CODEX_EXEC_HOME_OWNED:-0}" -eq 1 ] && [ -n "${CODEX_EXEC_HOME:-}" ] && [ -d "$CODEX_EXEC_HOME" ]; then
    rm -rf "$CODEX_EXEC_HOME"
  fi
}

ensure_codex_exec_home() {
  if [ -n "${CODEX_EXEC_HOME:-}" ]; then
    return 0
  fi

  if [ -n "${EDC_CODEX_HOME:-}" ]; then
    mkdir -p "$EDC_CODEX_HOME"
    CODEX_EXEC_HOME="$EDC_CODEX_HOME"
    CODEX_EXEC_HOME_OWNED=0
    return 0
  fi

  CODEX_EXEC_HOME=$(mktemp -d "${TMPDIR:-/tmp}/edc-codex-home.XXXXXX") \
    || { echo "ERROR: could not create temporary CODEX_HOME" >&2; return 1; }
  CODEX_EXEC_HOME_OWNED=1
  trap cleanup_codex_exec_home EXIT
}

# ── stream filter ────────────────────────────────────────────────────────────

# stream_filter: read NDJSON from agent CLI output and print human-readable
# progress lines. Handles Claude, Cursor, and Codex formats.
stream_filter() {
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # type=assistant with text content
    text=$(printf '%s' "$line" | jq -r 'if .type == "assistant" then (.message.content // []) | map(select(.type == "text") | .text) | join("") else empty end' 2>/dev/null)
    if [ -n "$text" ]; then
      printf '%s\n' "$text"
      continue
    fi
    # type=tool_use — show tool name + first arg truncated
    tool_info=$(printf '%s' "$line" | jq -r 'if .type == "assistant" then (.message.content // []) | map(select(.type == "tool_use") | "→ \(.name)(\((.input | to_entries | first | .value // "") | tostring | .[0:80]))") | .[] else empty end' 2>/dev/null)
    if [ -n "$tool_info" ]; then
      printf '%s\n' "$tool_info"
      continue
    fi
    # type=tool_call (Cursor stream format) — show tool name on start
    tool_call_info=$(printf '%s' "$line" | jq -r '
      if .type == "tool_call" and .subtype == "started" then
        (.tool_call | to_entries[0] |
         "→ \(.key)(\(.value.args // {} | to_entries[0] | .value // "" | tostring | .[0:80]))")
      else empty end' 2>/dev/null)
    if [ -n "$tool_call_info" ]; then
      printf '%s\n' "$tool_call_info"
      continue
    fi
    # type=result with is_error=true
    err=$(printf '%s' "$line" | jq -r 'if .type == "result" and .is_error == true then "ERROR (subprocess): \(.result // "unknown error")" else empty end' 2>/dev/null)
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
      continue
    fi
    # Codex JSON stream: events are wrapped as {"msg": {"type": ..., ...}}.
    # agent_message carries the assistant text the user needs to see; without
    # this handler the pipeline runs silent under real `codex exec`.
    codex_msg=$(printf '%s' "$line" | jq -r '
      if (.msg.type // "") == "agent_message" then (.msg.message // "")
      elif (.msg.type // "") == "agent_reasoning" then "… \(.msg.text // "")"
      elif (.msg.type // "") == "exec_command_begin" then "→ \(((.msg.command // []) | join(" "))[0:120])"
      else empty end' 2>/dev/null)
    if [ -n "$codex_msg" ]; then
      printf '%s\n' "$codex_msg"
      continue
    fi
    # Codex errors: both flat {"type":"error"} and nested {"msg":{"type":"error"}}.
    codex_err=$(printf '%s' "$line" | jq -r '
      if .type == "error" then "ERROR (subprocess): \(.message // "unknown error")"
      elif (.msg.type // "") == "error" then "ERROR (subprocess): \(.msg.message // "unknown error")"
      else empty end' 2>/dev/null)
    if [ -n "$codex_err" ]; then
      printf '%s\n' "$codex_err" >&2
    fi
  done
}
