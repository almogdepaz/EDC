#!/usr/bin/env bash
# t30-review-contextless-policy: changed contextless paths follow their manifest
# reviewPolicy instead of loading fake module docs or getting silently ignored.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BASH_BIN="${BASH_BIN:-bash}"

# shellcheck source=lib/check.sh
. "$(dirname "$0")/lib/check.sh"
check_init --file
trap 'check_cleanup' EXIT

SCRIPT="$ROOT/plugins/edc/scripts/edc-review.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; check_cleanup' EXIT

setup_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cd "$dir"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git config commit.gpgsign false
  printf 'seed\n' > seed.txt
  git add seed.txt
  git commit -q -m init
}

write_context() {
  mkdir -p edc-context/modules edc-context/reports edc-context/build
  printf '<!-- t30 -->\n# Stub\n\n## Route by path/task\n' > edc-context/index.md
  printf '<!-- t30 -->\n# Core\n\n## Scope\n' > edc-context/modules/core.md
  printf '## Known Issues\n' > edc-context/reports/issues.md
  printf '## Summary\n' > edc-context/reports/complexity.md
  printf '{}\n' > edc-context/build/build.json
  head=$(git rev-parse HEAD)
  cat > edc-context/manifest.json <<JSON
{
  "schemaVersion": 2,
  "edcVersion": "1.1.1",
  "sourceCommit": "$head",
  "repoContextFile": "edc-context/index.md",
  "reports": {"issues": "edc-context/reports/issues.md", "complexity": "edc-context/reports/complexity.md"},
  "build": {"buildInfoFile": "edc-context/build/build.json"},
  "policy": {"defaultMode": "advisory", "unmatchedPathPolicy": "warn-allow"},
  "modules": [
    {"name": "core", "doc": "edc-context/modules/core.md", "priority": 100, "match": {"prefixes": ["src/"]}}
  ],
  "contextless": {
    "entries": [
      {"id": "supporting-docs", "globs": ["docs/**"], "reason": "supporting docs", "reviewPolicy": "account-only"},
      {"id": "possible-context", "globs": ["config/**"], "reason": "may reveal durable context", "reviewPolicy": "promotion-check"},
      {"id": "risk-assets", "globs": ["assets/**"], "reason": "risk-bearing generated assets", "reviewPolicy": "no-context-review"}
    ]
  },
  "unmapped": {"allowedGlobs": []},
  "coverage": {"contextMappedFileCount": 0, "contextlessFileCount": 0, "uncoveredFileCount": 0, "ambiguousPathCount": 0, "ignoredFileCount": 0}
}
JSON
}

REPO="$TMP/repo"
setup_repo "$REPO"
mkdir -p docs config assets
printf 'docs\n' > docs/guide.md
printf 'config\n' > config/app.yml
printf 'asset\n' > assets/logo.txt
git add docs config assets
git commit -q -m 'add contextless paths'
write_context

out=$("$BASH_BIN" "$SCRIPT" --build HEAD --base HEAD~1 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  check "30.1: review build accepts changed contextless paths" 1
else
  check "30.1: review build accepts changed contextless paths" 0
  echo "$out"
fi

if [ -f edc-context/review-tasks/report-contextless-supporting-docs.md ] \
   && ! echo "$out" | grep -q 'TASK .*contextless-supporting-docs.md' \
   && jq -e '.modules[] | select(.name == "contextless-supporting-docs" and .doc == "" and .type == "contextless" and .reviewPolicy == "account-only")' edc-context/review-tasks/manifest.json >/dev/null; then
  check "30.2: account-only contextless path is accounted with no spawned task" 1
else
  check "30.2: account-only contextless path is accounted with no spawned task" 0
  echo "$out"
  cat edc-context/review-tasks/manifest.json 2>/dev/null || true
  ls edc-context/review-tasks 2>/dev/null || true
fi

if echo "$out" | grep -q 'TASK .*contextless-promotion-check.md' \
   && [ -f edc-context/review-tasks/contextless-promotion-check.md ] \
   && grep -q 'promotion check only' edc-context/review-tasks/contextless-promotion-check.md \
   && grep -q 'DO NOT edit `edc-context/manifest.json`' edc-context/review-tasks/contextless-promotion-check.md \
   && jq -e '.modules[] | select(.name == "contextless-promotion-check" and .doc == "" and .type == "contextless" and .reviewPolicy == "promotion-check")' edc-context/review-tasks/manifest.json >/dev/null; then
  check "30.3: promotion-check paths get bounded no-context promotion task" 1
else
  check "30.3: promotion-check paths get bounded no-context promotion task" 0
  echo "$out"
  cat edc-context/review-tasks/contextless-promotion-check.md 2>/dev/null || true
  cat edc-context/review-tasks/manifest.json 2>/dev/null || true
fi

if echo "$out" | grep -q 'TASK .*contextless-risk-assets.md' \
   && [ -f edc-context/review-tasks/contextless-risk-assets.md ] \
   && ! grep -q 'edc-context/modules/contextless-risk-assets.md\|Read `edc-context/modules' edc-context/review-tasks/contextless-risk-assets.md \
   && jq -e '.modules[] | select(.name == "contextless-risk-assets" and .doc == "" and .type == "contextless" and .reviewPolicy == "no-context-review")' edc-context/review-tasks/manifest.json >/dev/null; then
  check "30.4: no-context-review paths get direct task without module doc" 1
else
  check "30.4: no-context-review paths get direct task without module doc" 0
  echo "$out"
  cat edc-context/review-tasks/contextless-risk-assets.md 2>/dev/null || true
  cat edc-context/review-tasks/manifest.json 2>/dev/null || true
fi

cd "$ROOT"
check_summary "T30"
