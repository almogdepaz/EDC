#!/usr/bin/env bash
# t15-review-routing: pin the contract that build_mode in edc-review.sh
# routes changed files via edc-context/manifest.json (not naive top-level-dir
# grouping), and that unmapped/ambiguous outcomes are handled per
# policy.unmatchedPathPolicy with no silent failures.
#
# Run from repo root: bash tests/hardening/t15-review-routing.sh
set -uo pipefail

ORIG_DIR="$(pwd)"
SCRIPT="$ORIG_DIR/plugins/edc/scripts/edc-review.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

BASH_BIN="${BASH_BIN:-bash}"

# Counters live in temp files so subshell-scoped checks aggregate correctly.
# shellcheck source=lib/check.sh
. "$(dirname "$0")/lib/check.sh"
check_init --file
TMPDIR_T15A=""
trap 'rm -rf "${TMPDIR_T15A:-}"; check_cleanup' EXIT

# ── 15.0: review orchestrator help flag ─────────────────────────────────────
out=$("$BASH_BIN" "$SCRIPT" -h 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "Usage: edc-review.sh"; then
  check "15.0: edc-review.sh -h prints usage" 1
else
  check "15.0: edc-review.sh -h prints usage" 0
  echo "$out"
fi

setup_repo() {
  local dir="$1"
  cd "$dir"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git config commit.gpgsign false
  echo "seed" > seed.txt
  git add seed.txt
  git commit -q -m "init"
  node "$ORIG_DIR/plugins/edc/hooks/lib/runtime-manifest.mjs" install "$dir" "$ORIG_DIR/plugins/edc" >/dev/null
}

write_manifest() {
  local manifest="$1" head="$2" policy="$3" modules="$4"
  cat > "$manifest" <<EOF
{
  "schemaVersion": 2,
  "edcVersion": "1.1.0",
  "sourceCommit": "$head",
  "repoContextFile": "edc-context/index.md",
  "reports": {"issues": "edc-context/reports/issues.md", "complexity": "edc-context/reports/complexity.md"},
  "build": {"buildInfoFile": "edc-context/build/build.json"},
  "policy": {"defaultMode": "advisory", "unmatchedPathPolicy": "$policy"},
  "unmapped": {"allowedGlobs": ["README.md", "package.json"]},
  "modules": $modules,
  "coverage": {"mappedFileCount": 0, "unmappedFileCount": 0, "ambiguousPathCount": 0}
}
EOF
}

write_minimal_context() {
  mkdir -p edc-context/modules edc-context/reports edc-context/build
  printf '<!-- t15 -->\n# Stub\n\n## Module Map\n\n- mod\n' > edc-context/index.md
  printf '<!-- t15 -->\n# stub\n\n## Files\n' > edc-context/modules/stub.md
  printf '## Known Issues\n' > edc-context/reports/issues.md
}

# ── 15.1: prefix routing wins over naive top-level-dir grouping ─────────────
# wolfpack-style: src/broker/* and src/server/* should route to different
# modules, NOT both lumped under "src".
TMPDIR_T15A=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15A"
  write_minimal_context
  mkdir -p src/broker src/server
  echo "x" > src/broker/foo.ts
  echo "y" > src/server/bar.ts
  git add src edc-context
  git commit -q -m "add files"
  head=$(git rev-parse HEAD)
  # Write manifest AFTER the commit so sourceCommit == HEAD (freshness gate).
  write_manifest edc-context/manifest.json "$head" "warn-allow" '[
    {"name":"broker-client","doc":"edc-context/modules/broker-client.md","priority":100,"match":{"prefixes":["src/broker/"]}},
    {"name":"server","doc":"edc-context/modules/server.md","priority":100,"match":{"prefixes":["src/server/"]}}
  ]'

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1) || rc=$?

  if [ -f edc-context/review-tasks/broker-client.md ] && [ -f edc-context/review-tasks/server.md ]; then
    check "15.1: src/broker/* → broker-client, src/server/* → server" 1
  else
    check "15.1: src/broker/* → broker-client, src/server/* → server" 0
    ls edc-context/review-tasks/ 2>&1 || true
  fi

  if [ -f edc-context/review-tasks/src.md ]; then
    check "15.1: NO synthetic 'src' module bucket" 0
  else
    check "15.1: NO synthetic 'src' module bucket" 1
  fi
)

