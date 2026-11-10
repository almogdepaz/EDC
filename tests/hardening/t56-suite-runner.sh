#!/usr/bin/env bash
# T56: the hardening suite runner (run-all.sh)
# Run from repo root: bash tests/hardening/t56-suite-runner.sh
set -euo pipefail

echo "=== T56: suite runner ==="

T56_TMP=$(mktemp -d "${TMPDIR:-/tmp}/edc-test.XXXXXX")
trap 'rm -rf "$T56_TMP"' EXIT

# A fake repository with a copy of the real runner and four small tests.
FAKE="$T56_TMP/repo"
mkdir -p "$FAKE/tests/hardening" "$FAKE/plugins/edc/prompt-bundles/bundle-demo" "$FAKE/plugins/edc/skills/skill-demo"
cp tests/hardening/run-all.sh "$FAKE/tests/hardening/run-all.sh"
printf 'demo\n' >"$FAKE/plugins/edc/prompt-bundles/bundle-demo/SKILL.md"
printf 'demo\n' >"$FAKE/plugins/edc/skills/skill-demo/SKILL.md"
printf '#!/usr/bin/env bash\necho ran-t1\n' >"$FAKE/tests/hardening/t1-ok.sh"
printf '#!/usr/bin/env bash\necho ran-t2\nexit 1\n' >"$FAKE/tests/hardening/t2-fail.sh"
printf '#!/usr/bin/env bash\necho ran-t3\n' >"$FAKE/tests/hardening/t3-ok.sh"
printf 'print("ran-py")\n' >"$FAKE/tests/hardening/t4-py.py"
git -C "$FAKE" init -q

# "$BASH" is the interpreter that runs this test, so /bin/bash (3.2) can be tested.
# Every inner run sets EDC_TEST_KEEP_GOING explicitly: the outer suite can run
# with EDC_TEST_KEEP_GOING=1, and the inner runner would inherit that value.
set +e
EDC_TEST_KEEP_GOING=0 "$BASH" "$FAKE/tests/hardening/run-all.sh" >"$T56_TMP/fail-fast.out" 2>&1
fail_fast_rc=$?
EDC_TEST_KEEP_GOING=1 "$BASH" "$FAKE/tests/hardening/run-all.sh" >"$T56_TMP/keep-going.out" 2>&1
keep_going_rc=$?
set -e

# 1. Default mode: stop at the first failure and name the failed test.
if [ "$fail_fast_rc" -ne 0 ] \
  && grep -q '^ran-t1$' "$T56_TMP/fail-fast.out" \
  && grep -q '^ran-t2$' "$T56_TMP/fail-fast.out" \
  && ! grep -q '^ran-t3$' "$T56_TMP/fail-fast.out" \
  && grep -q '^FAIL: t2-fail.sh$' "$T56_TMP/fail-fast.out"; then
  echo "PASS: default mode stops at the first failure and names it"
else
  echo "FAIL: default mode (exit=$fail_fast_rc)"
  cat "$T56_TMP/fail-fast.out"
  exit 1
fi

# 2. Keep-going mode: run every test, then fail and name the failed test.
if [ "$keep_going_rc" -ne 0 ] \
  && grep -q '^ran-t3$' "$T56_TMP/keep-going.out" \
  && grep -q '^ran-py$' "$T56_TMP/keep-going.out" \
  && grep -q '^FAIL: t2-fail.sh$' "$T56_TMP/keep-going.out"; then
  echo "PASS: keep-going mode runs every test and names the failure"
else
  echo "FAIL: keep-going mode (exit=$keep_going_rc)"
  cat "$T56_TMP/keep-going.out"
  exit 1
fi

# 3. All tests pass: exit 0, the Python test ran, the status check ran.
rm -f "$FAKE/tests/hardening/t2-fail.sh"
set +e
EDC_TEST_KEEP_GOING=0 "$BASH" "$FAKE/tests/hardening/run-all.sh" >"$T56_TMP/green.out" 2>&1
green_rc=$?
set -e
if [ "$green_rc" -eq 0 ] \
  && grep -q '^ran-py$' "$T56_TMP/green.out" \
  && [ "$(tail -1 "$T56_TMP/green.out")" = "PASS: hardening suite left repository status unchanged" ]; then
  echo "PASS: a green run discovers the Python test and checks the repository status"
else
  echo "FAIL: green run (exit=$green_rc)"
  cat "$T56_TMP/green.out"
  exit 1
fi

echo ""
echo "All T56 checks passed."
