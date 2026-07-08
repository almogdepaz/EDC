#!/usr/bin/env bash
# t17-route-js-parity: verify the batch classifier CLI uses the same in-process
# JS classifier as direct route.mjs callers and works without shell router files.
set -uo pipefail

PASS=0
FAIL=0
say_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
say_fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/manifest.json" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    { "name": "exact-mod",  "priority": 10, "match": { "exactFiles": ["src/exact.ts"] } },
    { "name": "short-pfx",  "priority": 50, "match": { "prefixes": ["src/"] } },
    { "name": "long-pfx",   "priority": 10, "match": { "prefixes": ["src/sub/"] } },
    { "name": "glob-mod",   "priority": 10, "match": { "globs": ["docs/**/*.md"] } },
    { "name": "amb-a",      "priority": 100,"match": { "prefixes": ["amb/"] } },
    { "name": "amb-b",      "priority": 100,"match": { "prefixes": ["amb/"] } }
  ],
  "contextless": {"entries": [
    {"id":"docs","globs":["notes/**"],"reason":"docs","reviewPolicy":"account-only"}
  ]},
  "unmapped": {"allowedGlobs": ["package.json"]}
}
EOF

cases=(
  "src/exact.ts|context-module:exact-mod"
  "src/sub/foo.ts|context-module:long-pfx"
  "src/other.ts|context-module:short-pfx"
  "docs/a/b.md|context-module:glob-mod"
  "notes/todo.md|contextless:docs:account-only"
  "package.json|contextless:legacy-unmapped:account-only"
  "amb/x.ts|ambiguous"
  "no/match.zz|uncovered"
)

paths_file="$TMP/paths.txt"
: > "$paths_file"
for case in "${cases[@]}"; do
  printf '%s\n' "${case%%|*}" >> "$paths_file"
done

cli_output=$(node plugins/edc/hooks/lib/classify-cli.mjs "$TMP/manifest.json" < "$paths_file" 2>&1)
cli_ok=1
for case in "${cases[@]}"; do
  file="${case%%|*}"
  want="${case##*|}"
  got_cli=$(printf '%s\n' "$cli_output" | awk -F '\t' -v f="$file" '$1 == f {print $2; found=1} END {if (!found) exit 1}') || got_cli=""
  got_js=$(MANIFEST="$TMP/manifest.json" FILE="$file" node --input-type=module -e '
    const { classifyPathSync } = await import("./plugins/edc/hooks/lib/route.mjs");
    const fs = await import("node:fs");
    const m = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf-8"));
    process.stdout.write(classifyPathSync(m, process.env.FILE));
  ' 2>&1)

  if [ "$got_cli" != "$got_js" ] || [ "$got_cli" != "$want" ]; then
    cli_ok=0
    echo "  $file: cli='$got_cli' js='$got_js' want='$want'"
  fi
done

if [ "$cli_ok" -eq 1 ]; then
  say_pass "classify-cli.mjs matches classifyPathSync on all cases"
else
  say_fail "classify-cli.mjs parity with classifyPathSync"
fi

STAGE="$TMP/stage"
mkdir -p "$STAGE/plugins/edc/hooks/lib"
cp plugins/edc/hooks/lib/classify-cli.mjs "$STAGE/plugins/edc/hooks/lib/"
cp plugins/edc/hooks/lib/route.mjs        "$STAGE/plugins/edc/hooks/lib/"
cp plugins/edc/hooks/lib/paths.mjs        "$STAGE/plugins/edc/hooks/lib/"
cp "$TMP/manifest.json" "$STAGE/manifest.json"

no_shell=$(printf '%s\n' "src/sub/foo.ts" | node "$STAGE/plugins/edc/hooks/lib/classify-cli.mjs" "$STAGE/manifest.json" 2>&1 | awk -F '\t' 'NR == 1 {print $2}')

if [ "$no_shell" = "context-module:long-pfx" ]; then
  say_pass "classify-cli.mjs works without shell router files"
else
  say_fail "classify-cli.mjs without shell router files" "got: $no_shell"
fi

boundary_check=$(node --input-type=module -e '
  const { normalizePath } = await import("./plugins/edc/hooks/lib/route.mjs");
  const root = "/tmp/repo";
  const inRepo = normalizePath("/tmp/repo/src/app.ts", root);
  const sibling = normalizePath("/tmp/repo-other/src/app.ts", root);
  if (inRepo !== "src/app.ts") throw new Error(`in-repo normalized incorrectly: ${inRepo}`);
  if (sibling !== "/tmp/repo-other/src/app.ts") throw new Error(`sibling path was relativized: ${sibling}`);
  console.log("OK");
' 2>&1)
if [ "$boundary_check" = "OK" ]; then
  say_pass "normalizePath only relativizes paths inside project root"
else
  say_fail "normalizePath project-root boundary" "$boundary_check"
fi

echo
echo "t17-route-js-parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