# ── 15.2: exactFiles routing ────────────────────────────────────────────────
TMPDIR_T15B=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15B"
  write_minimal_context
  mkdir -p src
  echo "x" > src/auth.ts
  git add src edc-context
  git commit -q -m "add files"
  head=$(git rev-parse HEAD)
  write_manifest edc-context/manifest.json "$head" "warn-allow" '[
    {"name":"core","doc":"edc-context/modules/core.md","priority":100,"match":{"exactFiles":["src/auth.ts"]}}
  ]'

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1) || rc=$?
  if [ -f edc-context/review-tasks/core.md ]; then
    check "15.2: exactFiles match routes file to declared module" 1
  else
    check "15.2: exactFiles match routes file to declared module" 0
  fi
  rm -rf "$TMPDIR_T15B"
)

# ── 15.3: warn-allow policy — unexpected unmapped file ──────────────────────
TMPDIR_T15C=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15C"
  write_minimal_context
  echo "x" > orphan.ts
  git add orphan.ts edc-context
  git commit -q -m "add orphan"
  head=$(git rev-parse HEAD)
  write_manifest edc-context/manifest.json "$head" "warn-allow" '[
    {"name":"server","doc":"edc-context/modules/server.md","priority":100,"match":{"prefixes":["src/server/"]}}
  ]'

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f edc-context/review-tasks/unmapped.md ]; then
    check "15.3a: warn-allow groups unmapped file into 'unmapped' bucket" 1
  else
    check "15.3a: warn-allow groups unmapped file into 'unmapped' bucket" 0
    echo "$out"
  fi
  if echo "$out" | grep -q "^WARNING:" && echo "$out" | grep -q "orphan.ts"; then
    check "15.3b: warn-allow logs WARNING for unexpected unmapped file" 1
  else
    check "15.3b: warn-allow logs WARNING for unexpected unmapped file" 0
    echo "$out"
  fi
  rm -rf "$TMPDIR_T15C"
)

# ── 15.4: warn-allow policy — expected unmapped file (allowedGlobs) ─────────
TMPDIR_T15D=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15D"
  write_minimal_context
  echo "x" > README.md  # listed in allowedGlobs by write_manifest
  git add README.md edc-context
  git commit -q -m "edit README"
  head=$(git rev-parse HEAD)
  write_manifest edc-context/manifest.json "$head" "warn-allow" '[
    {"name":"server","doc":"edc-context/modules/server.md","priority":100,"match":{"prefixes":["src/server/"]}}
  ]'

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ ! -f edc-context/review-tasks/unmapped.md ]; then
    check "15.4a: README.md (allowedGlobs) does not spawn an unmapped review task" 1
  else
    check "15.4a: README.md (allowedGlobs) does not spawn an unmapped review task" 0
    echo "$out"
    ls edc-context/review-tasks 2>/dev/null || true
  fi
  if [ -f edc-context/review-tasks/report-allowed-unmapped.md ] && grep -q '^## Findings' edc-context/review-tasks/report-allowed-unmapped.md; then
    check "15.4b: allowedGlobs writes deterministic validating skipped report" 1
  else
    check "15.4b: allowedGlobs writes deterministic validating skipped report" 0
    cat edc-context/review-tasks/report-allowed-unmapped.md 2>/dev/null || true
  fi
  # README is in allowedGlobs — should NOT trigger a WARNING line at all.
  if echo "$out" | grep -qE '^WARNING:.*not mapped'; then
    check "15.4c: allowedGlobs match suppresses WARNING" 0
    echo "$out"
  else
    check "15.4c: allowedGlobs match suppresses WARNING" 1
  fi
  if echo "$out" | grep -q '^TASK .*\(unmapped\|allowed-unmapped\).md'; then
    check "15.4d: allowedGlobs skipped report is not emitted as a subprocess task" 0
    echo "$out"
  else
    check "15.4d: allowedGlobs skipped report is not emitted as a subprocess task" 1
  fi
  rm -rf "$TMPDIR_T15D"
)

