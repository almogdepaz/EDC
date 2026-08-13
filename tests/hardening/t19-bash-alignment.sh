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
  node "$ROOT/plugins/edc/hooks/lib/runtime-manifest.mjs" install "$TMP" "$ROOT/plugins/edc" >/dev/null
}

write_fake_pi() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pi" <<'FAKE_PI'
#!/bin/sh
set -eu
prompt_file=""
for arg in "$@"; do
  case "$arg" in @*) prompt_file=${arg#@} ;; esac
done
[ -n "$prompt_file" ] || { echo 'missing pi prompt file' >&2; exit 2; }
task_path=$(grep '^TASK FILE: ' "$prompt_file" | head -1 | sed 's/^TASK FILE: //')
[ -n "$task_path" ] || { echo 'missing task path in prompt' >&2; exit 2; }
module=$(basename "$task_path" .md)
task_dir=$(dirname "$task_path")
mkdir -p "$task_dir"
printf '## Findings\n\nmock review via pi\n' > "$task_dir/report-$module.md"
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
bash "$SCRIPT" HEAD --base HEAD~1 --committed-only --ignore-context >.git/t19-out.log 2>.git/t19-err.log
rc=$?

if [ "$rc" -eq 0 ] && [ -f review-HEAD.md ] && grep -q 'mock review via pi' review-HEAD.md; then
  check "19.1: review auto-mode runs without EDC_BASH" 1
else
  check "19.1: review auto-mode runs without EDC_BASH" 0
  cat .git/t19-out.log .git/t19-err.log
fi

if env | grep -q '^EDC_BASH='; then
  check "19.2: EDC_BASH stays unset in test process" 0
else
  check "19.2: EDC_BASH stays unset in test process" 1
fi

mkdir -p "$TMP/runtime/scripts" "$TMP/runtime/hooks/lib" "$TMP/edc-context"
cp "$ROOT/plugins/edc/scripts/edc" "$TMP/runtime/scripts/edc"
cp -R "$ROOT/plugins/edc/hooks/lib/." "$TMP/runtime/hooks/lib/"
cat >"$TMP/runtime/scripts/edc-audit.sh" <<'FAKE_AUDIT'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$EDC_PI_INJECT_ARGS"
FAKE_AUDIT
chmod +x "$TMP/runtime/scripts/edc" "$TMP/runtime/scripts/edc-audit.sh"
printf '{"schemaVersion":2,"policy":{"defaultMode":"inject"}}\n' >"$TMP/edc-context/manifest.json"
if (cd "$TMP" && PATH="$TMP/bin:$PATH" EDC_PI_INJECT_ARGS="$TMP/pi-inject-args" EDC_BUILD_MODEL=test/build EDC_REVIEW_MODEL=test/review bash runtime/scripts/edc quality full --agent pi) \
  && [ -f "$TMP/pi-inject-args" ]; then
  check "19.3: terminal quality review accepts pi inject mode" 1
else
  check "19.3: terminal quality review accepts pi inject mode" 0
fi

echo
check_summary "T19"
