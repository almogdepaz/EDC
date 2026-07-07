#!/usr/bin/env bash
# Task 27: prompt/docs contract for routing-first context index and distilled module docs
# Run from repo root: bash tests/hardening/t27-index-context-contract.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/hardening/lib/check.sh"
check_init

BUILD_PROMPT="$ROOT/plugins/edc/prompt-bundles/edc-build-impl/SKILL.md"
UPDATE_PROMPT="$ROOT/plugins/edc/prompt-bundles/edc-update-impl/SKILL.md"
MODULE_PROMPT="$ROOT/plugins/edc/prompt-bundles/edc-module-context-impl/SKILL.md"
MODULE_OUTPUT_REQUIREMENTS="$ROOT/plugins/edc/prompt-bundles/edc-module-context-impl/resources/OUTPUT_REQUIREMENTS.md"
MANIFEST_SCHEMA="$ROOT/plugins/edc/prompt-bundles/edc-build-impl/manifest-schema.md"
BUILD_PLAN="$ROOT/plugins/edc/scripts/edc-build-plan.sh"
JSON_CLI="$ROOT/plugins/edc/hooks/lib/json-cli.mjs"
REVIEW_SKILL="$ROOT/plugins/edc/skills/edc-review/SKILL.md"
REVIEW_METHODOLOGY="$ROOT/plugins/edc/skills/edc-review/methodology.md"

contains() {
  local file="$1" text="$2"
  grep -Fq "$text" "$file"
}

not_contains() {
  local file="$1" text="$2"
  ! grep -Fq "$text" "$file"
}

line_number() {
  local file="$1" text="$2"
  grep -nF "$text" "$file" | head -n 1 | cut -d: -f1
}

