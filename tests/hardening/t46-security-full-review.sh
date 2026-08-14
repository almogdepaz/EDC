#!/usr/bin/env bash
# t46-security-full-review: security full mode routes tracked repo files instead of requiring a diff.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/plugins/edc/scripts/edc-review.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '=== T46: security full review ===\n'

cd "$TMP"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
git init -q
git config user.email test@test.com
git config user.name Test
git config commit.gpgsign false
mkdir -p src docs edc-context/modules edc-context/reports
printf 'console.log("hi")\n' > src/app.ts
printf '# docs\n' > docs/usage.md
git add src/app.ts docs/usage.md
git commit -q -m init
node "$ROOT/plugins/edc/hooks/lib/runtime-manifest.mjs" install "$TMP" "$ROOT/plugins/edc" >/dev/null

printf '# Repo\n\n## Route by path/task\n' > edc-context/index.md
printf '# Core\n\n## Scope\n' > edc-context/modules/core.md
printf '## Issues\n' > edc-context/reports/issues.md
cat > edc-context/manifest.json <<EOF
{"schemaVersion":2,"sourceCommit":"$(git rev-parse HEAD)","repoContextFile":"edc-context/index.md","reports":{"issues":"edc-context/reports/issues.md","complexity":"edc-context/reports/complexity.md"},"build":{"buildInfoFile":"edc-context/build/build.json"},"policy":{"defaultMode":"advisory","unmatchedPathPolicy":"warn-allow"},"unmapped":{"allowedGlobs":[]},"modules":[{"name":"core","doc":"edc-context/modules/core.md","priority":10,"match":{"prefixes":["src/"]}}]}
EOF

set +e
bash "$SCRIPT" --build --full > "$TMP/full.out" 2> "$TMP/full.err"
rc=$?
set -e
if [ "$rc" -eq 0 ] \
  && [ -f edc-context/review-tasks/core.md ] \
  && grep -q 'src/app.ts' edc-context/review-tasks/core.md \
  && grep -q 'TASK edc-context/review-tasks/core.md' "$TMP/full.out"; then
  echo "PASS: security full mode builds module review tasks from tracked files"
else
  echo "FAIL: security full mode did not build expected tasks"
  echo "--- stdout ---"; cat "$TMP/full.out"
  echo "--- stderr ---"; cat "$TMP/full.err"
  find edc-context/review-tasks -maxdepth 1 -type f -print -exec sed -n '1,80p' {} \; 2>/dev/null || true
  exit 1
fi

node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const manifest = JSON.parse(readFileSync('edc-context/review-tasks/manifest.json', 'utf8'));
assert.equal(manifest.target, 'HEAD');
assert.equal(manifest.contextMode, 'context');
const core = manifest.modules.find((module) => module.name === 'core');
assert.ok(core);
assert.deepEqual(core.files, ['src/app.ts']);
assert.ok(!manifest.modules.some((module) => module.files.includes('edc-context/index.md')));
NODE

echo "PASS: security full mode writes review task manifest"

printf '\nAll T46 checks passed.\n'
