#!/usr/bin/env bash
# t45-review-phase-write-containment: delivery/audit agents cannot mutate source/config while writing valid reports.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
MOCK_BIN="$TMP/bin"
trap 'rm -rf "$TMP"' EXIT

printf '=== T45: delivery/audit write containment ===\n'

mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
prompt=$(cat)
scenario=${EDC_T45_SCENARIO:-valid}

if [[ "$prompt" == *"DELIVERY REVIEW TASK"* ]] || [[ "$prompt" == *"DELIVERY CURRENT-STATE REVIEW TASK"* ]]; then
  report_path=$(printf '%s\n' "$prompt" | awk -F': ' '/^DELIVERY_REPORT_PATH: /{print $2; exit}')
  if [ "$scenario" = "delivery-mutates" ]; then
    printf 'agent mutation\n' > src/app.ts
  fi
  printf '# Delivery / Architecture Review\n\n## Summary\n**Delivery verdict:** delivered\n**Architecture fit:** fits\n' > "$report_path"
  exit 0
fi

if [[ "$prompt" == *"AUDIT WORKER TASK"* ]]; then
  report_path=$(printf '%s\n' "$prompt" | awk -F': ' '/^AUDIT_REPORT_PATH: /{print $2; exit}')
  if [ "$scenario" = "audit-worker-mutates" ]; then
    printf 'agent mutation\n' > src/app.ts
  fi
  printf '## Module Audit\n\nNo findings.\n' > "$report_path"
  exit 0
fi

if [[ "$prompt" == *"AUDIT SYNTHESIS TASK"* ]]; then
  if [ "$scenario" = "audit-synthesis-mutates" ]; then
    printf 'agent mutation\n' > src/app.ts
  fi
  mkdir -p edc-context/reports
  printf '## Summary\n\nNo complexity findings.\n' > edc-context/reports/complexity.md
  printf '## Known Issues\n\nNo issues.\n' > edc-context/reports/issues.md
  exit 0
fi

printf 'mock did not recognize prompt\n' >&2
exit 1
SH
chmod +x "$MOCK_BIN/claude"

setup_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo"
  cd "$repo"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email t@example.com
  git config user.name T
  git config commit.gpgsign false
  mkdir -p src edc-context/modules .edc/skills/edc-delivery-review/references .edc/skills/edc-audit/references .edc/skills/edc-build-impl .edc/skills/edc-update-impl
  printf 'original\n' > src/app.ts
  git add src/app.ts
  git commit -q -m init
  printf 'changed\n' > src/app.ts
  git add src/app.ts
  git commit -q -m change
  head=$(git rev-parse HEAD)
  printf '# Repo\n\n## Module Map\n- app\n' > edc-context/index.md
  printf '# app\n\n## Files\n- src/app.ts\n' > edc-context/modules/app.md
  printf '{"schemaVersion":2,"sourceCommit":"%s","policy":{"defaultMode":"advisory","unmatchedPathPolicy":"warn-allow"},"modules":[{"name":"app","priority":10,"doc":"edc-context/modules/app.md","match":{"prefixes":["src/"]}}]}\n' "$head" > edc-context/manifest.json
  printf 'DELIVERY_SKILL_MARKER\n' > .edc/skills/edc-delivery-review/SKILL.md
  printf 'SPEC_AXIS_MARKER\n' > .edc/skills/edc-delivery-review/references/spec-axis.md
  printf 'ARCH_AXIS_MARKER\n' > .edc/skills/edc-delivery-review/references/architecture-axis.md
  printf 'REPORTING_MARKER\n' > .edc/skills/edc-delivery-review/references/reporting.md
  printf '# Audit\nname: edc-audit\n' > .edc/skills/edc-audit/SKILL.md
  printf '# Scope\n' > .edc/skills/edc-audit/references/scope-and-standards.md
  printf '# Smell\n' > .edc/skills/edc-audit/references/smell-baseline.md
  printf '# Checks\n' > .edc/skills/edc-audit/references/quality-checks.md
  printf '# Reporting\n' > .edc/skills/edc-audit/references/reporting.md
  printf '# Build\n' > .edc/skills/edc-build-impl/SKILL.md
  printf '# Update\n' > .edc/skills/edc-update-impl/SKILL.md
}

assert_source_clean() {
  if git diff --quiet -- src/app.ts && [ "$(cat src/app.ts)" = "changed" ]; then
    return 0
  fi
  echo "source was left mutated" >&2
  git diff -- src/app.ts >&2 || true
  return 1
}

export PATH="$MOCK_BIN:$PATH"
export EDC_AGENT_CLI=claude

setup_repo "$TMP/delivery"
export EDC_T45_SCENARIO=delivery-mutates
result=0
out=$(bash "$ROOT/plugins/edc/scripts/edc-delivery-review.sh" HEAD --base HEAD~1 2>&1) || result=$?
if [ "$result" -ne 0 ] \
  && grep -q 'touched forbidden paths' <<<"$out" \
  && grep -q 'src/app.ts' <<<"$out" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "delivery-review" && j.reasonCode === "delivery-write-containment" ? 0 : 1)'; then
  git checkout -- src/app.ts
  echo "PASS: delivery-review blocks forbidden source writes"
else
  echo "FAIL: delivery-review accepted forbidden write. exit=$result"; echo "$out"; cat edc-context/build/last-run.json 2>/dev/null || true; exit 1
fi

setup_repo "$TMP/audit-worker"
export EDC_T45_SCENARIO=audit-worker-mutates
result=0
out=$(bash "$ROOT/plugins/edc/scripts/edc-audit.sh" 2>&1) || result=$?
if [ "$result" -ne 0 ] \
  && grep -q 'audit worker touched forbidden paths' <<<"$out" \
  && grep -q 'src/app.ts' <<<"$out" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "audit" && j.reasonCode === "audit-write-containment" ? 0 : 1)'; then
  git checkout -- src/app.ts
  echo "PASS: audit worker blocks forbidden source writes"
else
  echo "FAIL: audit worker accepted forbidden write. exit=$result"; echo "$out"; cat edc-context/build/last-run.json 2>/dev/null || true; exit 1
fi

setup_repo "$TMP/audit-synthesis"
export EDC_T45_SCENARIO=audit-synthesis-mutates
result=0
out=$(bash "$ROOT/plugins/edc/scripts/edc-audit.sh" 2>&1) || result=$?
if [ "$result" -ne 0 ] \
  && grep -q 'audit synthesis touched forbidden paths' <<<"$out" \
  && grep -q 'src/app.ts' <<<"$out" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "audit" && j.reasonCode === "audit-write-containment" ? 0 : 1)'; then
  git checkout -- src/app.ts
  echo "PASS: audit synthesis blocks forbidden source writes"
else
  echo "FAIL: audit synthesis accepted forbidden write. exit=$result"; echo "$out"; cat edc-context/build/last-run.json 2>/dev/null || true; exit 1
fi

printf '\nAll T45 checks passed.\n'
