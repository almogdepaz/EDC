#!/usr/bin/env bash
# Task 3 smoke test: content validation (stub-fraud defense)
# Run from repo root: bash tests/hardening/t3-content-validation.sh
set -euo pipefail

SCRIPT="plugins/edc/scripts/edc-review.sh"
ORIG_DIR="$(pwd)"
TMPDIR_T3=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T3"' EXIT

echo "=== T3: Content validation (stub-fraud defense) ==="

# Set up a minimal fake git repo in TMPDIR_T3
cd "$TMPDIR_T3"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
git init -q
git config user.email "test@test.com"
git config user.name "Test"
git config commit.gpgsign false
touch dummy.txt && git add dummy.txt && git commit -q -m "init"
node "$ORIG_DIR/plugins/edc/hooks/lib/runtime-manifest.mjs" install "$TMPDIR_T3" "$ORIG_DIR/plugins/edc" >/dev/null
HEAD=$(git rev-parse HEAD)

# ── 3a: assert_context_fresh rejects index.md without ## headings ─────────────
mkdir -p edc-context
cat > edc-context/manifest.json <<EOF
{"schemaVersion": 2, "sourceCommit": "$HEAD", "modules": []}
EOF
printf 'plain text with no headings at all\n' > edc-context/index.md

result=0
bash "$ORIG_DIR/$SCRIPT" --check-context 2>"$TMPDIR_T3/stderr.txt" || result=$?
if [ "$result" -ne 0 ] && grep -q "no '## ' headings" "$TMPDIR_T3/stderr.txt"; then
  echo "PASS: index.md without ## headings rejected with descriptive error"
else
  echo "FAIL: expected rejection of index.md without headings, got exit $result"
  cat "$TMPDIR_T3/stderr.txt"
  exit 1
fi

# ── 3b: consolidate rejects an empty intermediate report ─────────────────────
printf '## Module Map\nlegit context\n' > edc-context/index.md

mkdir -p edc-context/review-tasks
cat > edc-context/review-tasks/manifest.json <<'MANIFEST'
{
  "target": "HEAD",
  "baseline": "",
  "head": "HEAD",
  "modules": [
    { "name": "foo", "doc": "edc-context/modules/foo.md", "files": ["foo/bar.js"] }
  ]
}
MANIFEST
sed -i.bak "s/\"head\": \"HEAD\"/\"head\": \"$HEAD\"/" edc-context/review-tasks/manifest.json

printf '   \n\n' > edc-context/review-tasks/report-foo.md

result=0
bash "$ORIG_DIR/$SCRIPT" --consolidate 2>"$TMPDIR_T3/stderr.txt" || result=$?
if [ "$result" -ne 0 ] && grep -q "has no substantive content" "$TMPDIR_T3/stderr.txt"; then
  echo "PASS: --consolidate rejects an empty intermediate report"
else
  echo "FAIL: expected --consolidate to reject an empty report, got exit $result"
  cat "$TMPDIR_T3/stderr.txt"
  exit 1
fi

# ── 3c: consolidate accepts substantive prose without canonical headings ─────
printf 'reviewed the assigned scope; no security findings were identified.\n' > edc-context/review-tasks/report-foo.md

result=0
bash "$ORIG_DIR/$SCRIPT" --consolidate 2>"$TMPDIR_T3/stderr.txt" || result=$?
if [ "$result" -eq 0 ] && grep -Fqx "## Module: \`foo\`" review-HEAD.md; then
  echo "PASS: --consolidate accepts substantive noncanonical module prose"
else
  echo "FAIL: expected --consolidate to accept substantive prose, got exit $result"
  cat "$TMPDIR_T3/stderr.txt"
  exit 1
fi

# ── 3d: valid report passes consolidate ───────────────────────────────────────
printf '## Findings\n\nfindings here\n' > edc-context/review-tasks/report-foo.md

result=0
bash "$ORIG_DIR/$SCRIPT" --consolidate 2>"$TMPDIR_T3/stderr.txt" || result=$?
if [ "$result" -eq 0 ]; then
  echo "PASS: valid report passes --consolidate (exit 0)"
else
  echo "FAIL: valid report rejected by --consolidate (exit $result)"
  cat "$TMPDIR_T3/stderr.txt"
  exit 1
fi

# ── 3e: manifest declares v2 schema ───────────────────────────────────────────
if jq -e '.schemaVersion == 2' edc-context/manifest.json > /dev/null; then
  echo "PASS: edc-context/manifest.json schemaVersion == 2"
else
  echo "FAIL: edc-context/manifest.json schemaVersion != 2"
  cat edc-context/manifest.json
  exit 1
fi

echo ""
echo "All T3 checks passed."
