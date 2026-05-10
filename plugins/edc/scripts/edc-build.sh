#!/usr/bin/env bash
# bash >= 4 required
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
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
#   EDC_AGENT_CLI=claude bash edc-build.sh \
#     [--force] [--focus <module>] [--ignore <glob>]...

set -euo pipefail

# ── dependency check ─────────────────────────────────────────────────────────

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required (brew install jq / apt install jq)" >&2
  exit 2
fi
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
# shellcheck source=edc-paths.sh
. "$SCRIPT_DIR/edc-paths.sh"
MANIFEST="$EDC_MANIFEST"
CLEAN_SLATE_SH="$SCRIPT_DIR/edc-clean-slate.sh"
DOCTOR_SH="$SCRIPT_DIR/edc-doctor.sh"

# ── agent CLI selection ──────────────────────────────────────────────────────

EDC_AGENT_CLI="${EDC_AGENT_CLI:-claude}"
CODEX_EXEC_HOME=""
CODEX_EXEC_HOME_OWNED=0

# ── shared helpers ───────────────────────────────────────────────────────────

# shellcheck source=edc-runtime.sh
. "$SCRIPT_DIR/edc-runtime.sh"
# shellcheck source=edc-resolve-prompt.sh
. "$SCRIPT_DIR/edc-resolve-prompt.sh"
# shellcheck source=edc-spawn.sh
. "$SCRIPT_DIR/edc-spawn.sh"

# ── usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF' >&2
Usage:
  EDC_AGENT_CLI=<claude|cursor|codex> edc-build.sh \
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
      ensure_codex_exec_home
      ;;
    *)
      echo "ERROR: EDC_AGENT_CLI must be 'claude', 'cursor', or 'codex'" >&2
      exit 2
      ;;
  esac

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

  # Validate via doctor — deterministic end-to-end check.
  if [ ! -x "$DOCTOR_SH" ] && [ ! -f "$DOCTOR_SH" ]; then
    echo "ERROR: edc-doctor.sh not found at $DOCTOR_SH" >&2
    exit 1
  fi
  if ! bash "$DOCTOR_SH"; then
    echo "ERROR: build produced an invalid v2 layout (edc-doctor failed)" >&2
    exit 1
  fi

  echo "Build OK. Layout validated by edc-doctor."
  exit 0
}

build_main "$@"
