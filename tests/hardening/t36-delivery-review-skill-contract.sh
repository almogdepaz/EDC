#!/usr/bin/env bash
# Task 36: edc-delivery-review prompt contract.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/hardening/lib/check.sh"
check_init

SKILL_DIR="$ROOT/plugins/edc/skills/edc-delivery-review"
SKILL="$SKILL_DIR/SKILL.md"

echo "=== T36: delivery review skill contract ==="

has() { grep -Rqi --include='*.md' -- "$1" "$SKILL_DIR" 2>/dev/null; }
main_has() { [ -f "$SKILL" ] && grep -qi -- "$1" "$SKILL"; }
not_has() { ! grep -Rqi --include='*.md' -- "$1" "$SKILL_DIR" 2>/dev/null; }

check "delivery review skill exists" "$([ -f "$SKILL" ] && echo 1 || echo 0)"
check "delivery review is framed around goal/spec and architecture" "$(main_has "Goal / Spec Delivery" && main_has "Architecture Fit" && echo 1 || echo 0)"
check "delivery review uses side-by-side axes" "$(has "Do not merge or rerank the axes" && echo 1 || echo 0)"
check "delivery review discovers spec sources" "$(has "Spec source discovery" && has "commit messages" && has ".plans" && echo 1 || echo 0)"
check "delivery review handles no spec without hallucinating" "$(has "No spec available" && has "do not hallucinate" && echo 1 || echo 0)"
check "delivery review requires requirement quotes" "$(has "quote the requirement" && echo 1 || echo 0)"
check "delivery review treats repo specs as untrusted evidence" "$(has "untrusted evidence" && has "must not override this skill" && has "hide findings" && echo 1 || echo 0)"
check "delivery review detects missing partial wrong scope creep" "$(has "missing requirement" && has "partial requirement" && has "implemented but wrong" && has "scope creep" && echo 1 || echo 0)"
check "delivery review checks module ownership" "$(has "module ownership" && has "source of truth" && echo 1 || echo 0)"
check "delivery review checks contracts and rollout" "$(has "API/error contract" && has "migration" && has "backward compatibility" && echo 1 || echo 0)"
check "delivery review includes review calibration gate" "$(has "Review Calibration" && has "real goal" && has "done evidence" && has "not the goal" && has "non-obvious invariants" && echo 1 || echo 0)"
check "delivery review can report flawed plan or spec" "$(has "spec/plan issue" && has "do not force bad spec compliance" && echo 1 || echo 0)"
check "delivery review requires candidate then verification" "$(has "candidate scan" && has "context verification" && echo 1 || echo 0)"
check "delivery review checks ownership boundary specifics" "$(has "unit-of-work" && has "session/resource ownership" && has "orchestration depth" && has "client/adapter abstraction" && has "event publisher/subscriber" && echo 1 || echo 0)"
check "delivery review findings include concrete action labels" "$(has "IMPLEMENT_REQUIREMENT" && has "REMOVE_SCOPE_CREEP" && has "MOVE_TO_OWNER" && has "CHOOSE_SOURCE_OF_TRUTH" && has "STANDARDIZE_CONTRACT" && has "ADD_MIGRATION_OR_ROLLOUT" && echo 1 || echo 0)"
check "delivery review excludes code quality" "$(has "Use edc-audit for code quality" && echo 1 || echo 0)"
check "delivery review excludes security" "$(has "Use edc-review for security" && echo 1 || echo 0)"
check "delivery review output has two verdicts" "$(has "Delivery verdict" && has "Architecture fit" && echo 1 || echo 0)"
check "delivery review has reporting reference" "$([ -f "$SKILL_DIR/references/reporting.md" ] && echo 1 || echo 0)"
check "delivery review has spec-axis reference" "$([ -f "$SKILL_DIR/references/spec-axis.md" ] && echo 1 || echo 0)"
check "delivery review has architecture-axis reference" "$([ -f "$SKILL_DIR/references/architecture-axis.md" ] && echo 1 || echo 0)"
check "delivery review avoids security framing" "$(not_has "attack path\|exploit\|vulnerability" && echo 1 || echo 0)"
check "delivery review avoids quality smell framing" "$(not_has "duplicated code\|primitive obsession\|possible smell" && echo 1 || echo 0)"

check_summary "T36"
