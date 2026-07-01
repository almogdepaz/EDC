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
check "review keeps scoped task mode" "$(main_has "--task-file" && main_has "edc-context/review-tasks/report-{module}.md" && echo 1 || echo 0)"
check "review keeps context routing guidance" "$(main_has "routing/coupling/blast-radius guidance" && echo 1 || echo 0)"
check "review requires concrete attack path for findings" "$(has "concrete attack path" && echo 1 || echo 0)"
check "review allows no-security-findings reports" "$(has "No security findings" && echo 1 || echo 0)"
check "review methodology is security-titled" "$(file_has "$METHODOLOGY" "Security Review Methodology" && echo 1 || echo 0)"
check "reporting is security-titled" "$(file_has "$REPORTING" "Security Report" && echo 1 || echo 0)"
check "adversarial reference remains present" "$(file_has "$ADVERSARIAL" "Attacker Model" && echo 1 || echo 0)"
check "patterns reference remains vulnerability-focused" "$(file_has "$PATTERNS" "Common Issue Patterns" && file_has "$PATTERNS" "Access Control Bypass" && echo 1 || echo 0)"
check "review no longer advertises generic code review" "$(not_has "Code review for PRs" && not_has "standard code review" && echo 1 || echo 0)"
check "reporting no longer recommends technical debt bucket" "$(not_has "Technical Debt" && echo 1 || echo 0)"

check_summary "T35"
