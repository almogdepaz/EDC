#!/usr/bin/env bash
# t19-bash-alignment: nested edc script calls use EDC_BASH, not ambient PATH bash.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/plugins/edc/scripts/edc-review.sh"
. "$(dirname "$0")/lib/check.sh"
check_init --file
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; check_cleanup' EXIT

REAL_BASH="$(command -v bash)"
ORIGINAL_PATH="$PATH"

setup_repo() {
  cd "$TMP"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  git init -q
  git config user.email test@test.com
  git config user.name Test
  git config commit.gpgsign false
  mkdir -p src
  printf 'one\n' > src/a.txt
  git add src/a.txt
  git commit -q -m init
  printf 'two\n' > src/a.txt
  git add src/a.txt
  git commit -q -m change
}

write_fake_tools() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/bash" <<'FAKE_BASH'
#!/bin/sh
echo "FAKE_BASH_USED: nested call resolved bash from PATH" >&2
exit 42
FAKE_BASH
  chmod +x "$TMP/bin/bash"

  cat > "$TMP/bin/pi" <<'FAKE_PI'
#!/bin/sh
set -eu
mkdir -p edc-context/review-tasks
printf '## Summary\n\nmock review via pi\n' > edc-context/review-tasks/report-ignore-context.md
printf '{"type":"result","is_error":false,"result":"ok"}\n'
FAKE_PI
  chmod +x "$TMP/bin/pi"
}

setup_repo
write_fake_tools

PATH="$TMP/bin:$ORIGINAL_PATH" \
EDC_BASH="$REAL_BASH" \
EDC_AGENT_CLI=pi \
EDC_KEEP_REVIEW_TASKS=1 \
"$REAL_BASH" "$SCRIPT" HEAD --base HEAD~1 --ignore-context >out.log 2>err.log
rc=$?

if [ "$rc" -eq 0 ] && [ -f review-HEAD.md ] && grep -q 'mock review via pi' review-HEAD.md; then
  check "19.1: review auto-mode uses EDC_BASH for nested self/consolidate/verify calls" 1
else
  check "19.1: review auto-mode uses EDC_BASH for nested self/consolidate/verify calls" 0
  cat out.log err.log
fi

if grep -q 'FAKE_BASH_USED' err.log out.log 2>/dev/null; then
  check "19.2: ambient PATH bash was not used" 0
else
  check "19.2: ambient PATH bash was not used" 1
fi

echo
check_summary "T19"
