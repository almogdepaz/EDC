#!/usr/bin/env bash
# t49-dirty-candidate-scope: differential reviews use one explicit immutable candidate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2"; }

printf '=== T49: dirty candidate scope ===\n'

prepare_plugin() {
  rm -rf "$TMP/plugin"
  cp -R "$ROOT/plugins/edc" "$TMP/plugin"
  cat > "$TMP/plugin/scripts/edc-recover-context.sh" <<'SH'
#!/usr/bin/env bash
recover_context_if_needed() { return 0; }
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
target="\${1:-HEAD}"
target_sha=\$(git rev-parse --verify "\${target}^{commit}")
show_file() {
  local path="\$1"
  if git cat-file -e "\${target_sha}:\${path}" 2>/dev/null; then
    git show "\${target_sha}:\${path}" | tr '\n' '|'
  else
    printf '<absent>'
  fi
}
nested_tracked='<absent>'
nested_untracked='<absent>'
if [ -e nested/.git ] && nested_sha=\$(git rev-parse "\${target_sha}:nested" 2>/dev/null); then
  nested_tracked=\$(git -C nested show "\${nested_sha}:inside.txt" | tr '\n' '|')
  if git -C nested cat-file -e "\${nested_sha}:new.txt" 2>/dev/null; then
    nested_untracked=\$(git -C nested show "\${nested_sha}:new.txt" | tr '\n' '|')
  fi
fi
printf '%s|target=%s|staged=%s|unstaged=%s|deleted=%s|rename_from=%s|rename_to=%s|untracked=%s|ignored=%s|nested_tracked=%s|nested_untracked=%s|args=%s\n' \
  '$phase' "\$target_sha" "\$(show_file staged.txt)" "\$(show_file unstaged.txt)" \
  "\$(show_file deleted.txt)" "\$(show_file rename-from.txt)" "\$(show_file rename-to.txt)" \
  "\$(show_file untracked.txt)" "\$(show_file ignored.tmp)" "\$nested_tracked" "\$nested_untracked" "\$*" >> "\$EDC_T49_LOG"
case '$phase' in
  security) mkdir -p "\$(dirname "\$EDC_REVIEW_PROMOTION_OUTPUT")"; printf '## security\n' > "\$EDC_REVIEW_PROMOTION_OUTPUT" ;;
  delivery) mkdir -p "\$(dirname "\$EDC_DELIVERY_REVIEW_OUTPUT")"; printf '## delivery\n' > "\$EDC_DELIVERY_REVIEW_OUTPUT" ;;
  quality) mkdir -p "\$(dirname "\$EDC_AUDIT_COMPLEXITY_OUTPUT")"; printf '## complexity\n' > "\$EDC_AUDIT_COMPLEXITY_OUTPUT"; printf '## issues\n' > "\$EDC_AUDIT_ISSUES_OUTPUT" ;;
esac
mkdir -p "\$(dirname "\$EDC_RESULT_FILE")"
printf '%s\n' '{"schemaVersion":1,"kind":"$kind","phase":"$phase","status":"success","exitCode":0,"reasonCode":"success","message":"$phase succeeded","outputs":[]}' > "\$EDC_RESULT_FILE"
SH
    chmod +x "$TMP/plugin/scripts/$script"
  done
}

setup_repo() {
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo"
  cd "$TMP/repo"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email test@example.com
  git config user.name Test
  git config commit.gpgsign false
  printf 'original\n' > unstaged.txt
  printf 'delete me\n' > deleted.txt
  printf 'rename me\n' > rename-from.txt
  printf '*.tmp\n' > .gitignore
  git add .gitignore unstaged.txt deleted.txt rename-from.txt
  git commit -q -m initial
  git branch -M main
  git checkout -q -b candidate
  printf 'committed\n' > committed.txt
  git add committed.txt
  git commit -q -m candidate
}

prepare_dirty_candidate() {
  printf 'staged candidate\n' > staged.txt
  git add staged.txt
  printf 'unstaged candidate\n' > unstaged.txt
  rm deleted.txt
  git mv rename-from.txt rename-to.txt
  printf 'untracked candidate\n' > untracked.txt
  printf 'ignored secret\n' > ignored.tmp
}

prepare_plugin

