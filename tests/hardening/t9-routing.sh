#!/usr/bin/env bash
# t9-routing: pin classifier routing tier order, longest-prefix tie-break,
# priority tie-break, ambiguity, no-match, and EDC glob dialect.
set -uo pipefail

SCRIPT="plugins/edc/hooks/lib/classify-cli.mjs"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MANIFEST="$TMP/manifest.json"

PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected: '$expected'"
    echo "  actual:   '$actual'"
  fi
}

classify() {
  local file="$1"
  printf '%s\n' "$file" | node "$SCRIPT" "$MANIFEST" 2>/dev/null | awk -F '\t' 'NR == 1 {print $2}'
}

# --- Test 1: exactFiles wins over prefix/glob ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "exact-mod",  "priority": 50, "match": {"exactFiles": ["scripts/edc"]}},
    {"name": "prefix-mod", "priority": 99, "match": {"prefixes": ["scripts/"]}}
  ]
}
EOF
check "exactFiles beats prefixes regardless of priority" "context-module:exact-mod" "$(classify "scripts/edc")"

# --- Test 2: longest prefix wins ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "short", "priority": 50, "match": {"prefixes": ["a/"]}},
    {"name": "long",  "priority": 50, "match": {"prefixes": ["a/b/"]}}
  ]
}
EOF
check "longest prefix wins" "context-module:long" "$(classify "a/b/c/file.txt")"

# --- Test 3: priority breaks tie at same prefix length ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "low",  "priority": 10, "match": {"prefixes": ["x/"]}},
    {"name": "high", "priority": 90, "match": {"prefixes": ["x/"]}}
  ]
}
EOF
check "priority breaks tie when prefix lengths equal" "context-module:high" "$(classify "x/y.txt")"

# --- Test 4: glob match (extensionless path) ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "globmod", "priority": 50, "match": {"globs": ["bin/*"]}}
  ]
}
EOF
check "glob matches extensionless path" "context-module:globmod" "$(classify "bin/run")"
check "single-star glob does not cross slash" "uncovered" "$(classify "bin/nested/run")"

# --- Test 5: no match ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "only", "priority": 50, "match": {"prefixes": ["src/"]}}
  ]
}
EOF
check "no match returns uncovered" "uncovered" "$(classify "no/such/path.xyz")"

# --- Test 6: ambiguity (same tier, same priority, different modules) ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "a", "priority": 50, "match": {"exactFiles": ["dup.txt"]}},
    {"name": "b", "priority": 50, "match": {"exactFiles": ["dup.txt"]}}
  ]
}
EOF
check "tied top-priority candidates return ambiguous" "ambiguous" "$(classify "dup.txt")"

# --- Test 7: tier order — prefix beats glob ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "prefer-prefix", "priority": 10, "match": {"prefixes": ["src/"]}},
    {"name": "fallback-glob", "priority": 99, "match": {"globs": ["src/**"]}}
  ]
}
EOF
check "prefix tier wins over glob tier even with lower priority" "context-module:prefer-prefix" "$(classify "src/lib/foo.ts")"

echo
echo "t9-routing: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
