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

echo "=== T34: audit skill contract ==="

has() {
  grep -Rqi --include='*.md' -- "$1" "$SKILL_DIR"
}

main_has() {
  grep -qi -- "$1" "$SKILL"
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
check "audit can stop on no findings" "$(has "Lean already. Ship." && echo 1 || echo 0)"
check "audit includes root-cause fix heuristic" "$(has "root-cause fix" && has "grep every caller" && echo 1 || echo 0)"
check "audit includes smallest runnable check heuristic" "$(has "smallest runnable check" && echo 1 || echo 0)"
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
