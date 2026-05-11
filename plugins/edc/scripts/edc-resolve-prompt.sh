#!/usr/bin/env bash
# edc-resolve-prompt: shared prompt-resolution helper.
#
# Sourced (not exec'd) by orchestrators. Defines `resolve_prompt` which
# builds the subprocess prompt for a given action (build / update / audit /
# review) based on $EDC_AGENT_CLI.
#
# All three agents (claude / cursor / codex) follow the SAME pattern: the
# orchestrator finds the SKILL.md on disk and emits its contents as the
# subprocess prompt. No agent depends on a host plugin/slash-command system
# at this layer. For review, the full skill bundle (SKILL.md + methodology
# + adversarial + reporting + patterns) is embedded inline so the subagent
# has zero room to improvise its own methodology.
#
# Caller contract:
#   - EDC_AGENT_CLI must be set to "claude", "cursor", or "codex".
#
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
