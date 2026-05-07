#!/usr/bin/env bash
# edc-resolve-prompt: shared prompt-resolution helper.
#
# Sourced (not exec'd) by orchestrators. Defines `resolve_prompt` which
# builds the subprocess prompt for a given action (build / update / audit /
# review) based on $EDC_AGENT_CLI.
#
# Claude routes through slash commands; Cursor and Codex cat the installed
# skill file so the subprocess follows the exact same -impl skill content.
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

# Cursor skills are installed under .cursor/skills/<name>/ or ~/.cursor/skills/<name>/.
find_cursor_skill() {
  find_installed_skill "$1" ".cursor/skills" "$HOME/.cursor/skills"
}

# Codex skills are installed under .codex/skills/<name>/ or ~/.codex/skills/<name>/.
find_codex_skill() {
  find_installed_skill "$1" ".codex/skills" "$HOME/.codex/skills"
}

resolve_prompt() {
  local action="$1"; shift
  local prompt_arg_string="$*"
  case "$EDC_AGENT_CLI" in
    claude)
      case "$action" in
        build)  echo "/edc:edc-build${prompt_arg_string:+ $prompt_arg_string}" ;;
        update) echo "/edc:edc-update${prompt_arg_string:+ $prompt_arg_string}" ;;
        review) echo "/edc:edc-review --task-file $1" ;;
        audit)  echo "Invoke the edc-audit-impl skill and follow its instructions exactly." ;;
        *)      echo "ERROR: unknown action: $action" >&2; return 1 ;;
      esac
      ;;
    cursor)
      case "$action" in
        build)
          local skill
          skill=$(find_cursor_skill "edc-build-impl") || return 1
          [ -n "$prompt_arg_string" ] && printf 'When following the skill instructions below, use these CLI arguments: %s\n\n' "$prompt_arg_string"
          cat "$skill"
          ;;
        update)
          local skill
          skill=$(find_cursor_skill "edc-update-impl") || return 1
          [ -n "$prompt_arg_string" ] && printf 'When following the skill instructions below, use these CLI arguments: %s\n\n' "$prompt_arg_string"
          cat "$skill"
          ;;
        audit)
          local skill
          skill=$(find_cursor_skill "edc-audit-impl") || return 1
          cat "$skill"
          ;;
        review)
          local task_path="$1"
          local review_skill review_dir
          review_skill=$(find_cursor_skill "edc-review-impl") || return 1
          review_dir=$(dirname "$review_skill")
          printf 'Read the task file at %s and follow its instructions.\n\nRead %s and all supporting files in %s (methodology.md, adversarial.md, reporting.md, patterns.md) for the review methodology.\n\nDo not write your own review methodology. Follow the skill exactly. Do not skip reading the .context/ files.' \
            "$task_path" "$review_skill" "$review_dir"
          ;;
        *) echo "ERROR: unknown action: $action" >&2; return 1 ;;
      esac
      ;;
    codex)
      case "$action" in
        build)
          local skill
          skill=$(find_codex_skill "edc-build-impl") || return 1
          [ -n "$prompt_arg_string" ] && printf 'When following the skill instructions below, use these CLI arguments: %s\n\n' "$prompt_arg_string"
          cat "$skill"
          ;;
        update)
          local skill
          skill=$(find_codex_skill "edc-update-impl") || return 1
          [ -n "$prompt_arg_string" ] && printf 'When following the skill instructions below, use these CLI arguments: %s\n\n' "$prompt_arg_string"
          cat "$skill"
          ;;
        audit)
          local skill
          skill=$(find_codex_skill "edc-audit-impl") || return 1
          cat "$skill"
          ;;
        review)
          local task_path="$1"
          local review_skill review_dir
          review_skill=$(find_codex_skill "edc-review-impl") || return 1
          review_dir=$(dirname "$review_skill")
          printf 'Read the task file at %s and follow its instructions.\n\nRead %s and all supporting files in %s (methodology.md, adversarial.md, reporting.md, patterns.md) for the review methodology.\n\nDo not write your own review methodology. Follow the skill exactly. Do not skip reading the .context/ files.' \
            "$task_path" "$review_skill" "$review_dir"
          ;;
        *) echo "ERROR: unknown action: $action" >&2; return 1 ;;
      esac
      ;;
    *)
      echo "ERROR: unknown EDC_AGENT_CLI: $EDC_AGENT_CLI" >&2
      return 2
      ;;
  esac
}
