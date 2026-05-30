#!/bin/bash
# EDC — Every Day Carry Skills installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s <agent>
#   bash install.sh --agent <agent>
#
# Agents: claude, cursor, codex, pi
#
# Runtime mode (advisory vs inject) is controlled by `edc-context/manifest.json`'s
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
  "plugins/edc/prompt-bundles/edc-module-context-impl/SKILL.md"
  "plugins/edc/prompt-bundles/edc-module-context-impl/resources/COMPLETENESS_CHECKLIST.md"
  "plugins/edc/prompt-bundles/edc-module-context-impl/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md"
  "plugins/edc/prompt-bundles/edc-module-context-impl/resources/OUTPUT_REQUIREMENTS.md"
  "plugins/edc/skills/edc-review/SKILL.md"
  "plugins/edc/skills/edc-review/methodology.md"
  "plugins/edc/skills/edc-review/adversarial.md"
  "plugins/edc/skills/edc-review/reporting.md"
  "plugins/edc/skills/edc-review/patterns.md"
  "plugins/edc/prompt-bundles/edc-build-impl/SKILL.md"
  "plugins/edc/prompt-bundles/edc-update-impl/SKILL.md"
  "plugins/edc/skills/edc-audit/SKILL.md"
)

PUBLIC_SKILLS=(
  "plugins/edc/skills/edc-review/SKILL.md"
  "plugins/edc/skills/edc-review/methodology.md"
  "plugins/edc/skills/edc-review/adversarial.md"
  "plugins/edc/skills/edc-review/reporting.md"
  "plugins/edc/skills/edc-review/patterns.md"
  "plugins/edc/skills/edc-audit/SKILL.md"
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

skill_rel() {
  local rel="${1#plugins/edc/skills/}"
  if [ "$rel" = "$1" ]; then
    rel="${1#plugins/edc/prompt-bundles/}"
  fi
  echo "$rel"
}

install_terminal_cli() {
  local scripts_target="$HOME/.edc/scripts"
  mkdir -p "$scripts_target"
  copy_or_download "plugins/edc/scripts/edc"                 "$scripts_target/edc"
  copy_or_download "plugins/edc/scripts/edc-review.sh"        "$scripts_target/edc-review.sh"
  copy_or_download "plugins/edc/scripts/edc-build.sh"         "$scripts_target/edc-build.sh"
  copy_or_download "plugins/edc/scripts/edc-update.sh"        "$scripts_target/edc-update.sh"
  copy_or_download "plugins/edc/scripts/edc-audit.sh"         "$scripts_target/edc-audit.sh"
  copy_or_download "plugins/edc/scripts/edc-doctor.sh"        "$scripts_target/edc-doctor.sh"
  copy_or_download "plugins/edc/scripts/edc-route.sh"         "$scripts_target/edc-route.sh"
  copy_or_download "plugins/edc/scripts/edc-manifest.sh"      "$scripts_target/edc-manifest.sh"
  copy_or_download "plugins/edc/scripts/edc-clean-slate.sh"   "$scripts_target/edc-clean-slate.sh"
  copy_or_download "plugins/edc/scripts/edc-lib.sh"           "$scripts_target/edc-lib.sh"
  copy_or_download "plugins/edc/scripts/edc-assert-fresh.sh"  "$scripts_target/edc-assert-fresh.sh"
  copy_or_download "plugins/edc/scripts/edc-recover-context.sh" "$scripts_target/edc-recover-context.sh"
  copy_or_download "plugins/edc/scripts/edc-build-plan.sh"    "$scripts_target/edc-build-plan.sh"
  copy_or_download "plugins/edc/scripts/edc-spawn-analyze.sh" "$scripts_target/edc-spawn-analyze.sh"
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
    "$scripts_target/edc-assert-fresh.sh" \
    "$scripts_target/edc-recover-context.sh" \
    "$scripts_target/edc-build-plan.sh" \
    "$scripts_target/edc-spawn-analyze.sh"
  # edc-lib.sh is sourced, not exec'd — no chmod needed
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
  rm -f "$target/commands/edc-audit.md" "$target/commands/edc-review.md"
  local entry action script
  for entry in build:build update:update run-review:review doctor:doctor; do
    action="${entry%%:*}"
    script="${entry##*:}"
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
if [ -f ".edc/scripts/edc-$script.sh" ]; then
  bash .edc/scripts/edc-$script.sh "\$@"
elif [ -f "\$HOME/.edc/scripts/edc-$script.sh" ]; then
  bash "\$HOME/.edc/scripts/edc-$script.sh" "\$@"
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
  local entry action script
  for entry in build:build update:update run-review:review doctor:doctor; do
    action="${entry%%:*}"
    script="${entry##*:}"
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
if [ -f ".edc/scripts/edc-$script.sh" ]; then
  bash .edc/scripts/edc-$script.sh "\$@"
elif [ -f "\$HOME/.edc/scripts/edc-$script.sh" ]; then
  bash "\$HOME/.edc/scripts/edc-$script.sh" "\$@"
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

# print_cli_hint <agent>
# Shows the terminal-CLI commands the user can run from any shell once
# ~/.edc/scripts is on PATH. <agent> is one of claude/cursor/codex/pi and
# is used to fill in the --agent flag for the example commands.
print_cli_hint() {
  local agent="$1"
  echo
  echo "Terminal CLI (run from any repo, after PATH is set):"
  case "$agent" in
    pi)
      echo "  edc build  --agent pi             # build or update edc-context/"
      echo "  edc update --agent pi --base main # force incremental update"
      echo "  edc review --agent pi HEAD --base main # differential review of current branch"
      echo "  edc audit  --agent pi             # complexity / bloat audit"
      echo "  edc doctor                        # validate context"
      echo "  edc mode advisory|inject          # toggle runtime mode"
      echo
      echo "Inside pi, use /edc for the interactive menu (review/status/build/update/audit/doctor)."
      ;;
    *)
      echo "  edc build  --agent $agent             # build or update edc-context/"
      echo "  edc update --agent $agent             # force incremental update"
      echo "  edc review --agent $agent --base main # differential review of current branch"
      echo "  edc audit  --agent $agent             # complexity / bloat audit"
      echo "  edc doctor                            # validate context"
      echo "  edc mode advisory|inject              # toggle runtime mode"
      ;;
  esac
}

