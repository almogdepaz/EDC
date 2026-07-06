#!/usr/bin/env bash
# Task 38: delivery-review orchestrator with mocked agent.
set -euo pipefail

if [ -n "${EDC_BASH:-}" ]; then
  export PATH="$(dirname "$EDC_BASH"):$PATH"
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/plugins/edc/scripts/edc-delivery-review.sh"
TMPDIR_T38=$(mktemp -d)
MOCK_BIN="$TMPDIR_T38/bin"
trap 'rm -rf "$TMPDIR_T38"' EXIT

echo "=== T38: delivery-review orchestrator (mocked agent) ==="

mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
prompt=\$(cat)
SCENARIO_FILE="$TMPDIR_T38/scenario"
scenario="valid"
[ -f "\$SCENARIO_FILE" ] && scenario=\$(cat "\$SCENARIO_FILE")

printf '%s\n' "\$@" > "$TMPDIR_T38/last-args"
if [[ "\$prompt" == *"DELIVERY REVIEW TASK"* ]]; then
  printf '%s\n' "\$prompt" > "$TMPDIR_T38/last-prompt"
  report_path=\$(printf '%s\n' "\$prompt" | grep '^DELIVERY_REPORT_PATH: ' | head -1 | sed 's/^DELIVERY_REPORT_PATH: //')
  case "\$scenario" in
    valid|valid-exit-fail)
      printf '# Delivery / Architecture Review\n\n## Summary\n**Delivery verdict:** delivered\n**Architecture fit:** fits\n' > "\$report_path"
      ;;
    missing-report)
      :
      ;;
  esac
  if [ "\$scenario" = "valid-exit-fail" ]; then
    exit 1
  fi
  exit 0
fi

echo "MOCK ERROR: unrecognized prompt" >&2
exit 1
MOCK
chmod +x "$MOCK_BIN/claude"

setup_repo() {
  rm -rf "$TMPDIR_T38/repo"
  mkdir -p "$TMPDIR_T38/repo"
  cd "$TMPDIR_T38/repo"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email "t@t.com"
  git config user.name "T"
  git config commit.gpgsign false
  mkdir -p src
  echo 'one' > src/app.ts
  git add src/app.ts
  git commit -q -m init
  echo 'two' > src/app.ts
  git add src/app.ts
  git commit -q -m change

  mkdir -p edc-context/modules .edc/skills/edc-delivery-review/references .edc/skills/edc-build-impl .edc/skills/edc-update-impl
  printf '# Repo\n\n## Module Map\n- app\n' > edc-context/index.md
  printf '# app\n\n## Files\n- src/app.ts\n' > edc-context/modules/app.md
  head=$(git rev-parse HEAD)
  printf '{"schemaVersion":2,"sourceCommit":"%s","policy":{"defaultMode":"advisory","unmatchedPathPolicy":"warn-allow"},"modules":[{"name":"app","priority":10,"doc":"edc-context/modules/app.md","match":{"prefixes":["src/"]}}]}\n' "$head" > edc-context/manifest.json
  printf 'DELIVERY_SKILL_MARKER\n' > .edc/skills/edc-delivery-review/SKILL.md
  printf 'SPEC_AXIS_MARKER\n' > .edc/skills/edc-delivery-review/references/spec-axis.md
  printf 'ARCH_AXIS_MARKER\n' > .edc/skills/edc-delivery-review/references/architecture-axis.md
  printf 'REPORTING_MARKER\n' > .edc/skills/edc-delivery-review/references/reporting.md
  printf '# Build\n' > .edc/skills/edc-build-impl/SKILL.md
  printf '# Update\n' > .edc/skills/edc-update-impl/SKILL.md
}

export PATH="$MOCK_BIN:$PATH"
export EDC_AGENT_CLI=claude

