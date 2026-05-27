#!/usr/bin/env bash
# edc-lib.sh: shared helpers sourced by every orchestrator.
#
# Sections (each was a separate file before merge):
#   1. PATHS        canonical edc-context/ layout (was edc-paths.sh)
#   2. RUNTIME      timeout wrapper, codex isolation, stream filter (was edc-runtime.sh)
#   3. SPAWN        per-CLI subprocess dispatch (was edc-spawn.sh)
#   4. PROMPT       prompt construction for each action (was edc-resolve-prompt.sh)
#
# Caller contract:
#   - Source (do not exec).
#   - EDC_AGENT_CLI must be set before calling edc_spawn / resolve_prompt.
#   - CODEX_EXEC_HOME / CODEX_EXEC_HOME_OWNED must be initialized
#     ("" and 0 respectively) before sourcing if the caller uses codex.
#   - jq is recommended (most edc orchestrators hard-fail without it).

# ════════════════════════════════════════════════════════════════════════════
# 1. PATHS — single source of truth for the context directory layout.
# ════════════════════════════════════════════════════════════════════════════
# All variables are repo-relative. Callers needing absolute paths resolve
# with `pwd` / `realpath` themselves.

EDC_CONTEXT_DIR="${EDC_CONTEXT_DIR:-edc-context}"
EDC_MANIFEST="$EDC_CONTEXT_DIR/manifest.json"

# EDC_SCRIPTS_DIR: absolute path to the directory containing this lib and the
# sibling edc-*.sh orchestrators. Resolved through symlinks so installs that
# symlink the bin or the lib still produce a correct path. Exported so spawned
# subprocess agents see it and can substitute it for the `plugins/edc/scripts/`
# paths baked into the skill markdown (those paths only exist when running
# inside the EDC dev repo).
_edc_lib_resolve_scripts_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local d
    d="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$d/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
EDC_SCRIPTS_DIR="$(_edc_lib_resolve_scripts_dir)"
export EDC_SCRIPTS_DIR
EDC_INDEX="$EDC_CONTEXT_DIR/index.md"
EDC_MODULES_DIR="$EDC_CONTEXT_DIR/modules"
EDC_REPORTS_DIR="$EDC_CONTEXT_DIR/reports"
EDC_BUILD_DIR="$EDC_CONTEXT_DIR/build"
EDC_REVIEW_TASKS_DIR="$EDC_CONTEXT_DIR/review-tasks"
EDC_ISSUES="$EDC_REPORTS_DIR/issues.md"
EDC_COMPLEXITY="$EDC_REPORTS_DIR/complexity.md"
EDC_BUILD_INFO="$EDC_BUILD_DIR/build.json"
EDC_REVIEW_TASKS_MANIFEST="$EDC_REVIEW_TASKS_DIR/manifest.json"

# Single bash contract for all nested EDC script invocations. Orchestrators
# require bash >= 4, so once an entrypoint is running in a valid bash, child
# script calls must reuse that interpreter instead of resolving bare `bash`
# from ambient PATH (macOS login shells can make that `/bin/bash` 3.2).
EDC_BASH="${EDC_BASH:-$BASH}"
export EDC_BASH

# ════════════════════════════════════════════════════════════════════════════
# 2. RUNTIME — subprocess runtime helpers.
# ════════════════════════════════════════════════════════════════════════════
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

edc_require_agent_cli() {
  case "$EDC_AGENT_CLI" in
    claude)
      command -v claude > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=claude but 'claude' not found on PATH" >&2; exit 2; }
      ;;
    cursor)
      command -v cursor > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=cursor but 'cursor' not found on PATH" >&2; exit 2; }
      ;;
    codex)
      command -v codex > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=codex but 'codex' not found on PATH" >&2; exit 2; }
      ensure_codex_exec_home || exit 1
      ;;
    pi)
      command -v pi > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=pi but 'pi' not found on PATH" >&2; exit 2; }
      command -v python3 > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=pi requires python3 for JSON subprocess supervision" >&2; exit 2; }
      ;;
    *)
      echo "ERROR: EDC_AGENT_CLI must be 'claude', 'cursor', 'codex', or 'pi'" >&2
      exit 2
      ;;
  esac
}

