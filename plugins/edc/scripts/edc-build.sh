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

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edc-lib.sh
. "$SCRIPT_DIR/edc-lib.sh"
SCRIPT_DIR="$EDC_SCRIPTS_DIR"
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
  local rc=0 check_err
  check_err=$(mktemp)
  bash "$CLEAN_SLATE_SH" --check > /dev/null 2>"$check_err" || rc=$?
  case "$rc" in
    0)  # no context dir
      rm -f "$check_err"
      echo "build"
      return 0
      ;;
    11) # healthy v2
      rm -f "$check_err"
      if [ "$force" = "1" ]; then
        echo "wipe-and-build"
      else
        echo "update"
      fi
      return 0
      ;;
    10) # partial / malformed v2
      rm -f "$check_err"
      echo "wipe-and-build"
      return 0
      ;;
    12) # v1 layout — refuse
      cat "$check_err" >&2 || true
      rm -f "$check_err"
      return 12
      ;;
    *)
      echo "ERROR: edc-clean-slate.sh --check returned unexpected exit $rc" >&2
      cat "$check_err" >&2 || true
      rm -f "$check_err"
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

# ── deterministic full-build dag ─────────────────────────────────────────────

write_build_inventory() {
  local output="$1"
  shift
  local -a patterns=("$@")
  local line path pattern ignored
  : > "$output"
  while IFS= read -r line; do
    path="${line#*$'\t'}"
    ignored=0
    for pattern in ${patterns[@]+"${patterns[@]}"}; do
      # shellcheck disable=SC2053 # ignore entries are intentional glob patterns
      if [[ "$path" == $pattern ]] || [[ "$path" == "$pattern/"* ]]; then
        ignored=1
        break
      fi
    done
    [ "$ignored" -eq 1 ] || printf '%s\n' "$line" >> "$output"
  done < <(git ls-files -s)
}

load_build_ignore_patterns() {
  [ -f .edcignore ] || return 0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    printf '%s\n' "$line"
  done < .edcignore
}

