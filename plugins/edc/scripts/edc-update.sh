#!/usr/bin/env bash
# bash >= 4 required
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
# edc-update orchestrator.
# Deterministic control plane for /edc:edc-update.
#
# Flow:
#   1. dep check (jq, git)
#   2. parse args (--base, --ignore, --context-mode)
#   3. preflight gate via edc-clean-slate.sh --check:
#        11 (healthy v2)            → proceed
#        0  (no context dir)         → REFUSE: "run edc-build first"
#        10 (partial / malformed)   → REFUSE: "run edc-build to rebuild"
#        12 (v1 layout)             → already printed migration hint, exit
#   4. auto-detect base if --base not given (git merge-base with main/master)
#   5. spawn ONE update subprocess via edc_spawn (claude/cursor/codex).
#      Skill internally re-runs git diff + edc-route.sh against the same
#      base, refreshes affected modules + reports + manifest.
#   6. validate via edc-doctor.sh — non-zero doctor → update failed
#
# Usage:
#   EDC_AGENT_CLI=claude bash edc-update.sh [--base <ref>] [--ignore <glob>]...

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
  EDC_AGENT_CLI=<claude|cursor|codex> edc-update.sh \
    [--base <ref>] [--ignore <glob>]... [--context-mode advisory|inject]
EOF
  exit 2
}

# ── preflight gate ───────────────────────────────────────────────────────────

# Echoes nothing on success. Exits non-zero with a copy-pasteable hint when
# the on-disk state cannot be safely updated.
preflight_check() {
  local rc=0
  bash "$CLEAN_SLATE_SH" --check > /dev/null 2>/tmp/edc-clean-slate-check.err || rc=$?
  case "$rc" in
    11) # healthy v2 — good to go
      return 0
      ;;
    0)  # no context dir
      cat >&2 <<EOF
ERROR: no ${EDC_CONTEXT_DIR}/ to update.

Run a full build first:

  /edc:edc-build      # or: edc build --agent <claude|cursor|codex>
EOF
      return 1
      ;;
    10) # partial / malformed v2
      cat >&2 <<EOF
ERROR: partial or malformed ${EDC_CONTEXT_DIR}/ layout detected.

This usually means a previous build was interrupted or wrote v1-shaped output.
Run a full rebuild to fix it:

  /edc:edc-build --force      # or: edc build --agent <agent> --force
EOF
      return 1
      ;;
    12) # v1 layout — clean-slate already printed the migration hint
      cat /tmp/edc-clean-slate-check.err >&2 || true
      return 1
      ;;
    *)
      echo "ERROR: edc-clean-slate.sh --check returned unexpected exit $rc" >&2
      cat /tmp/edc-clean-slate-check.err >&2 || true
      return 1
      ;;
  esac
}

# Auto-detect base ref if --base not provided. Mirrors the skill's logic.
auto_detect_base() {
  git merge-base HEAD main 2>/dev/null \
    || git merge-base HEAD master 2>/dev/null \
    || true
}

# ── main ─────────────────────────────────────────────────────────────────────

update_main() {
  local base=""
  local -a passthrough=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base)
        [ "$#" -ge 2 ] || { echo "ERROR: --base requires a ref" >&2; usage; }
        base="$2"
        passthrough+=("$1" "$2")
        shift 2
        ;;
      --ignore)
        [ "$#" -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; usage; }
        passthrough+=("$1" "$2")
        shift 2
        ;;
      --context-mode)
        [ "$#" -ge 2 ] || { echo "ERROR: --context-mode requires a value" >&2; usage; }
        # accepted; not currently used by update path. Stays out of passthrough
        # because the update skill doesn't consume it.
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

  # Preflight: shell decides whether the on-disk state is updateable.
  preflight_check || exit 1

  # Auto-detect base if not given. Pass through to skill so its git-diff
  # call sees the same base. Empty base = "skill auto-detects" (existing
  # skill behavior); we just print what we found for log clarity.
  if [ -z "$base" ]; then
    base=$(auto_detect_base)
    if [ -n "$base" ]; then
      echo "→ auto-detected base: $base"
      passthrough+=("--base" "$base")
    else
      echo "→ no main/master branch found; skill will infer base"
    fi
  fi

  echo "→ spawning $EDC_AGENT_CLI for edc-update..."
  local prompt
  prompt=$(resolve_prompt update "${passthrough[@]}") || exit 1
  edc_spawn "edc-update" "${EDC_UPDATE_TIMEOUT:-1800}" "$prompt" \
    || { echo "ERROR: edc-update invocation failed" >&2; exit 1; }

  # Validate via doctor.
  if [ ! -f "$DOCTOR_SH" ]; then
    echo "ERROR: edc-doctor.sh not found at $DOCTOR_SH" >&2
    exit 1
  fi
  if ! bash "$DOCTOR_SH"; then
    echo "ERROR: update produced an invalid v2 layout (edc-doctor failed)" >&2
    exit 1
  fi

  echo "Update OK. Layout validated by edc-doctor."
  exit 0
}

update_main "$@"
