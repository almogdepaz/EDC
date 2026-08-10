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
    git branch -M main
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
  local clean_slate_mode="${3:-override}"
  local spawn_marker="${4:-}"
  local script="$TMP/recovery-$mode.sh"
  cat > "$script" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
cd "$TMP_REPO"

export EDC_CONTEXT_DIR="edc-context"
export EDC_INDEX="edc-context/index.md"
export MANIFEST="edc-context/manifest.json"
export EDC_AGENT_CLI="pi"
export EDC_BUILD_TIMEOUT=1
export EDC_UPDATE_TIMEOUT=1
export ROOT_UNDER_TEST

if [ "$CLEAN_SLATE_MODE" = "override" ]; then
  export CLEAN_SLATE_SH="$TMP_REPO/clean-slate.sh"
  cat > "$CLEAN_SLATE_SH" <<'CLEAN'
#!/usr/bin/env bash
exit 0
CLEAN
  chmod +x "$CLEAN_SLATE_SH"
fi

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
  [ -z "$SPAWN_MARKER" ] || touch "$SPAWN_MARKER"
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
  TMP_REPO="$repo" ROOT_UNDER_TEST="$ROOT" SPAWN_MODE="$mode" CLEAN_SLATE_MODE="$clean_slate_mode" SPAWN_MARKER="$spawn_marker" "$script" 2>&1
}

run_stale_recovery() {
  local repo="$1"
  local source_commit="$2"
  local spawn_mode="$3"
  local spawn_log="$4"
  local recovery_args_mode="${5:-review-base}"
  local script="$TMP/stale-recovery-$spawn_mode.sh"
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

mkdir -p "$EDC_CONTEXT_DIR"
cat > "$EDC_INDEX" <<'EOF_INDEX'
# Index
## Module Map
- app
EOF_INDEX
cat > "$MANIFEST" <<EOF_MANIFEST
{"schemaVersion":2,"sourceCommit":"$SOURCE_COMMIT","modules":[]}
EOF_MANIFEST

resolve_prompt() {
  printf 'prompt:%s' "$1"
  shift
  if [ "$#" -gt 0 ]; then
    printf ' %s' "$@"
  fi
  printf '\n'
}

read_manifest_source_commit() {
  printf '%s\n' "$SOURCE_COMMIT"
}

assert_context_fresh() {
  [ -f "$MANIFEST" ] \
    && [ -f "$EDC_INDEX" ] \
    && grep -q '^##' "$EDC_INDEX" \
    && [ "$(read_manifest_source_commit)" = "$(git rev-parse HEAD)" ]
}

write_fresh_context() {
  SOURCE_COMMIT="$(git rev-parse HEAD)"
  cat > "$MANIFEST" <<EOF_MANIFEST
{"schemaVersion":2,"sourceCommit":"$SOURCE_COMMIT","modules":[]}
EOF_MANIFEST
}

edc_spawn() {
  local phase="$1" prompt="$3"
  printf '%s\t%s\n' "$phase" "$prompt" >> "$SPAWN_LOG"
  case "$SPAWN_MODE:$phase" in
    update-succeeds:edc-update|update-fails-build-succeeds:edc-build-retry|build-only-succeeds:edc-build-retry)
      write_fresh_context
      return 0
      ;;
    update-fails-build-succeeds:edc-update)
      return 1
      ;;
    update-writes-fresh-fails:edc-update)
      write_fresh_context
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# shellcheck source=plugins/edc/scripts/edc-recover-context.sh
. "$ROOT_UNDER_TEST/plugins/edc/scripts/edc-recover-context.sh"
case "$RECOVERY_ARGS_MODE" in
  review-base) recover_context_if_needed -- --base HEAD ;;
  option-like-ignore) recover_context_if_needed -- --ignore --base --base HEAD ;;
  *) exit 2 ;;
esac
EOS
  chmod +x "$script"
  TMP_REPO="$repo" SOURCE_COMMIT="$source_commit" SPAWN_MODE="$spawn_mode" SPAWN_LOG="$spawn_log" RECOVERY_ARGS_MODE="$recovery_args_mode" ROOT_UNDER_TEST="$ROOT" "$script" 2>&1
}

default_repo="$TMP/default-repo"
setup_repo "$default_repo"
set +e
default_output=$(run_recovery_after_failed_spawn "$default_repo" no-context default "$default_repo/spawn-reached")
default_rc=$?
set -e
if [ "$default_rc" -eq 0 ] || [ ! -f "$default_repo/spawn-reached" ]; then
  echo "FAIL: recovery did not reach the spawn boundary without a CLEAN_SLATE_SH override"
  printf '%s\n' "$default_output"
  exit 1
fi
echo "PASS: recovery resolves its default clean-slate dependency"

