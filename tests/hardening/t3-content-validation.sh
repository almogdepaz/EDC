#!/usr/bin/env bash
# Task 3 smoke test: content validation (stub-fraud defense)
# Run from repo root: bash tests/hardening/t3-content-validation.sh
set -euo pipefail

SCRIPT="scripts/edc-review.sh"
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
HEAD=$(git rev-parse HEAD)

# ── 3a: assert_context_fresh rejects index.md without ## headings ─────────────
mkdir -p .context
cat > .context/manifest.json <<EOF
{"schemaVersion": 2, "sourceCommit": "$HEAD", "modules": []}
EOF
printf 'plain text with no headings at all\n' > .context/index.md

result=0
bash "$(cd - > /dev/null && pwd)/$SCRIPT" --check-context 2>/tmp/t3-stderr.txt || result=$?
if [ "$result" -ne 0 ] && grep -q "no '## ' headings" /tmp/t3-stderr.txt; then
  echo "PASS: index.md without ## headings rejected with descriptive error"
else
  echo "FAIL: expected rejection of index.md without headings, got exit $result"
  cat /tmp/t3-stderr.txt
  exit 1
fi

# ── 3b: consolidate rejects report without ## headings ────────────────────────
printf '## Module Map\nlegit context\n' > .context/index.md

mkdir -p review-tasks
cat > review-tasks/manifest.json <<'MANIFEST'
{
  "target": "HEAD",
  "baseline": "",
  "head": "HEAD",
  "modules": [
    { "name": "foo", "doc": ".context/modules/foo.md", "files": ["foo/bar.js"] }
  ]
}
MANIFEST
sed -i.bak "s/\"head\": \"HEAD\"/\"head\": \"$HEAD\"/" review-tasks/manifest.json

printf 'just plain text with zero markdown structure\n' > review-tasks/report-foo.md

ORIG_DIR="$(cd - > /dev/null && pwd)"
result=0
bash "$ORIG_DIR/$SCRIPT" --consolidate 2>/tmp/t3-stderr.txt || result=$?
if [ "$result" -ne 0 ] && grep -q "no '## ' headings" /tmp/t3-stderr.txt; then
  echo "PASS: --consolidate rejects report without ## headings with descriptive error"
else
  echo "FAIL: expected --consolidate to reject report without headings, got exit $result"
  cat /tmp/t3-stderr.txt
  exit 1
fi

# ── 3c: valid report passes consolidate ───────────────────────────────────────
printf '## Summary\n\nfindings here\n' > review-tasks/report-foo.md

result=0
bash "$ORIG_DIR/$SCRIPT" --consolidate 2>/tmp/t3-stderr.txt || result=$?
if [ "$result" -eq 0 ]; then
  echo "PASS: valid report passes --consolidate (exit 0)"
else
  echo "FAIL: valid report rejected by --consolidate (exit $result)"
  cat /tmp/t3-stderr.txt
  exit 1
fi

# ── 3d: manifest declares v2 schema ───────────────────────────────────────────
if jq -e '.schemaVersion == 2' .context/manifest.json > /dev/null; then
  echo "PASS: .context/manifest.json schemaVersion == 2"
else
  echo "FAIL: .context/manifest.json schemaVersion != 2"
  cat .context/manifest.json
  exit 1
fi

echo ""
echo "All T3 checks passed."
