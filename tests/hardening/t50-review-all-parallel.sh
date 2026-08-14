#!/usr/bin/env bash
# t50-review-all-parallel: combined review starts every lens concurrently and waits for all.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '=== T50: review-all parallel lenses ===\n'

prepare_plugin() {
  cp -R "$ROOT/plugins/edc" "$TMP/plugin"
  cat > "$TMP/plugin/scripts/edc-recover-context.sh" <<'SH'
#!/usr/bin/env bash
recover_context_if_needed() {
  printf '%s\n' "$@" > "$EDC_T50_STATE/recovery-args"
  printf 'context prepared\n' >> "$EDC_T50_STATE/context-events"
}
SH
  chmod +x "$TMP/plugin/scripts/edc-recover-context.sh"
  local phase script kind
  for phase in security delivery quality; do
    case "$phase" in
      security) script=edc-review.sh; kind=review ;;
      delivery) script=edc-delivery-review.sh; kind=delivery-review ;;
      quality) script=edc-audit.sh; kind=audit ;;
    esac
    cat > "$TMP/plugin/scripts/$script" <<SH
#!/usr/bin/env bash
set -euo pipefail
state="\$EDC_T50_STATE"
touch "\$state/$phase.started"
printf '%s started\n' '$phase' >> "\$state/events"
ready=0
for _ in \$(seq 1 100); do
  if [ -f "\$state/security.started" ] && [ -f "\$state/delivery.started" ] && [ -f "\$state/quality.started" ]; then
    ready=1
    break
  fi
  sleep 0.02
done
if [ "\$ready" -ne 1 ]; then
  echo '$phase timed out waiting for sibling phases to start' >&2
  exit 9
fi
sleep "\${EDC_T50_DELAY_$phase:-0}"
printf '%s finished\n' '$phase' >> "\$state/events"
touch "\$state/$phase.finished"
case '$phase' in
  security) mkdir -p "\$(dirname "\$EDC_REVIEW_PROMOTION_OUTPUT")"; printf '## security\n' > "\$EDC_REVIEW_PROMOTION_OUTPUT"; printf '%s\n' "\$EDC_REVIEW_PROMOTION_OUTPUT" > "\$state/security.output" ;;
  delivery)
    mkdir -p "\$(dirname "\$EDC_DELIVERY_REVIEW_OUTPUT")"
    if [ "\${EDC_T50_LINK_ESCAPE:-}" = symlink ]; then
      printf '## escaped delivery\n' > "\$state/outside-delivery.md"
      ln -s "\$state/outside-delivery.md" "\$EDC_DELIVERY_REVIEW_OUTPUT"
    elif [ "\${EDC_T50_LINK_ESCAPE:-}" = hardlink ]; then
      printf '## escaped delivery\n' > "\$state/outside-delivery.md"
      ln "\$state/outside-delivery.md" "\$EDC_DELIVERY_REVIEW_OUTPUT"
    else
      printf '## delivery\n' > "\$EDC_DELIVERY_REVIEW_OUTPUT"
    fi
    printf '%s\n' "\$EDC_DELIVERY_REVIEW_OUTPUT" > "\$state/delivery.output"
    ;;
  quality)
    mkdir -p "\$(dirname "\$EDC_AUDIT_COMPLEXITY_OUTPUT")"
    printf '## complexity\n' > "\$EDC_AUDIT_COMPLEXITY_OUTPUT"
    if [ "\${EDC_T50_INVALID_QUALITY_PAIR:-}" = issues-symlink ]; then
      printf '## escaped issues\n' > "\$state/outside-issues.md"
      ln -s "\$state/outside-issues.md" "\$EDC_AUDIT_ISSUES_OUTPUT"
    else
      printf '## issues\n' > "\$EDC_AUDIT_ISSUES_OUTPUT"
    fi
    printf '%s\n%s\n' "\$EDC_AUDIT_COMPLEXITY_OUTPUT" "\$EDC_AUDIT_ISSUES_OUTPUT" > "\$state/quality.output"
    ;;
esac
mkdir -p "\$(dirname "\$EDC_RESULT_FILE")"
printf '%s\n' "\$EDC_RESULT_FILE" > "\$state/$phase.result"
if [ "\${EDC_T50_FAIL:-}" = '$phase' ]; then
  printf '%s\n' '{"schemaVersion":1,"kind":"$kind","phase":"$phase","status":"failed","exitCode":1,"reasonCode":"forced-$phase-failure","message":"$phase failed"}' > "\$EDC_RESULT_FILE"
  exit 1
fi
printf '%s\n' '{"schemaVersion":1,"kind":"$kind","phase":"$phase","status":"success","exitCode":0,"reasonCode":"success","message":"$phase succeeded","outputs":[]}' > "\$EDC_RESULT_FILE"
SH
    chmod +x "$TMP/plugin/scripts/$script"
  done
}

setup_repo() {
  rm -rf "$TMP/repo" "$TMP/state"
  mkdir -p "$TMP/repo" "$TMP/state"
  cd "$TMP/repo"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git config commit.gpgsign false
  printf 'tracked\n' > tracked.txt
  git add tracked.txt
  git commit -q -m initial
  node "$ROOT/plugins/edc/hooks/lib/runtime-manifest.mjs" install "$TMP/repo" "$TMP/plugin" >/dev/null
}

prepare_plugin
setup_repo
set +e
EDC_AGENT_CLI=pi EDC_T50_STATE="$TMP/state" bash .edc/scripts/edc-review-all.sh --full \
  --ignore 'vendor/**' --ignore 'generated/**' --context-mode inject > "$TMP/success.out" 2>&1
