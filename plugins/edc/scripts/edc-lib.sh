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
EDC_INDEX="$EDC_CONTEXT_DIR/index.md"
EDC_MODULES_DIR="$EDC_CONTEXT_DIR/modules"
EDC_REPORTS_DIR="$EDC_CONTEXT_DIR/reports"
EDC_BUILD_DIR="$EDC_CONTEXT_DIR/build"
EDC_REVIEW_TASKS_DIR="$EDC_CONTEXT_DIR/review-tasks"
EDC_ISSUES="$EDC_REPORTS_DIR/issues.md"
EDC_COMPLEXITY="$EDC_REPORTS_DIR/complexity.md"
EDC_BUILD_INFO="$EDC_BUILD_DIR/build.json"
EDC_REVIEW_TASKS_MANIFEST="$EDC_REVIEW_TASKS_DIR/manifest.json"

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

# ════════════════════════════════════════════════════════════════════════════
# 3. SPAWN — per-CLI subprocess dispatch.
# ════════════════════════════════════════════════════════════════════════════
# Depends on run_with_timeout, stream_filter, CODEX_EXEC_HOME (all defined
# above in the RUNTIME section).

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

# ════════════════════════════════════════════════════════════════════════════
# 4. PROMPT — build subprocess prompts for each action.
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
#   claude: .edc/skills, ~/.edc/skills, plus a marketplace fallback so a
#           plugin-only setup (no CLI install) still finds skill content.
#   cursor: .cursor/skills, ~/.cursor/skills
#   codex:  .codex/skills,  ~/.codex/skills
_find_skill_for_agent() {
  local name="$1"
  case "$EDC_AGENT_CLI" in
    claude)
      find_installed_skill "$name" \
        ".edc/skills" \
        "$HOME/.edc/skills" \
        "$HOME/.claude/plugins/marketplaces/edc/plugins/edc/skills"
      ;;
    cursor)
      find_installed_skill "$name" ".cursor/skills" "$HOME/.cursor/skills"
      ;;
    codex)
      find_installed_skill "$name" ".codex/skills" "$HOME/.codex/skills"
      ;;
    *)
      echo "ERROR: unknown EDC_AGENT_CLI: $EDC_AGENT_CLI" >&2
      return 2
      ;;
  esac
}

# _emit_skill_prompt <skill-name> [args-string]
# Emit the canonical "find skill, optionally prepend args, cat content"
# prompt used by build/update/audit across all agents.
_emit_skill_prompt() {
  local skill_name="$1" args_string="${2:-}"
  local skill
  skill=$(_find_skill_for_agent "$skill_name") || return 1
  if [ -n "$args_string" ]; then
    printf 'When following the skill instructions below, use these CLI arguments: %s\n\n' "$args_string"
  fi
  cat "$skill"
}

# _emit_review_prompt <task-path>
# Emit the per-module review prompt: strict no-improvise prefix, the task
# file's contents, then the full edc-review-impl skill bundle (SKILL.md +
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
  skill_path=$(_find_skill_for_agent "edc-review-impl") || return 1
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
Follow the instructions below EXACTLY. Do not improvise, do not substitute
your own methodology, do not skip steps. The methodology, adversarial
checks, reporting format, and patterns are all embedded below — read them
all before producing the report.

================================================================================
TASK FILE: $task_path
================================================================================
$(cat "$task_path")

================================================================================
SKILL: edc-review-impl/SKILL.md
================================================================================
$(cat "$skill_path")

================================================================================
SKILL: edc-review-impl/methodology.md
================================================================================
$(cat "$methodology")

================================================================================
SKILL: edc-review-impl/adversarial.md
================================================================================
$(cat "$adversarial")

================================================================================
SKILL: edc-review-impl/reporting.md
================================================================================
$(cat "$reporting")

================================================================================
SKILL: edc-review-impl/patterns.md
================================================================================
$(cat "$patterns")
EOF
}

resolve_prompt() {
  local action="$1"; shift
  local prompt_arg_string="$*"

  # Validate agent up front so error messages are uniform.
  case "$EDC_AGENT_CLI" in
    claude|cursor|codex) ;;
    *)
      echo "ERROR: unknown EDC_AGENT_CLI: $EDC_AGENT_CLI" >&2
      return 2
      ;;
  esac

  case "$action" in
    build)  _emit_skill_prompt "edc-build-impl"  "$prompt_arg_string" ;;
    update) _emit_skill_prompt "edc-update-impl" "$prompt_arg_string" ;;
    audit)  _emit_skill_prompt "edc-audit-impl" ;;
    review) _emit_review_prompt "$1" ;;
    *)
      echo "ERROR: unknown action: $action" >&2
      return 1
      ;;
  esac
}