line_before() {
  local file="$1" first="$2" second="$3" a b
  a=$(line_number "$file" "$first")
  b=$(line_number "$file" "$second")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

echo "=== T27: index/context prompt contract ==="

check "build prompt frames index as single operational context index" \
  "$(contains "$BUILD_PROMPT" "single operational context index" && echo 1 || echo 0)"
check "build prompt requires route table section" \
  "$(contains "$BUILD_PROMPT" "## Route by path/task" && echo 1 || echo 0)"
check "build prompt makes overview/table optional and compact" \
  "$(contains "$BUILD_PROMPT" "Optional compact sections" && contains "$BUILD_PROMPT" "Architecture overview" && contains "$BUILD_PROMPT" "Module table" && contains "$BUILD_PROMPT" "Do not include generated file counts, LOC estimates, or manifest priority values" && echo 1 || echo 0)"
check "build prompt keeps route table before optional overview" \
  "$(line_before "$BUILD_PROMPT" "## Route by path/task" "Architecture overview" && echo 1 || echo 0)"
check "build prompt keeps reports out of ordinary index read path" \
  "$(contains "$BUILD_PROMPT" "reports are not part of the ordinary index read path" && not_contains "$BUILD_PROMPT" "links to issues/complexity/review reports when present" && echo 1 || echo 0)"
check "build prompt carries cd8080c signal filter" \
  "$(contains "$BUILD_PROMPT" "If an agent can discover it with one Read, Grep, or Glob, leave it out." && echo 1 || echo 0)"
check "build prompt explains contextless entries are machine coverage" \
  "$(contains "$BUILD_PROMPT" "contextless.entries" && contains "$BUILD_PROMPT" "must not appear in the human index read path" && echo 1 || echo 0)"
check "build prompt detects gitlink submodule boundaries" \
  "$(contains "$BUILD_PROMPT" "git ls-files -s" && contains "$BUILD_PROMPT" "mode 160000" && contains "$BUILD_PROMPT" "submodule/gitlink" && echo 1 || echo 0)"

check "update prompt preserves routing-first index sections without reports" \
  "$(contains "$UPDATE_PROMPT" "preserve this section order" && contains "$UPDATE_PROMPT" "Route by path/task" && contains "$UPDATE_PROMPT" "Cross-module coupling / blast radius" && contains "$UPDATE_PROMPT" "Do not add a Reports section" && echo 1 || echo 0)"
check "update prompt avoids noisy local-only index rewrites" \
  "$(contains "$UPDATE_PROMPT" "purely local implementation detail changed" && echo 1 || echo 0)"

check "module prompt distinguishes reasoning depth from persisted prose" \
  "$(contains "$MODULE_PROMPT" "analysis depth is the reasoning method, not the persisted artifact shape" && echo 1 || echo 0)"
check "module prompt requires distilled high-signal docs" \
  "$(contains "$MODULE_PROMPT" "distilled high-signal module context" && echo 1 || echo 0)"
check "module prompt carries single Read/Grep/Glob signal filter" \
  "$(contains "$MODULE_PROMPT" "If an agent can discover it with one Read, Grep, or Glob, leave it out." && echo 1 || echo 0)"
check "module prompt requires decision-useful read boundaries" \
  "$(contains "$MODULE_PROMPT" "read-boundary guidance" && contains "$MODULE_PROMPT" "Do not add empty template sections" && echo 1 || echo 0)"
check "module prompt requires source-truth pointers for exact details" \
  "$(contains "$MODULE_PROMPT" "source-truth pointers" && contains "$MODULE_PROMPT" "exact constants, schemas, enum values, timeouts, limits, generated artifacts, or protocol workflow details" && echo 1 || echo 0)"
check "module prompt treats exact literals as source-owned snapshots" \
  "$(contains "$MODULE_PROMPT" "Avoid exact reference material" && contains "$MODULE_PROMPT" "service lists, file modes, timeout/count tables" && contains "$MODULE_PROMPT" "mark it as a snapshot and name the authoritative source file" && echo 1 || echo 0)"
check "module prompt forbids inferred submodule internals" \
  "$(contains "$MODULE_PROMPT" "submodule/gitlink" && contains "$MODULE_PROMPT" "boundary-only" && contains "$MODULE_PROMPT" "do not infer internal architecture" && echo 1 || echo 0)"
check "module prompt preserves parent context for large targets" \
  "$(contains "$MODULE_PROMPT" "Large target rule" && contains "$MODULE_PROMPT" "preserve the whole-target mental model" && contains "$MODULE_PROMPT" "internal sub-routing or harness/workflow guidance" && echo 1 || echo 0)"
check "module prompt rejects size-only splitting" \
  "$(contains "$MODULE_PROMPT" "Do not split solely because LOC or file count is high" && contains "$MODULE_PROMPT" "Split or promote only when subareas have independent durable ownership contracts" && echo 1 || echo 0)"
check "build-plan task asks subagents for distilled docs" \
  "$(contains "$BUILD_PLAN" "Write distilled high-signal context" && echo 1 || echo 0)"
check "generated module task prompt forbids sibling source bodies" \
  "$(contains "$JSON_CLI" "do not read sibling source bodies" && not_contains "$JSON_CLI" "You may read sibling-module source" && echo 1 || echo 0)"
check "module output requirements are backend-neutral" \
  "$(contains "$MODULE_OUTPUT_REQUIREMENTS" "the agent MUST" && not_contains "$MODULE_OUTPUT_REQUIREMENTS" "Claude MUST" && echo 1 || echo 0)"

check "manifest schema documents contextless coverage" \
  "$(contains "$MANIFEST_SCHEMA" "contextless.entries" && contains "$MANIFEST_SCHEMA" "promotion-check" && contains "$MANIFEST_SCHEMA" "no-context-review" && echo 1 || echo 0)"
check "AGENTS template points to routing index instead of architecture-only overview" \
  "$(contains "$MANIFEST_SCHEMA" "routing index, critical invariants, and coupling/blast-radius guidance" && echo 1 || echo 0)"
check "AGENTS template no longer uses old architecture-overview-only sentence" \
  "$(not_contains "$MANIFEST_SCHEMA" "architecture overview, actor map, key flows, global invariants, and module table" && echo 1 || echo 0)"

check "review skill loads index for routing/coupling/blast-radius guidance" \
  "$(contains "$REVIEW_SKILL" "routing/coupling/blast-radius guidance" && echo 1 || echo 0)"
check "review methodology uses routing index rather than module map table" \
  "$(contains "$REVIEW_METHODOLOGY" "Route by path/task" && not_contains "$REVIEW_METHODOLOGY" "Map changed files to modules using the Module Map table" && echo 1 || echo 0)"

check_summary "T27"