write_pi_json_supervisor() {
  local path="$1"
  cat > "$path" <<'PY'
#!/usr/bin/env python3
import json
import signal
import subprocess
import sys

proc = None


def stop(signum, _frame):
    global proc
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

cmd = sys.argv[1:]
if not cmd:
    print("ERROR: missing pi command", file=sys.stderr)
    sys.exit(2)

proc = subprocess.Popen(
    cmd,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=None,
    text=True,
    bufsize=1,
)

SUCCESS_STOP_REASONS = {"stop"}


def stop_proc():
    global proc
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def final_assistant(messages):
    if not isinstance(messages, list):
        return None
    for message in reversed(messages):
        if isinstance(message, dict) and message.get("role") == "assistant":
            return message
    return None


def error_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("errorMessage", "message", "error"):
            nested = value.get(key)
            if nested:
                return error_text(nested)
        try:
            return json.dumps(value, sort_keys=True)
        except Exception:
            return str(value)
    return str(value)


def classify_agent_end(event):
    assistant = final_assistant(event.get("messages"))
    if assistant is None:
        return False, "agent_end did not include a final assistant message"

    error_message = assistant.get("errorMessage")
    if error_message:
        return False, error_text(error_message)

    stop_reason = assistant.get("stopReason")
    if stop_reason not in SUCCESS_STOP_REASONS:
        return False, f"agent_end stopReason was {stop_reason or 'missing'}"

    return True, ""


try:
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        try:
            event = json.loads(line)
        except Exception:
            continue

        event_type = event.get("type")
        if event_type == "error":
            print(f"ERROR: pi subprocess: {error_text(event.get('error') or event)}", file=sys.stderr)
            stop_proc()
            sys.exit(1)

        if event_type == "agent_end":
            ok, reason = classify_agent_end(event)
            stop_proc()
            if ok:
                sys.exit(0)
            print(f"ERROR: pi subprocess: {reason}", file=sys.stderr)
            sys.exit(1)

    rc = proc.wait()
    if rc != 0:
        sys.exit(rc)
    print("ERROR: pi subprocess ended without successful agent_end", file=sys.stderr)
    sys.exit(1)
finally:
    stop_proc()
PY
  chmod +x "$path"
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
    # Pi JSON mode: stream text deltas and tool starts from AgentSession events.
    pi_msg=$(printf '%s' "$line" | jq -r '
      if .type == "message_update" and (.assistantMessageEvent.type // "") == "text_delta" then (.assistantMessageEvent.delta // "")
      elif .type == "tool_execution_start" then "→ \(.toolName)(\((.args // {}) | to_entries[0] | .value // "" | tostring | .[0:80]))"
      else empty end' 2>/dev/null)
    if [ -n "$pi_msg" ]; then
      printf '%s\n' "$pi_msg"
      continue
    fi
    pi_err=$(printf '%s' "$line" | jq -r '
      if .type == "tool_execution_end" and .isError == true then "ERROR (subprocess): \(.result.content // .result.error // .result // "tool execution failed" | tostring)"
      elif .type == "auto_retry_end" and .success == false then "ERROR (subprocess): \(.finalError // "provider request failed")"
      else empty end' 2>/dev/null)
    if [ -n "$pi_err" ]; then
      printf '%s\n' "$pi_err" >&2
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

# ════════════════════════════════════════════════════════════════════════════
# 3. CONFIG — load ~/.edc/config if present (model knobs etc.)
# ════════════════════════════════════════════════════════════════════════════
# Sourced once per orchestrator invocation. Env vars already set always win
# over the file (resolution order: CLI flag → env → ~/.edc/config → unset).

edc_load_config() {
  local cfg="${EDC_CONFIG_FILE:-$HOME/.edc/config}"
  [ -f "$cfg" ] || return 0
  # Only export keys we recognize. Refuse to source arbitrary shell.
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key// /}"
    # Strip surrounding quotes if present.
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    case "$key" in
      EDC_BUILD_MODEL|EDC_REVIEW_MODEL|EDC_PI_MODEL|EDC_AGENT_CLI|EDC_PROVIDER)
        # Only set if not already exported by the caller.
        if [ -z "${!key:-}" ]; then
          export "$key=$val"
        fi
        ;;
    esac
  done < "$cfg"
}

# resolve_model_for_phase <phase> <out-var-name>
# Phases starting with "edc-review" → EDC_REVIEW_MODEL, everything else →
# EDC_BUILD_MODEL. Writes the resolved slug (possibly empty) to the named
# variable. Empty means "no --model flag" → backend default.
resolve_model_for_phase() {
  local __phase="$1" __outvar="$2" __resolved=""
  case "$__phase" in
    edc-review*) __resolved="${EDC_REVIEW_MODEL:-}" ;;
    *)           __resolved="${EDC_BUILD_MODEL:-}" ;;
  esac
  if [ -z "$__resolved" ] && [ "${EDC_AGENT_CLI:-}" = "pi" ]; then
    __resolved="${EDC_PI_MODEL:-}"
  fi
  # Refuse to assign back into our own locals — caller must pass a unique var name.
  case "$__outvar" in
    __phase|__outvar|__resolved)
      echo "ERROR: resolve_model_for_phase: outvar name '$__outvar' collides with internal locals" >&2
      return 2
      ;;
  esac
  printf -v "$__outvar" '%s' "$__resolved"
}

