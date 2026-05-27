#!/usr/bin/env bash
# bash >= 4 required: uses set -u with empty arrays
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
  echo "ERROR: requires bash >= 4.0 (on macOS: brew install bash)" >&2
  exit 2
}
# edc-audit orchestrator.
# Deterministic control plane for terminal/orchestrated edc audit runs.
#
# Flow:
#   1. dependency check (jq, git)
#   2. parse args (--ignore, --context-mode)
#   3. freshness gate via assert_context_fresh; auto-recover (build/update +
#      force-retry) if stale or missing — same recovery path review uses
#   4. spawn ONE audit subprocess via edc_spawn (claude/cursor/codex/pi)
#   5. validate output: <reports-dir>/{complexity,issues}.md must exist
#      and contain at least one ## heading
#   6. exit 0 with paths printed, non-zero with reason
#
# Usage:
#   EDC_AGENT_CLI=claude|cursor|codex|pi bash edc-audit.sh [--ignore <glob>]... [--context-mode advisory|inject]

set -euo pipefail

# ── dependency check ─────────────────────────────────────────────────────────

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required (brew install jq / apt install jq)" >&2
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

# ── agent CLI selection ──────────────────────────────────────────────────────

EDC_AGENT_CLI="${EDC_AGENT_CLI:-claude}"
CODEX_EXEC_HOME=""
CODEX_EXEC_HOME_OWNED=0

# ── shared helpers ───────────────────────────────────────────────────────────

# shellcheck source=edc-assert-fresh.sh
. "$SCRIPT_DIR/edc-assert-fresh.sh"
# shellcheck source=edc-recover-context.sh
. "$SCRIPT_DIR/edc-recover-context.sh"

# ── validate audit output ────────────────────────────────────────────────────

assert_audit_reports_valid() {
  local complexity="$EDC_COMPLEXITY"
  local issues="$EDC_ISSUES"
  local rc=0
  for f in "$complexity" "$issues"; do
    if [ ! -f "$f" ]; then
      echo "ERROR: audit report missing: $f" >&2
      rc=1
      continue
    fi
    if ! grep -q '^##' "$f"; then
      echo "ERROR: $f has no '## ' headings — expected sections like ## Summary, ## LOC Estimates" >&2
      echo "HINT: subprocess produced a stub. check the agent output above." >&2
      rc=1
    fi
  done
  return $rc
}

# ── main ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF' >&2
Usage:
  EDC_AGENT_CLI=<claude|cursor|codex|pi> edc-audit.sh [--ignore <glob>]... [--context-mode advisory|inject]
EOF
  exit 2
}

audit_main() {
  local -a ignore_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ignore)
        [ "$#" -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; usage; }
        ignore_args+=("$1" "$2")
        shift 2
        ;;
      --context-mode)
        [ "$#" -ge 2 ] || { echo "ERROR: --context-mode requires a value" >&2; usage; }
        # accepted but currently advisory-only for audit; passed through to
        # build/update if recovery is needed.
        shift 2
        ;;
      --help|-h) usage ;;
      *) echo "ERROR: unknown argument: $1" >&2; usage ;;
    esac
  done

  edc_require_agent_cli

  # Gate on freshness; recover if needed. After this returns, $EDC_CONTEXT_DIR is fresh.
  recover_context_if_needed "${ignore_args[@]}" \
    || exit 1

  # Spawn the audit subprocess.
  echo "→ running audit via $EDC_AGENT_CLI..."
  local audit_prompt
  audit_prompt=$(resolve_prompt audit) || exit 1
  edc_spawn "edc-audit" "${EDC_AUDIT_TIMEOUT:-1800}" "$audit_prompt" \
    || { echo "ERROR: edc-audit invocation failed" >&2; exit 1; }

  # Validate reports.
  assert_audit_reports_valid || exit 1

  echo "Audit reports:"
  echo "  $EDC_COMPLEXITY"
  echo "  $EDC_ISSUES"
  exit 0
}

audit_main "$@"