# ── 15.4e: mixed expected + unexpected unmapped paths keep both accounted ───
TMPDIR_T15D2=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15D2"
  write_minimal_context
  echo "x" > README.md   # listed in allowedGlobs by write_manifest
  echo "y" > orphan.ts   # unexpected unmapped
  git add README.md orphan.ts edc-context
  git commit -q -m "edit allowed and orphan"
  head=$(git rev-parse HEAD)
  write_manifest edc-context/manifest.json "$head" "warn-allow" '[
    {"name":"server","doc":"edc-context/modules/server.md","priority":100,"match":{"prefixes":["src/server/"]}}
  ]'

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] \
     && [ -f edc-context/review-tasks/unmapped.md ] \
     && grep -q 'orphan.ts' edc-context/review-tasks/unmapped.md \
     && ! grep -q 'README.md' edc-context/review-tasks/unmapped.md; then
    check "15.4e: mixed unmapped task reviews only unexpected paths" 1
  else
    check "15.4e: mixed unmapped task reviews only unexpected paths" 0
    echo "$out"
    cat edc-context/review-tasks/unmapped.md 2>/dev/null || true
  fi
  if [ -f edc-context/review-tasks/report-allowed-unmapped.md ] \
     && grep -q 'README.md' edc-context/review-tasks/report-allowed-unmapped.md \
     && jq -e '.modules[] | select(.name == "allowed-unmapped")' edc-context/review-tasks/manifest.json >/dev/null; then
    check "15.4f: mixed allowedGlobs writes separate skipped report and manifest entry" 1
  else
    check "15.4f: mixed allowedGlobs writes separate skipped report and manifest entry" 0
    cat edc-context/review-tasks/report-allowed-unmapped.md 2>/dev/null || true
    cat edc-context/review-tasks/manifest.json 2>/dev/null || true
  fi
  if echo "$out" | grep -q '^TASK .*allowed-unmapped.md'; then
    check "15.4g: mixed allowedGlobs skipped report is not emitted as a subprocess task" 0
    echo "$out"
  else
    check "15.4g: mixed allowedGlobs skipped report is not emitted as a subprocess task" 1
  fi
  if echo "$out" | grep -q '^WARNING:.*not mapped' \
     && echo "$out" | grep -q 'orphan.ts' \
     && ! echo "$out" | grep -q '^WARNING:.*README.md'; then
    check "15.4h: mixed warning names only unexpected unmapped paths" 1
  else
    check "15.4h: mixed warning names only unexpected unmapped paths" 0
    echo "$out"
  fi
  rm -rf "$TMPDIR_T15D2"
)

# ── 15.5: fail policy — unexpected unmapped file → exit 2 ───────────────────
TMPDIR_T15E=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15E"
  write_minimal_context
  echo "x" > orphan.ts
  git add orphan.ts edc-context
  git commit -q -m "add orphan"
  head=$(git rev-parse HEAD)
  write_manifest edc-context/manifest.json "$head" "fail" '[
    {"name":"server","doc":"edc-context/modules/server.md","priority":100,"match":{"prefixes":["src/server/"]}}
  ]'

  set +e
  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
  rc=$?
  set -e

  if [ "$rc" -eq 2 ]; then
    check "15.5a: fail policy exits 2 on unmapped file" 1
  else
    check "15.5a: fail policy exits 2 on unmapped file (got rc=$rc)" 0
  fi
  if echo "$out" | grep -qE "ERROR.*not mapped.*orphan.ts|ERROR.*orphan.ts.*not mapped|ERROR.*not mapped" \
     && echo "$out" | grep -q "orphan.ts"; then
    check "15.5b: fail policy lists offending file in error" 1
  else
    check "15.5b: fail policy lists offending file in error" 0
    echo "$out"
  fi
  rm -rf "$TMPDIR_T15E"
)

