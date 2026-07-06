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
#   - node is required for JSON/NDJSON helper CLIs.

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
edc_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local d
    d="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$d/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
EDC_SCRIPTS_DIR="$(edc_resolve_script_dir)"
export EDC_SCRIPTS_DIR
EDC_JSON_CLI="$EDC_SCRIPTS_DIR/../hooks/lib/json-cli.mjs"
EDC_STREAM_FILTER_CLI="$EDC_SCRIPTS_DIR/../hooks/lib/stream-filter.mjs"
EDC_INDEX="$EDC_CONTEXT_DIR/index.md"
EDC_MODULES_DIR="$EDC_CONTEXT_DIR/modules"
EDC_REPORTS_DIR="$EDC_CONTEXT_DIR/reports"
EDC_BUILD_DIR="$EDC_CONTEXT_DIR/build"
EDC_REVIEW_TASKS_DIR="$EDC_CONTEXT_DIR/review-tasks"
EDC_ISSUES="$EDC_REPORTS_DIR/issues.md"
EDC_COMPLEXITY="$EDC_REPORTS_DIR/complexity.md"
EDC_BUILD_INFO="$EDC_BUILD_DIR/build.json"
EDC_REVIEW_TASKS_MANIFEST="$EDC_REVIEW_TASKS_DIR/manifest.json"
EDC_ROOT_AGENTS="AGENTS.md"
EDC_ALT_AGENTS="EDC_AGENTS.md"
EDC_CLAUDE_AGENTS="CLAUDE.md"
EDC_AGENTS_REF_START="<!-- EDC_CONTEXT_REFERENCE_START -->"
EDC_AGENTS_REF_END="<!-- EDC_CONTEXT_REFERENCE_END -->"

EDC_RESULT_ACTIVE=0
EDC_RESULT_WRITTEN=0
EDC_RESULT_KIND=""
EDC_RESULT_STARTED_HEAD=""

edc_result_file() {
  if [ -n "${EDC_RESULT_FILE:-}" ]; then
    echo "$EDC_RESULT_FILE"
  else
    echo "$EDC_BUILD_DIR/last-run.json"
  fi
}

edc_result_begin() {
  EDC_RESULT_KIND="$1"
  EDC_RESULT_ACTIVE=1
  EDC_RESULT_WRITTEN=0
  EDC_RESULT_STARTED_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
}

edc_result_write() {
  [ "${EDC_RESULT_ACTIVE:-0}" = "1" ] || return 0
  local exit_code="$1" reason_code="$2" failure_reason="${3:-}" failure_hint="${4:-}" failed_module="${5:-}" final_review="${6:-}"
  local result_file finished_head
  result_file=$(edc_result_file)
  finished_head=$(git rev-parse HEAD 2>/dev/null || true)
  if ! node "$EDC_JSON_CLI" result-write "$result_file" "$EDC_RESULT_KIND" "$exit_code" "$reason_code" "$failure_reason" "$failure_hint" "$failed_module" "$final_review" "$EDC_RESULT_STARTED_HEAD" "$finished_head"; then
    echo "WARNING: failed to write EDC result file: $result_file" >&2
  fi
  EDC_RESULT_WRITTEN=1
}

edc_result_success() {
  edc_result_write 0 success "" "" "" "${1:-}"
}

edc_result_success_with_warning() {
  edc_result_write 0 success-with-warning "${1:-$EDC_RESULT_KIND succeeded with warning}" "${2:-inspect the log for transport/provider diagnostics}" "" "${3:-}"
}

edc_result_failure() {
  edc_result_write "${1:-1}" "${2:-pipeline-failed}" "${3:-$EDC_RESULT_KIND pipeline failed}" "${4:-inspect the log for the subprocess error and rerun after fixing it}" "${5:-}" "${6:-}"
}

edc_result_on_exit() {
  local rc=$?
  if [ "${EDC_RESULT_ACTIVE:-0}" = "1" ] && [ "${EDC_RESULT_WRITTEN:-0}" != "1" ] && [ "$rc" -ne 0 ]; then
    edc_result_failure "$rc" "$EDC_RESULT_KIND-pipeline-failed" "$EDC_RESULT_KIND pipeline failed" "inspect the log for the subprocess error and rerun after fixing it" "" ""
  fi
  return "$rc"
}

