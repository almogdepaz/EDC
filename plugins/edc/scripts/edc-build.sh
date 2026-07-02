#!/usr/bin/env bash
# edc-build orchestrator.
# Deterministic control plane for /edc:edc-build.
#
# Routes between full build and incremental update based on the on-disk
# state of the context dir, decided by `edc-clean-slate.sh --check`.
# The LLM never decides "is this an update or a build" — that's a
# shell decision.
#
# Routing matrix (state × --force):
#
#   state                    no --force        --force
#   ─────────────────────    ─────────────     ─────────────────────
#   no context dir           full build        full build
#   healthy v2               UPDATE            wipe + full build
#   partial / malformed v2   wipe + build      wipe + build
#   v1 layout                FAIL with hint    FAIL with hint
#
# After the spawned subprocess finishes, the orchestrator runs
# `edc-doctor.sh` to validate the resulting layout. A non-zero doctor
# exit fails the build.
#
# Usage:
#   EDC_AGENT_CLI=claude|cursor|codex|pi bash edc-build.sh \
#     [--force] [--focus <module>] [--ignore <glob>]...

set -euo pipefail

# ── dependency check ─────────────────────────────────────────────────────────

if ! command -v git > /dev/null 2>&1; then
  echo "ERROR: git is required" >&2
  exit 2
fi

# Resolve SCRIPT_DIR through symlinks so sibling helpers are found via the
# real script location, not the invocation path.
_edc_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_edc_resolve_script_dir)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
MANIFEST="$EDC_MANIFEST"
CLEAN_SLATE_SH="$SCRIPT_DIR/edc-clean-slate.sh"
DOCTOR_SH="$SCRIPT_DIR/edc-doctor.sh"

# ── agent CLI selection ──────────────────────────────────────────────────────

EDC_AGENT_CLI="${EDC_AGENT_CLI:-claude}"
CODEX_EXEC_HOME=""
CODEX_EXEC_HOME_OWNED=0

# ── shared helpers ───────────────────────────────────────────────────────────


# ── usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF' >&2
Usage:
  EDC_AGENT_CLI=<claude|cursor|codex|pi> edc-build.sh \
    [--force] [--focus <module>] [--ignore <glob>]...
EOF
  exit 2
}

# ── routing decision ─────────────────────────────────────────────────────────

# Echoes one of: "build" | "update" | "wipe-and-build"
# Exits non-zero with a v1 migration hint if v1 markers detected.
decide_route() {
  local force="$1"
  local rc=0
  bash "$CLEAN_SLATE_SH" --check > /dev/null 2>/tmp/edc-clean-slate-check.err || rc=$?
  case "$rc" in
    0)  # no context dir
      echo "build"
      return 0
      ;;
    11) # healthy v2
      if [ "$force" = "1" ]; then
        echo "wipe-and-build"
      else
        echo "update"
      fi
      return 0
      ;;
    10) # partial / malformed v2
      echo "wipe-and-build"
      return 0
      ;;
    12) # v1 layout — refuse
      cat /tmp/edc-clean-slate-check.err >&2 || true
      return 12
      ;;
    *)
      echo "ERROR: edc-clean-slate.sh --check returned unexpected exit $rc" >&2
      cat /tmp/edc-clean-slate-check.err >&2 || true
      return 1
      ;;
  esac
}

# ── AGENTS.md conflict handling ──────────────────────────────────────────────

choose_agents_mode() {
  local mode="${EDC_AGENTS_MODE:-}"
  case "$mode" in
    ""|edc-agents|overwrite) ;;
    *) echo "ERROR: EDC_AGENTS_MODE must be 'edc-agents' or 'overwrite'" >&2; return 2 ;;
  esac

  if [ ! -f "$EDC_ROOT_AGENTS" ] || edc_is_generated_agents_file "$EDC_ROOT_AGENTS"; then
    echo "overwrite"
    return 0
  fi

  if [ -n "$mode" ]; then
    echo "$mode"
    return 0
  fi

  if [ "${EDC_AGENT_CLI:-}" = "pi" ] && [ -t 0 ] && [ -t 2 ]; then
    cat >&2 <<EOF
EDC found an existing AGENTS.md that does not look EDC-generated.

Choose how to add EDC's generated repo-context entrypoint:
  1) preserve AGENTS.md, write EDC_AGENTS.md, and add a reference block (recommended)
  2) overwrite AGENTS.md with EDC's generated entrypoint

EOF
    local answer=""
    printf 'Select [1/2] (default 1): ' >&2
    read -r answer || true
    case "$answer" in
      2|o|overwrite) echo "overwrite" ;;
      *) echo "edc-agents" ;;
    esac
    return 0
  fi

  echo "WARNING: existing non-EDC AGENTS.md detected; preserving it and writing EDC context instructions to $EDC_ALT_AGENTS. Set EDC_AGENTS_MODE=overwrite to replace AGENTS.md." >&2
  echo "edc-agents"
}

