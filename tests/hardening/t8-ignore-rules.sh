#!/usr/bin/env bash
# Task 8 smoke test: ignore rules for review file selection
# Run from repo root: bash tests/hardening/t8-ignore-rules.sh
set -euo pipefail

SCRIPT="plugins/edc/scripts/edc-review.sh"
ORIG_DIR="$(pwd)"
TMPDIR_T8=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T8"' EXIT
T8_BUILD_OUT="$TMPDIR_T8/build-out.txt"

echo "=== T8: Ignore rules ==="

mkdir "$TMPDIR_T8/repo"
cd "$TMPDIR_T8/repo"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
git init -q
git config user.email "test@test.com"
git config user.name "Test"
git config commit.gpgsign false

mkdir -p src generated
printf 'one\n' > src/keep.txt
printf 'one\n' > generated/skip.txt
printf 'generated/**\n' > .edcignore
git add .edcignore src/keep.txt generated/skip.txt
git commit -q -m "init"

printf 'two\n' > src/keep.txt
printf 'two\n' > generated/skip.txt
git add src/keep.txt generated/skip.txt
git commit -q -m "change files"
HEAD_SHA=$(git rev-parse HEAD)
node "$ORIG_DIR/plugins/edc/hooks/lib/runtime-manifest.mjs" install "$PWD" "$ORIG_DIR/plugins/edc" >/dev/null

mkdir -p edc-context
cat > edc-context/manifest.json <<EOF
{"schemaVersion":2,"sourceCommit":"$HEAD_SHA","modules":[]}
EOF
printf '## Module Map\n\n- root\n' > edc-context/index.md

# ── 8a: .edcignore filters files when no --ignore flag is passed ──────────────
bash "$ORIG_DIR/$SCRIPT" --build HEAD --base HEAD~1 > "$T8_BUILD_OUT"

if grep -q '"src/keep.txt"' edc-context/review-tasks/manifest.json \
  && ! grep -q '"generated/skip.txt"' edc-context/review-tasks/manifest.json; then
  echo "PASS: .edcignore excludes matching files from review tasks"
else
  echo "FAIL: .edcignore did not filter manifest as expected"
  cat edc-context/review-tasks/manifest.json
  exit 1
fi

# ── 8b: --ignore overrides .edcignore for the run ─────────────────────────────
bash "$ORIG_DIR/$SCRIPT" --build HEAD --base HEAD~1 --ignore src/** > "$T8_BUILD_OUT"

if grep -q '"generated/skip.txt"' edc-context/review-tasks/manifest.json \
  && ! grep -q '"src/keep.txt"' edc-context/review-tasks/manifest.json; then
  echo "PASS: --ignore overrides .edcignore"
else
  echo "FAIL: --ignore did not override .edcignore as expected"
  cat edc-context/review-tasks/manifest.json
  exit 1
fi

echo ""
echo "All T8 checks passed."