edc_result_scope_from_args() {
  unset EDC_RESULT_SCOPE EDC_RESULT_BASE EDC_RESULT_TARGET EDC_RESULT_DIRTY_TRACKED_INCLUDED EDC_RESULT_UNTRACKED_INCLUDED
  local target="" base="" full_scope=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --full)
        full_scope=1
        shift
        ;;
      --base)
        if [ "$#" -ge 2 ]; then
          base="$2"
          shift 2
        else
          shift
        fi
        ;;
      --ignore|--context-mode|--agent|--model|--pr)
        if [ "$#" -ge 2 ]; then shift 2; else shift; fi
        ;;
      --*)
        shift
        ;;
      *)
        if [ -z "$target" ]; then target="$1"; fi
        shift
        ;;
    esac
  done

  if [ "$full_scope" -eq 1 ]; then
    export EDC_RESULT_SCOPE="full"
    export EDC_RESULT_TARGET="current working tree / HEAD"
    export EDC_RESULT_DIRTY_TRACKED_INCLUDED="1"
    export EDC_RESULT_UNTRACKED_INCLUDED="0"
    return 0
  fi
  if [ -n "$base" ] || [ -n "$target" ]; then
    export EDC_RESULT_SCOPE="differential"
    export EDC_RESULT_BASE="$base"
    export EDC_RESULT_TARGET="${target:-HEAD}"
    export EDC_RESULT_DIRTY_TRACKED_INCLUDED="1"
    export EDC_RESULT_UNTRACKED_INCLUDED="0"
  fi
}

edc_is_generated_agents_file() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -Fq 'This repo ships deep architectural context generated by EDC' "$file" \
    && grep -Fq 'edc-context/index.md' "$file" \
    && grep -Fq 'edc-context/manifest.json' "$file"
}

edc_file_references_alt_agents() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -Fq "$EDC_ALT_AGENTS" "$file"
}

edc_entrypoint_valid() {
  if edc_is_generated_agents_file "$EDC_ROOT_AGENTS"; then
    return 0
  fi
  if edc_is_generated_agents_file "$EDC_ALT_AGENTS"; then
    return 0
  fi
  return 1
}

edc_remove_alt_agents_reference() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp="${file}.edc-ref.$$"
  awk -v start="$EDC_AGENTS_REF_START" -v end="$EDC_AGENTS_REF_END" '
    $0 == start { skipping = 1; next }
    $0 == end { skipping = 0; next }
    !skipping { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
  rm -f "$tmp" 2>/dev/null || true
}

edc_add_alt_agents_reference() {
  local file="$1"
  [ -f "$file" ] || return 0
  edc_remove_alt_agents_reference "$file"
  cat >> "$file" <<EOF

$EDC_AGENTS_REF_START
## EDC Context

EDC generated repository context lives in [$EDC_ALT_AGENTS]($EDC_ALT_AGENTS). Read it after this file for architecture overview, routing, and runtime-mode guidance.
$EDC_AGENTS_REF_END
EOF
}

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
  if [ "${EDC_TIMEOUT_WARNED:-}" != "1" ]; then
    echo "WARNING: neither 'timeout' nor 'gtimeout' found; using background watchdog (brew install coreutils for native timeout)" >&2
    export EDC_TIMEOUT_WARNED=1
  fi

  # watchdog fallback: the watchdog subshell prints the timeout message itself
  # when it fires; we just forward the command's exit code.
  # Preserve stdin via fd 3: bash redirects async cmds' stdin to /dev/null in
  # non-interactive scripts, which swallows here-strings passed to the caller.
  exec 3<&0
  "$@" <&3 &
  local cmd_pid=$!
  local watchdog_pid=""
  trap 'kill "${cmd_pid:-}" "${watchdog_pid:-}" 2>/dev/null || true; exit 143' TERM INT
  exec 3<&-
  # NOTE: >/dev/null on the subshell so its forked `sleep` child doesn't inherit
  # the pipe write-end. If it did, the sleep (reparented to init when the
  # subshell dies on kill) would keep the downstream `stream_filter` reader
  # blocked for the full watchdog duration after the real command already exited.
  (sleep "$secs" && kill "$cmd_pid" 2>/dev/null && \
    echo "ERROR: phase '$label' timed out after ${secs}s (watchdog)" >&2) >/dev/null &
  watchdog_pid=$!
  wait "$cmd_pid"
  local rc=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  trap - TERM INT
  return $rc
}