# ── 15.6: ambiguous routing → hard exit 2 ───────────────────────────────────
TMPDIR_T15F=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15F"
  write_minimal_context
  mkdir -p src
  echo "x" > src/foo.ts
  git add src edc-context
  git commit -q -m "add ambiguous"
  head=$(git rev-parse HEAD)
  # Two modules with the same prefix and same priority — ambiguous.
  write_manifest edc-context/manifest.json "$head" "warn-allow" '[
    {"name":"alpha","doc":"edc-context/modules/alpha.md","priority":100,"match":{"prefixes":["src/"]}},
    {"name":"beta","doc":"edc-context/modules/beta.md","priority":100,"match":{"prefixes":["src/"]}}
  ]'

  set +e
  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
  rc=$?
  set -e

  if [ "$rc" -eq 2 ]; then
    check "15.6a: ambiguous routing exits 2" 1
  else
    check "15.6a: ambiguous routing exits 2 (got rc=$rc)" 0
  fi
  if echo "$out" | grep -q "match multiple modules"; then
    check "15.6b: ambiguous error mentions 'match multiple modules'" 1
  else
    check "15.6b: ambiguous error mentions 'match multiple modules'" 0
    echo "$out"
  fi
  rm -rf "$TMPDIR_T15F"
)

# ── 15.7: regression guard — edc-context/review-tasks/manifest.json names are real ──
# Already implicitly verified by 15.1 (no synthetic 'src' bucket), but pin it
# explicitly: the only synthetic names allowed are "unmapped" and "allowed-unmapped".
TMPDIR_T15G=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15G"
  write_minimal_context
  mkdir -p src
  echo "x" > src/a.ts
  echo "y" > src/b.ts
  echo "z" > orphan.ts
  git add src orphan.ts edc-context
  git commit -q -m "add"
  head=$(git rev-parse HEAD)
  write_manifest edc-context/manifest.json "$head" "warn-allow" '[
    {"name":"core","doc":"edc-context/modules/core.md","priority":100,"match":{"prefixes":["src/"]}}
  ]'

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1) || true

  # Every name in edc-context/review-tasks/manifest.json must either exist in
  # edc-context/manifest.json or be an explicit review accounting synthetic.
  context_modules=$(jq -r '.modules[].name' edc-context/manifest.json)
  review_modules=$(jq -r '.modules[].name' edc-context/review-tasks/manifest.json)
  bad_count=0
  for m in $review_modules; do
    case "$m" in
      unmapped|allowed-unmapped) continue ;;
    esac
    if ! echo "$context_modules" | grep -qx "$m"; then
      bad_count=$((bad_count + 1))
      echo "  unexpected synthetic module: $m"
    fi
  done

  if [ "$bad_count" -eq 0 ]; then
    check "15.7: review-tasks modules are real or expected synthetics only" 1
  else
    check "15.7: review-tasks modules are real or expected synthetics only" 0
  fi
  rm -rf "$TMPDIR_T15G"
)

# ── 15.8: --ignore-context requires no manifest and writes pure baseline task ──
TMPDIR_T15H=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15H"
  mkdir -p src
  echo "x" > src/a.ts
  git add src/a.ts
  git commit -q -m "add"

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 --ignore-context 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f edc-context/review-tasks/ignore-context.md ]; then
    check "15.8a: --ignore-context writes synthetic baseline task without manifest" 1
  else
    check "15.8a: --ignore-context writes synthetic baseline task without manifest" 0
    echo "$out"
  fi
  if [ "$(jq -r '.contextMode' edc-context/review-tasks/manifest.json 2>/dev/null)" = "ignored" ]; then
    check "15.8b: --ignore-context manifest records contextMode=ignored" 1
  else
    check "15.8b: --ignore-context manifest records contextMode=ignored" 0
    cat edc-context/review-tasks/manifest.json 2>/dev/null || true
  fi
  if grep -q "DO NOT use prebuilt EDC context" edc-context/review-tasks/ignore-context.md; then
    check "15.8c: --ignore-context task forbids context usage" 1
  else
    check "15.8c: --ignore-context task forbids context usage" 0
    cat edc-context/review-tasks/ignore-context.md 2>/dev/null || true
  fi
  if grep -q 'immutable candidate commit' edc-context/review-tasks/ignore-context.md \
    && grep -q 'git show' edc-context/review-tasks/ignore-context.md \
    && grep -q 'mutable working tree' edc-context/review-tasks/ignore-context.md \
    && grep -q 'changed gitlink' edc-context/review-tasks/ignore-context.md \
    && grep -q 'git -C <submodule-path> diff' edc-context/review-tasks/ignore-context.md; then
    check "15.8d: differential security task pins immutable candidate evidence" 1
  else
    check "15.8d: differential security task pins immutable candidate evidence" 0
    cat edc-context/review-tasks/ignore-context.md 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_T15H"
)