stale_repo="$TMP/stale-repo"
setup_repo "$stale_repo"
stale_source=$(git -C "$stale_repo" rev-parse HEAD)
printf 'changed\n' >> "$stale_repo/tracked.txt"
git -C "$stale_repo" add tracked.txt
git -C "$stale_repo" -c commit.gpgsign=false commit -q -m changed
stale_spawn_log="$TMP/stale-spawns.log"
if ! stale_output=$(run_stale_recovery "$stale_repo" "$stale_source" update-succeeds "$stale_spawn_log"); then
  echo "FAIL: stale-main recovery failed"
  printf '%s\n' "$stale_output"
  exit 1
fi
if [ "$(git -C "$stale_repo" branch --show-current)" = main ] \
  && grep -Fq "edc-update"$'\t'"prompt:update --base $stale_source" "$stale_spawn_log" \
  && ! grep -Fq 'prompt:update --base HEAD' "$stale_spawn_log"; then
  echo "PASS: stale-main recovery updates from manifest sourceCommit"
else
  echo "FAIL: stale-main recovery reused the review base"
  cat "$stale_spawn_log"
  exit 1
fi

option_arg_spawn_log="$TMP/option-arg-spawns.log"
if ! option_arg_output=$(run_stale_recovery "$stale_repo" "$stale_source" update-succeeds "$option_arg_spawn_log" option-like-ignore); then
  echo "FAIL: option-like --ignore value broke stale recovery"
  printf '%s\n' "$option_arg_output"
  exit 1
fi
if grep -Fq "edc-update"$'\t'"prompt:update --ignore --base --base $stale_source" "$option_arg_spawn_log"; then
  echo "PASS: replacing recovery base preserves option-like argument values"
else
  echo "FAIL: replacing recovery base corrupted an option-like argument value"
  cat "$option_arg_spawn_log"
  exit 1
fi

fresh_failure_spawn_log="$TMP/fresh-failure-spawns.log"
if ! fresh_failure_output=$(run_stale_recovery "$stale_repo" "$stale_source" update-writes-fresh-fails "$fresh_failure_spawn_log"); then
  echo "FAIL: nonzero update with fresh durable context was rejected"
  printf '%s\n' "$fresh_failure_output"
  exit 1
fi
if grep -q 'EDC context recovery succeeded with warning' <<< "$fresh_failure_output" \
  && grep -Fq 'edc-update' "$fresh_failure_spawn_log" \
  && ! grep -Fq 'edc-build-retry' "$fresh_failure_spawn_log"; then
  echo "PASS: fresh durable context after nonzero update skips force build"
else
  echo "FAIL: fresh durable context after nonzero update used the wrong fallback"
  cat "$fresh_failure_spawn_log"
  exit 1
fi

fallback_spawn_log="$TMP/fallback-spawns.log"
if ! fallback_output=$(run_stale_recovery "$stale_repo" "$stale_source" update-fails-build-succeeds "$fallback_spawn_log"); then
  echo "FAIL: stale recovery did not force-build after update failure"
  printf '%s\n' "$fallback_output"
  exit 1
fi
if grep -Fq "edc-update"$'\t'"prompt:update --base $stale_source" "$fallback_spawn_log" \
  && grep -Fq "edc-build-retry"$'\t'"prompt:build --force" "$fallback_spawn_log" \
  && [ "$(wc -l < "$fallback_spawn_log" | tr -d ' ')" -eq 2 ]; then
  echo "PASS: failed incremental recovery gets exactly one force-build fallback"
else
  echo "FAIL: failed incremental recovery did not use the expected fallback sequence"
  cat "$fallback_spawn_log"
  exit 1
fi

unrelated_tree=$(git -C "$stale_repo" mktree < /dev/null)
unrelated_source=$(printf 'unrelated\n' | git -C "$stale_repo" commit-tree "$unrelated_tree")
for source_case in missing invalid symbolic nonancestor; do
  case "$source_case" in
    missing) unsafe_source="" ;;
    invalid) unsafe_source="not-a-commit" ;;
    symbolic) unsafe_source="HEAD~1" ;;
    nonancestor) unsafe_source="$unrelated_source" ;;
  esac
  unsafe_spawn_log="$TMP/$source_case-spawns.log"
  if ! unsafe_output=$(run_stale_recovery "$stale_repo" "$unsafe_source" build-only-succeeds "$unsafe_spawn_log"); then
    echo "FAIL: $source_case sourceCommit did not force-build"
    printf '%s\n' "$unsafe_output"
    exit 1
  fi
  if grep -Fq "edc-build-retry"$'\t'"prompt:build --force" "$unsafe_spawn_log" \
    && ! grep -Fq 'edc-update' "$unsafe_spawn_log" \
    && [ "$(wc -l < "$unsafe_spawn_log" | tr -d ' ')" -eq 1 ]; then
    echo "PASS: $source_case sourceCommit skips update and force-builds once"
  else
    echo "FAIL: $source_case sourceCommit used an unsafe recovery path"
    cat "$unsafe_spawn_log"
    exit 1
  fi
done

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
