#!/usr/bin/env bash
# t28-contextless-classification: pin the contextless coverage contract.
#
# Contextless paths are deterministic coverage/accounting, not fake human
# modules. The shared batch classifier must return exactly one state for each
# path and doctor must require docs only for real context modules.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

resolve_bash4() {
  local candidate
  for candidate in "${EDC_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)" /bin/bash; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    if "$candidate" -lc '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

BASH_BIN="$(resolve_bash4)" || { echo "FAIL: bash >=4 not found"; exit 1; }
export EDC_BASH="$BASH_BIN"

# shellcheck source=lib/check.sh
. "$(dirname "$0")/lib/check.sh"
check_init --file
trap 'check_cleanup' EXIT

CLASSIFY_CLI="$ROOT/plugins/edc/hooks/lib/classify-cli.mjs"
DOCTOR="$ROOT/plugins/edc/scripts/edc-doctor.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; check_cleanup' EXIT
MANIFEST="$TMP/manifest.json"

cat > "$MANIFEST" <<'JSON'
{
  "schemaVersion": 2,
  "edcVersion": "1.1.1",
  "repoContextFile": "edc-context/index.md",
  "reports": {"issues": "edc-context/reports/issues.md", "complexity": "edc-context/reports/complexity.md"},
  "build": {"buildInfoFile": "edc-context/build/build.json"},
  "policy": {"defaultMode": "advisory", "unmatchedPathPolicy": "warn-allow"},
  "modules": [
    {"name": "exact-mod", "doc": "edc-context/modules/exact-mod.md", "priority": 10, "match": {"exactFiles": ["src/exact.ts"]}},
    {"name": "core", "doc": "edc-context/modules/core.md", "priority": 10, "match": {"prefixes": ["src/"]}},
    {"name": "amb-a", "doc": "edc-context/modules/amb-a.md", "priority": 100, "match": {"prefixes": ["amb/"]}},
    {"name": "amb-b", "doc": "edc-context/modules/amb-b.md", "priority": 100, "match": {"prefixes": ["amb/"]}},
    {"name": "scripts", "doc": "edc-context/modules/scripts.md", "priority": 10, "match": {"globs": ["scripts/*.py"]}}
  ],
  "contextless": {
    "entries": [
      {"id": "supporting-docs", "globs": ["docs/**", "README.md"], "reason": "supporting docs", "reviewPolicy": "account-only"},
      {"id": "risky-config", "globs": ["config/**"], "reason": "no durable context yet, but diff may reveal promotion need", "reviewPolicy": "promotion-check"},
      {"id": "generated-assets", "globs": ["assets/**"], "reason": "generated but risk-bearing", "reviewPolicy": "no-context-review"}
    ]
  },
  "unmapped": {"allowedGlobs": ["package.json"]}
}
JSON

classify_batch() {
  printf '%s\n' "$1" | node "$CLASSIFY_CLI" --ignore 'tmp/**' "$MANIFEST" 2>/dev/null | awk -F '\t' 'NR == 1 {print $2}'
}

classify_js() {
  MANIFEST="$MANIFEST" FILE="$1" node --input-type=module -e '
    const { classifyPathSync } = await import("./plugins/edc/hooks/lib/route.mjs");
    const fs = await import("node:fs");
    const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf-8"));
    process.stdout.write(classifyPathSync(manifest, process.env.FILE, ["tmp/**"]));
  ' 2>/dev/null
}

cases=(
  "tmp/cache.bin|ignored"
  "src/exact.ts|context-module:exact-mod"
  "src/other.ts|context-module:core"
  "docs/guide/setup.md|contextless:supporting-docs:account-only"
  "config/prod.yml|contextless:risky-config:promotion-check"
  "assets/logo.png|contextless:generated-assets:no-context-review"
  "package.json|contextless:legacy-unmapped:account-only"
  "scripts/tool.py|context-module:scripts"
  "scripts/nested/tool.py|uncovered"
  "orphan.ts|uncovered"
  "amb/file.ts|ambiguous"
)

all_ok=1
for case in "${cases[@]}"; do
  file="${case%%|*}"
  want="${case##*|}"
  got="$(classify_batch "$file")" || got=""
  if [ "$got" != "$want" ]; then
    all_ok=0
    echo "  batch $file: got '$got', want '$want'"
  fi
  got_js="$(classify_js "$file")" || got_js=""
  if [ "$got_js" != "$want" ]; then
    all_ok=0
    echo "  js $file: got '$got_js', want '$want'"
  fi
  if [ "$got" != "$got_js" ]; then
    all_ok=0
    echo "  parity $file: batch '$got' vs js '$got_js'"
  fi
done

check "28.1: batch/js classifier returns exact context states" "$all_ok"

setup_doctor_repo() {
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
  mkdir -p src docs edc-context/modules edc-context/reports edc-context/build
  printf 'code\n' > src/main.ts
  printf 'docs\n' > docs/guide.md
  printf '<!-- t28 -->\n# Index\n\n## Route by path/task\n' > edc-context/index.md
  printf '<!-- t28 -->\n# Core\n\n## Scope\n' > edc-context/modules/core.md
  printf '## Known Issues\n' > edc-context/reports/issues.md
  printf '## Summary\n' > edc-context/reports/complexity.md
  printf '{}\n' > edc-context/build/build.json
  printf '# Agent Instructions\n\nThis repo ships deep architectural context generated by EDC.\n\nSee [`edc-context/index.md`](edc-context/index.md).\nSee [`edc-context/manifest.json`](edc-context/manifest.json).\n' > AGENTS.md
  cat > edc-context/manifest.json <<'JSON'
{
  "schemaVersion": 2,
  "edcVersion": "1.1.1",
  "sourceCommit": "dummy",
  "repoContextFile": "edc-context/index.md",
  "reports": {"issues": "edc-context/reports/issues.md", "complexity": "edc-context/reports/complexity.md"},
  "build": {"buildInfoFile": "edc-context/build/build.json"},
  "policy": {"defaultMode": "advisory", "unmatchedPathPolicy": "warn-allow"},
  "modules": [
    {"name": "core", "doc": "edc-context/modules/core.md", "priority": 100, "match": {"prefixes": ["src/"]}}
  ],
  "contextless": {
    "entries": [
      {"id": "supporting-docs", "globs": ["docs/**", "AGENTS.md", "edc-context/**"], "reason": "supporting docs and generated context", "reviewPolicy": "account-only"}
    ]
  },
  "unmapped": {"allowedGlobs": []},
  "coverage": {"mappedFileCount": 0, "unmappedFileCount": 0, "ambiguousPathCount": 0}
}
JSON
  git add .
  git commit -q -m init
}

DOCTOR_REPO="$TMP/doctor-ok"
setup_doctor_repo "$DOCTOR_REPO"
out=$("$BASH_BIN" "$DOCTOR" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  check "28.2: doctor accepts contextless tracked paths without module docs" 1
else
  check "28.2: doctor accepts contextless tracked paths without module docs" 0
  echo "$out"
fi

DOCTOR_REPO="$TMP/doctor-policy-fail"
setup_doctor_repo "$DOCTOR_REPO"
jq '.policy.unmatchedPathPolicy = "fail"' edc-context/manifest.json > edc-context/manifest.json.tmp
mv edc-context/manifest.json.tmp edc-context/manifest.json
out=$("$BASH_BIN" "$DOCTOR" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  check "28.2b: doctor accepts policy.unmatchedPathPolicy=fail" 1
else
  check "28.2b: doctor accepts policy.unmatchedPathPolicy=fail" 0
  echo "$out"
fi

DOCTOR_REPO="$TMP/doctor-policy-allow"
setup_doctor_repo "$DOCTOR_REPO"
jq '.policy.unmatchedPathPolicy = "allow"' edc-context/manifest.json > edc-context/manifest.json.tmp
mv edc-context/manifest.json.tmp edc-context/manifest.json
out=$("$BASH_BIN" "$DOCTOR" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  check "28.2c: doctor accepts policy.unmatchedPathPolicy=allow" 1
else
  check "28.2c: doctor accepts policy.unmatchedPathPolicy=allow" 0
  echo "$out"
fi

DOCTOR_REPO="$TMP/doctor-uncovered"
setup_doctor_repo "$DOCTOR_REPO"
printf 'orphan\n' > orphan.ts
git add orphan.ts
git commit -q -m orphan
set +e
out=$("$BASH_BIN" "$DOCTOR" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'uncovered tracked path'; then
  check "28.3: doctor fails uncovered tracked paths" 1
else
  check "28.3: doctor fails uncovered tracked paths" 0
  echo "$out"
fi

DOCTOR_REPO="$TMP/doctor-ambiguous"
setup_doctor_repo "$DOCTOR_REPO"
jq '.modules += [{"name":"core-copy","doc":"edc-context/modules/core-copy.md","priority":100,"match":{"prefixes":["src/"]}}]' edc-context/manifest.json > edc-context/manifest.json.tmp
mv edc-context/manifest.json.tmp edc-context/manifest.json
printf '<!-- t28 -->\n# Core copy\n\n## Scope\n' > edc-context/modules/core-copy.md
git add edc-context/manifest.json edc-context/modules/core-copy.md
git commit -q -m ambiguous
set +e
out=$("$BASH_BIN" "$DOCTOR" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'ambiguous routing'; then
  check "28.4: doctor fails ambiguous tracked paths" 1
else
  check "28.4: doctor fails ambiguous tracked paths" 0
  echo "$out"
fi

cd "$ROOT"
check_summary "T28"
