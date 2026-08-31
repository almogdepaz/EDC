#!/usr/bin/env bash
# t50-review-all-parallel: combined review is serial by default with explicit parallel retention.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
export EDC_CONFIG_FILE="$TMP/missing-config"
unset EDC_PARALLEL
trap 'rm -rf "$TMP"' EXIT

printf '=== T50: review-all concurrency modes ===\n'

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
if [ "\${EDC_T50_EXPECT_PARALLEL:-0}" = "1" ]; then
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
}

prepare_plugin

# Config parsing recognizes the opt-in without executing values as shell code.
printf 'EDC_PARALLEL=1\nEDC_MAX_CONCURRENCY=3\nEDC_BUILD_MODEL=%s(touch %s)\n' '$' "$TMP/config-executed" > "$TMP/parallel-config"
cat > "$TMP/read-concurrency-config.sh" <<'SH'
#!/usr/bin/env bash
. "$1"
if edc_parallel_enabled; then
  printf 'parallel:'
fi
edc_worker_max_concurrency
SH
config_mode=$(env -u EDC_PARALLEL -u EDC_MAX_CONCURRENCY EDC_CONFIG_FILE="$TMP/parallel-config" bash "$TMP/read-concurrency-config.sh" "$TMP/plugin/scripts/edc-lib.sh" 2>"$TMP/config.err" || true)
if [ "$config_mode" = "parallel:3" ] && [ ! -e "$TMP/config-executed" ]; then
  echo 'PASS: config parser recognizes EDC_PARALLEL without executing values'
else
  echo "FAIL: config parser did not safely load EDC_PARALLEL (mode=$config_mode)"
  cat "$TMP/config.err"
  exit 1
fi

printf 'EDC_BUILD_MODEL=config-model\n' > "$TMP/empty-override-config"
cat > "$TMP/read-empty-config.sh" <<'SH'
#!/usr/bin/env bash
. "$1"
printf '<%s>\n' "$EDC_BUILD_MODEL"
SH
empty_override=$(EDC_BUILD_MODEL= EDC_CONFIG_FILE="$TMP/empty-override-config" bash "$TMP/read-empty-config.sh" "$TMP/plugin/scripts/edc-lib.sh")
unset_fallback=$(env -u EDC_BUILD_MODEL EDC_CONFIG_FILE="$TMP/empty-override-config" bash "$TMP/read-empty-config.sh" "$TMP/plugin/scripts/edc-lib.sh")
if [ "$empty_override" = '<>' ] && [ "$unset_fallback" = '<config-model>' ]; then
  echo 'PASS: caller-set empty config value overrides file while unset still falls back'
else
  echo "FAIL: config set/unset precedence is wrong (empty=$empty_override unset=$unset_fallback)"
  exit 1
fi

# Default mode runs each lens to completion in security/delivery/quality order.
setup_repo
set +e
env -u EDC_PARALLEL EDC_AGENT_CLI=pi EDC_T50_STATE="$TMP/state" bash "$TMP/plugin/scripts/edc-review-all.sh" --full \
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
expected_serial=$(printf '%s\n' 'security started' 'security finished' 'delivery started' 'delivery finished' 'quality started' 'quality finished')
actual_serial=$(cat "$TMP/state/events" 2>/dev/null || true)
if [ "$rc" -eq 0 ] \
  && [ "$actual_serial" = "$expected_serial" ] \
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
  echo 'PASS: default combined review runs security, delivery, then quality without overlap'
else
  echo "FAIL: default combined review was not serial in lens order (rc=$rc)"
  cat "$TMP/success.out"
  printf '%s\n' "$actual_serial"
  exit 1
fi

# Exact opt-in retains the old concurrent start/wait path.
setup_repo
set +e
EDC_AGENT_CLI=pi EDC_PARALLEL=1 EDC_T50_EXPECT_PARALLEL=1 EDC_T50_STATE="$TMP/state" \
  bash "$TMP/plugin/scripts/edc-review-all.sh" --full > "$TMP/parallel.out" 2>&1
rc=$?
set -e
first_finished_line=$(grep -n ' finished$' "$TMP/state/events" 2>/dev/null | head -1 | cut -d: -f1 || echo 0)
if [ "$rc" -eq 0 ] && [ "$first_finished_line" -gt 3 ]; then
  echo 'PASS: EDC_PARALLEL=1 retains concurrent review lenses'
else
  echo "FAIL: explicit opt-in did not retain concurrent lenses (rc=$rc first-finished=$first_finished_line)"
  cat "$TMP/parallel.out"
  cat "$TMP/state/events" 2>/dev/null || true
  exit 1
fi

# Values other than exact 0/1 fail before any lens starts.
for invalid in 2 true yes; do
  setup_repo
  set +e
  EDC_AGENT_CLI=pi EDC_PARALLEL="$invalid" EDC_T50_STATE="$TMP/state" \
    bash "$TMP/plugin/scripts/edc-review-all.sh" --full > "$TMP/invalid-$invalid.out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ ! -e "$TMP/state/events" ] && grep -q 'EDC_PARALLEL must be 0 or 1' "$TMP/invalid-$invalid.out"; then
    echo "PASS: invalid EDC_PARALLEL=$invalid fails clearly before lenses start"
  else
    echo "FAIL: invalid EDC_PARALLEL=$invalid was accepted or started work (rc=$rc)"
    cat "$TMP/invalid-$invalid.out"
    cat "$TMP/state/events" 2>/dev/null || true
    exit 1
  fi
done

# Staged report links must fail containment instead of promoting outside bytes.
for link_kind in symlink hardlink; do
  setup_repo
  set +e
  EDC_AGENT_CLI=pi EDC_T50_STATE="$TMP/state" EDC_T50_LINK_ESCAPE="$link_kind" bash "$TMP/plugin/scripts/edc-review-all.sh" --full > "$TMP/$link_kind.out" 2>&1
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
EDC_AGENT_CLI=pi EDC_T50_STATE="$TMP/state" EDC_T50_INVALID_QUALITY_PAIR=issues-symlink bash "$TMP/plugin/scripts/edc-review-all.sh" --full > "$TMP/quality-pair.out" 2>&1
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
env -u EDC_PARALLEL EDC_AGENT_CLI=pi EDC_T50_STATE="$TMP/state" EDC_T50_FAIL=security bash "$TMP/plugin/scripts/edc-review-all.sh" --full > "$TMP/failure.out" 2>&1
rc=$?
set -e
failure_events=$(cat "$TMP/state/events" 2>/dev/null || true)
if [ "$rc" -ne 0 ] \
  && [ "$failure_events" = "$expected_serial" ] \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.status === "failed" && j.phases?.length === 3 && j.phases.some((p) => p.phase === "security" && p.status === "failed") ? 0 : 1)'; then
  echo 'PASS: default serial review continues later lenses after failure and aggregates all phases'
else
  echo "FAIL: failed serial lens prevented later lenses or aggregate omitted results (rc=$rc)"
  cat "$TMP/failure.out"
  cat "$TMP/state/events" 2>/dev/null || true
  cat edc-context/build/last-run.json 2>/dev/null || true
  exit 1
fi

printf '\nAll T50 checks passed.\n'