assert_build_markdown_outputs() {
  local modules_json="$1" field="$2" label="$3"
  # shellcheck disable=SC2016 # JavaScript template literals must not expand in Bash.
  node -e '
    const fs = require("fs");
    const path = require("path");
    const [inputPath, field, label, exactDir] = process.argv.slice(1);
    const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
    const expected = new Set();
    for (const entry of input.modules || []) {
      const output = entry[field];
      if (!output || !fs.existsSync(output)) throw new Error(`missing ${label} output: ${output || "<unset>"}`);
      if (!/^##/m.test(fs.readFileSync(output, "utf8"))) throw new Error(`${label} output has no ## heading: ${output}`);
      expected.add(path.basename(output));
    }
    if (exactDir) {
      const unexpected = fs.readdirSync(exactDir).filter((name) => !expected.has(name));
      if (unexpected.length > 0) throw new Error(`unexpected ${label} output: ${unexpected.join(", ")}`);
    }
  ' "$modules_json" "$field" "$label" "${4:-}"
}

assert_staged_build_outputs() {
  local context_dir="$1" agents_file="$2"
  local required
  for required in \
    "$context_dir/index.md" \
    "$context_dir/manifest.json" \
    "$context_dir/reports/issues.md" \
    "$context_dir/reports/complexity.md" \
    "$context_dir/build/build.json" \
    "$agents_file"
  do
    [ -f "$required" ] || { echo "ERROR: staged build output missing: $required" >&2; return 1; }
  done
  grep -q '^##' "$context_dir/index.md" || { echo "ERROR: staged index has no ## heading" >&2; return 1; }
  grep -q '^##' "$context_dir/reports/issues.md" || { echo "ERROR: staged issues report has no ## heading" >&2; return 1; }
  grep -q '^##' "$context_dir/reports/complexity.md" || { echo "ERROR: staged complexity report has no ## heading" >&2; return 1; }
  node -e 'const manifest=require(process.argv[1]); require(process.argv[2]); process.exit(manifest.schemaVersion===2 ? 0 : 1)' "$context_dir/manifest.json" "$context_dir/build/build.json"
}

execute_full_build_dag() {
  local focus="$1"
  shift
  local -a ignore_globs=("$@")
  local run_dir run_id
  edc_create_worker_run "build" run_dir run_id || return $?
  local staged_context="$run_dir/staged/edc-context"
  local staged_modules="$staged_context/modules"
  local staged_reports="$staged_context/reports"
  local staged_build="$staged_context/build"
  local staged_agents="$run_dir/staged/agent-entrypoint.md"
  EDC_BUILD_STAGED_CONTEXT="$staged_context"
  EDC_BUILD_STAGED_AGENTS="$staged_agents"
  mkdir -p "$staged_modules" "$staged_reports" "$staged_build"

  local inventory="$run_dir/inventory.txt" discovery="$run_dir/module-plan.json"
  local discovery_prompt="$run_dir/prompts/build-discovery.md"
  write_build_inventory "$inventory" ${ignore_globs[@]+"${ignore_globs[@]}"} || return 1
  cat > "$discovery_prompt" <<EOF
BUILD DISCOVERY TASK
INVENTORY_FILE: $inventory
DISCOVERY_OUTPUT: $discovery
FOCUS_HINT: ${focus:-<none>}

Read only the git index inventory file; do not read source bodies. Identify stable operational modules using package/crate/workspace boundaries and top-level directories only as fallback. Git mode 160000 is a boundary, not indexed source. Write exactly this JSON shape to DISCOVERY_OUTPUT:
{"modules":[{"name":"kebab-case","paths":["repo/relative/path"],"approxLoc":0}]}
Names must be unique kebab-case and every module must have at least one path. Do not launch agents or invoke skills. Do not write anywhere else.
EOF
  edc_worker_run_single "$run_dir" "$run_id" build-discovery edc-build/discovery "" "$discovery_prompt" "${EDC_BUILD_TIMEOUT:-3600}" fail-fast "$discovery" || return 1

  local build_plan="$run_dir/build-plan.json"
  bash "$SCRIPT_DIR/edc-build-plan.sh" --modules-dir "$staged_modules" < "$discovery" > "$build_plan" || return 1

  local module_skill module_bundle="$run_dir/module-bundle.md" audit_bundle="$run_dir/audit-bundle.md"
  module_skill=$(_find_skill_for_agent "edc-module-context-impl") || return 1
  {
    cat "$module_skill"
    local resource
    for resource in COMPLETENESS_CHECKLIST.md FUNCTION_MICRO_ANALYSIS_EXAMPLE.md OUTPUT_REQUIREMENTS.md; do
      [ -f "$(dirname "$module_skill")/resources/$resource" ] && cat "$(dirname "$module_skill")/resources/$resource"
    done
  } > "$module_bundle"
  _emit_audit_prompt > "$audit_bundle" || return 1

  local max_concurrency
  max_concurrency=$(edc_worker_max_concurrency) || return $?
  node "$SCRIPT_DIR/../hooks/lib/build-dag.mjs" "$build_plan" "$run_id" "$run_dir" "$max_concurrency" "$module_bundle" "$audit_bundle" "${EDC_BUILD_WORKER_TIMEOUT:-1800}" || return 1
  edc_worker_pool_run "$run_dir/module-manifest.json" || return 1
  assert_build_markdown_outputs "$run_dir/build-modules.json" moduleDoc module "$staged_modules" || return 1

  local cross_notes="$run_dir/cross-module.md" cross_prompt="$run_dir/prompts/cross-module.md"
  cat > "$cross_prompt" <<EOF
CROSS-MODULE SYNTHESIS TASK
MODULE_METADATA: $run_dir/build-modules.json
OUTPUT: $cross_notes

Read every staged module doc named by MODULE_METADATA. Derive only cross-module entrypoint flows, authority boundaries, global invariants, and bounded blast-radius relationships. Do not read source bodies. Write concise markdown with at least one ## heading to OUTPUT. Do not launch agents or write other files.
EOF
  edc_worker_run_single "$run_dir" "$run_id" cross-module edc-build/cross-module "" "$cross_prompt" "${EDC_BUILD_WORKER_TIMEOUT:-1800}" fail-fast "$cross_notes" || return 1
  grep -q '^##' "$cross_notes" || { echo "ERROR: cross-module synthesis has no ## heading" >&2; return 1; }

  local partial_manifest="$run_dir/partial-manifest.json" assembly_prompt="$run_dir/prompts/build-assembly.md"
  cat > "$assembly_prompt" <<EOF
BUILD ASSEMBLY TASK
DISCOVERY_PLAN: $discovery
MODULE_METADATA: $run_dir/build-modules.json
CROSS_MODULE_NOTES: $cross_notes
INDEX_OUTPUT: $staged_context/index.md
PARTIAL_MANIFEST_OUTPUT: $partial_manifest
BUILD_INFO_OUTPUT: $staged_build/build.json
AGENT_ENTRYPOINT_OUTPUT: $staged_agents
CANONICAL_AGENT_ENTRYPOINT: ${EDC_AGENTS_TARGET:-AGENTS.md}

Read only the discovery plan, staged module docs named by MODULE_METADATA, cross-module notes, and lightweight repository metadata. Do not re-read source bodies and do not launch agents.

Write a routing-first index with this order: ## How to use, ## Route by path/task, optional compact orientation, ## Critical global invariants, ## Cross-module coupling / blast radius. Reports and contextless machine coverage are not part of the ordinary human index read path.

Write a partial schemaVersion 2 manifest with edcVersion, repoContextFile, reports, build, policy.defaultMode (advisory unless an operator value was supplied), policy.unmatchedPathPolicy=warn-allow, modules with unique priorities and canonical docs under edc-context/modules/, optional contextless.entries, and unmapped.allowedGlobs. Do not write generatedAt, sourceCommit, or coverage.

Write build metadata JSON and a short EDC agent entrypoint that points to edc-context/index.md and edc-context/manifest.json. Write only the four declared outputs. The coordinator owns manifest finalization, reports, promotion, and validation.
EOF
  edc_worker_run_single "$run_dir" "$run_id" build-assembly edc-build/assembly "" "$assembly_prompt" "${EDC_BUILD_WORKER_TIMEOUT:-1800}" fail-fast "$staged_context/index.md" "$partial_manifest" "$staged_build/build.json" "$staged_agents" || return 1

  # Build-time quality workers consume staged module docs and remain isolated.
  edc_worker_pool_run "$run_dir/build-audit-manifest.json" || return 1
  assert_build_markdown_outputs "$run_dir/build-modules.json" auditReport "build audit" || return 1
  local build_audit_synthesis="$run_dir/prompts/build-audit-synthesis.md"
  cat > "$build_audit_synthesis" <<EOF
AUDIT SYNTHESIS TASK
AUDIT_WORKER_REPORTS_DIR: $run_dir/staged/audit-tasks
CANONICAL_COMPLEXITY_REPORT: $staged_reports/complexity.md
CANONICAL_ISSUES_REPORT: $staged_reports/issues.md

Read every staged module audit report. Synthesize maintainability findings into the complexity output and concrete correctness risks into the issues output. Both files require ## headings. Preserve module evidence. Do not re-audit source, launch agents, or write other files.

$(cat "$audit_bundle")
EOF
  edc_worker_run_single "$run_dir" "$run_id" build-audit-synthesis edc-build/audit-synthesis "" "$build_audit_synthesis" "${EDC_BUILD_WORKER_TIMEOUT:-1800}" fail-fast "$staged_reports/complexity.md" "$staged_reports/issues.md" || return 1

  local manifest_tmp="$staged_context/manifest.json.tmp"
  local -a manifest_ignore_args=()
  local ignore_glob
  for ignore_glob in ${ignore_globs[@]+"${ignore_globs[@]}"}; do
    manifest_ignore_args+=(--ignore "$ignore_glob")
  done
  if ! bash "$SCRIPT_DIR/edc-manifest.sh" ${manifest_ignore_args[@]+"${manifest_ignore_args[@]}"} < "$partial_manifest" > "$manifest_tmp"; then
    rm -f "$manifest_tmp"
    return 1
  fi
  mv "$manifest_tmp" "$staged_context/manifest.json"
  assert_staged_build_outputs "$staged_context" "$staged_agents" || return 1
}

run_full_build_dag() {
  local before_snapshot after_snapshot changed_forbidden dag_rc=0
  before_snapshot=$(mktemp)
  after_snapshot=$(mktemp)
  edc_snapshot_review_forbidden_paths "$before_snapshot"

  EDC_BUILD_STAGED_CONTEXT=""
  EDC_BUILD_STAGED_AGENTS=""
  execute_full_build_dag "$@" || dag_rc=$?

  edc_snapshot_review_forbidden_paths "$after_snapshot"
  changed_forbidden=$(edc_diff_review_forbidden_paths "$before_snapshot" "$after_snapshot" || true)
  rm -f "$before_snapshot" "$after_snapshot"
  if [ -n "$changed_forbidden" ]; then
    echo "ERROR: forbidden paths changed during the build worker dag:" >&2
    echo "$changed_forbidden" | sed 's/^/  /' >&2
    return 1
  fi
  [ "$dag_rc" -eq 0 ] || return "$dag_rc"

  [ -n "$EDC_BUILD_STAGED_CONTEXT" ] && [ -n "$EDC_BUILD_STAGED_AGENTS" ] \
    || { echo "ERROR: build dag did not declare staged promotion paths" >&2; return 1; }
  [ ! -e "$EDC_CONTEXT_DIR" ] || { echo "ERROR: refusing to promote over existing $EDC_CONTEXT_DIR" >&2; return 1; }
  mv "$EDC_BUILD_STAGED_CONTEXT" "$EDC_CONTEXT_DIR" || return 1
  edc_promote_file "$EDC_BUILD_STAGED_AGENTS" "${EDC_AGENTS_TARGET:-$EDC_ROOT_AGENTS}" || return 1
}

# ── main ─────────────────────────────────────────────────────────────────────

build_main() {
  edc_result_begin build
  trap edc_result_on_exit EXIT
  local force=0 focus=""
  local -a passthrough=() ignore_globs=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        force=1
        passthrough+=("$1")
        shift
        ;;
      --focus)
        [ "$#" -ge 2 ] || { echo "ERROR: --focus requires a module name" >&2; usage; }
        focus="$2"
        passthrough+=("$1" "$2")
        shift 2
        ;;
      --ignore)
        [ "$#" -ge 2 ] || { echo "ERROR: --ignore requires a glob pattern" >&2; usage; }
        ignore_globs+=("$2")
        passthrough+=("$1" "$2")
        shift 2
        ;;
      --help|-h) usage ;;
      *) echo "ERROR: unknown argument: $1" >&2; usage ;;
    esac
  done

  if [ "${#ignore_globs[@]}" -eq 0 ]; then
    while IFS= read -r ignore_glob; do
      [ -n "$ignore_glob" ] && ignore_globs+=("$ignore_glob")
    done < <(load_build_ignore_patterns)
  fi

  edc_require_agent_cli

  # Decide route in shell (LLM does NOT make this call).
  local route route_rc=0
  route=$(decide_route "$force") || route_rc=$?
  if [ "$route_rc" -ne 0 ]; then
    case "$route_rc" in
      12) edc_result_failure "$route_rc" "legacy-v1-layout" "legacy v1 edc-context layout detected" "remove edc-context and run edc build again" ;;
      *) edc_result_failure "$route_rc" "build-route-failed" "build route decision failed" "inspect edc-clean-slate output and rerun after fixing it" ;;
    esac
    exit "$route_rc"
  fi
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

  if [ "$action" = "build" ]; then
    echo "→ executing coordinator-owned full-build dag via $EDC_AGENT_CLI..."
    run_full_build_dag "$focus" ${ignore_globs[@]+"${ignore_globs[@]}"} \
      || { echo "ERROR: coordinator-owned edc-build dag failed" >&2; edc_result_failure 1 "agent-failed" "edc-build worker dag failed" "inspect git-private run artifacts, then rerun edc build --agent $EDC_AGENT_CLI --force"; exit 1; }
    finalize_agents_entrypoint
  else
    echo "→ spawning $EDC_AGENT_CLI for edc-update..."
    prompt=$(resolve_prompt update ${passthrough[@]+"${passthrough[@]}"}) || exit 1
    edc_spawn edc-update "${EDC_UPDATE_TIMEOUT:-1800}" "$prompt" \
      || { echo "ERROR: edc-update invocation failed" >&2; edc_result_failure 1 "agent-failed" "edc-update agent invocation failed" "inspect the log above, then rerun edc update"; exit 1; }
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

  edc_result_success
  echo "Build OK. Layout validated by edc-doctor; context curator report/edit pass completed."
  exit 0
}

build_main "$@"