# ── codex home override ──────────────────────────────────────────────────────

ensure_codex_exec_home() {
  if [ -n "${CODEX_EXEC_HOME:-}" ]; then
    return 0
  fi

  if [ -n "${EDC_CODEX_HOME:-}" ]; then
    mkdir -p "$EDC_CODEX_HOME"
    CODEX_EXEC_HOME="$EDC_CODEX_HOME"
    return 0
  fi

  CODEX_EXEC_HOME=""
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
      command -v node > /dev/null 2>&1 \
        || { echo "ERROR: EDC_AGENT_CLI=pi requires node for JSON subprocess supervision" >&2; exit 2; }
      ;;
    *)
      echo "ERROR: EDC_AGENT_CLI must be 'claude', 'cursor', 'codex', or 'pi'" >&2
      exit 2
      ;;
  esac
}

# ── stream filter ────────────────────────────────────────────────────────────

edc_is_codex_auth_failure_text() {
  case "$1" in
    *401\ Unauthorized*|*Missing\ bearer*|*authentication\ token\ has\ been\ invalidated*|*token_invalidated*|*session\ has\ ended*|*app_session_terminated*|*Failed\ to\ refresh\ token*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

edc_print_codex_auth_failure() {
  printf '%s\n' "ERROR: Codex authentication failed. Run 'codex logout && codex login' for ChatGPT OAuth, or pipe an API key with 'codex login --with-api-key'." >&2
}

edc_is_model_rejection_text() {
  local text
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$text" in
    *model*not\ found*|*model*not\ supported*|*unsupported\ model*|*unknown\ model*|*invalid\ model*|*model_not_found*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

edc_print_agent_model_list_hint() {
  local agent="$1" model="$2" output=""
  case "$agent" in
    pi)
      if command -v pi >/dev/null 2>&1; then
        if [ -n "$TIMEOUT_BIN" ]; then
          output=$("$TIMEOUT_BIN" 10 pi --list-models "$model" 2>&1 || true)
          [ -n "$output" ] || output=$("$TIMEOUT_BIN" 10 pi --list-models 2>&1 || true)
        else
          output=$(pi --list-models "$model" 2>&1 || true)
          [ -n "$output" ] || output=$(pi --list-models 2>&1 || true)
        fi
        if [ -n "$output" ]; then
          printf '%s\n' "available pi models matching '$model' (or all models if no exact search result):" >&2
          printf '%s\n' "$output" | sed -n '1,80p' >&2
          return 0
        fi
      fi
      printf '%s\n' "could not fetch pi models. run: pi --list-models" >&2
      ;;
    codex)
      printf '%s\n' "Codex CLI does not expose a stable model-list command in this version. Run 'codex --help', omit --model to use the backend default, or choose a model supported by your Codex auth mode." >&2
      ;;
    claude)
      printf '%s\n' "Claude CLI does not expose a stable model-list command in this version. Run 'claude --help', omit --model to use the backend default, or use a supported alias/full model name." >&2
      ;;
    *)
      printf '%s\n' "omit --model to use the backend default, or choose a model supported by '$agent'." >&2
      ;;
  esac
}

edc_print_model_rejection() {
  local agent="${STREAM_FILTER_AGENT:-${EDC_AGENT_CLI:-agent}}"
  local model="${STREAM_FILTER_MODEL:-}"
  local message="$1"
  if [ -n "$model" ]; then
    printf '%s\n' "ERROR: model '$model' was rejected by $agent: $message" >&2
    edc_print_agent_model_list_hint "$agent" "$model"
  else
    printf '%s\n' "ERROR: model was rejected by $agent: $message" >&2
    printf '%s\n' "hint: omit --model to use the backend default, or set EDC_BUILD_MODEL / EDC_REVIEW_MODEL to a supported model." >&2
  fi
}