# ── 15.9: --no-context-refresh does not force-ignore context ───────────────
TMPDIR_T15I=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15I"
  mkdir -p src
  echo "x" > src/a.ts
  git add src/a.ts
  git commit -q -m "add"

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 --no-context-refresh 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f edc-context/review-tasks/no-context-refresh.md ]; then
    check "15.9a: --no-context-refresh writes direct task when context absent" 1
  else
    check "15.9a: --no-context-refresh writes direct task when context absent" 0
    echo "$out"
  fi
  if [ "$(jq -r '.contextMode' edc-context/review-tasks/manifest.json 2>/dev/null)" = "no-refresh" ]; then
    check "15.9b: --no-context-refresh manifest records contextMode=no-refresh" 1
  else
    check "15.9b: --no-context-refresh manifest records contextMode=no-refresh" 0
    cat edc-context/review-tasks/manifest.json 2>/dev/null || true
  fi
  if grep -q "DO NOT use prebuilt EDC context" edc-context/review-tasks/no-context-refresh.md; then
    check "15.9c: --no-context-refresh does not force-ignore context" 0
    cat edc-context/review-tasks/no-context-refresh.md 2>/dev/null || true
  else
    check "15.9c: --no-context-refresh does not force-ignore context" 1
  fi
  rm -rf "$TMPDIR_T15I"
)

# ── 15.10: --no-context-refresh uses existing stale context if present ────
TMPDIR_T15J=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15J"
  write_minimal_context
  mkdir -p src
  echo "x" > src/a.ts
  git add src/a.ts edc-context
  git commit -q -m "add file"
  old_head=$(git rev-parse HEAD)
  write_manifest edc-context/manifest.json "$old_head" "warn-allow" '[
    {"name":"core","doc":"edc-context/modules/core.md","priority":100,"match":{"prefixes":["src/"]}}
  ]'
  echo "y" >> src/a.ts
  git add src/a.ts
  git commit -q -m "change file"

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 --no-context-refresh 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f edc-context/review-tasks/core.md ]; then
    check "15.10a: --no-context-refresh uses existing context/routing" 1
  else
    check "15.10a: --no-context-refresh uses existing context/routing" 0
    echo "$out"
    ls edc-context/review-tasks 2>/dev/null || true
  fi
  if echo "$out" | grep -q "context is stale"; then
    check "15.10b: --no-context-refresh warns but does not update stale context" 1
  else
    check "15.10b: --no-context-refresh warns but does not update stale context" 0
    echo "$out"
  fi
  if [ "$(jq -r '.contextMode' edc-context/review-tasks/manifest.json 2>/dev/null)" = "no-refresh" ]; then
    check "15.10c: routed no-refresh manifest records contextMode=no-refresh" 1
  else
    check "15.10c: routed no-refresh manifest records contextMode=no-refresh" 0
    cat edc-context/review-tasks/manifest.json 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_T15J"
)

# ── 15.11: --verify skips freshness gate for non-context manifests ─────────
TMPDIR_T15J=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15J"
  mkdir -p edc-context/review-tasks
  cat > edc-context/review-tasks/manifest.json <<'EOF'
{"target":"HEAD","baseline":"","head":"dummy","contextMode":"ignored","modules":[{"name":"ignore-context","doc":"","files":["src/a.ts"]}]}
EOF
  printf '## Findings\n\nnone\n' > edc-context/review-tasks/report-ignore-context.md
  printf '# Review\n' > review-HEAD.md

  out=$("$BASH_BIN" "$SCRIPT" --verify 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && echo "$out" | grep -q "Verified: review-HEAD.md"; then
    check "15.11: --verify skips context freshness for contextMode=ignored" 1
  else
    check "15.11: --verify skips context freshness for contextMode=ignored" 0
    echo "$out"
  fi
  rm -rf "$TMPDIR_T15J"
)