# Pi task-store records are operational state, but unrelated .pi source/config
# remains eligible for an immutable working-tree candidate.
setup_repo
mkdir -p .pi/tasks/task-example .pi/extensions
printf '{"status":"completed"}\n' > .pi/tasks/task-example/task.json
printf 'export const extension = true;\n' > .pi/extensions/example.mjs
selected_untracked=$(bash -c 'source "$1"; edc_candidate_selected_untracked' _ "$TMP/plugin/scripts/edc-review-candidate.sh" | tr '\0' '\n')
if ! grep -q '^\.pi/tasks/task-example/task.json$' <<<"$selected_untracked" \
  && grep -q '^\.pi/extensions/example.mjs$' <<<"$selected_untracked" \
  && git -C "$ROOT" check-ignore -q --no-index .pi/tasks/task-example/task.json; then
  pass 'Pi task records are ignored/excluded while unrelated .pi source remains reviewable'
else
  fail 'Pi task exclusion swallowed unrelated .pi source or lacks repository ignore' "$selected_untracked"
fi

# Dirty state without a policy must stop before any phase starts.
setup_repo
prepare_dirty_candidate
: > "$TMP/default-phases.log"
set +e
out=$(EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/default-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] \
  && [ ! -s "$TMP/default-phases.log" ] \
  && grep -q 'working tree contains changes that are not part of the committed target' <<<"$out" \
  && grep -q -- '--include-working-tree' <<<"$out" \
  && grep -q -- '--committed-only' <<<"$out"; then
  pass 'dirty differential review fails before workers with corrective choices'
else
  fail 'dirty differential review did not fail before workers with actionable guidance' "rc=$rc\n$out\nphases=$(cat "$TMP/default-phases.log")"
fi

# Caller-controlled environment cannot bypass the default dirty-state guard.
setup_repo
prepare_dirty_candidate
: > "$TMP/env-bypass-phases.log"
set +e
out=$(EDC_CANDIDATE_RESOLVED=1 EDC_CANDIDATE_COMMIT=$(git rev-parse HEAD) EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/env-bypass-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ ! -s "$TMP/env-bypass-phases.log" ] \
  && grep -q 'working tree contains changes' <<<"$out"; then
  pass 'caller environment cannot bypass dirty candidate resolution'
else
  fail 'caller environment bypassed dirty candidate resolution' "rc=$rc\n$out"
fi

# External targets must explicitly exclude local dirt and can never absorb it.
setup_repo
prepare_dirty_candidate
set +e
out=$(bash -c 'source "$1"; edc_candidate_resolve_external patch.diff main ""' _ "$TMP/plugin/scripts/edc-review-candidate.sh" 2>&1)
rc_default=$?
include_out=$(bash -c 'source "$1"; edc_candidate_resolve_external patch.diff main include-working-tree' _ "$TMP/plugin/scripts/edc-review-candidate.sh" 2>&1)
rc_include=$?
set -e
if [ "$rc_default" -ne 0 ] && [ "$rc_include" -ne 0 ] \
  && grep -q -- '--committed-only' <<<"$out" \
  && grep -q 'incompatible with an external PR or patch target' <<<"$include_out"; then
  pass 'external targets require explicit local exclusion'
else
  fail 'external target policy allowed ambiguous local dirt' "default_rc=$rc_default\n$out\ninclude_rc=$rc_include\n$include_out"
fi

# Committed-only is explicit and metadata must not claim dirty inclusion.
setup_repo
prepare_dirty_candidate
: > "$TMP/committed-phases.log"
set +e
out=$(EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/committed-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main --committed-only 2>&1)
rc=$?
set -e
head_sha=$(git rev-parse HEAD)
if [ "$rc" -eq 0 ] \
  && [ "$(grep -c "target=$head_sha" "$TMP/committed-phases.log" || true)" -eq 3 ] \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.candidateKind === "committed" && j.candidateCommit === process.argv[1] && j.dirtyTrackedIncluded === false && j.untrackedIncluded === false ? 0 : 1)' "$head_sha"; then
  pass 'committed-only excludes dirty content and reports truthful metadata'
else
  fail 'committed-only scope or metadata is not explicit' "rc=$rc\n$out\n$(cat "$TMP/committed-phases.log" 2>/dev/null || true)"
fi

