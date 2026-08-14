#!/bin/bash
# EDC — Every Day Carry Skills installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s <agent>
#   bash install.sh --agent <agent> [--no-path]
#
# Agents: claude, cursor, codex, pi
#
# Runtime mode (advisory vs inject) is controlled by `edc-context/manifest.json`'s
# `policy.defaultMode` field. Flip it with: `edc mode advisory|inject`.

set -euo pipefail

REPO="almogdepaz/EDC"
EDC_INSTALL_REF="${EDC_INSTALL_REF:-v1.1.5}"
INSTALL_URL="https://raw.githubusercontent.com/$REPO/main/install.sh"
ARCHIVE_URL="https://github.com/$REPO/archive/refs/tags/$EDC_INSTALL_REF.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EDC_INSTALL_TMP=""

AGENT=""
ADD_PATH=1

usage() {
  cat <<EOF
Usage:
  curl -fsSL $INSTALL_URL | bash -s <agent>
  bash install.sh --agent <agent> [--no-path]

Agents: claude, cursor, codex, pi

Options:
  --no-path   Do not edit shell rc files to add ~/.edc/scripts to PATH

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
    --no-path)
      ADD_PATH=0
      shift
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

PRIVATE_SKILLS=(
  "plugins/edc/prompt-bundles/edc-module-context-impl/SKILL.md"
  "plugins/edc/prompt-bundles/edc-module-context-impl/resources/COMPLETENESS_CHECKLIST.md"
  "plugins/edc/prompt-bundles/edc-module-context-impl/resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md"
  "plugins/edc/prompt-bundles/edc-module-context-impl/resources/OUTPUT_REQUIREMENTS.md"
  "plugins/edc/prompt-bundles/edc-build-impl/SKILL.md"
  "plugins/edc/prompt-bundles/edc-build-impl/adapter-contract.md"
  "plugins/edc/prompt-bundles/edc-build-impl/manifest-schema.md"
  "plugins/edc/prompt-bundles/edc-update-impl/SKILL.md"
  "plugins/edc/prompt-bundles/edc-context-curator-impl/SKILL.md"
  "plugins/edc/prompt-bundles/edc-context-curator-edit-impl/SKILL.md"
)

PUBLIC_SKILLS=(
  "plugins/edc/skills/edc-review/SKILL.md"
  "plugins/edc/skills/edc-review/methodology.md"
  "plugins/edc/skills/edc-review/adversarial.md"
  "plugins/edc/skills/edc-review/reporting.md"
  "plugins/edc/skills/edc-review/patterns.md"
  "plugins/edc/skills/edc-audit/SKILL.md"
  "plugins/edc/skills/edc-audit/references/scope-and-standards.md"
  "plugins/edc/skills/edc-audit/references/smell-baseline.md"
  "plugins/edc/skills/edc-audit/references/quality-checks.md"
  "plugins/edc/skills/edc-audit/references/reporting.md"
  "plugins/edc/skills/edc-delivery-review/SKILL.md"
  "plugins/edc/skills/edc-delivery-review/references/spec-axis.md"
  "plugins/edc/skills/edc-delivery-review/references/architecture-axis.md"
  "plugins/edc/skills/edc-delivery-review/references/reporting.md"
)

SKILLS=("${PRIVATE_SKILLS[@]}" "${PUBLIC_SKILLS[@]}")

cleanup_install_tmp() {
  if [ -n "$EDC_INSTALL_TMP" ]; then
    rm -rf "$EDC_INSTALL_TMP"
  fi
}
trap cleanup_install_tmp EXIT

prepare_source_tree() {
  if [ -f "$SCRIPT_DIR/plugins/edc/scripts/edc" ]; then
    return 0
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required for remote install"
  command -v tar >/dev/null 2>&1 || die "tar is required for remote install"

  EDC_INSTALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/edc-install.XXXXXX")"
  local archive="$EDC_INSTALL_TMP/edc.tar.gz"
  local source_dir="$EDC_INSTALL_TMP/source"
  mkdir -p "$source_dir"

  curl -fsSL "$ARCHIVE_URL" -o "$archive"
  tar -xzf "$archive" -C "$source_dir" --strip-components=1
  SCRIPT_DIR="$source_dir"

  [ -f "$SCRIPT_DIR/plugins/edc/scripts/edc" ] \
    || die "downloaded archive does not contain EDC plugin runtime: $ARCHIVE_URL"
}

copy_from_source() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  [ -f "$SCRIPT_DIR/$src" ] || die "installer source missing: $src"
  cp "$SCRIPT_DIR/$src" "$dst"
}

skill_rel() {
  local rel="${1#plugins/edc/skills/}"
  if [ "$rel" = "$1" ]; then
    rel="${1#plugins/edc/prompt-bundles/}"
  fi
  echo "$rel"
}

