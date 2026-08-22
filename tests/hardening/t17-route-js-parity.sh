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
cp plugins/edc/hooks/lib/runtime-manifest.mjs "$STAGE/plugins/edc/hooks/lib/"
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

cat > "$TMP/bad-glob-manifest.json" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    { "name": "exact-mod", "priority": 20, "match": { "exactFiles": ["src/exact.ts"] } },
    { "name": "prefix-mod", "priority": 10, "match": { "prefixes": ["src/"] } },
    { "name": "bad-glob", "priority": 10, "match": { "globs": ["bad/[z-a]"] } }
  ]
}
EOF
printf '%s\n%s\n' "bad/y" "src/other.ts" > "$TMP/bad-glob-paths.txt"
node plugins/edc/hooks/lib/classify-cli.mjs "$TMP/bad-glob-manifest.json" < "$TMP/bad-glob-paths.txt" > "$TMP/bad-glob.stdout" 2> "$TMP/bad-glob.stderr"
bad_glob_rc=$?
bad_glob_stderr_lines=$(wc -l < "$TMP/bad-glob.stderr" | tr -d ' ')
if [ "$bad_glob_rc" -ne 0 ] \
  && [ ! -s "$TMP/bad-glob.stdout" ] \
  && [ "$bad_glob_stderr_lines" = "1" ] \
  && grep -Fq 'classify-cli: invalid glob pattern "bad/[z-a]"' "$TMP/bad-glob.stderr" \
  && ! grep -Eq 'SyntaxError| at ' "$TMP/bad-glob.stderr"; then
  say_pass "malformed manifest glob returns bounded classify-cli diagnostic"
else
  say_fail "malformed manifest glob diagnostic" "rc=$bad_glob_rc stdout=$(cat "$TMP/bad-glob.stdout") stderr=$(tr '\n' '|' < "$TMP/bad-glob.stderr")"
fi

printf '%s\n' "src/exact.ts" | node plugins/edc/hooks/lib/classify-cli.mjs "$TMP/bad-glob-manifest.json" > "$TMP/bad-glob-exact.stdout" 2> "$TMP/bad-glob-exact.stderr"
bad_glob_exact_rc=$?
bad_glob_exact_stderr_lines=$(wc -l < "$TMP/bad-glob-exact.stderr" | tr -d ' ')
if [ "$bad_glob_exact_rc" -ne 0 ] \
  && [ ! -s "$TMP/bad-glob-exact.stdout" ] \
  && [ "$bad_glob_exact_stderr_lines" = "1" ] \
  && grep -Fq 'classify-cli: invalid glob pattern "bad/[z-a]"' "$TMP/bad-glob-exact.stderr" \
  && ! grep -Eq 'SyntaxError| at ' "$TMP/bad-glob-exact.stderr"; then
  say_pass "malformed manifest glob fails before exact/prefix routing wins"
else
  say_fail "malformed manifest glob before exact/prefix diagnostic" "rc=$bad_glob_exact_rc stdout=$(cat "$TMP/bad-glob-exact.stdout") stderr=$(tr '\n' '|' < "$TMP/bad-glob-exact.stderr")"
fi

: | node plugins/edc/hooks/lib/classify-cli.mjs "$TMP/bad-glob-manifest.json" > "$TMP/bad-glob-empty.stdout" 2> "$TMP/bad-glob-empty.stderr"
bad_glob_empty_rc=$?
bad_glob_empty_stderr_lines=$(wc -l < "$TMP/bad-glob-empty.stderr" | tr -d ' ')
if [ "$bad_glob_empty_rc" -ne 0 ] \
  && [ ! -s "$TMP/bad-glob-empty.stdout" ] \
  && [ "$bad_glob_empty_stderr_lines" = "1" ] \
  && grep -Fq 'classify-cli: invalid glob pattern "bad/[z-a]"' "$TMP/bad-glob-empty.stderr" \
  && ! grep -Eq 'SyntaxError| at ' "$TMP/bad-glob-empty.stderr"; then
  say_pass "malformed manifest glob fails before empty stdin succeeds"
else
  say_fail "malformed manifest glob empty stdin diagnostic" "rc=$bad_glob_empty_rc stdout=$(cat "$TMP/bad-glob-empty.stdout") stderr=$(tr '\n' '|' < "$TMP/bad-glob-empty.stderr")"
fi

printf '%s\n' "bad/y" | node plugins/edc/hooks/lib/classify-cli.mjs --ignore 'bad/[z-a]' "$TMP/manifest.json" > "$TMP/bad-ignore.stdout" 2> "$TMP/bad-ignore.stderr"
bad_ignore_rc=$?
bad_ignore_stderr_lines=$(wc -l < "$TMP/bad-ignore.stderr" | tr -d ' ')
if [ "$bad_ignore_rc" -ne 0 ] \
  && [ ! -s "$TMP/bad-ignore.stdout" ] \
  && [ "$bad_ignore_stderr_lines" = "1" ] \
  && grep -Fq 'classify-cli: invalid glob pattern "bad/[z-a]"' "$TMP/bad-ignore.stderr" \
  && ! grep -Eq 'SyntaxError| at ' "$TMP/bad-ignore.stderr"; then
  say_pass "malformed --ignore glob returns bounded classify-cli diagnostic"
else
  say_fail "malformed --ignore glob diagnostic" "rc=$bad_ignore_rc stdout=$(cat "$TMP/bad-ignore.stdout") stderr=$(tr '\n' '|' < "$TMP/bad-ignore.stderr")"
fi

echo
echo "t17-route-js-parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
