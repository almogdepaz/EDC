#!/bin/bash
# Backend-specific agent command construction and dispatch.
# Sourced by edc-lib.sh after stream, timeout, model, and metrics helpers exist.

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
      local pi_extension="${EDC_PI_EXTENSION_PATH:-}"
      if [ -n "$pi_extension" ]; then
        case "$pi_extension" in
          /*) ;;
          *)
            echo "ERROR: EDC_PI_EXTENSION_PATH must be an absolute readable file: $pi_extension" >&2
            [ "$cleanup_prompt_file" -eq 1 ] && rm -f "$effective_prompt_file"
            return 2
            ;;
        esac
        if [[ "$pi_extension" == *$'\n'* ]] || [[ "$pi_extension" == *$'\r'* ]] || [ ! -f "$pi_extension" ] || [ ! -r "$pi_extension" ]; then
          echo "ERROR: EDC_PI_EXTENSION_PATH must be an absolute readable file: $pi_extension" >&2
          [ "$cleanup_prompt_file" -eq 1 ] && rm -f "$effective_prompt_file"
          return 2
        fi
      fi
      local -a cmd=(env EDC_PI_SUBPROCESS=1 pi --mode json --no-session --no-context-files --no-skills --no-prompt-templates --no-extensions)
      [ -n "$pi_extension" ] && cmd+=(-e "$pi_extension")
      cmd+=(-p)
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