rc=$?
set -e
printf '%s\n' --ignore 'vendor/**' --ignore 'generated/**' > "$TMP/expected-recovery-args"
if [ "$rc" -eq 0 ] && cmp -s "$TMP/expected-recovery-args" "$TMP/state/recovery-args"; then
  echo 'PASS: combined recovery receives only repeated ignore pairs'
else
  echo "FAIL: combined recovery lost ignores or received review-only flags (rc=$rc)"
  printf '%s\n' '--- expected recovery argv ---'
  cat "$TMP/expected-recovery-args"
  printf '%s\n' '--- observed recovery argv ---'
  cat "$TMP/state/recovery-args" 2>/dev/null || true
  cat "$TMP/success.out"
  exit 1
fi
if [ "$rc" -eq 0 ] \
  && [ -f "$TMP/state/security.finished" ] \
  && [ -f "$TMP/state/delivery.finished" ] \
  && [ -f "$TMP/state/quality.finished" ] \
  && [ "$(grep -c ' started$' "$TMP/state/events" || true)" -eq 3 ] \
  && [ "$(grep -c ' finished$' "$TMP/state/events" || true)" -eq 3 ] \
  && [ "$(grep -c '^context prepared$' "$TMP/state/context-events" || true)" -eq 1 ] \
  && grep -q '/.git/edc/' "$TMP/state/security.output" \
  && grep -q '/.git/edc/' "$TMP/state/delivery.output" \
  && grep -q '/.git/edc/' "$TMP/state/quality.output" \
  && grep -q '/.git/edc/' "$TMP/state/security.result" \
  && grep -q '/.git/edc/' "$TMP/state/delivery.result" \
  && grep -q '/.git/edc/' "$TMP/state/quality.result" \
  && [ ! -e edc-context/build/review-all-security.json ] \
  && [ ! -e edc-context/build/review-all-delivery.json ] \
  && [ ! -e edc-context/build/review-all-quality.json ] \
  && [ -f review-HEAD.md ] \
  && [ -f delivery-review-current.md ] \
  && [ -f edc-context/reports/complexity.md ] \
  && [ -f edc-context/reports/issues.md ]; then
  first_finished_line=$(grep -n ' finished$' "$TMP/state/events" | head -1 | cut -d: -f1)
  if [ "$first_finished_line" -gt 3 ]; then
    echo 'PASS: all three lenses start before any lens finishes'
  else
    echo 'FAIL: a lens finished before all three lenses started'
    cat "$TMP/state/events"
    exit 1
  fi
else
  echo "FAIL: combined review did not run all lenses concurrently (rc=$rc)"
  cat "$TMP/success.out"
  cat "$TMP/state/events" 2>/dev/null || true
  exit 1
fi

# Staged report links must fail containment instead of promoting outside bytes.
for link_kind in symlink hardlink; do
  setup_repo
  set +e
  EDC_AGENT_CLI=pi EDC_T50_STATE="$TMP/state" EDC_T50_LINK_ESCAPE="$link_kind" bash .edc/scripts/edc-review-all.sh --full > "$TMP/$link_kind.out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] \
    && [ ! -e delivery-review-current.md ] \
    && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.status === "failed" && j.phases?.some((p) => p.phase === "delivery" && p.reasonCode === "promotion-containment-failed") ? 0 : 1)'; then
    echo "PASS: staged output $link_kind cannot escape private run containment"
  else
    echo "FAIL: staged output $link_kind was promoted or accepted (rc=$rc)"
    cat "$TMP/$link_kind.out"
    cat edc-context/build/last-run.json 2>/dev/null || true
    exit 1
  fi
done

# The two quality reports validate as a pair before either canonical file moves.
setup_repo
set +e
EDC_AGENT_CLI=pi EDC_T50_STATE="$TMP/state" EDC_T50_INVALID_QUALITY_PAIR=issues-symlink bash .edc/scripts/edc-review-all.sh --full > "$TMP/quality-pair.out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] \
  && [ ! -e edc-context/reports/complexity.md ] \
  && [ ! -e edc-context/reports/issues.md ] \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.status === "failed" && j.phases?.some((p) => p.phase === "quality" && p.reasonCode === "promotion-containment-failed") ? 0 : 1)'; then
  echo 'PASS: invalid quality pair promotes neither canonical report'
else
  echo "FAIL: invalid quality pair partially promoted (rc=$rc)"
  cat "$TMP/quality-pair.out"
  cat edc-context/build/last-run.json 2>/dev/null || true
  exit 1
fi

# A failed lens must not cancel siblings; aggregation happens after every result exists.
setup_repo
set +e
EDC_AGENT_CLI=pi EDC_T50_STATE="$TMP/state" EDC_T50_FAIL=security bash .edc/scripts/edc-review-all.sh --full > "$TMP/failure.out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] \
  && [ -f "$TMP/state/security.finished" ] \
  && [ -f "$TMP/state/delivery.finished" ] \
  && [ -f "$TMP/state/quality.finished" ] \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.status === "failed" && j.phases?.length === 3 && j.phases.some((p) => p.phase === "security" && p.status === "failed") ? 0 : 1)'; then
  echo 'PASS: failed lens does not cancel siblings and aggregate contains all phases'
else
  echo "FAIL: failed lens cancelled siblings or aggregate omitted results (rc=$rc)"
  cat "$TMP/failure.out"
  cat "$TMP/state/events" 2>/dev/null || true
  cat edc-context/build/last-run.json 2>/dev/null || true
  exit 1
fi

printf '\nAll T50 checks passed.\n'