# Include-working-tree must create one complete candidate without mutating user state.
setup_repo
prepare_dirty_candidate
head_before=$(git rev-parse HEAD)
index_before=$(git write-tree)
refs_before=$(git show-ref | LC_ALL=C sort)
source_before=$(for path in staged.txt unstaged.txt untracked.txt ignored.tmp; do printf '%s ' "$path"; git hash-object "$path"; done; printf 'deleted=%s\n' "$(test -e deleted.txt && echo present || echo absent)")
: > "$TMP/include-phases.log"
set +e
out=$(EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/include-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main --include-working-tree 2>&1)
rc=$?
set -e
head_after=$(git rev-parse HEAD)
index_after=$(git write-tree)
refs_after=$(git show-ref | LC_ALL=C sort)
source_after=$(for path in staged.txt unstaged.txt untracked.txt ignored.tmp; do printf '%s ' "$path"; git hash-object "$path"; done; printf 'deleted=%s\n' "$(test -e deleted.txt && echo present || echo absent)")
candidate_sha=$(sed -n 's/^security|target=\([^|]*\).*/\1/p' "$TMP/include-phases.log" | head -1)
if [ "$rc" -eq 0 ] \
  && [ -n "$candidate_sha" ] \
  && [ "$candidate_sha" != "$head_before" ] \
  && [ "$(grep -c "target=$candidate_sha" "$TMP/include-phases.log" || true)" -eq 3 ] \
  && [ "$(grep -c 'staged=staged candidate|' "$TMP/include-phases.log" || true)" -eq 3 ] \
  && [ "$(grep -c 'unstaged=unstaged candidate|' "$TMP/include-phases.log" || true)" -eq 3 ] \
  && [ "$(grep -c 'deleted=<absent>' "$TMP/include-phases.log" || true)" -eq 3 ] \
  && [ "$(grep -c 'rename_from=<absent>' "$TMP/include-phases.log" || true)" -eq 3 ] \
  && [ "$(grep -c 'rename_to=rename me|' "$TMP/include-phases.log" || true)" -eq 3 ] \
  && [ "$(grep -c 'untracked=untracked candidate|' "$TMP/include-phases.log" || true)" -eq 3 ] \
  && [ "$(grep -c 'ignored=<absent>' "$TMP/include-phases.log" || true)" -eq 3 ]; then
  pass 'include-working-tree gives every lens the same complete candidate commit'
else
  fail 'include-working-tree did not produce one complete shared candidate' "rc=$rc candidate=$candidate_sha\n$out\n$(cat "$TMP/include-phases.log" 2>/dev/null || true)"
fi
if [ "$head_before" = "$head_after" ] \
  && [ "$index_before" = "$index_after" ] \
  && [ "$refs_before" = "$refs_after" ] \
  && [ "$source_before" = "$source_after" ]; then
  pass 'candidate snapshot preserves HEAD, refs, real index, and source bytes'
else
  fail 'candidate snapshot mutated user Git/source state'
fi
if [ -n "$candidate_sha" ] \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.candidateKind === "working-tree-snapshot" && j.candidateCommit === process.argv[1] && j.dirtyTrackedIncluded === true && j.untrackedIncluded === true ? 0 : 1)' "$candidate_sha"; then
  pass 'include-working-tree metadata identifies the actual candidate snapshot'
else
  fail 'include-working-tree metadata does not describe the resolved candidate'
fi

# A historical target cannot be combined with the current working tree.
setup_repo
prepare_dirty_candidate
: > "$TMP/historical-phases.log"
set +e
out=$(EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/historical-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD~1 --base main --include-working-tree 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] \
  && [ ! -s "$TMP/historical-phases.log" ] \
  && grep -q -- '--include-working-tree requires target HEAD' <<<"$out" \
  && grep -q -- '--committed-only' <<<"$out"; then
  pass 'historical target plus working tree fails with corrective guidance'
else
  fail 'historical target plus working tree was not rejected clearly' "rc=$rc\n$out"
fi

