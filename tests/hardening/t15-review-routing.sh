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

# Counters live in temp files so subshell-scoped checks aggregate correctly.
PASS_FILE=$(mktemp)
FAIL_FILE=$(mktemp)
echo 0 > "$PASS_FILE"
echo 0 > "$FAIL_FILE"
trap 'rm -f "$PASS_FILE" "$FAIL_FILE"' EXIT

check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    echo $(( $(cat "$PASS_FILE") + 1 )) > "$PASS_FILE"
    echo "PASS: $desc"
  else
    echo $(( $(cat "$FAIL_FILE") + 1 )) > "$FAIL_FILE"
    echo "FAIL: $desc"
  fi
}

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
trap 'rm -rf "$TMPDIR_T15A"' EXIT
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

  out=$(bash "$SCRIPT" --build HEAD --base HEAD~1 2>&1) || rc=$?

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

  out=$(bash "$SCRIPT" --build HEAD --base HEAD~1 2>&1) || rc=$?
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

  out=$(bash "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
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

  out=$(bash "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f edc-context/review-tasks/unmapped.md ]; then
    check "15.4a: README.md (allowedGlobs) groups under 'unmapped'" 1
  else
    check "15.4a: README.md (allowedGlobs) groups under 'unmapped'" 0
  fi
  # README is in allowedGlobs — should NOT trigger a WARNING line at all.
  if echo "$out" | grep -qE '^WARNING:.*not mapped'; then
    check "15.4b: allowedGlobs match suppresses WARNING" 0
    echo "$out"
  else
    check "15.4b: allowedGlobs match suppresses WARNING" 1
  fi
  rm -rf "$TMPDIR_T15D"
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
  out=$(bash "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
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
  out=$(bash "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
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
# explicitly: the only synthetic name allowed is "unmapped".
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

  out=$(bash "$SCRIPT" --build HEAD --base HEAD~1 2>&1) || true

  # Every name in edc-context/review-tasks/manifest.json must either exist in
  # edc-context/manifest.json or be the literal "unmapped".
  context_modules=$(jq -r '.modules[].name' edc-context/manifest.json)
  review_modules=$(jq -r '.modules[].name' edc-context/review-tasks/manifest.json)
  bad_count=0
  for m in $review_modules; do
    [ "$m" = "unmapped" ] && continue
    if ! echo "$context_modules" | grep -qx "$m"; then
      bad_count=$((bad_count + 1))
      echo "  unexpected synthetic module: $m"
    fi
  done

  if [ "$bad_count" -eq 0 ]; then
    check "15.7: review-tasks modules are real or 'unmapped' only" 1
  else
    check "15.7: review-tasks modules are real or 'unmapped' only" 0
  fi
  rm -rf "$TMPDIR_T15G"
)

cd "$ORIG_DIR"
PASS=$(cat "$PASS_FILE")
FAIL=$(cat "$FAIL_FILE")
echo
echo "=== T15 result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
