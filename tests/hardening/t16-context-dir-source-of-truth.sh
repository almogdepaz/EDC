#!/usr/bin/env bash
# t16-context-dir-source-of-truth: pin that the context directory layout
# routes through edc-paths.sh / paths.mjs, with no stray `.context/`
# literals in production shell or hook code.
#
# Skill markdown is allowed to contain literal `edc-context/` because
# agents read it as text; we just verify the literal it contains is the
# new name, not the old `.context/` one.
#
# Run from repo root: bash tests/hardening/t16-context-dir-source-of-truth.sh
set -uo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    PASS=$((PASS + 1))
    echo "PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc"
  fi
}

echo "=== T16: context dir source-of-truth ==="

# ── 16.1: edc-paths.sh exists and exports the canonical vars ────────────────
PATHS_SH="plugins/edc/scripts/edc-paths.sh"
if [ -f "$PATHS_SH" ]; then
  check "16.1a: $PATHS_SH exists" 1
else
  check "16.1a: $PATHS_SH exists" 0
fi

if [ -f "$PATHS_SH" ]; then
  if (
    set +u
    . "$PATHS_SH"
    [ "${EDC_CONTEXT_DIR:-}" = "edc-context" ] && \
    [ "${EDC_MANIFEST:-}" = "edc-context/manifest.json" ] && \
    [ "${EDC_INDEX:-}" = "edc-context/index.md" ] && \
    [ "${EDC_MODULES_DIR:-}" = "edc-context/modules" ] && \
    [ "${EDC_REPORTS_DIR:-}" = "edc-context/reports" ]
  ); then
    check "16.1b: edc-paths.sh exports canonical defaults" 1
  else
    check "16.1b: edc-paths.sh exports canonical defaults" 0
  fi
fi

# ── 16.2: paths.mjs exists with matching defaults ───────────────────────────
PATHS_MJS="plugins/edc/hooks/lib/paths.mjs"
if [ -f "$PATHS_MJS" ]; then
  check "16.2a: $PATHS_MJS exists" 1
  if grep -q 'EDC_CONTEXT_DIR = "edc-context"' "$PATHS_MJS"; then
    check "16.2b: paths.mjs declares EDC_CONTEXT_DIR = \"edc-context\"" 1
  else
    check "16.2b: paths.mjs declares EDC_CONTEXT_DIR = \"edc-context\"" 0
  fi
else
  check "16.2a: $PATHS_MJS exists" 0
fi

# ── 16.3: no production shell script under plugins/edc/scripts/ contains
#          a stray `.context/` literal ─────────────────────────────────────
stray_files=$(grep -l "\.context/" plugins/edc/scripts/*.sh 2>/dev/null || true)
if [ -z "$stray_files" ]; then
  check "16.3: no plugins/edc/scripts/*.sh contains literal '.context/'" 1
else
  check "16.3: no plugins/edc/scripts/*.sh contains literal '.context/'" 0
  echo "  offending files:"
  echo "$stray_files" | sed 's/^/    /'
fi

# ── 16.4: no hook .mjs file uses literal `.context` for routing ─────────────
stray_mjs=$(grep -l '"\.context"' plugins/edc/hooks/*.mjs plugins/edc/hooks/lib/*.mjs 2>/dev/null || true)
if [ -z "$stray_mjs" ]; then
  check "16.4: no hook .mjs uses literal '.context' for path joining" 1
else
  check "16.4: no hook .mjs uses literal '.context' for path joining" 0
  echo "$stray_mjs" | sed 's/^/    /'
fi

# ── 16.5: orchestrator scripts source edc-paths.sh ──────────────────────────
expected_sources=(
  edc-review.sh edc-clean-slate.sh edc-audit.sh edc-build.sh edc-update.sh
  edc-assert-fresh.sh edc-recover-context.sh edc-doctor.sh edc-build-plan.sh
)
missing_source=()
for s in "${expected_sources[@]}"; do
  if ! grep -q "edc-paths.sh" "plugins/edc/scripts/$s" 2>/dev/null; then
    missing_source+=("$s")
  fi
done
if [ "${#missing_source[@]}" -eq 0 ]; then
  check "16.5: all production orchestrators reference edc-paths.sh" 1
else
  check "16.5: all production orchestrators reference edc-paths.sh" 0
  echo "  missing reference in: ${missing_source[*]}"
fi

# ── 16.6: hooks lib import paths.mjs ────────────────────────────────────────
if grep -q 'from "./paths.mjs"' plugins/edc/hooks/lib/route.mjs; then
  check "16.6: hooks/lib/route.mjs imports from ./paths.mjs" 1
else
  check "16.6: hooks/lib/route.mjs imports from ./paths.mjs" 0
fi

# ── 16.7: skill content uses the new dir name (regression guard) ────────────
old_in_skills=$(grep -l "\.context/" \
  plugins/edc/skills/*/*.md \
  plugins/edc/skills/*/SKILL.md \
  plugins/edc/skills/edc-context/resources/*.md \
  2>/dev/null || true)
if [ -z "$old_in_skills" ]; then
  check "16.7: no skill markdown contains the old '.context/' literal" 1
else
  check "16.7: no skill markdown contains the old '.context/' literal" 0
  echo "$old_in_skills" | sed 's/^/    /'
fi

echo
echo "=== T16 result: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