# ════════════════════════════════════════════════════════════════════════════
# 4. COST LOG — per-spawn telemetry (model_observed, tokens, cost).
# ════════════════════════════════════════════════════════════════════════════
# Appends one JSON line per spawn to $EDC_SPAWN_LOG (default:
# edc-context/build/spawn-log.jsonl, fallback /tmp/edc-spawn-log.jsonl).
#
# Reads from the captured stream-json output the child wrote; we save the
# whole stream to $EDC_SPAWN_CAPTURE then tail the result line.

_edc_spawn_log_path() {
  local path="${EDC_SPAWN_LOG:-}"
  if [ -z "$path" ]; then
    if [ -d "$EDC_BUILD_DIR" ] || mkdir -p "$EDC_BUILD_DIR" 2>/dev/null; then
      path="$EDC_BUILD_DIR/spawn-log.jsonl"
    else
      path="/tmp/edc-spawn-log.jsonl"
    fi
  fi
  printf '%s' "$path"
}

# _edc_log_spawn_metrics <phase> <model_requested> <duration_s> <stream_file>
# Parse the last `"type":"result"` line from a Claude/Cursor stream-json
# capture and append a JSONL record. No-op if the capture file is missing
# or unparseable — observability is best-effort.
_edc_log_spawn_metrics() {
  local phase="$1" model_req="$2" duration="$3" capture="$4"
  command -v jq >/dev/null 2>&1 || return 0
  [ -s "$capture" ] || return 0
  local result_line
  result_line=$(grep '"type":"result"' "$capture" 2>/dev/null | tail -1)
  [ -n "$result_line" ] || return 0

  # Pull observed model from the first system/init block too (some CLIs only
  # put the slug there, not on the result line).
  local init_line
  init_line=$(grep -m1 '"type":"system"' "$capture" 2>/dev/null)

  local rec
  rec=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg phase "$phase" \
    --arg backend "$EDC_AGENT_CLI" \
    --arg model_req "$model_req" \
    --argjson duration "$duration" \
    --argjson result "$result_line" \
    --argjson init "${init_line:-null}" \
    '{
      ts: $ts,
      phase: $phase,
      backend: $backend,
      session_id: ($result.session_id // null),
      model_requested: ($model_req | if . == "" then null else . end),
      model_observed: ($init.model // $result.model // null),
      duration_s: $duration,
      num_turns: ($result.num_turns // null),
      input_tokens: ($result.usage.input_tokens // 0),
      output_tokens: ($result.usage.output_tokens // 0),
      cache_read_tokens: ($result.usage.cache_read_input_tokens // 0),
      cache_write_tokens: ($result.usage.cache_creation_input_tokens // 0),
      total_cost_usd: ($result.total_cost_usd // null)
    }' 2>/dev/null) || return 0

  local log_path; log_path=$(_edc_spawn_log_path)
  printf '%s\n' "$rec" >> "$log_path" 2>/dev/null || true

  # Warn loudly on silent model fallback.
  local req obs
  req=$(printf '%s' "$rec" | jq -r '.model_requested // ""')
  obs=$(printf '%s' "$rec" | jq -r '.model_observed // ""')
  if [ -n "$req" ] && [ -n "$obs" ]; then
    case "$obs" in
      *"$req"*) ;;
      *)
        echo "WARNING: model_observed='$obs' does not match model_requested='$req' (phase=$phase)" >&2
        ;;
    esac
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# 5. SPAWN — per-CLI subprocess dispatch.
# ════════════════════════════════════════════════════════════════════════════
# Depends on run_with_timeout, stream_filter, CODEX_EXEC_HOME (RUNTIME),
# resolve_model_for_phase (CONFIG), _edc_log_spawn_metrics (COST LOG).
#
# Two invocation shapes:
#   edc_spawn <phase> <timeout> <prompt>                    # legacy: inline prompt as user message
#   edc_spawn <phase> <timeout> --prompt-file <path>        # phase 1: prompt-file used as --system-prompt-file
#
# Phase-1 mode (`--prompt-file`):
#   - Passes --system-prompt-file <path> (replaces backend default system prompt)
#   - Passes --exclude-dynamic-system-prompt-sections (cache-friendly prefix)
#   - Tightens --allowed-tools to Read,Write,Bash,Grep,Glob (drops Skill,Task,Edit)
#   - User message is a fixed marker ("execute the task per the system prompt")
#
# Legacy mode (third positional == prompt text): unchanged for backward
# compatibility with paths that haven't migrated to prompt-file yet.

edc_spawn() {
  local phase="$1" timeout_secs="$2"
  shift 2

  local prompt_file="" prompt=""
  if [ "${1:-}" = "--prompt-file" ]; then
    prompt_file="$2"
    [ -f "$prompt_file" ] || { echo "ERROR: edc_spawn: --prompt-file '$prompt_file' not found" >&2; return 2; }
    shift 2
  else
    prompt="$1"
    shift
  fi

  local model=""
  resolve_model_for_phase "$phase" model

  # Capture stream to a tempfile so we can parse the result line for cost log.
  # When EDC_PRESERVE_TRANSCRIPTS=1 (or EDC_TRANSCRIPT_DIR is set), the
  # capture is COPIED to a stable location after parsing; otherwise deleted.
  local capture
  capture=$(mktemp "${TMPDIR:-/tmp}/edc-spawn-$$.XXXXXX.jsonl") || capture=""
  local t0=$(date +%s)
  local rc=0

  case "$EDC_AGENT_CLI" in
    claude)
      # --dangerously-skip-permissions: required for headless agent spawns. Without
      # it, claude code defaults to permissionMode=default which makes the model
      # think it needs to prompt the user before any tool use. In -p (non-TTY) mode
      # there is no user to prompt — sonnet/opus charge ahead anyway, haiku gives up
      # immediately ("what do you need?"). Setting this matches the parent bench
      # harness's own claude -p invocation.
      local -a cmd=(claude -p --output-format stream-json --verbose \
                    --dangerously-skip-permissions)
      [ -n "$model" ] && cmd+=(--model "$model")
      # Force Claude Code's Task-tool subagents to inherit the requested model.
      # Without an override, claude code reads CLAUDE_CODE_SUBAGENT_MODEL from
      # ~/.claude/settings.json (env block) AFTER process env, so a plain
      # `export CLAUDE_CODE_SUBAGENT_MODEL=...` is silently overwritten by the
      # user's global setting. --settings injects the env into claude code's
      # config layer where it wins. Inline JSON keeps it self-contained.
      if [ -n "$model" ]; then
        cmd+=(--settings "$(printf '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"%s"}}' "$model")")
      fi
      if [ -n "$prompt_file" ]; then
        cmd+=(--system-prompt-file "$prompt_file" \
              --exclude-dynamic-system-prompt-sections \
              --allowed-tools "Read,Write,Bash,Grep,Glob")
        if [ -n "$capture" ]; then
          run_with_timeout "$timeout_secs" "$phase" \
            "${cmd[@]}" "execute the task per the system prompt." \
            < /dev/null \
            | tee "$capture" | stream_filter
          rc=${PIPESTATUS[0]}
        else
          run_with_timeout "$timeout_secs" "$phase" \
            "${cmd[@]}" "execute the task per the system prompt." \
            < /dev/null \
            | stream_filter
          rc=${PIPESTATUS[0]}
        fi
      else
        cmd+=(--allowed-tools "Skill,Bash,Read,Write,Edit,Grep,Glob")
        if [ -n "$capture" ]; then
          run_with_timeout "$timeout_secs" "$phase" \
            "${cmd[@]}" <<< "$prompt" \
            | tee "$capture" | stream_filter
          rc=${PIPESTATUS[0]}
        else
          run_with_timeout "$timeout_secs" "$phase" \
            "${cmd[@]}" <<< "$prompt" \
            | stream_filter
          rc=${PIPESTATUS[0]}
        fi
      fi
      ;;
    cursor)
      local -a cmd=(cursor agent -p --output-format stream-json --force --trust)
      [ -n "$model" ] && cmd+=(--model "$model")
      # Cursor doesn't expose --system-prompt-file; prompt-file mode falls back
      # to inlining the file contents as the user message.
      local effective_prompt
      if [ -n "$prompt_file" ]; then
        effective_prompt=$(cat "$prompt_file")
      else
        effective_prompt="$prompt"
      fi
      if [ -n "$capture" ]; then
        run_with_timeout "$timeout_secs" "$phase" \
          "${cmd[@]}" <<< "$effective_prompt" \
          | tee "$capture" | stream_filter
        rc=${PIPESTATUS[0]}
      else
        run_with_timeout "$timeout_secs" "$phase" \
          "${cmd[@]}" <<< "$effective_prompt" \
          | stream_filter
        rc=${PIPESTATUS[0]}
      fi
      ;;
    codex)
      local -a cmd=(env CODEX_HOME="$CODEX_EXEC_HOME" codex exec --json --color never --sandbox workspace-write)
      [ -n "$model" ] && cmd+=(--model "$model")
      cmd+=(-)
      local effective_prompt
      if [ -n "$prompt_file" ]; then
        effective_prompt=$(cat "$prompt_file")
      else
        effective_prompt="$prompt"
      fi
      if [ -n "$capture" ]; then
        run_with_timeout "$timeout_secs" "$phase" \
          "${cmd[@]}" <<< "$effective_prompt" \
          | tee "$capture" | stream_filter
        rc=${PIPESTATUS[0]}
      else
        run_with_timeout "$timeout_secs" "$phase" \
          "${cmd[@]}" <<< "$effective_prompt" \
          | stream_filter
        rc=${PIPESTATUS[0]}
      fi
      ;;
    pi)
      local effective_prompt_file="" cleanup_prompt_file=0
      if [ -n "$prompt_file" ]; then
        effective_prompt_file="$prompt_file"
      else
        effective_prompt_file=$(mktemp "${TMPDIR:-/tmp}/edc-pi-prompt-$$.XXXXXX.md") \
          || { echo "ERROR: could not create pi prompt file" >&2; return 1; }
        printf '%s' "$prompt" > "$effective_prompt_file"
        cleanup_prompt_file=1
      fi
      local -a cmd=(env EDC_PI_SUBPROCESS=1 pi --mode json --no-session --no-context-files --no-skills --no-prompt-templates -p)
      [ -n "$model" ] && cmd+=(--model "$model")
      cmd+=("@$effective_prompt_file")
      local pi_supervisor
      pi_supervisor=$(mktemp "${TMPDIR:-/tmp}/edc-pi-supervisor-$$.XXXXXX.py") \
        || { echo "ERROR: could not create pi supervisor" >&2; return 1; }
      write_pi_json_supervisor "$pi_supervisor"
      if [ -n "$capture" ]; then
        run_with_timeout "$timeout_secs" "$phase" \
          "$pi_supervisor" "${cmd[@]}" < /dev/null \
          | tee "$capture" | stream_filter
        rc=${PIPESTATUS[0]}
      else
        run_with_timeout "$timeout_secs" "$phase" \
          "$pi_supervisor" "${cmd[@]}" < /dev/null \
          | stream_filter
        rc=${PIPESTATUS[0]}
      fi
      rm -f "$pi_supervisor"
      [ "$cleanup_prompt_file" -eq 1 ] && rm -f "$effective_prompt_file"
      ;;
    *)
      echo "ERROR: edc_spawn: unknown EDC_AGENT_CLI=$EDC_AGENT_CLI" >&2
      [ -n "$capture" ] && rm -f "$capture"
      return 2
      ;;
  esac

  local duration=$(( $(date +%s) - t0 ))
  [ -n "$capture" ] && _edc_log_spawn_metrics "$phase" "$model" "$duration" "$capture"
  _edc_preserve_transcript "$phase" "$capture"
  [ -n "$capture" ] && rm -f "$capture"
  return $rc
}

# _edc_preserve_transcript <phase> <capture-file>
# Optionally copy the spawn transcript to a stable location for post-hoc
# analysis. Opt-in via EDC_PRESERVE_TRANSCRIPTS=1 (uses default dir under
# edc-context/build/transcripts/) or EDC_TRANSCRIPT_DIR=<dir> (explicit).
_edc_preserve_transcript() {
  local phase="$1" capture="$2"
  [ -n "$capture" ] && [ -s "$capture" ] || return 0
  local dest_dir=""
  if [ -n "${EDC_TRANSCRIPT_DIR:-}" ]; then
    dest_dir="$EDC_TRANSCRIPT_DIR"
  elif [ "${EDC_PRESERVE_TRANSCRIPTS:-0}" = "1" ]; then
    if [ -d "$EDC_BUILD_DIR" ] || mkdir -p "$EDC_BUILD_DIR" 2>/dev/null; then
      dest_dir="$EDC_BUILD_DIR/transcripts"
    else
      dest_dir="/tmp/edc-transcripts"
    fi
  else
    return 0
  fi
  mkdir -p "$dest_dir" 2>/dev/null || return 0
  # Phase may contain slashes (e.g. "edc-review/foo") — normalize for filenames.
  local safe_phase="${phase//\//-}"
  local ts; ts=$(date +%Y%m%dT%H%M%S)
  cp "$capture" "$dest_dir/${safe_phase}-${ts}-$$.jsonl" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════
# 6. PROMPT — build subprocess prompts for each action.
# ════════════════════════════════════════════════════════════════════════════
# Usage:
#   prompt=$(resolve_prompt build [args...])     # build skill prompt
#   prompt=$(resolve_prompt update [args...])    # update skill prompt
#   prompt=$(resolve_prompt audit)               # audit skill prompt
#   prompt=$(resolve_prompt review <task-path>)  # per-module review prompt

find_installed_skill() {
  local name="$1"; shift
  local base
  for base in "$@"; do
    if [ -f "$base/$name/SKILL.md" ]; then
      echo "$base/$name/SKILL.md"
      return 0
    fi
  done
  echo "ERROR: skill '$name' not found in: $*" >&2
  return 1
}

# _find_skill_for_agent <skill-name>
# Resolve <skill-name>/SKILL.md from the agent-specific install paths.
#
# Per-agent layout:
#   claude: .edc/skills, ~/.edc/skills, plus marketplace fallbacks.
#   cursor: private .edc/~/.edc prompt bundles first, then public cursor skills.
#   codex:  private .edc/~/.edc prompt bundles first, then public codex skills.
_find_skill_for_agent() {
  local name="$1"
  case "$EDC_AGENT_CLI" in
    claude)
      find_installed_skill "$name" \
        ".edc/skills" \
        "$HOME/.edc/skills" \
        "$HOME/.claude/plugins/marketplaces/edc/plugins/edc/prompt-bundles" \
        "$HOME/.claude/plugins/marketplaces/edc/plugins/edc/skills"
      ;;
    cursor)
      find_installed_skill "$name" ".edc/skills" "$HOME/.edc/skills" ".cursor/skills" "$HOME/.cursor/skills"
      ;;
    codex)
      find_installed_skill "$name" ".edc/skills" "$HOME/.edc/skills" ".codex/skills" "$HOME/.codex/skills"
      ;;
    pi)
      find_installed_skill "$name" ".edc/skills" "$HOME/.edc/skills" ".pi/skills" "$HOME/.pi/agent/skills"
      ;;
    *)
      echo "ERROR: unknown EDC_AGENT_CLI: $EDC_AGENT_CLI" >&2
      return 2
      ;;
  esac
}

