#!/bin/bash
# EDC — Every Day Carry Skills installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s <agent>
#   bash install.sh --agent <agent>
#
# Agents: claude, cursor, codex, pi
#
# Runtime mode (advisory vs inject) is controlled by `.context/manifest.json`'s
# `policy.defaultMode` field. Flip it with: `edc mode advisory|inject`.

set -euo pipefail

REPO="almogdepaz/EDC"
BRANCH="main"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PLUGIN_ROOT="$SCRIPT_DIR/plugins/edc"

AGENT=""

usage() {
  cat <<EOF
Usage:
  curl -fsSL $BASE/install.sh | bash -s <agent>
  bash install.sh --agent <agent>

Agents: claude, cursor, codex, pi

After install, toggle runtime mode in any repo with:
  edc mode advisory   # docs only (default), hooks no-op
  edc mode inject     # claude PreToolUse hook auto-injects module docs
EOF
}

die() {
  echo "edc: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      [ "$#" -ge 2 ] || die "--agent requires a value"
      AGENT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      if [ -n "$AGENT" ]; then
        die "unexpected argument: $1"
      fi
      AGENT="$1"
      shift
      ;;
  esac
done

[ -n "$AGENT" ] || {
  usage
  exit 1
}

SKILLS=(
  "plugins/edc/skills/edc-context/SKILL.md"
  "plugins/edc/skills/edc-context/resources/COMPLETENESS_CHECKLIST.md"
  "plugins/edc/skills/edc-context/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md"
  "plugins/edc/skills/edc-context/resources/OUTPUT_REQUIREMENTS.md"
  "plugins/edc/skills/edc-review-impl/SKILL.md"
  "plugins/edc/skills/edc-review-impl/methodology.md"
  "plugins/edc/skills/edc-review-impl/adversarial.md"
  "plugins/edc/skills/edc-review-impl/reporting.md"
  "plugins/edc/skills/edc-review-impl/patterns.md"
  "plugins/edc/skills/edc-build-impl/SKILL.md"
  "plugins/edc/skills/edc-update-impl/SKILL.md"
  "plugins/edc/skills/edc-audit-impl/SKILL.md"
)

download() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "$BASE/$src" -o "$dst"
}

copy_or_download() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$SCRIPT_DIR/$src" ]; then
    cp "$SCRIPT_DIR/$src" "$dst"
  else
    download "$src" "$dst"
  fi
}

copy_tree_or_fail() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  rm -rf "$dst"
  cp -R "$src" "$dst"
}

skill_rel() {
  echo "${1#plugins/edc/skills/}"
}

install_terminal_cli() {
  local scripts_target="$HOME/.edc/scripts"
  mkdir -p "$scripts_target"
  copy_or_download "scripts/edc"                              "$scripts_target/edc"
  copy_or_download "plugins/edc/scripts/edc-review.sh"        "$scripts_target/edc-review.sh"
  copy_or_download "plugins/edc/scripts/edc-build.sh"         "$scripts_target/edc-build.sh"
  copy_or_download "plugins/edc/scripts/edc-update.sh"        "$scripts_target/edc-update.sh"
  copy_or_download "plugins/edc/scripts/edc-audit.sh"         "$scripts_target/edc-audit.sh"
  copy_or_download "plugins/edc/scripts/edc-doctor.sh"        "$scripts_target/edc-doctor.sh"
  copy_or_download "plugins/edc/scripts/edc-route.sh"         "$scripts_target/edc-route.sh"
  copy_or_download "plugins/edc/scripts/edc-manifest.sh"      "$scripts_target/edc-manifest.sh"
  copy_or_download "plugins/edc/scripts/edc-clean-slate.sh"   "$scripts_target/edc-clean-slate.sh"
  copy_or_download "plugins/edc/scripts/edc-runtime.sh"       "$scripts_target/edc-runtime.sh"
  copy_or_download "plugins/edc/scripts/edc-assert-fresh.sh"  "$scripts_target/edc-assert-fresh.sh"
  copy_or_download "plugins/edc/scripts/edc-resolve-prompt.sh" "$scripts_target/edc-resolve-prompt.sh"
  copy_or_download "plugins/edc/scripts/edc-spawn.sh"         "$scripts_target/edc-spawn.sh"
  copy_or_download "plugins/edc/scripts/edc-recover-context.sh" "$scripts_target/edc-recover-context.sh"
  chmod +x \
    "$scripts_target/edc" \
    "$scripts_target/edc-review.sh" \
    "$scripts_target/edc-build.sh" \
    "$scripts_target/edc-update.sh" \
    "$scripts_target/edc-audit.sh" \
    "$scripts_target/edc-doctor.sh" \
    "$scripts_target/edc-route.sh" \
    "$scripts_target/edc-manifest.sh" \
    "$scripts_target/edc-clean-slate.sh" \
    "$scripts_target/edc-runtime.sh" \
    "$scripts_target/edc-assert-fresh.sh" \
    "$scripts_target/edc-resolve-prompt.sh" \
    "$scripts_target/edc-spawn.sh" \
    "$scripts_target/edc-recover-context.sh"
}

