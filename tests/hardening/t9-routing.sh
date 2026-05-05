#!/usr/bin/env bash
# t9-routing: pin edc-route.sh contract — exit codes, tier order, longest-prefix
# tie-break, priority tie-break, ambiguity, no-match.
set -uo pipefail

SCRIPT="plugins/edc/scripts/edc-route.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MANIFEST="$TMP/manifest.json"

PASS=0
FAIL=0

check() {
  local desc="$1" expected_rc="$2" expected_out="$3" actual_rc="$4" actual_out="$5"
  if [ "$actual_rc" = "$expected_rc" ] && [ "$actual_out" = "$expected_out" ]; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
    echo "  expected: rc=$expected_rc out='$expected_out'"
    echo "  actual:   rc=$actual_rc out='$actual_out'"
  fi
}

run_route() {
  local file="$1"
  local out rc
  out=$(bash "$SCRIPT" "$MANIFEST" "$file" 2>/dev/null)
  rc=$?
  printf '%s\t%s' "$rc" "$out"
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
result=$(run_route "scripts/edc")
check "exactFiles beats prefixes regardless of priority" 0 "exact-mod" "${result%%	*}" "${result#*	}"

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
result=$(run_route "a/b/c/file.txt")
check "longest prefix wins" 0 "long" "${result%%	*}" "${result#*	}"

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
result=$(run_route "x/y.txt")
check "priority breaks tie when prefix lengths equal" 0 "high" "${result%%	*}" "${result#*	}"

# --- Test 4: glob match (extensionless path) ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "globmod", "priority": 50, "match": {"globs": ["bin/*"]}}
  ]
}
EOF
result=$(run_route "bin/run")
check "glob matches extensionless path" 0 "globmod" "${result%%	*}" "${result#*	}"

# --- Test 5: no match → exit 1 ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "only", "priority": 50, "match": {"prefixes": ["src/"]}}
  ]
}
EOF
result=$(run_route "no/such/path.xyz")
check "no match returns exit 1 with empty stdout" 1 "" "${result%%	*}" "${result#*	}"

# --- Test 6: ambiguity (same tier, same priority, different modules) → exit 2 ---
cat > "$MANIFEST" <<'EOF'
{
  "schemaVersion": 2,
  "modules": [
    {"name": "a", "priority": 50, "match": {"exactFiles": ["dup.txt"]}},
    {"name": "b", "priority": 50, "match": {"exactFiles": ["dup.txt"]}}
  ]
}
EOF
result=$(run_route "dup.txt")
check "tied top-priority candidates → exit 2 with empty stdout" 2 "" "${result%%	*}" "${result#*	}"

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
result=$(run_route "src/lib/foo.ts")
check "prefix tier wins over glob tier even with lower priority" 0 "prefer-prefix" "${result%%	*}" "${result#*	}"

echo
echo "t9-routing: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