# ── 15.12: ambiguous legacy --no-context flag is rejected ──────────────────
TMPDIR_T15K=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15K"
  set +e
  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 --no-context 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && echo "$out" | grep -q "unknown argument: --no-context"; then
    check "15.12: --no-context is rejected" 1
  else
    check "15.12: --no-context is rejected" 0
    echo "$out"
  fi
  rm -rf "$TMPDIR_T15K"
)

# ── 15.13: PR shorthand target uses gh PR diff path ────────────────────────
TMPDIR_T15L=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15L"
  mkdir -p fake-bin src
  cat > fake-bin/gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > gh-args.txt
if [ "$1" = "pr" ] && [ "$2" = "diff" ] && [ "$3" = "147" ] && [ "$4" = "--name-only" ]; then
  echo "src/a.ts"
  exit 0
fi
exit 1
EOF
  chmod +x fake-bin/gh
  PATH="$PWD/fake-bin:$PATH" out=$("$BASH_BIN" "$SCRIPT" --build pr:147 --committed-only --ignore-context 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f edc-context/review-tasks/ignore-context.md ] && grep -q "src/a.ts" edc-context/review-tasks/ignore-context.md; then
    check "15.13a: pr:<number> target uses gh pr diff output" 1
  else
    check "15.13a: pr:<number> target uses gh pr diff output" 0
    echo "$out"
  fi
  if grep -qx "pr" gh-args.txt && grep -qx "diff" gh-args.txt && grep -qx "147" gh-args.txt && grep -qx -- "--name-only" gh-args.txt; then
    check "15.13b: pr:<number> invokes gh pr diff <number> --name-only" 1
  else
    check "15.13b: pr:<number> invokes gh pr diff <number> --name-only" 0
    cat gh-args.txt 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_T15L"
)

# ── 15.14: --pr flag accepts a PR number without URL ───────────────────────
TMPDIR_T15M=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15M"
  mkdir -p fake-bin src
  cat > fake-bin/gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > gh-args.txt
if [ "$1" = "pr" ] && [ "$2" = "diff" ] && [ "$3" = "147" ] && [ "$4" = "--name-only" ]; then
  echo "src/a.ts"
  exit 0
fi
exit 1
EOF
  chmod +x fake-bin/gh
  PATH="$PWD/fake-bin:$PATH" out=$("$BASH_BIN" "$SCRIPT" --build --pr 147 --committed-only --ignore-context 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f edc-context/review-tasks/ignore-context.md ] && grep -q '"target": "pr:147"' edc-context/review-tasks/manifest.json; then
    check "15.14a: --build --pr <number> normalizes target to pr:<number>" 1
  else
    check "15.14a: --build --pr <number> normalizes target to pr:<number>" 0
    echo "$out"
    cat edc-context/review-tasks/manifest.json 2>/dev/null || true
  fi
  if grep -qx "147" gh-args.txt; then
    check "15.14b: --pr <number> passes number to gh pr diff" 1
  else
    check "15.14b: --pr <number> passes number to gh pr diff" 0
    cat gh-args.txt 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_T15M"
)

# ── 15.15: branch reviews use merge-base diff, not snapshot diff ───────────
TMPDIR_T15N=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15N"
  git checkout -q -b feature
  echo "branch" > branch-only.ts
  git add branch-only.ts
  git commit -q -m "branch change"
  git checkout -q master
  echo "main" > main-only.ts
  git add main-only.ts
  git commit -q -m "main change"

  out=$("$BASH_BIN" "$SCRIPT" --build feature --base master --ignore-context 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] \
     && grep -q 'branch-only.ts' edc-context/review-tasks/ignore-context.md \
     && ! grep -q 'main-only.ts' edc-context/review-tasks/ignore-context.md; then
    check "15.15: branch review excludes base-side changes after branch point" 1
  else
    check "15.15: branch review excludes base-side changes after branch point" 0
    echo "$out"
    cat edc-context/review-tasks/ignore-context.md 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_T15N"
)