# _emit_scripts_dir_preamble
# Emitted at the top of every skill prompt. The installed skill markdown
# references `plugins/edc/scripts/<name>.sh` — a path that only exists inside
# the EDC dev repo. In any target repo the scripts live at $EDC_SCRIPTS_DIR
# (typically ~/.edc/scripts). This preamble tells the agent to do the
# substitution at invocation time so we don't have to rewrite skill text per
# install or maintain a probe in every skill.
_emit_scripts_dir_preamble() {
  cat <<EOF
IMPORTANT — script path substitution:
The skill instructions below reference orchestrator helpers as
\`plugins/edc/scripts/<name>.sh\`. That path is only valid inside the EDC
dev repo. In this repo it is not. The orchestrator scripts actually live at:

    $EDC_SCRIPTS_DIR

Whenever the skill tells you to invoke or reference a script under
\`plugins/edc/scripts/\`, substitute the absolute path above and run it with
\`$EDC_BASH\` (the resolved bash >=4 interpreter). For example:
  skill says:  bash plugins/edc/scripts/edc-manifest.sh
  you run:     "$EDC_BASH" $EDC_SCRIPTS_DIR/edc-manifest.sh

The scripts to substitute include (at least):
edc-build-plan.sh, edc-manifest.sh, edc-doctor.sh, edc-route.sh,
edc-clean-slate.sh, edc-assert-fresh.sh, edc-recover-context.sh.

Do not rewrite the skill text. Do not fail the build because
\`plugins/edc/scripts/\` is empty — that is expected; use the absolute path
above instead. \$EDC_SCRIPTS_DIR and \$EDC_BASH are also exported in this
subprocess if you prefer the env-var form, but the literal absolute script path
and resolved bash interpreter are authoritative.

EOF
}

# _emit_skill_prompt <skill-name> [args-string]
# Emit the canonical "find skill, optionally prepend args, cat content"
# prompt used by build/update/audit across all agents.
#
# Output ordering matters: we lead with an explicit, imperative TASK line so
# weaker / more chat-tuned models (e.g. haiku) recognize this as work to do
# right now, not as reference material they're being shown. Without this,
# haiku reads the skill prose as documentation and asks "what do you need?"
# while sonnet/opus charge ahead regardless.
_emit_skill_prompt() {
  local skill_name="$1" args_string="${2:-}"
  local skill
  skill=$(_find_skill_for_agent "$skill_name") || return 1
  # Imperative header — first thing the model sees.
  local task_verb="Execute"
  case "$skill_name" in
    edc-build-impl)  task_verb="Build the v2 architectural context" ;;
    edc-update-impl) task_verb="Update the existing v2 architectural context" ;;
    edc-audit)       task_verb="Run the complexity / overengineering audit" ;;
  esac
  printf 'TASK: %s for the repository at the current working directory, following the skill below verbatim. Start immediately. Do not ask for clarification — the skill specifies everything.\n\n' "$task_verb"
  if [ -n "$args_string" ]; then
    printf 'CLI ARGUMENTS: %s\n\n' "$args_string"
  fi
  _emit_scripts_dir_preamble
  cat "$skill"
}

# _emit_review_prompt <task-path>
# Emit the per-module review prompt: strict no-improvise prefix, the task
# file's contents, then the full edc-review skill bundle (SKILL.md +
# methodology.md + adversarial.md + reporting.md + patterns.md) inline.
# Embedding everything is intentional — past runs showed agents improvising
# their own methodology when only a Read instruction was given.
_emit_review_prompt() {
  local task_path="$1"
  if [ ! -f "$task_path" ]; then
    echo "ERROR: review task file not found: $task_path" >&2
    return 1
  fi

  local skill_path skill_dir
  skill_path=$(_find_skill_for_agent "edc-review") || return 1
  skill_dir=$(dirname "$skill_path")

  local methodology="$skill_dir/methodology.md"
  local adversarial="$skill_dir/adversarial.md"
  local reporting="$skill_dir/reporting.md"
  local patterns="$skill_dir/patterns.md"
  local f
  for f in "$methodology" "$adversarial" "$reporting" "$patterns"; do
    if [ ! -f "$f" ]; then
      echo "ERROR: review skill bundle incomplete — missing $f" >&2
      return 1
    fi
  done

  cat <<EOF
$(_emit_scripts_dir_preamble)
Follow the instructions below EXACTLY. Do not improvise, do not substitute
your own methodology, do not skip steps. The methodology, adversarial
checks, reporting format, and patterns are all embedded below — read them
all before producing the report.

================================================================================
TASK FILE: $task_path
================================================================================
$(cat "$task_path")

================================================================================
SKILL: edc-review/SKILL.md
================================================================================
$(cat "$skill_path")

================================================================================
SKILL: edc-review/methodology.md
================================================================================
$(cat "$methodology")

================================================================================
SKILL: edc-review/adversarial.md
================================================================================
$(cat "$adversarial")

================================================================================
SKILL: edc-review/reporting.md
================================================================================
$(cat "$reporting")

================================================================================
SKILL: edc-review/patterns.md
================================================================================
$(cat "$patterns")
EOF
}

resolve_prompt() {
  local action="$1"; shift
  local prompt_arg_string="$*"

  # Validate agent up front so error messages are uniform.
  case "$EDC_AGENT_CLI" in
    claude|cursor|codex|pi) ;;
    *)
      echo "ERROR: unknown EDC_AGENT_CLI: $EDC_AGENT_CLI" >&2
      return 2
      ;;
  esac

  case "$action" in
    build)  _emit_skill_prompt "edc-build-impl"  "$prompt_arg_string" ;;
    update) _emit_skill_prompt "edc-update-impl" "$prompt_arg_string" ;;
    audit)  _emit_skill_prompt "edc-audit" ;;
    review) _emit_review_prompt "$1" ;;
    *)
      echo "ERROR: unknown action: $action" >&2
      return 1
      ;;
  esac
}
