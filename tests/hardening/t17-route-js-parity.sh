#!/usr/bin/env bash
# t17-route-js-parity: verify the in-process JS router (routeFileSync) matches
# the shell router (plugins/edc/scripts/edc-route.sh) for representative cases,
# AND that it works without edc-route.sh on disk (no shell exec on the hot path).
#
# Motivated by the audit finding that buildToolCallInjection used to spawn
# edc-route.sh on every Edit/Write/Bash tool call. Routing is now pure JS;
# this test pins that contract.
set -uo pipefail

PASS=0
FAIL=0
say_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
say_fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a manifest that exercises all 3 tiers + priority + ambiguity.
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
  ]
}
EOF

# Each line: "<file>|<expected-module-or-empty>"
cases=(
  "src/exact.ts|exact-mod"          # T1 exact beats T2 prefix regardless of priority
  "src/sub/foo.ts|long-pfx"         # T2 longest prefix wins (even with lower prio)
  "src/other.ts|short-pfx"          # T2 only short prefix matches
  "docs/a/b.md|glob-mod"            # T3 glob
  "amb/x.ts|"                       # T2 tied top-priority -> ambiguous -> null
  "no/match.zz|"                    # nothing matches
)

# 17.1: parity with edc-route.sh on every case
parity_ok=1
for case in "${cases[@]}"; do
  file="${case%%|*}"
  want="${case##*|}"

  set +e
  got_shell=$(bash plugins/edc/scripts/edc-route.sh "$TMP/manifest.json" "$file" 2>/dev/null)
  set -e

  got_js=$(MANIFEST="$TMP/manifest.json" FILE="$file" node --input-type=module -e '
    const { routeFileSync } = await import("./plugins/edc/hooks/lib/route.mjs");
    const fs = await import("node:fs");
    const m = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf-8"));
    const r = routeFileSync(m, process.env.FILE);
    process.stdout.write(r || "");
  ' 2>&1)

  if [ "$got_shell" != "$got_js" ]; then
    parity_ok=0
    echo "  divergence on $file: shell=\"$got_shell\" js=\"$got_js\""
    continue
  fi
  if [ "$got_js" != "$want" ]; then
    parity_ok=0
    echo "  wrong answer on $file: got=\"$got_js\" want=\"$want\""
  fi
done

if [ "$parity_ok" -eq 1 ]; then
  say_pass "routeFileSync matches edc-route.sh on all parity cases"
else
  say_fail "routeFileSync vs edc-route.sh parity"
fi

# 17.2: routing works without edc-route.sh on disk (no shell exec).
# Stage a copy of the plugin tree without scripts/edc-route.sh, then route.
STAGE="$TMP/stage"
mkdir -p "$STAGE/plugins/edc/hooks/lib"
cp plugins/edc/hooks/lib/route.mjs   "$STAGE/plugins/edc/hooks/lib/"
cp plugins/edc/hooks/lib/paths.mjs   "$STAGE/plugins/edc/hooks/lib/"
cp "$TMP/manifest.json" "$STAGE/manifest.json"
# Deliberately do NOT copy plugins/edc/scripts/edc-route.sh.

no_shell=$(node --input-type=module -e '
  const { routeFileSync } = await import("'"$STAGE"'/plugins/edc/hooks/lib/route.mjs");
  const fs = await import("node:fs");
  const m = JSON.parse(fs.readFileSync("'"$STAGE"'/manifest.json", "utf-8"));
  const r = routeFileSync(m, "src/sub/foo.ts");
  process.stdout.write(r || "MISS");
' 2>&1)

if [ "$no_shell" = "long-pfx" ]; then
  say_pass "routeFileSync works without edc-route.sh on disk"
else
  say_fail "routeFileSync without edc-route.sh" "got: $no_shell"
fi

echo
echo "t17-route-js-parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