# ── 15.16: changed paths are JSON escaped in review-task manifests ─────────
TMPDIR_T15O=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15O"
  printf 'weird\n' > 'weird"name.txt'
  git add 'weird"name.txt'
  git commit -q -m "add weird path"

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 --ignore-context 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] \
     && jq -e . edc-context/review-tasks/manifest.json >/dev/null \
     && jq -e '.modules[0].files[] == "weird\"name.txt"' edc-context/review-tasks/manifest.json >/dev/null; then
    check "15.16: review-task manifest escapes quote-containing paths" 1
  else
    check "15.16: review-task manifest escapes quote-containing paths" 0
    echo "$out"
    cat edc-context/review-tasks/manifest.json 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_T15O"
)

# ── 15.17: explicit include policy snapshots dirty tracked files ──────────
TMPDIR_T15Q=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15Q"
  write_minimal_context
  mkdir -p src
  echo "original" > src/dirty.ts
  git add src edc-context
  git commit -q -m "add tracked source"
  head=$(git rev-parse HEAD)
  write_manifest edc-context/manifest.json "$head" "warn-allow" '[
    {"name":"core","doc":"edc-context/modules/core.md","priority":100,"match":{"prefixes":["src/"]}}
  ]'
  echo "dirty" > src/dirty.ts

  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD --include-working-tree 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] \
     && [ -f edc-context/review-tasks/core.md ] \
     && grep -q 'src/dirty.ts' edc-context/review-tasks/core.md; then
    check "15.17: include-working-tree snapshots dirty tracked files into review tasks" 1
  else
    check "15.17: include-working-tree snapshots dirty tracked files into review tasks" 0
    echo "$out"
    cat edc-context/review-tasks/core.md 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_T15Q"
)

# ── 15.18: no committed or dirty tracked changes gives actionable error ───
TMPDIR_T15R=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15R"
  set +e
  out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD --ignore-context 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] \
     && echo "$out" | grep -q 'no changed files found for target:' \
     && echo "$out" | grep -q 'edc review full --agent <agent>'; then
    check "15.18: no-change committed review suggests full review" 1
  else
    check "15.18: no-change committed review suggests full review" 0
    echo "$out"
  fi
  rm -rf "$TMPDIR_T15R"
)

# ── 15.19: review auto-mode does not use build output as IPC ──────────────
if ! grep -q 'bash "$0" --build' "$SCRIPT" \
   && ! grep -q 'grep -q "\^Review tasks ready"' "$SCRIPT" \
   && grep -q 'find "$EDC_REVIEW_TASKS_DIR"' "$SCRIPT"; then
  check "15.19: review auto-mode derives task files without shell/log IPC" 1
else
  check "15.19: review auto-mode derives task files without shell/log IPC" 0
fi

# ── 15.20: gh PR diff failures surface stderr ──────────────────────────────
TMPDIR_T15P=$(mktemp -d)
(
  setup_repo "$TMPDIR_T15P"
  mkdir -p fake-bin
  cat > fake-bin/gh <<'EOF'
#!/usr/bin/env bash
echo "gh auth failed: login required" >&2
exit 2
EOF
  chmod +x fake-bin/gh
  set +e
  PATH="$PWD/fake-bin:$PATH" out=$("$BASH_BIN" "$SCRIPT" --build pr:147 --committed-only --ignore-context 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && echo "$out" | grep -q "gh pr diff failed" && echo "$out" | grep -q "gh auth failed"; then
    check "15.20: gh PR diff failure reports gh stderr" 1
  else
    check "15.20: gh PR diff failure reports gh stderr" 0
    echo "$out"
  fi
  rm -rf "$TMPDIR_T15P"
)

cd "$ORIG_DIR"
check_summary "T15"