# stream_filter: read NDJSON from agent CLI output and print human-readable
# progress lines. Handles Claude, Cursor, Pi, and Codex formats.
stream_filter() {
  if [ ! -f "$EDC_STREAM_FILTER_CLI" ]; then
    echo "ERROR: stream-filter.mjs not found at $EDC_STREAM_FILTER_CLI" >&2
    return 2
  fi
  node "$EDC_STREAM_FILTER_CLI"
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
    edc-review*|edc-delivery-review*) __resolved="${EDC_REVIEW_MODEL:-}" ;;
    *)                                __resolved="${EDC_BUILD_MODEL:-}" ;;
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
  [ -s "$capture" ] || return 0
  [ -f "$EDC_JSON_CLI" ] || return 0
  local log_path; log_path=$(_edc_spawn_log_path)
  node "$EDC_JSON_CLI" spawn-metrics "$phase" "$EDC_AGENT_CLI" "$model_req" "$duration" "$capture" "$log_path" 2>/tmp/edc-spawn-metrics-warn.$$ || true
  if [ -s /tmp/edc-spawn-metrics-warn.$$ ]; then
    cat /tmp/edc-spawn-metrics-warn.$$ >&2
  fi
  rm -f /tmp/edc-spawn-metrics-warn.$$ 2>/dev/null || true
}

edc_kill_process_tree() {
  local pid="$1" child
  [ -n "$pid" ] || return 0
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    edc_kill_process_tree "$child"
  done
  kill "$pid" 2>/dev/null || true
}

edc_stream_pipeline_rc() {
  local runner_rc="$1" filter_rc="$2"
  if [ "$filter_rc" -eq 86 ] || [ "$filter_rc" -eq 87 ]; then
    return 1
  fi
  return "$runner_rc"
}

edc_run_codex_stream() {
  local timeout_secs="$1" phase="$2" capture="$3" effective_prompt="$4"
  shift 4

  if [ ! -f "$EDC_STREAM_FILTER_CLI" ]; then
    echo "ERROR: stream-filter.mjs not found at $EDC_STREAM_FILTER_CLI" >&2
    return 2
  fi

  local prompt_file
  prompt_file=$(mktemp "${TMPDIR:-/tmp}/edc-codex-prompt-$$.XXXXXX.md") || return 1
  printf '%s' "$effective_prompt" > "$prompt_file"

  local rc=0
  if STREAM_FILTER_CAPTURE="$capture" EDC_STREAM_STDIN_FILE="$prompt_file" node "$EDC_STREAM_FILTER_CLI" --run "$timeout_secs" "$phase" -- "$@"; then
    rc=0
  else
    rc=$?
  fi

  rm -f "$prompt_file"
  edc_stream_pipeline_rc "$rc" "$rc"
  return $?
}