# install_edc_skills <skills-target>
# Drop SKILL.md (+ supporting files) into <target>/<skill-name>/. Used by
# the claude CLI install path so resolve_prompt's claude branch can find
# skills under ~/.edc/skills/ without depending on the claude plugin.
install_edc_skills() {
  local target="$1"
  local f rel
  rm -rf \
    "$target/edc-review-impl" \
    "$target/edc-audit-impl" \
    "$target/edc-context"
  for f in "${SKILLS[@]}"; do
    rel=$(skill_rel "$f")
    copy_or_download "$f" "$target/$rel"
  done
}

install_public_edc_skills() {
  local target="$1"
  local f rel
  rm -rf \
    "$target/edc-review-impl" \
    "$target/edc-audit-impl" \
    "$target/edc-context" \
    "$target/edc-build-impl" \
    "$target/edc-update-impl" \
    "$target/edc-module-context-impl"
  for f in "${PUBLIC_SKILLS[@]}"; do
    rel=$(skill_rel "$f")
    copy_or_download "$f" "$target/$rel"
  done
}

install_claude_runtime() {
  install_terminal_cli
  install_edc_skills "$HOME/.edc/skills"
  echo "Installed EDC terminal CLI at $HOME/.edc/scripts/edc."
  echo "Installed EDC skill bundle at $HOME/.edc/skills/."
  echo
  echo "This installs the standalone CLI only. The CLI works without the claude plugin."
  echo
  echo "For slash commands (/edc:edc-build, hooks) inside interactive claude, ALSO run:"
  echo "  claude plugin marketplace add almogdepaz/edc"
  echo "  claude plugin install edc@edc"
  echo
  echo "Runtime mode is read from edc-context/manifest.json (defaults to advisory)."
  echo "Flip with: edc mode inject"
  print_cli_hint claude
  print_path_hint
}

case "$AGENT" in
  claude)
    install_claude_runtime
    ;;

  cursor)
    TARGET="$HOME/.cursor"
    SCRIPTS_TARGET="$HOME/.edc/scripts"
    echo "Installing EDC public skills globally for Cursor..."
    install_public_edc_skills "$TARGET/skills"
    install_edc_skills "$HOME/.edc/skills"
    install_terminal_cli
    write_cursor_commands "$TARGET"
    echo "Done. Public skills at $TARGET/skills/, commands at $TARGET/commands/, terminal CLI + private prompt bundle at $SCRIPTS_TARGET/ and $HOME/.edc/skills/"
    print_cli_hint cursor
    print_path_hint
    ;;

  codex)
    TARGET="$HOME/.codex/skills"
    SCRIPTS_TARGET="$HOME/.edc/scripts"
    echo "Installing EDC public skills globally for Codex..."
    install_public_edc_skills "$TARGET"
    install_edc_skills "$HOME/.edc/skills"
    install_terminal_cli
    write_codex_skills "$TARGET"
    echo "Done. Public skills at $TARGET/, terminal CLI + private prompt bundle at $SCRIPTS_TARGET/ and $HOME/.edc/skills/. Use \$edc-build, \$edc-update, \$edc-run-review, or \$edc-doctor."
    print_cli_hint codex
    print_path_hint
    ;;

  pi)
    if ! command -v pi >/dev/null 2>&1; then
      die "pi CLI not found on PATH. Install pi first: https://pi.dev"
    fi
    if [ -d "$SCRIPT_DIR/pi" ]; then
      bash "$SCRIPT_DIR/pi/install.sh" --from-source
    else
      echo "Installing EDC as pi extension via git..."
      pi install "git:github.com/almogdepaz/edc"
    fi
    install_terminal_cli
    install_edc_skills "$HOME/.edc/skills"
    echo "Done. Run /edc inside pi for review/status/build/update/audit/doctor. Toggle mode with 'edc mode advisory|inject'."
    print_cli_hint pi
    print_path_hint
    ;;

  *)
    die "unknown agent: $AGENT (supported: claude, cursor, codex, pi)"
    ;;
esac
