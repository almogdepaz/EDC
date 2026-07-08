#!/usr/bin/env bash
set -euo pipefail

printf '=== T42: phase result contract ===\n'

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

setup_repo() {
  local repo="$1"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email a@example.com
    git config user.name a
    touch tracked.txt
    git add tracked.txt
    git -c commit.gpgsign=false commit -q -m init
  )
}

run_recovery_after_failed_spawn() {
  local repo="$1"
  local mode="${2:-writes-valid-context}"
  local script="$TMP/recovery-$mode.sh"
  cat > "$script" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
cd "$TMP_REPO"

export EDC_CONTEXT_DIR="edc-context"
export EDC_INDEX="edc-context/index.md"
export MANIFEST="edc-context/manifest.json"
export CLEAN_SLATE_SH="$TMP_REPO/clean-slate.sh"
export EDC_AGENT_CLI="pi"
export EDC_BUILD_TIMEOUT=1
export EDC_UPDATE_TIMEOUT=1
export ROOT_UNDER_TEST

cat > "$CLEAN_SLATE_SH" <<'CLEAN'
#!/usr/bin/env bash
exit 0
CLEAN
chmod +x "$CLEAN_SLATE_SH"

resolve_prompt() {
  printf 'prompt:%s\n' "$1"
}

assert_context_fresh() {
  [ -f "$MANIFEST" ] && [ -f "$EDC_INDEX" ] && grep -q '^##' "$EDC_INDEX"
}

read_manifest_source_commit() {
  git rev-parse HEAD
}

edc_spawn() {
  if [ "$SPAWN_MODE" = "writes-valid-context" ]; then
    mkdir -p edc-context
    cat > "$EDC_INDEX" <<'EOF_INDEX'
# Index
## Module Map
- app
EOF_INDEX
    cat > "$MANIFEST" <<EOF_MANIFEST
{"schemaVersion":2,"sourceCommit":"$(git rev-parse HEAD)","modules":[]}
EOF_MANIFEST
  fi
  return 1
}

# shellcheck source=plugins/edc/scripts/edc-recover-context.sh
. "$ROOT_UNDER_TEST/plugins/edc/scripts/edc-recover-context.sh"
recover_context_if_needed
EOS
  chmod +x "$script"
  TMP_REPO="$repo" ROOT_UNDER_TEST="$ROOT" SPAWN_MODE="$mode" "$script" 2>&1
}

repo="$TMP/repo"
setup_repo "$repo"
if ! output=$(run_recovery_after_failed_spawn "$repo"); then
  echo "FAIL: recovery returned failure even though durable context validation passed"
  printf '%s\n' "$output"
  exit 1
fi

if grep -q 'EDC context recovery succeeded with warning' <<< "$output" \
  && grep -q 'edc-build subprocess reported failure' <<< "$output"; then
  echo "PASS: recovery accepts valid context after failed build rc and emits warning"
else
  echo "FAIL: recovery did not emit the expected success-with-warning diagnostics"
  printf '%s\n' "$output"
  exit 1
fi

failing_repo="$TMP/failing-repo"
setup_repo "$failing_repo"
if failure_output=$(run_recovery_after_failed_spawn "$failing_repo" no-context 2>&1); then
  echo "FAIL: recovery succeeded even though subprocess failed and context validation failed"
  printf '%s\n' "$failure_output"
  exit 1
fi

if grep -q 'EDC context recovery failed.' <<< "$failure_output" \
  && grep -q 'reason: edc-build subprocess failed and context validation did not pass' <<< "$failure_output" \
  && grep -q 'next step: inspect the agent log' <<< "$failure_output"; then
  echo "PASS: recovery failure reports clear reason and next step"
else
  echo "FAIL: recovery failure did not report clear diagnostics"
  printf '%s\n' "$failure_output"
  exit 1
fi

printf '\nAll T42 checks passed.\n'