edc_run_filtered_stream() {
  local timeout_secs="$1" phase="$2" capture="$3" model="$4" input_mode="$5" input_value="$6"
  shift 6

  local stdin_path="" cleanup_stdin=0
  case "$input_mode" in
    stdin-null)
      stdin_path="/dev/null"
      ;;
    stdin-text)
      stdin_path=$(mktemp "${TMPDIR:-/tmp}/edc-stdin-$$.XXXXXX.txt") || return 1
      printf '%s' "$input_value" > "$stdin_path"
      cleanup_stdin=1
      ;;
    stdin-file)
      stdin_path="$input_value"
      ;;
    *)
      echo "ERROR: edc_run_filtered_stream: unknown input mode '$input_mode'" >&2
      return 2
      ;;
  esac

  run_with_timeout "$timeout_secs" "$phase" "$@" < "$stdin_path" \
    | tee "$capture" | STREAM_FILTER_AGENT="$EDC_AGENT_CLI" STREAM_FILTER_MODEL="$model" stream_filter
  local -a pipeline_status=("${PIPESTATUS[@]}")
  [ "$cleanup_stdin" -eq 1 ] && rm -f "$stdin_path"

  edc_stream_pipeline_rc "${pipeline_status[0]}" "${pipeline_status[2]}"
  return $?
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
  local capture capture_is_temp=0
  if capture=$(mktemp "${TMPDIR:-/tmp}/edc-spawn-$$.XXXXXX.jsonl"); then
    capture_is_temp=1
  else
    capture="/dev/null"
  fi
  local t0
  t0=$(date +%s)
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
        edc_run_filtered_stream "$timeout_secs" "$phase" "$capture" "$model" stdin-null "" \
          "${cmd[@]}" "execute the task per the system prompt."
        rc=$?
      else
        cmd+=(--allowed-tools "Skill,Bash,Read,Write,Edit,Grep,Glob")
        edc_run_filtered_stream "$timeout_secs" "$phase" "$capture" "$model" stdin-text "$prompt" \
          "${cmd[@]}"
        rc=$?
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
      edc_run_filtered_stream "$timeout_secs" "$phase" "$capture" "$model" stdin-text "$effective_prompt" \
        "${cmd[@]}"
      rc=$?
      ;;
    codex)
      local -a cmd=()
      if [ -n "$CODEX_EXEC_HOME" ]; then
        cmd=(env CODEX_HOME="$CODEX_EXEC_HOME" codex exec --json --color never --sandbox workspace-write)
      else
        cmd=(codex exec --json --color never --sandbox workspace-write)
      fi
      [ -n "$model" ] && cmd+=(--model "$model")
      cmd+=(-)
      local effective_prompt
      if [ -n "$prompt_file" ]; then
        effective_prompt=$(cat "$prompt_file")
      else
        effective_prompt="$prompt"
      fi
      STREAM_FILTER_AGENT="$EDC_AGENT_CLI" STREAM_FILTER_MODEL="$model" edc_run_codex_stream "$timeout_secs" "$phase" "$capture" "$effective_prompt" "${cmd[@]}"
      rc=$?
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
      local pi_supervisor="$EDC_SCRIPTS_DIR/../hooks/lib/pi-supervisor.mjs"
      if [ ! -f "$pi_supervisor" ]; then
        echo "ERROR: pi supervisor not found at $pi_supervisor" >&2
        [ "$cleanup_prompt_file" -eq 1 ] && rm -f "$effective_prompt_file"
        return 1
      fi
      edc_run_filtered_stream "$timeout_secs" "$phase" "$capture" "$model" stdin-null "" \
        node "$pi_supervisor" "${cmd[@]}"
      rc=$?
      [ "$cleanup_prompt_file" -eq 1 ] && rm -f "$effective_prompt_file"
      ;;
    *)
      echo "ERROR: edc_spawn: unknown EDC_AGENT_CLI=$EDC_AGENT_CLI" >&2
      [ "$capture_is_temp" -eq 1 ] && rm -f "$capture"
      return 2
      ;;
  esac

  local duration=$(( $(date +%s) - t0 ))
  [ "$capture_is_temp" -eq 1 ] && _edc_log_spawn_metrics "$phase" "$model" "$duration" "$capture"
  [ "$capture_is_temp" -eq 1 ] && _edc_preserve_transcript "$phase" "$capture"
  [ "$capture_is_temp" -eq 1 ] && rm -f "$capture"
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
\`bash\`. For example:
  skill says:  bash plugins/edc/scripts/edc-manifest.sh
  you run:     bash $EDC_SCRIPTS_DIR/edc-manifest.sh

The scripts to substitute include (at least):
edc-build-plan.sh, edc-manifest.sh, edc-doctor.sh, edc-clean-slate.sh,
edc-assert-fresh.sh, edc-recover-context.sh. Path classification uses
$EDC_SCRIPTS_DIR/../hooks/lib/classify-cli.mjs.

Do not rewrite the skill text. Do not fail the build because
\`plugins/edc/scripts/\` is empty — that is expected; use the absolute path
above instead. \$EDC_SCRIPTS_DIR is also exported in this
subprocess if you prefer the env-var form, but the literal absolute script path
is authoritative.

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
    edc-audit)       task_verb="Run the code quality audit" ;;
  esac
  printf 'TASK: %s for the repository at the current working directory, following the skill below verbatim. Start immediately. Do not ask for clarification — the skill specifies everything.\n\n' "$task_verb"
  if [ "$skill_name" = "edc-build-impl" ]; then
    cat <<EOF
IMPORTANT — EDC agent entrypoint destination:
EDC_AGENTS_TARGET: ${EDC_AGENTS_TARGET:-AGENTS.md}

For the build skill's agent-entrypoint step, write the EDC-generated orientation to exactly the file named by EDC_AGENTS_TARGET above.
If EDC_AGENTS_TARGET is EDC_AGENTS.md, do NOT overwrite or edit an existing AGENTS.md or CLAUDE.md; the shell orchestrator will tell the user how to replace, append, or reference EDC_AGENTS.md after the build output exists.
If EDC_AGENTS_TARGET is AGENTS.md, write the normal EDC-generated AGENTS.md file.

EOF
  fi
  if [ -n "$args_string" ]; then
    printf 'CLI ARGUMENTS: %s\n\n' "$args_string"
  fi
  _emit_scripts_dir_preamble
  cat "$skill"
}

# _emit_audit_prompt
# Emit the audit prompt as a self-contained bundle (SKILL.md + references).
# Splitting the audit skill keeps the main skill lean, but orchestrated
# subprocesses still need the full methodology inline so they do not skip
# moved reference material.
_emit_audit_prompt() {
  local skill_path skill_dir refs ref
  skill_path=$(_find_skill_for_agent "edc-audit") || return 1
  skill_dir=$(dirname "$skill_path")

  refs="scope-and-standards.md smell-baseline.md quality-checks.md reporting.md"
  for ref in $refs; do
    if [ ! -f "$skill_dir/references/$ref" ]; then
      echo "ERROR: audit skill bundle incomplete — missing $skill_dir/references/$ref" >&2
      return 1
    fi
  done

  cat <<EOF
$(_emit_scripts_dir_preamble)
Follow the instructions below EXACTLY. Do not improvise, do not substitute
another audit methodology, and do not skip the referenced checks. The audit
scope/standards, smell baseline, quality checks, and reporting contract are
all embedded below — read them all before producing the report.

================================================================================
SKILL: edc-audit/SKILL.md
================================================================================
$(cat "$skill_path")

================================================================================
SKILL: edc-audit/references/scope-and-standards.md
================================================================================
$(cat "$skill_dir/references/scope-and-standards.md")

================================================================================
SKILL: edc-audit/references/smell-baseline.md
================================================================================
$(cat "$skill_dir/references/smell-baseline.md")

================================================================================
SKILL: edc-audit/references/quality-checks.md
================================================================================
$(cat "$skill_dir/references/quality-checks.md")

================================================================================
SKILL: edc-audit/references/reporting.md
================================================================================
$(cat "$skill_dir/references/reporting.md")
EOF
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
    build)   _emit_skill_prompt "edc-build-impl"  "$prompt_arg_string" ;;
    update)  _emit_skill_prompt "edc-update-impl" "$prompt_arg_string" ;;
    curator)      _emit_skill_prompt "edc-context-curator-impl" ;;
    curator-edit) _emit_skill_prompt "edc-context-curator-edit-impl" ;;
    audit)        _emit_audit_prompt ;;
    review)  _emit_review_prompt "$1" ;;
    *)
      echo "ERROR: unknown action: $action" >&2
      return 1
      ;;
  esac
}

edc_run_context_curator() {
  mkdir -p "$EDC_REPORTS_DIR"
  rm -f "$EDC_REPORTS_DIR/context-curation.md"

  echo "→ spawning $EDC_AGENT_CLI for edc-context-curator..."
  local prompt
  prompt=$(resolve_prompt curator) || return 1
  edc_spawn "edc-context-curator" "${EDC_CURATOR_TIMEOUT:-900}" "$prompt" \
    || { echo "ERROR: edc-context-curator invocation failed" >&2; return 1; }

  local report="$EDC_REPORTS_DIR/context-curation.md"
  if [ ! -f "$report" ]; then
    echo "ERROR: context curator report missing: $report" >&2
    return 1
  fi
  if ! grep -q '^##' "$report"; then
    echo "ERROR: context curator report has no '## ' headings: $report" >&2
    return 1
  fi
}

edc_curator_edit_allowed_path() {
  case "$1" in
    "$EDC_INDEX") return 0 ;;
    "$EDC_MODULES_DIR"/*.md) return 0 ;;
    *) return 1 ;;
  esac
}

edc_emit_dirty_tracked_paths() {
  git diff --name-only -z -- 2>/dev/null || true
  git diff --cached --name-only -z -- 2>/dev/null || true
}

edc_snapshot_curator_forbidden_paths() {
  local output="$1"
  : > "$output"
  {
    edc_emit_dirty_tracked_paths
    git ls-files --others --exclude-standard -z "$EDC_CONTEXT_DIR" 2>/dev/null || true
  } | while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    case "$path" in
      "$EDC_BUILD_DIR/spawn-log.jsonl") continue ;;
    esac
    edc_curator_edit_allowed_path "$path" && continue
    if [ -f "$path" ]; then
      shasum -a 256 "$path"
    else
      printf 'MISSING  %s\n' "$path"
    fi
  done | sort -u > "$output"
}

edc_diff_curator_forbidden_paths() {
  local before="$1" after="$2"
  local diff_file
  diff_file=$(mktemp)
  if diff -u "$before" "$after" > "$diff_file"; then
    rm -f "$diff_file"
    return 0
  fi
  sed -n -E \
    -e 's/^[+-][0-9a-f]{64}  //p' \
    -e 's/^[+-]MISSING  //p' \
    "$diff_file" | sort -u
  rm -f "$diff_file"
  return 1
}

edc_review_write_allowed_path() {
  local path="$1"
  shift || true
  local allowed
  for allowed in "$@"; do
    [ -n "$allowed" ] || continue
    case "$path" in
      "$allowed") return 0 ;;
    esac
  done
  case "$path" in
    "$EDC_BUILD_DIR/spawn-log.jsonl") return 0 ;;
    "$EDC_BUILD_DIR"/transcripts/*) return 0 ;;
    *) return 1 ;;
  esac
}

edc_snapshot_review_forbidden_paths() {
  local output="$1"
  shift
  : > "$output"
  {
    edc_emit_dirty_tracked_paths
    git ls-files --others --exclude-standard -z 2>/dev/null || true
  } | while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    edc_review_write_allowed_path "$path" "$@" && continue
    if [ -f "$path" ]; then
      shasum -a 256 "$path"
    else
      printf 'MISSING  %s\n' "$path"
    fi
  done | sort -u > "$output"
}

edc_diff_review_forbidden_paths() {
  edc_diff_curator_forbidden_paths "$@"
}

edc_run_context_curator_edit() {
  local before after changed prompt
  before=$(mktemp)
  after=$(mktemp)
  edc_snapshot_curator_forbidden_paths "$before"

  echo "→ spawning $EDC_AGENT_CLI for edc-context-curator-edit..."
  prompt=$(resolve_prompt curator-edit) || { rm -f "$before" "$after"; return 1; }
  edc_spawn "edc-context-curator-edit" "${EDC_CURATOR_EDIT_TIMEOUT:-900}" "$prompt" \
    || { rm -f "$before" "$after"; echo "ERROR: edc-context-curator-edit invocation failed" >&2; return 1; }

  edc_snapshot_curator_forbidden_paths "$after"
  changed=$(edc_diff_curator_forbidden_paths "$before" "$after" || true)
  rm -f "$before" "$after"
  if [ -n "$changed" ]; then
    echo "ERROR: context curator edit touched forbidden paths:" >&2
    echo "$changed" | sed 's/^/  /' >&2
    return 1
  fi
}

edc_remove_context_curator_report() {
  rm -f "$EDC_REPORTS_DIR/context-curation.md"
}