setup_repo
echo valid > "$TMPDIR_T38/scenario"
export EDC_REVIEW_MODEL=review-test-model
unset EDC_BUILD_MODEL
result=0
out=$("${EDC_BASH:-bash}" "$SCRIPT" HEAD --base HEAD~1 2>&1) || result=$?
if [ "$result" -eq 0 ] && [ -f delivery-review-HEAD.md ] \
  && grep -q 'Delivery review report: delivery-review-HEAD.md' <<<"$out" \
  && grep -q 'DELIVERY_BASE: HEAD~1' "$TMPDIR_T38/last-prompt" \
  && grep -q 'DELIVERY_SKILL_MARKER' "$TMPDIR_T38/last-prompt" \
  && grep -q 'SPEC_AXIS_MARKER' "$TMPDIR_T38/last-prompt" \
  && grep -q 'ARCH_AXIS_MARKER' "$TMPDIR_T38/last-prompt" \
  && grep -q 'REPORTING_MARKER' "$TMPDIR_T38/last-prompt"; then
  echo "PASS: delivery-review writes report from embedded skill bundle"
else
  echo "FAIL: delivery-review success path failed. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi
if grep -qx -- '--model' "$TMPDIR_T38/last-args" && grep -qx 'review-test-model' "$TMPDIR_T38/last-args"; then
  echo "PASS: delivery-review uses EDC_REVIEW_MODEL"
else
  echo "FAIL: delivery-review did not pass EDC_REVIEW_MODEL"
  echo "--- args ---"; cat "$TMPDIR_T38/last-args"; echo "--- end ---"
  exit 1
fi
unset EDC_REVIEW_MODEL

setup_repo
git branch -M main
echo valid > "$TMPDIR_T38/scenario"
result=0
out=$(/bin/bash "$SCRIPT" --full 2>&1) || result=$?
if [ "$result" -eq 0 ] && [ -f delivery-review-current.md ] \
  && grep -q 'DELIVERY_MODE: full' "$TMPDIR_T38/last-prompt" \
  && grep -q 'No git diff is the source of truth for this review.' "$TMPDIR_T38/last-prompt" \
  && grep -q 'Delivery review report: delivery-review-current.md' <<<"$out"; then
  echo "PASS: delivery-review supports explicit full current-state mode"
else
  echo "FAIL: delivery-review --full mode failed. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- prompt ---"; cat "$TMPDIR_T38/last-prompt" 2>/dev/null || true; echo "--- end ---"
  exit 1
fi

setup_repo
git branch -M main
echo valid > "$TMPDIR_T38/scenario"
result=0
out=$("${EDC_BASH:-bash}" "$SCRIPT" 2>&1) || result=$?
if [ "$result" -eq 0 ] && [ -f delivery-review-current.md ] \
  && grep -q 'DELIVERY_MODE: full' "$TMPDIR_T38/last-prompt"; then
  echo "PASS: delivery-review auto-selects full mode on clean main"
else
  echo "FAIL: delivery-review did not auto-select full mode on clean main. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- prompt ---"; cat "$TMPDIR_T38/last-prompt" 2>/dev/null || true; echo "--- end ---"
  exit 1
fi

setup_repo
echo valid-exit-fail > "$TMPDIR_T38/scenario"
result=0
out=$("${EDC_BASH:-bash}" "$SCRIPT" HEAD --base HEAD~1 2>&1) || result=$?
if [ "$result" -eq 0 ] && [ -f delivery-review-HEAD.md ] \
  && grep -q 'delivery-review subprocess reported failure, but report validation passed' <<<"$out" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "delivery-review" && j.exitCode === 0 && j.reasonCode === "success" ? 0 : 1)'; then
  echo "PASS: delivery-review accepts valid report after failed agent rc with warning"
else
  echo "FAIL: delivery-review did not accept valid report after failed agent rc. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

setup_repo
echo missing-report > "$TMPDIR_T38/scenario"
result=0
out=$("${EDC_BASH:-bash}" "$SCRIPT" HEAD --base HEAD~1 2>&1) || result=$?
if [ "$result" -ne 0 ] && grep -q 'delivery review report missing' <<<"$out"; then
  echo "PASS: missing delivery report rejected"
else
  echo "FAIL: expected missing report rejection. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- end ---"
  exit 1
fi

echo ""
echo "All T38 checks passed."
