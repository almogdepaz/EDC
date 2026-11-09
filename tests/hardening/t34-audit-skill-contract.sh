#!/usr/bin/env bash
# Task 34: audit skill prompt contract.
#
# Pins the edc-audit methodology as read-only scoped quality/maintainability
# analysis, not a whole-repo-only bloat pass.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/hardening/lib/check.sh"

check_init

SKILL_DIR="$ROOT/plugins/edc/skills/edc-audit"
SKILL="$SKILL_DIR/SKILL.md"
SCOPE_STANDARDS="$SKILL_DIR/references/scope-and-standards.md"
RUNTIME_LIB="$ROOT/plugins/edc/scripts/edc-lib.sh"
QUALITY_CHECKS="$SKILL_DIR/references/quality-checks.md"
REPORTING="$SKILL_DIR/references/reporting.md"

echo "=== T34: audit skill contract ==="

has() {
  grep -Rqi --include='*.md' -- "$1" "$SKILL_DIR"
}

main_has() {
  grep -qi -- "$1" "$SKILL"
}

file_has() {
  grep -qi -- "$2" "$1"
}

check "audit is framed as scoped analysis" "$(has "read-only scoped analysis" && echo 1 || echo 0)"
check "audit forbids source mutation" "$(has "must not mutate" && echo 1 || echo 0)"
check "audit constrains writes to assigned report artifact" "$(has "assigned report artifact" && echo 1 || echo 0)"
check "audit documents module scope" "$(has "full module" && echo 1 || echo 0)"
check "audit documents diff scope for future reuse" "$(has "changed files" && echo 1 || echo 0)"
check "audit keeps global conclusions for synthesis" "$(has "global/cross-module conclusions belong to synthesis" && echo 1 || echo 0)"
check "audit loads documented standards sources" "$(has "documented standards sources" && echo 1 || echo 0)"
check "audit treats repo standards as overriding smell baseline" "$(has "repo standards override" && echo 1 || echo 0)"
check "audit uses Fowler smell baseline as heuristics" "$(has "Fowler smell baseline" && echo 1 || echo 0)"
check "audit main points to scope reference" "$(main_has "references/scope-and-standards.md" && echo 1 || echo 0)"
check "audit main points to smell reference" "$(main_has "references/smell-baseline.md" && echo 1 || echo 0)"
check "audit main points to quality checks reference" "$(main_has "references/quality-checks.md" && echo 1 || echo 0)"
check "audit main points to reporting reference" "$(main_has "references/reporting.md" && echo 1 || echo 0)"
check "audit requires standard citations" "$(has "cite the standard" && echo 1 || echo 0)"
check "audit scope reference treats Octocode results as candidates, not proof" "$(file_has "$SCOPE_STANDARDS" 'OCTOCODE_STATUS: available' && file_has "$SCOPE_STANDARDS" "dead exports" && file_has "$SCOPE_STANDARDS" "cannot prove dead code or zero references" && file_has "$SCOPE_STANDARDS" "lexical search, exact reads, and the smallest runnable verification" && echo 1 || echo 0)"
check "audit coordinator guidance preserves scope, semantic uncertainty, and fallback" "$(file_has "$RUNTIME_LIB" "Do not install or configure Octocode" && file_has "$RUNTIME_LIB" "widen scope" && file_has "$RUNTIME_LIB" "Treat unavailable semantic support as unknown" && file_has "$RUNTIME_LIB" "existing Read, Grep, Glob, and Bash tools" && echo 1 || echo 0)"
check "audit labels smell findings as possible" "$(has "possible smell" && echo 1 || echo 0)"
check "audit skips tooling-enforced issues" "$(has "do not report formatter/linter/type errors" && echo 1 || echo 0)"
check "audit has no security framing" "$(! grep -qi -- "security" "$SKILL" && echo 1 || echo 0)"
check "audit has no operational framing" "$(! grep -qi -- "operational\|operability" "$SKILL" && echo 1 || echo 0)"

for category in \
  "correctness smells" \
  "error handling" \
  "interface honesty" \
  "side-effect breadth" \
  "type/contract weakness" \
  "test value" \
  "simplicity"; do
  check "audit includes quality category: $category" "$(has "$category" && echo 1 || echo 0)"
done

