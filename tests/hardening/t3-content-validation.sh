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
git init -q
git config user.email "test@test.com"
git config user.name "Test"
touch dummy.txt && git add dummy.txt && git commit -q -m "init"
HEAD=$(git rev-parse HEAD)

# ── 3a: assert_context_fresh rejects stub context.md (too small) ──────────────
mkdir -p .context
cat > .context/.meta.json <<EOF
{"lastCommit": "$HEAD", "modules": []}
EOF
printf '## Stub\nsmall content\n' > .context/context.md   # only ~20 bytes, has heading

result=0
bash "$(cd - > /dev/null && pwd)/$SCRIPT" --check-context 2>/tmp/t3-stderr.txt || result=$?
if [ "$result" -ne 0 ] && grep -q 'too small' /tmp/t3-stderr.txt; then
  echo "PASS: stub context.md (too small) rejected by check-context"
else
  echo "FAIL: expected rejection of small context.md, got exit $result"
  cat /tmp/t3-stderr.txt
  exit 1
fi

# ── 3b: assert_context_fresh rejects context.md without ## headings ───────────
python3 -c "print('x' * 600)" > .context/context.md   # ≥500 bytes, no ## heading

result=0
bash "$(cd - > /dev/null && pwd)/$SCRIPT" --check-context 2>/tmp/t3-stderr.txt || result=$?
if [ "$result" -ne 0 ] && grep -q 'no ## headings' /tmp/t3-stderr.txt; then
  echo "PASS: context.md without ## headings rejected"
else
  echo "FAIL: expected rejection of context.md without headings, got exit $result"
  cat /tmp/t3-stderr.txt
  exit 1
fi

# ── 3c: consolidate rejects stub report (too small) ──────────────────────────
# Set up valid context
python3 -c "print('## Module Map\n' + 'x' * 600)" > .context/context.md

mkdir -p review-tasks
cat > review-tasks/manifest.json <<'MANIFEST'
{
  "target": "HEAD",
  "baseline": "",
  "head": "HEAD",
  "modules": [
    { "module": "foo", "files": ["foo/bar.js"] }
  ]
}
MANIFEST
# Update manifest with real HEAD
sed -i.bak "s/\"head\": \"HEAD\"/\"head\": \"$HEAD\"/" review-tasks/manifest.json

# Write a stub report (too small)
printf 'stub\n' > review-tasks/report-foo.md

ORIG_DIR="$(cd - > /dev/null && pwd)"
result=0
bash "$ORIG_DIR/$SCRIPT" --consolidate 2>/tmp/t3-stderr.txt || result=$?
if [ "$result" -ne 0 ] && grep -q 'too small\|stub' /tmp/t3-stderr.txt; then
  echo "PASS: --consolidate rejects stub report (too small)"
else
  echo "FAIL: expected --consolidate to reject stub report, got exit $result"
  cat /tmp/t3-stderr.txt
  exit 1
fi

# ── 3d: consolidate rejects report without ## headings ────────────────────────
python3 -c "print('x' * 300)" > review-tasks/report-foo.md  # ≥200 bytes, no ##

result=0
bash "$ORIG_DIR/$SCRIPT" --consolidate 2>/tmp/t3-stderr.txt || result=$?
if [ "$result" -ne 0 ] && grep -q 'no ## headings' /tmp/t3-stderr.txt; then
  echo "PASS: --consolidate rejects report without ## headings"
else
  echo "FAIL: expected --consolidate to reject report without headings, got exit $result"
  cat /tmp/t3-stderr.txt
  exit 1
fi

# ── 3e: valid report passes consolidate ───────────────────────────────────────
python3 -c "print('## Summary\n\nThis is a valid review report with sufficient content.\n' + 'detail line\n' * 20)" > review-tasks/report-foo.md

result=0
bash "$ORIG_DIR/$SCRIPT" --consolidate 2>/tmp/t3-stderr.txt || result=$?
if [ "$result" -eq 0 ]; then
  echo "PASS: valid report passes --consolidate (exit 0)"
else
  echo "FAIL: valid report rejected by --consolidate (exit $result)"
  cat /tmp/t3-stderr.txt
  exit 1
fi

echo ""
echo "All T3 checks passed."