install_terminal_cli() {
  local runtime_manifest="$SCRIPT_DIR/plugins/edc/hooks/lib/runtime-manifest.mjs"
  [ -f "$runtime_manifest" ] || die "installer source missing: plugins/edc/hooks/lib/runtime-manifest.mjs"
  command -v node >/dev/null 2>&1 || die "node is required for EDC runtime installation"
  node "$runtime_manifest" install "$HOME" "$SCRIPT_DIR/plugins/edc" >/dev/null

  install_shell_path
}

edc_shell_rc_file() {
  if [ -n "${EDC_INSTALL_SHELL_RC:-}" ]; then
    echo "$EDC_INSTALL_SHELL_RC"
    return 0
  fi

  case "$(basename "${SHELL:-}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) echo "$HOME/.bashrc" ;;
    *)    return 1 ;;
  esac
}

install_shell_path() {
  local edc_path="$HOME/.edc/scripts"
  if [ "$ADD_PATH" -eq 0 ]; then
    return 0
  fi

  case ":$PATH:" in
    *":$edc_path:"*) return 0 ;;
  esac

  if [ "${CI:-0}" = "1" ]; then
    return 0
  fi

  local rc_file
  if ! rc_file="$(edc_shell_rc_file)"; then
    return 0
  fi

  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"
  if grep -Fq '.edc/scripts' "$rc_file"; then
    return 0
  fi

  cat >> "$rc_file" <<'EOF'

# EDC CLI
if [ -d "$HOME/.edc/scripts" ]; then
  export PATH="$HOME/.edc/scripts:$PATH"
fi
EOF
  echo "Added EDC CLI to PATH in $rc_file. Restart your shell or run:"
  echo "  export PATH=\"\$HOME/.edc/scripts:\$PATH\""
}

# write_cursor_commands <cursor-target>
# Generates thin slash-command wrappers under <target>/commands/. Each
# wrapper is a Bash-only shim that exports EDC_AGENT_CLI=cursor and shells to
# the matching ~/.edc/scripts/edc-*.sh orchestrator. No source-file checked
# into the repo — the wrapper template lives here, the only place it can
# diverge from the contract is install.sh itself.
write_cursor_commands() {
  local target="$1"
  mkdir -p "$target/commands"
  rm -f "$target/commands/edc-audit.md" "$target/commands/edc-review.md"
  local entry action script
  for entry in build:build update:update run-review:review-all doctor:doctor; do
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
  for entry in build:build update:update run-review:review-all doctor:doctor; do
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
      if [ "$ADD_PATH" -eq 0 ]; then
        echo "NOTE: PATH setup was skipped (--no-path). To call 'edc' from anywhere, add:"
      else
        echo "NOTE: Restart your shell, or run this now to call 'edc' from the current shell:"
      fi
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
      echo "  edc review full --agent pi        # security + delivery + quality full repo review"
      echo "  edc review diff --agent pi        # security + delivery + quality vs default branch"
      echo "  edc security full --agent pi      # security-only full repo review"
      echo "  edc delivery diff main --agent pi # delivery/architecture review vs main"
      echo "  edc quality full --agent pi       # code quality full repo audit"
      echo "  edc doctor                        # validate context"
      echo "  edc mode advisory|inject          # toggle runtime mode"
      echo
      echo "Inside pi, use /edc for the interactive menu (choose scope, then combined/security/delivery/quality lens)."
      ;;
    *)
      echo "  edc build  --agent $agent             # build or update edc-context/"
      echo "  edc update --agent $agent             # force incremental update"
      echo "  edc review full --agent $agent        # security + delivery + quality full repo review"
      echo "  edc review diff main --agent $agent   # security + delivery + quality vs main"
      echo "  edc security full --agent $agent      # security-only full repo review"
      echo "  edc delivery diff main --agent $agent # delivery/architecture review vs main"
      echo "  edc quality full --agent $agent       # code quality full repo audit"
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
    copy_from_source "$f" "$target/$rel"
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
    copy_from_source "$f" "$target/$rel"
  done
}

install_claude_runtime() {
  prepare_source_tree
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
    prepare_source_tree
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
    prepare_source_tree
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
    prepare_source_tree
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
    echo "installed extension/source path: $SCRIPT_DIR/pi"
    echo "restart pi or run /reload in existing sessions to refresh menu labels."
    echo "Done. Run /edc inside pi for review/security review/delivery review/quality review/status/build/update/doctor. Toggle mode with 'edc mode advisory|inject'."
    print_cli_hint pi
    print_path_hint
    ;;

  *)
    die "unknown agent: $AGENT (supported: claude, cursor, codex, pi)"
    ;;
esac
