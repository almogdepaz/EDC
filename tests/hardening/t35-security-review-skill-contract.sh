#!/usr/bin/env bash
# Task 35: edc-review security-review prompt contract.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/hardening/lib/check.sh"
check_init

SKILL_DIR="$ROOT/plugins/edc/skills/edc-review"
SKILL="$SKILL_DIR/SKILL.md"
METHODOLOGY="$SKILL_DIR/methodology.md"
REPORTING="$SKILL_DIR/reporting.md"
ADVERSARIAL="$SKILL_DIR/adversarial.md"
PATTERNS="$SKILL_DIR/patterns.md"

echo "=== T35: security review skill contract ==="

has() { grep -Rqi --include='*.md' -- "$1" "$SKILL_DIR"; }
main_has() { grep -qi -- "$1" "$SKILL"; }
file_has() { grep -qi -- "$2" "$1"; }
not_has() { ! grep -Rqi --include='*.md' -- "$1" "$SKILL_DIR"; }

line_count=$(wc -l < "$SKILL")
check "review main skill is slim enough" "$([ "$line_count" -le 120 ] && echo 1 || echo 0)"
check "review is framed as security review" "$(main_has "# Security Review" && main_has "security/adversarial" && echo 1 || echo 0)"
check "description names security/adversarial review" "$(main_has "security" && main_has "adversarial" && echo 1 || echo 0)"
check "review excludes code quality audit" "$(has "Use edc-audit for code quality" && echo 1 || echo 0)"
check "review excludes delivery/spec review" "$(has "Use edc-delivery-review" && echo 1 || echo 0)"
check "review keeps scoped task mode with task-declared output" "$(main_has "--task-file" && main_has "task-declared report path" && ! main_has "edc-context/review-tasks/report-{module}.md" && echo 1 || echo 0)"
check "review is read-only outside declared output" "$(main_has "read-only" && main_has "Do not mutate source" && echo 1 || echo 0)"
check "review keeps context routing guidance" "$(main_has "routing/coupling/blast-radius guidance" && echo 1 || echo 0)"
check "review requires concrete attack path for findings" "$(has "concrete attack path" && echo 1 || echo 0)"
check "review allows no-security-findings reports" "$(has "No security findings" && echo 1 || echo 0)"
check "review methodology is security-titled" "$(file_has "$METHODOLOGY" "Security Review Methodology" && echo 1 || echo 0)"
check "review uses optional Octocode for targeted security evidence" "$(file_has "$METHODOLOGY" "already installed and useful" && file_has "$METHODOLOGY" "reachability, blast-radius, dependency-source, and permitted history research" && echo 1 || echo 0)"
check "review methodology preserves scope, semantic uncertainty, and fallback" "$(file_has "$METHODOLOGY" "Do not install or configure Octocode" && file_has "$METHODOLOGY" "widen assigned scope" && file_has "$METHODOLOGY" "unavailable semantic support as evidence of absence" && file_has "$METHODOLOGY" "fail when Octocode is unavailable or unnecessary" && file_has "$METHODOLOGY" "existing Read, Grep, Glob, and Bash workflows remain valid fallbacks" && echo 1 || echo 0)"
check "reporting is security-titled" "$(file_has "$REPORTING" "Security Report" && echo 1 || echo 0)"
check "reporting requires exact Findings heading" "$(file_has "$REPORTING" "exact heading \`## Findings\`" && file_has "$REPORTING" "Do not replace" && echo 1 || echo 0)"
check "adversarial reference remains present" "$(file_has "$ADVERSARIAL" "Attacker Model" && echo 1 || echo 0)"
check "C/C++ fast path covers recursive stack exhaustion" "$(file_has "$METHODOLOGY" "unbounded recursion" && file_has "$METHODOLOGY" "stack-overflow risk" && file_has "$PATTERNS" "Recursive Parser / Walker Depth" && echo 1 || echo 0)"
check "patterns reference remains vulnerability-focused" "$(file_has "$PATTERNS" "Common Issue Patterns" && file_has "$PATTERNS" "Access Control Bypass" && echo 1 || echo 0)"
check "review no longer advertises generic code review" "$(not_has "Code review for PRs" && not_has "standard code review" && echo 1 || echo 0)"
check "reporting no longer recommends technical debt bucket" "$(not_has "Technical Debt" && echo 1 || echo 0)"

check_summary "T35"
