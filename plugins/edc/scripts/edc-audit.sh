#!/usr/bin/env bash
# edc-audit orchestrator.
# Deterministic control plane for terminal/orchestrated edc audit runs.
#
# Flow:
#   1. dependency check (git/node via helpers)
#   2. parse args (--ignore, --context-mode)
#   3. freshness gate via assert_context_fresh; auto-recover (build/update +
#      force-retry) if stale or missing — same recovery path review uses
#   4. spawn one scoped audit subprocess per manifest module
#   5. spawn one synthesis subprocess to write canonical reports
#   6. validate output: <reports-dir>/{complexity,issues}.md must exist
#      and contain at least one ## heading
#   7. exit 0 with paths printed, non-zero with reason
#
# Usage:
#   EDC_AGENT_CLI=claude|cursor|codex|pi bash edc-audit.sh [--ignore <glob>]... [--context-mode advisory|inject]

set -euo pipefail

# ── dependency check ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
SCRIPT_DIR="$EDC_SCRIPTS_DIR"
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

# ── audit task helpers ───────────────────────────────────────────────────────

AUDIT_TASKS_DIR="$EDC_CONTEXT_DIR/audit-tasks"

safe_audit_name() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

manifest_audit_modules() {
  node "$EDC_JSON_CLI" audit-modules "$MANIFEST"
}

assert_markdown_report_valid() {
  local f="$1" label="$2"
  if [ ! -f "$f" ]; then
    echo "ERROR: audit report missing: $f ($label)" >&2
    return 1
  fi
  if ! grep -q '^##' "$f"; then
    echo "ERROR: $f has no '## ' headings — expected sections like ## Summary" >&2
    echo "HINT: subprocess produced a stub. check the agent output above." >&2
    return 1
  fi
}

assert_audit_reports_valid() {
  local rc=0
  assert_markdown_report_valid "$EDC_COMPLEXITY" "complexity" || rc=1
  assert_markdown_report_valid "$EDC_ISSUES" "issues" || rc=1
  return $rc
}

build_audit_worker_prompt() {
  local module="$1" module_doc="$2" report_path="$3"
  cat <<EOF
AUDIT WORKER TASK
AUDIT_MODULE: $module
AUDIT_MODULE_DOC: $module_doc
AUDIT_REPORT_PATH: $report_path

Run a scoped code quality audit for this one module only.

Rules:
1. Read $EDC_INDEX, $MANIFEST, and $module_doc for this module's documented ownership, invariants, and file scope.
2. Inspect only this module plus the smallest supporting references needed to verify a local code-quality finding.
3. Write exactly one markdown report to $report_path.
4. Do not write $EDC_COMPLEXITY or $EDC_ISSUES; synthesis owns canonical reports.
5. Use the embedded edc-audit skill bundle below.

$(_emit_audit_prompt)
EOF
}

build_audit_synthesis_prompt() {
  cat <<EOF
AUDIT SYNTHESIS TASK
AUDIT_WORKER_REPORTS_DIR: $AUDIT_TASKS_DIR
CANONICAL_COMPLEXITY_REPORT: $EDC_COMPLEXITY
CANONICAL_ISSUES_REPORT: $EDC_ISSUES

Synthesize the scoped module audit reports into the canonical EDC audit reports.

Rules:
1. Read every markdown report under $AUDIT_TASKS_DIR.
2. Do not re-audit source code unless a worker report is ambiguous and a small verification read is necessary.
3. Write $EDC_COMPLEXITY for maintainability/code-quality findings.
4. Write $EDC_ISSUES only for concrete correctness risks surfaced by worker reports.
5. Preserve module names and evidence from worker reports so findings remain traceable.
6. Use the embedded edc-audit reporting contract below.

$(_emit_audit_prompt)
EOF
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
  edc_result_begin audit
  trap edc_result_on_exit EXIT
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
  recover_context_if_needed ${ignore_args[@]+"${ignore_args[@]}"} \
    || exit 1

  # Spawn one scoped audit subprocess per real module, then synthesize the
  # worker outputs into the canonical reports.
  echo "→ running per-module audit via $EDC_AGENT_CLI..."
  rm -rf "$AUDIT_TASKS_DIR"
  mkdir -p "$AUDIT_TASKS_DIR" "$EDC_REPORTS_DIR"

  local module module_doc safe report_path worker_prompt module_count=0
  while IFS=$'\t' read -r module module_doc; do
    [ -n "${module:-}" ] || continue
    module_count=$((module_count + 1))
    if [ -z "${module_doc:-}" ] || [ ! -f "$module_doc" ]; then
      echo "ERROR: manifest module '$module' has missing doc: ${module_doc:-<empty>}" >&2
      exit 1
    fi
    safe=$(safe_audit_name "$module")
    [ -n "$safe" ] || safe="module_$module_count"
    report_path="$AUDIT_TASKS_DIR/$safe.md"
    echo "→ auditing module: $module"
    worker_prompt=$(build_audit_worker_prompt "$module" "$module_doc" "$report_path") || exit 1
    local worker_rc
    if edc_spawn "edc-audit/$safe" "${EDC_AUDIT_TIMEOUT:-1800}" "$worker_prompt"; then
      worker_rc=0
    else
      worker_rc=$?
    fi
    assert_markdown_report_valid "$report_path" "module $module" \
      || { echo "ERROR: module audit validation failed for $module" >&2; edc_result_failure 1 "audit-report-validation" "module audit validation failed for $module" "inspect the module audit output in the log; the report is missing or incomplete" "$module"; exit 1; }
    if [ "$worker_rc" -ne 0 ]; then
      echo "EDC audit succeeded with warning: audit subprocess for module $module reported failure, but report validation passed." >&2
      echo "HINT: treating the validated module audit report as success; inspect the agent log for transport/provider diagnostics." >&2
    fi
  done < <(manifest_audit_modules)

  if [ "$module_count" -eq 0 ]; then
    echo "ERROR: no real modules found in $MANIFEST; cannot run per-module audit" >&2
    exit 1
  fi

  rm -f "$EDC_COMPLEXITY" "$EDC_ISSUES"
  echo "→ synthesizing audit reports..."
  local synthesis_prompt
  synthesis_prompt=$(build_audit_synthesis_prompt) || exit 1
  local synthesis_rc
  if edc_spawn "edc-audit/synthesis" "${EDC_AUDIT_TIMEOUT:-1800}" "$synthesis_prompt"; then
    synthesis_rc=0
  else
    synthesis_rc=$?
  fi

  # Validate reports.
  assert_audit_reports_valid || { edc_result_failure 1 "audit-report-validation" "audit report validation failed" "inspect synthesis output in the log; canonical reports are missing or incomplete"; exit 1; }
  if [ "$synthesis_rc" -ne 0 ]; then
    echo "EDC audit succeeded with warning: audit synthesis subprocess reported failure, but report validation passed." >&2
    echo "HINT: treating the validated audit reports as success; inspect the agent log for transport/provider diagnostics." >&2
  fi

  if [ "${EDC_KEEP_AUDIT_TASKS:-0}" != "1" ]; then
    rm -rf "$AUDIT_TASKS_DIR"
  fi

  edc_result_success
  echo "Audit reports:"
  echo "  $EDC_COMPLEXITY"
  echo "  $EDC_ISSUES"
  exit 0
}

audit_main "$@"