# Dirty bytes inside an initialized submodule require a nested immutable commit.
setup_repo
rm -rf "$TMP/sub-origin"
mkdir -p "$TMP/sub-origin"
git -C "$TMP/sub-origin" init -q
git -C "$TMP/sub-origin" config user.email test@example.com
git -C "$TMP/sub-origin" config user.name Test
git -C "$TMP/sub-origin" config commit.gpgsign false
printf 'sub original\n' > "$TMP/sub-origin/inside.txt"
git -C "$TMP/sub-origin" add inside.txt
git -C "$TMP/sub-origin" commit -q -m initial
git -c protocol.file.allow=always submodule add -q "$TMP/sub-origin" nested
git add .gitmodules nested
git commit -q -m 'add submodule'
printf 'sub dirty\n' > nested/inside.txt
printf 'sub untracked\n' > nested/new.txt
head_before=$(git rev-parse HEAD)
index_before=$(git write-tree)
sub_index_before=$(git -C nested write-tree)
refs_before=$(git show-ref | LC_ALL=C sort)
sub_refs_before=$(git -C nested show-ref | LC_ALL=C sort)
: > "$TMP/submodule-phases.log"
set +e
out=$(EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/submodule-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main --include-working-tree 2>&1)
rc=$?
set -e
candidate_sha=$(sed -n 's/^security|target=\([^|]*\).*/\1/p' "$TMP/submodule-phases.log" | head -1)
sub_candidate=$(git ls-tree "$candidate_sha" nested 2>/dev/null | awk '{print $3}')
if [ "$rc" -eq 0 ] && [ -n "$sub_candidate" ] \
  && [ "$(git -C nested show "$sub_candidate:inside.txt")" = 'sub dirty' ] \
  && [ "$(git -C nested show "$sub_candidate:new.txt")" = 'sub untracked' ] \
  && [ "$(grep -c 'nested_tracked=sub dirty||nested_untracked=sub untracked||' "$TMP/submodule-phases.log" || true)" -eq 3 ] \
  && [ "$(git rev-parse HEAD)" = "$head_before" ] \
  && [ "$(git write-tree)" = "$index_before" ] \
  && [ "$(git -C nested write-tree)" = "$sub_index_before" ] \
  && [ "$(git show-ref | LC_ALL=C sort)" = "$refs_before" ] \
  && [ "$(git -C nested show-ref | LC_ALL=C sort)" = "$sub_refs_before" ]; then
  pass 'include-working-tree snapshots dirty submodule bytes without mutating refs or indexes'
else
  fail 'dirty submodule bytes were omitted or user state mutated' "rc=$rc candidate=$candidate_sha subcandidate=$sub_candidate\n$out\n$(cat "$TMP/submodule-phases.log" 2>/dev/null || true)"
fi

# Configured submodule ignore rules must not hide tracked bytes from candidate
# policy, external-target checks, snapshot recursion, or inclusion metadata.
setup_repo
rm -rf "$TMP/sub-origin"
mkdir -p "$TMP/sub-origin"
git -C "$TMP/sub-origin" init -q
git -C "$TMP/sub-origin" config user.email test@example.com
git -C "$TMP/sub-origin" config user.name Test
git -C "$TMP/sub-origin" config commit.gpgsign false
printf 'sub original\n' > "$TMP/sub-origin/inside.txt"
git -C "$TMP/sub-origin" add inside.txt
git -C "$TMP/sub-origin" commit -q -m initial
git -c protocol.file.allow=always submodule add -q "$TMP/sub-origin" nested
git add .gitmodules nested
git commit -q -m 'add ignored submodule'
git config submodule.nested.ignore all
printf 'sub ignored dirty\n' > nested/inside.txt
: > "$TMP/ignored-submodule-default-phases.log"
set +e
default_out=$(EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/ignored-submodule-default-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main 2>&1)
default_rc=$?
external_out=$(bash -c 'source "$1"; edc_candidate_resolve_external patch.diff main ""' _ "$TMP/plugin/scripts/edc-review-candidate.sh" 2>&1)
external_rc=$?
set -e
if [ "$default_rc" -ne 0 ] && [ ! -s "$TMP/ignored-submodule-default-phases.log" ] \
  && grep -q 'working tree contains changes' <<<"$default_out" \
  && [ "$external_rc" -ne 0 ] && grep -q 'local changes outside the external review target' <<<"$external_out"; then
  pass 'ignore=all dirty tracked submodule is rejected without explicit policy'
else
  fail 'ignore=all hid dirty tracked submodule from policy checks' "default_rc=$default_rc\n$default_out\nexternal_rc=$external_rc\n$external_out"
fi
: > "$TMP/ignored-submodule-phases.log"
set +e
include_out=$(EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/ignored-submodule-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main --include-working-tree 2>&1)
include_rc=$?
set -e
ignored_candidate=$(sed -n 's/^security|target=\([^|]*\).*/\1/p' "$TMP/ignored-submodule-phases.log" | head -1)
ignored_sub_candidate=$(git ls-tree "$ignored_candidate" nested 2>/dev/null | awk '{print $3}')
if [ "$include_rc" -eq 0 ] && [ -n "$ignored_sub_candidate" ] \
  && [ "$(git -C nested show "$ignored_sub_candidate:inside.txt")" = 'sub ignored dirty' ] \
  && [ "$(grep -c 'nested_tracked=sub ignored dirty||nested_untracked=<absent>|' "$TMP/ignored-submodule-phases.log" || true)" -eq 3 ] \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.candidateKind === "working-tree-snapshot" && j.candidateCommit === process.argv[1] && j.dirtyTrackedIncluded === true && j.untrackedIncluded === false ? 0 : 1)' "$ignored_candidate"; then
  pass 'include-working-tree snapshots ignore=all dirty tracked submodule truthfully'
