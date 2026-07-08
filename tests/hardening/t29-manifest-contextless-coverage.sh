#!/usr/bin/env bash
# t29-manifest-contextless-coverage: pin deterministic manifest accounting for
# context modules, contextless coverage, uncovered paths, ambiguous paths, and
# ignored paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BASH_BIN="${BASH_BIN:-bash}"

# shellcheck source=lib/check.sh
. "$(dirname "$0")/lib/check.sh"
check_init --file
trap 'check_cleanup' EXIT

SCRIPT="$ROOT/plugins/edc/scripts/edc-manifest.sh"
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
  mkdir -p src docs generated
  printf 'code\n' > src/main.ts
  printf 'docs\n' > docs/guide.md
  printf 'pkg\n' > package.json
  printf 'orphan\n' > orphan.ts
  printf 'ignored\n' > generated/out.ts
  git add .
  git commit -q -m init
}

write_partial_manifest() {
  cat > partial.json <<'JSON'
{
  "schemaVersion": 2,
  "edcVersion": "1.1.1",
  "repoContextFile": "edc-context/index.md",
  "reports": {"issues": "edc-context/reports/issues.md", "complexity": "edc-context/reports/complexity.md"},
  "build": {"buildInfoFile": "edc-context/build/build.json"},
  "policy": {"defaultMode": "advisory", "unmatchedPathPolicy": "warn-allow"},
  "modules": [
    {"name": "core", "doc": "edc-context/modules/core.md", "priority": 100, "match": {"prefixes": ["src/"]}}
  ],
  "contextless": {
    "entries": [
      {"id": "supporting-docs", "globs": ["docs/**"], "reason": "supporting docs", "reviewPolicy": "account-only"}
    ]
  },
  "unmapped": {"allowedGlobs": ["package.json"]}
}
JSON
}

REPO="$TMP/repo"
setup_repo "$REPO"
write_partial_manifest
out=$("$BASH_BIN" "$SCRIPT" --ignore 'generated/**' < partial.json)
printf '%s\n' "$out" > manifest.json

if jq -e '
  .coverage.contextMappedFileCount == 1 and
  .coverage.contextlessFileCount == 2 and
  .coverage.uncoveredFileCount == 1 and
  .coverage.ambiguousPathCount == 0 and
  .coverage.ignoredFileCount == 1 and
  .coverage.mappedFileCount == 1 and
  .coverage.unmappedFileCount == 3
' manifest.json >/dev/null; then
  check "29.1: manifest writes context/contextless/uncovered/ignored counters plus legacy aliases" 1
else
  check "29.1: manifest writes context/contextless/uncovered/ignored counters plus legacy aliases" 0
  jq '.coverage' manifest.json
fi

if jq -e '.coverage.ignoreSource == "flags" and .coverage.ignoreGlobs == ["generated/**"]' manifest.json >/dev/null; then
  check "29.2: manifest records ignore provenance for --ignore flags" 1
else
  check "29.2: manifest records ignore provenance for --ignore flags" 0
  jq '.coverage' manifest.json
fi

NO_IGNORE="$TMP/no-ignore"
setup_repo "$NO_IGNORE"
write_partial_manifest
out=$("$BASH_BIN" "$SCRIPT" < partial.json)
printf '%s\n' "$out" > manifest.json
if jq -e '.coverage.ignoreSource == "none" and .coverage.ignoreGlobs == []' manifest.json >/dev/null; then
  check "29.3: manifest records empty ignoreGlobs when no ignore rules exist" 1
else
  check "29.3: manifest records empty ignoreGlobs when no ignore rules exist" 0
  jq '.coverage' manifest.json
fi

BAD="$TMP/bad-policy"
setup_repo "$BAD"
cat > bad.json <<'JSON'
{
  "schemaVersion": 2,
  "edcVersion": "1.1.1",
  "repoContextFile": "edc-context/index.md",
  "reports": {"issues": "edc-context/reports/issues.md", "complexity": "edc-context/reports/complexity.md"},
  "build": {"buildInfoFile": "edc-context/build/build.json"},
  "policy": {"defaultMode": "advisory", "unmatchedPathPolicy": "warn-allow"},
  "modules": [
    {"name": "core", "doc": "edc-context/modules/core.md", "priority": 100, "match": {"prefixes": ["src/"]}}
  ],
  "contextless": {"entries": [{"id": "bad", "globs": ["docs/**"], "reason": "bad", "reviewPolicy": "full-review"}]},
  "unmapped": {"allowedGlobs": []}
}
JSON
set +e
bad_out=$("$BASH_BIN" "$SCRIPT" < bad.json 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$bad_out" | grep -q 'contextless.entries.*reviewPolicy'; then
  check "29.4: manifest rejects invalid contextless reviewPolicy" 1
else
  check "29.4: manifest rejects invalid contextless reviewPolicy" 0
  echo "$bad_out"
fi

cd "$ROOT"
check_summary "T29"