check "audit includes simplification ladder" "$(has "Simplification ladder" && has "existing repo helper" && has "standard library" && has "native platform" && has "installed dependency" && has "one line" && has "minimum custom code" && echo 1 || echo 0)"
check "audit includes ponytail simplification tags" "$(has "delete:" && has "stdlib:" && has "native:" && has "yagni:" && has "shrink:" && echo 1 || echo 0)"
check "audit orders by simplification impact" "$(has "rank biggest cuts first" && has "estimated removal" && echo 1 || echo 0)"
check "audit can stop on scoped no findings without shipment approval" "$(has "No actionable code-quality findings in the inspected scope" && ! has "Lean already. Ship." && echo 1 || echo 0)"
check "audit treats size ratios as leads rather than findings" "$(has "investigation leads, never sufficient findings" && ! has "actual LOC > 2x" && ! has 'abstractions > 3 \* callers' && echo 1 || echo 0)"
check "audit uses bounded history to investigate coupling" "$(has "bounded local git history" && has "co-change" && has "formatting" && has "missing history is a coverage limitation" && echo 1 || echo 0)"
check "audit checks interface stability and caller vocabulary" "$(has "Interface stability" && has "implementation-only changes" && has "caller-specific vocabulary" && has "volatile implementation details" && echo 1 || echo 0)"
check "audit keeps structural heuristics evidence-based" "$(has "not a requirement that every change touch one file" && has "not an absolute import rule" && echo 1 || echo 0)"
check "audit includes root-cause fix heuristic" "$(has "root-cause fix" && has "grep every caller" && echo 1 || echo 0)"
check "audit includes smallest runnable check heuristic" "$(has "smallest runnable check" && echo 1 || echo 0)"
check "audit derives state complexity from source-backed transitions" "$(file_has "$QUALITY_CHECKS" "states, events, transition guards, mutation ownership" && file_has "$QUALITY_CHECKS" "source-backed invariants" && file_has "$QUALITY_CHECKS" "implicit state encoded by flags or callbacks" && file_has "$QUALITY_CHECKS" "Do not infer atomicity" && echo 1 || echo 0)"
check "audit requires concrete state complexity evidence and counterexamples" "$(file_has "$QUALITY_CHECKS" "contradictory reachable states" && file_has "$QUALITY_CHECKS" "duplicated transition rules" && file_has "$QUALITY_CHECKS" "unclear mutation ownership" && file_has "$QUALITY_CHECKS" "inconsistent failure/retry cleanup" && file_has "$QUALITY_CHECKS" "Counts of states/booleans alone" && file_has "$QUALITY_CHECKS" "intentional independent flags and legitimate complex workflows" && echo 1 || echo 0)"
check "audit compares existing tests before claiming missing sequences" "$(file_has "$QUALITY_CHECKS" "Compare relevant existing tests before claiming a missing case" && file_has "$QUALITY_CHECKS" "bounded event sequence" && file_has "$QUALITY_CHECKS" "externally observable result" && file_has "$QUALITY_CHECKS" "coverage evidence or explicit uncertainty" && file_has "$QUALITY_CHECKS" "existing test file/harness" && echo 1 || echo 0)"
check "audit considers applicable async edges without mandatory expansion" "$(file_has "$QUALITY_CHECKS" "retry, cancellation, late/duplicate/out-of-order responses, partial failure, cleanup, and re-entry" && file_has "$QUALITY_CHECKS" "not a mandatory checklist for unrelated code" && echo 1 || echo 0)"
check "audit distinguishes test suggestions from executions and bugs" "$(file_has "$QUALITY_CHECKS" "Suggestions are not executed tests or verified bugs" && file_has "$QUALITY_CHECKS" "already-covered sequences" && echo 1 || echo 0)"
check "audit reporting retains actionable state-test evidence through synthesis" "$(file_has "$REPORTING" "bounded event sequence" && file_has "$REPORTING" "externally observable result" && file_has "$REPORTING" "source/invariant" && file_has "$REPORTING" "coverage evidence or explicit uncertainty" && file_has "$REPORTING" "existing test file/harness" && file_has "$REPORTING" "Synthesis must retain" && file_has "$REPORTING" "not executed tests or verified bugs" && echo 1 || echo 0)"
check "audit includes accepted debt marker" "$(has "edc-debt:" && has "upgrade when" && echo 1 || echo 0)"
check "audit includes antipattern catalog overlap" "$(has "Antipattern catalog overlap" && has "boat anchor" && has "cargo cult" && has "action at a distance" && has "magic pushbutton" && has "soft code" && has "shooting the messenger" && echo 1 || echo 0)"

for smell in \
  "mysterious name" \
  "feature envy" \
  "data clumps" \
  "primitive obsession" \
  "repeated switches" \
  "shotgun surgery" \
  "divergent change" \
  "message chains" \
  "refused bequest"; do
  check "audit includes smell baseline: $smell" "$(has "$smell" && echo 1 || echo 0)"
done

check_summary "T34"
