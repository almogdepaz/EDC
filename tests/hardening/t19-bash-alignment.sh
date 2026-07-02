#!/usr/bin/env bash
# t19-bash-alignment: edc review auto-mode runs without EDC_BASH indirection.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/plugins/edc/scripts/edc-review.sh"
. "$(dirname "$0")/lib/check.sh"
check_init --file
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; check_cleanup' EXIT

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

write_fake_pi() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pi" <<'FAKE_PI'
#!/bin/sh
set -eu
mkdir -p edc-context/review-tasks
printf '## Findings\n\nmock review via pi\n' > edc-context/review-tasks/report-ignore-context.md
printf '{"type":"result","is_error":false,"result":"ok"}\n'
printf '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"ok"}]}]}\n'
FAKE_PI
  chmod +x "$TMP/bin/pi"
}

setup_repo
write_fake_pi

unset EDC_BASH
PATH="$TMP/bin:$PATH" \
EDC_AGENT_CLI=pi \
EDC_KEEP_REVIEW_TASKS=1 \
bash "$SCRIPT" HEAD --base HEAD~1 --ignore-context >out.log 2>err.log
rc=$?

if [ "$rc" -eq 0 ] && [ -f review-HEAD.md ] && grep -q 'mock review via pi' review-HEAD.md; then
  check "19.1: review auto-mode runs without EDC_BASH" 1
else
  check "19.1: review auto-mode runs without EDC_BASH" 0
  cat out.log err.log
fi

if env | grep -q '^EDC_BASH='; then
  check "19.2: EDC_BASH stays unset in test process" 0
else
  check "19.2: EDC_BASH stays unset in test process" 1
fi

echo
check_summary "T19"