# write_cursor_commands <cursor-target>
# Generates four thin slash-command wrappers under <target>/commands/. Each
# wrapper is a Bash-only shim that exports EDC_AGENT_CLI=cursor and shells to
# the matching ~/.edc/scripts/edc-*.sh orchestrator. No source-file checked
# into the repo — the wrapper template lives here, the only place it can
# diverge from the contract is install.sh itself.
write_cursor_commands() {
  local target="$1"
  mkdir -p "$target/commands"
  for action in build update audit review; do
    cat > "$target/commands/edc-$action.md" <<EOF
---
description: edc $action via deterministic orchestrator (auto-installed by install.sh)
---

**Arguments:** \$ARGUMENTS

The orchestrator owns the full pipeline. Your only job is to invoke it and
surface its output.

\`\`\`bash
set -- \$ARGUMENTS
export EDC_AGENT_CLI=cursor
if [ -f ".edc/scripts/edc-$action.sh" ]; then
  bash .edc/scripts/edc-$action.sh "\$@"
elif [ -f "\$HOME/.edc/scripts/edc-$action.sh" ]; then
  bash "\$HOME/.edc/scripts/edc-$action.sh" "\$@"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first"
  exit 1
fi
\`\`\`

If the script exits non-zero, surface its error verbatim and stop.
EOF
  done
}

# write_codex_skills <codex-skills-target>
# Codex equivalent of write_cursor_commands. Writes <target>/edc-<action>/SKILL.md
# wrappers that delegate to ~/.edc/scripts/edc-*.sh with EDC_AGENT_CLI=codex.
write_codex_skills() {
  local target="$1"
  for action in build update audit review; do
    mkdir -p "$target/edc-$action"
    cat > "$target/edc-$action/SKILL.md" <<EOF
---
name: edc-$action
description: edc $action via deterministic orchestrator (auto-installed by install.sh)
---

The orchestrator owns the full pipeline. Invoke it via the target's bash
shell and surface its output. Pass through any user arguments verbatim.

\`\`\`bash
export EDC_AGENT_CLI=codex
if [ -f ".edc/scripts/edc-$action.sh" ]; then
  bash .edc/scripts/edc-$action.sh "\$@"
elif [ -f "\$HOME/.edc/scripts/edc-$action.sh" ]; then
  bash "\$HOME/.edc/scripts/edc-$action.sh" "\$@"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first"
  exit 1
fi
\`\`\`

If the script exits non-zero, surface its error verbatim and stop.
EOF
  done
}

print_path_hint() {
  case ":$PATH:" in
    *":$HOME/.edc/scripts:"*) ;;
    *)
      echo
      echo "NOTE: $HOME/.edc/scripts is not on PATH. Add this to your shell rc to call 'edc' from anywhere:"
      echo "  export PATH=\"\$HOME/.edc/scripts:\$PATH\""
      ;;
  esac
}

install_claude_runtime() {
  local target="$HOME/.claude/plugins/edc"

  if [ -d "$LOCAL_PLUGIN_ROOT" ]; then
    mkdir -p "$HOME/.claude/plugins"
    copy_tree_or_fail "$LOCAL_PLUGIN_ROOT" "$target"
  else
    mkdir -p "$target/.claude-plugin" "$target/commands" "$target/hooks" "$target/scripts"
    copy_or_download "plugins/edc/.claude-plugin/plugin.json" "$target/.claude-plugin/plugin.json"
    copy_or_download "plugins/edc/commands/edc-build.md" "$target/commands/edc-build.md"
    copy_or_download "plugins/edc/commands/edc-update.md" "$target/commands/edc-update.md"
    copy_or_download "plugins/edc/commands/edc-audit.md" "$target/commands/edc-audit.md"
    copy_or_download "plugins/edc/commands/edc-review.md" "$target/commands/edc-review.md"
    copy_or_download "plugins/edc/commands/edc-run-review.md" "$target/commands/edc-run-review.md"
    copy_or_download "plugins/edc/commands/edc-doctor.md" "$target/commands/edc-doctor.md"
    copy_or_download "plugins/edc/hooks/hooks.json" "$target/hooks/hooks.json"
    copy_or_download "plugins/edc/hooks/session-start.mjs" "$target/hooks/session-start.mjs"
    copy_or_download "plugins/edc/hooks/pretooluse-context-inject.mjs" "$target/hooks/pretooluse-context-inject.mjs"
    copy_or_download "plugins/edc/scripts/edc-review.sh" "$target/scripts/edc-review.sh"
    copy_or_download "plugins/edc/scripts/edc-build.sh" "$target/scripts/edc-build.sh"
    copy_or_download "plugins/edc/scripts/edc-update.sh" "$target/scripts/edc-update.sh"
    copy_or_download "plugins/edc/scripts/edc-audit.sh" "$target/scripts/edc-audit.sh"
    copy_or_download "plugins/edc/scripts/edc-route.sh" "$target/scripts/edc-route.sh"
    copy_or_download "plugins/edc/scripts/edc-clean-slate.sh" "$target/scripts/edc-clean-slate.sh"
    copy_or_download "plugins/edc/scripts/edc-runtime.sh" "$target/scripts/edc-runtime.sh"
    copy_or_download "plugins/edc/scripts/edc-assert-fresh.sh" "$target/scripts/edc-assert-fresh.sh"
    copy_or_download "plugins/edc/scripts/edc-resolve-prompt.sh" "$target/scripts/edc-resolve-prompt.sh"
    copy_or_download "plugins/edc/scripts/edc-spawn.sh" "$target/scripts/edc-spawn.sh"
    copy_or_download "plugins/edc/scripts/edc-recover-context.sh" "$target/scripts/edc-recover-context.sh"
  fi

  install_terminal_cli
  echo "Installed EDC Claude runtime in $target."
  echo "Terminal CLI installed at $HOME/.edc/scripts/edc."
  echo "Runtime mode is read from .context/manifest.json (defaults to advisory)."
  echo "Flip with: edc mode inject"
  print_path_hint
}

case "$AGENT" in
  claude)
    install_claude_runtime
    ;;

  cursor)
    TARGET="$HOME/.cursor"
    SCRIPTS_TARGET="$HOME/.edc/scripts"
    echo "Installing EDC skills globally for Cursor..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/skills/$(skill_rel "$f")"
    done
    install_terminal_cli
    write_cursor_commands "$TARGET"
    echo "Done. Skills at $TARGET/skills/, commands at $TARGET/commands/, terminal CLI + orchestrator at $SCRIPTS_TARGET/"
    print_path_hint
    ;;

  codex)
    TARGET="$HOME/.codex/skills"
    SCRIPTS_TARGET="$HOME/.edc/scripts"
    echo "Installing EDC skills globally for Codex..."
    for f in "${SKILLS[@]}"; do
      download "$f" "$TARGET/$(skill_rel "$f")"
    done
    install_terminal_cli
    write_codex_skills "$TARGET"
    echo "Done. Skills at $TARGET/, terminal CLI + orchestrator at $SCRIPTS_TARGET/. Use \$edc-build, \$edc-update, \$edc-audit, or \$edc-run-review."
    print_path_hint
    ;;

  pi)
    if ! command -v pi >/dev/null 2>&1; then
      die "pi CLI not found on PATH. Install pi first: https://github.com/mariozechner/pi"
    fi
    if [ -d "$SCRIPT_DIR/agents/pi" ]; then
      bash "$SCRIPT_DIR/agents/pi/install.sh" --from-source
    else
      echo "Installing EDC as pi extension via git..."
      pi install "git:github.com/almogdepaz/edc"
    fi
    install_terminal_cli
    echo "Done. Run /edc-build inside pi to create context. Toggle mode with 'edc mode advisory|inject'."
    print_path_hint
    ;;

  *)
    die "unknown agent: $AGENT (supported: claude, cursor, codex, pi)"
    ;;
esac