else
  fail 'include-working-tree omitted ignore=all dirty tracked submodule' "rc=$include_rc candidate=$ignored_candidate subcandidate=$ignored_sub_candidate\n$include_out\n$(cat "$TMP/ignored-submodule-phases.log" 2>/dev/null || true)"
fi

# Nested untracked-only dirt remains selected recursively but must not be
# mislabeled as tracked, even when the submodule config says ignore=all.
git -C nested checkout -q -- inside.txt
printf 'sub ignored untracked\n' > nested/new.txt
: > "$TMP/ignored-submodule-untracked-phases.log"
set +e
untracked_out=$(EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/ignored-submodule-untracked-phases.log" bash "$TMP/plugin/scripts/edc-review-all.sh" HEAD --base main --include-working-tree 2>&1)
untracked_rc=$?
set -e
untracked_candidate=$(sed -n 's/^security|target=\([^|]*\).*/\1/p' "$TMP/ignored-submodule-untracked-phases.log" | head -1)
untracked_sub_candidate=$(git ls-tree "$untracked_candidate" nested 2>/dev/null | awk '{print $3}')
untracked_metadata=$(node -e 'const j=require("./edc-context/build/last-run.json"); process.stdout.write(`${j.candidateKind}|${j.candidateCommit}|${j.dirtyTrackedIncluded}|${j.untrackedIncluded}`)')
if [ "$untracked_rc" -eq 0 ] && [ -n "$untracked_sub_candidate" ] \
  && [ "$(git -C nested show "$untracked_sub_candidate:inside.txt")" = 'sub original' ] \
  && [ "$(git -C nested show "$untracked_sub_candidate:new.txt")" = 'sub ignored untracked' ] \
  && [ "$(grep -c 'nested_tracked=sub original||nested_untracked=sub ignored untracked||' "$TMP/ignored-submodule-untracked-phases.log" || true)" -eq 3 ] \
  && [ "$untracked_metadata" = "working-tree-snapshot|$untracked_candidate|false|true" ]; then
  pass 'ignore=all nested untracked-only dirt has truthful metadata'
else
  fail 'ignore=all nested untracked-only dirt was mislabeled or omitted' "rc=$untracked_rc candidate=$untracked_candidate subcandidate=$untracked_sub_candidate metadata=$untracked_metadata\n$untracked_out\n$(cat "$TMP/ignored-submodule-untracked-phases.log" 2>/dev/null || true)"
fi

# An uninitialized submodule must be treated as an opaque gitlink, not as the
# parent repository discovered by Git's upward directory search.
setup_repo
rm -rf "$TMP/sub-origin"
mkdir -p "$TMP/sub-origin"
git -C "$TMP/sub-origin" init -q
git -C "$TMP/sub-origin" config user.email test@example.com
git -C "$TMP/sub-origin" config user.name Test
git -C "$TMP/sub-origin" config commit.gpgsign false
printf 'sub original\n' > "$TMP/sub-origin/inside.txt"
git -C "$TMP/sub-origin" add inside.txt
git -C "$TMP/sub-origin" commit -q -m initial
git -c protocol.file.allow=always submodule add -q "$TMP/sub-origin" nested
git add .gitmodules nested
git commit -q -m 'add submodule'
git submodule deinit -q -f nested
printf 'top dirty\n' > unstaged.txt
: > "$TMP/uninitialized-phases.log"
set +e
EDC_AGENT_CLI=pi EDC_T49_LOG="$TMP/uninitialized-phases.log" EDC_T49_REVIEW_ALL="$TMP/plugin/scripts/edc-review-all.sh" python3 - <<'PY' >"$TMP/uninitialized.out" 2>&1
import os
import subprocess
import sys
try:
    completed = subprocess.run(
        ["bash", os.environ["EDC_T49_REVIEW_ALL"], "HEAD", "--base", "main", "--include-working-tree"],
        env=os.environ,
        timeout=15,
    )
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(completed.returncode)
PY
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(grep -c 'unstaged=top dirty|' "$TMP/uninitialized-phases.log" || true)" -eq 3 ]; then
  pass 'uninitialized submodule remains an opaque gitlink without recursive traversal'
else
  fail 'uninitialized submodule caused recursive traversal or incomplete review' "rc=$rc\n$(cat "$TMP/uninitialized.out" 2>/dev/null || true)"
fi

printf '\nt49-dirty-candidate-scope: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