prepare_agents_entrypoint() {
  local mode
  mode=$(choose_agents_mode) || return $?
  case "$mode" in
    overwrite)
      export EDC_AGENTS_TARGET="$EDC_ROOT_AGENTS"
      ;;
    edc-agents)
      export EDC_AGENTS_TARGET="$EDC_ALT_AGENTS"
      ;;
  esac
}

finalize_agents_entrypoint() {
  case "${EDC_AGENTS_TARGET:-$EDC_ROOT_AGENTS}" in
    "$EDC_ALT_AGENTS")
      if [ "${EDC_AGENT_CLI:-}" = "pi" ]; then
        if [ -f "$EDC_ROOT_AGENTS" ]; then
          edc_add_alt_agents_reference "$EDC_ROOT_AGENTS"
        fi
        if [ -f "$EDC_CLAUDE_AGENTS" ]; then
          edc_add_alt_agents_reference "$EDC_CLAUDE_AGENTS"
        fi
      else
        cat >&2 <<EOF
EDC wrote its generated agent entrypoint to $EDC_ALT_AGENTS and preserved your existing $EDC_ROOT_AGENTS.

Choose how you want to expose it to agents:
  - replace $EDC_ROOT_AGENTS with $EDC_ALT_AGENTS,
  - append the relevant EDC section into $EDC_ROOT_AGENTS, or
  - add a short reference from $EDC_ROOT_AGENTS / $EDC_CLAUDE_AGENTS to $EDC_ALT_AGENTS.

To force overwrite on the next build, run with EDC_AGENTS_MODE=overwrite.
EOF
      fi
      ;;
  esac
}

# ── main ─────────────────────────────────────────────────────────────────────

build_main() {
  local force=0
  local -a passthrough=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        force=1
        passthrough+=("$1")
        shift
        ;;
      --focus)
        [ "$#" -ge 2 ] || { echo "ERROR: --focus requires a module name" >&2; usage; }
        passthrough+=("$1" "$2")
        shift 2
        ;;
      --ignore)
        [ "$#" -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; usage; }
        passthrough+=("$1" "$2")
        shift 2
        ;;
      --help|-h) usage ;;
      *) echo "ERROR: unknown argument: $1" >&2; usage ;;
    esac
  done

  edc_require_agent_cli

  # Decide route in shell (LLM does NOT make this call).
  local route
  route=$(decide_route "$force") || exit $?
  echo "→ build route: $route"

  # Wipe if route demands it.
  if [ "$route" = "wipe-and-build" ]; then
    bash "$CLEAN_SLATE_SH" --force >&2 \
      || { echo "ERROR: clean-slate --force failed" >&2; exit 1; }
  fi

  # Spawn the right subprocess.
  local action prompt
  case "$route" in
    update)
      action="update"
      ;;
    build|wipe-and-build)
      action="build"
      ;;
    *)
      echo "ERROR: internal: unknown route '$route'" >&2
      exit 1
      ;;
  esac

  if [ "$action" = "build" ]; then
    prepare_agents_entrypoint || exit $?
  fi

  echo "→ spawning $EDC_AGENT_CLI for edc-$action..."
  prompt=$(resolve_prompt "$action" "${passthrough[@]}") || exit 1
  local timeout_var
  if [ "$action" = "update" ]; then
    timeout_var="${EDC_UPDATE_TIMEOUT:-1800}"
  else
    timeout_var="${EDC_BUILD_TIMEOUT:-3600}"
  fi
  edc_spawn "edc-$action" "$timeout_var" "$prompt" \
    || { echo "ERROR: edc-$action invocation failed" >&2; exit 1; }

  if [ "$action" = "build" ]; then
    finalize_agents_entrypoint
  fi

  # Validate via doctor — deterministic end-to-end check.
  if [ ! -x "$DOCTOR_SH" ] && [ ! -f "$DOCTOR_SH" ]; then
    echo "ERROR: edc-doctor.sh not found at $DOCTOR_SH" >&2
    exit 1
  fi
  if ! bash "$DOCTOR_SH"; then
    echo "ERROR: build produced an invalid v2 layout (edc-doctor failed)" >&2
    exit 1
  fi

  edc_run_context_curator || exit 1
  edc_run_context_curator_edit || exit 1

  if ! bash "$DOCTOR_SH"; then
    echo "ERROR: context curator edit produced an invalid v2 layout (edc-doctor failed)" >&2
    exit 1
  fi
  edc_remove_context_curator_report

  echo "Build OK. Layout validated by edc-doctor; context curator report/edit pass completed."
  exit 0
}

build_main "$@"
