#!/usr/bin/env bash
# t18-pi-backend: EDC_AGENT_CLI=pi uses pi CLI for spawned update/review work.
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
  echo 'one' > src/a.txt
  git add src/a.txt
  git commit -q -m init

  mkdir -p edc-context/modules edc-context/reports .edc/skills/edc-update-impl .edc/skills/edc-review
  printf '# Repo\n\n## Module Map\n' > edc-context/index.md
  printf '## Issues\n' > edc-context/reports/issues.md
  printf '# Core\n\n## Files\n' > edc-context/modules/core.md
  cat > edc-context/manifest.json <<EOF
{
  "schemaVersion": 2,
  "sourceCommit": "0000000000000000000000000000000000000000",
  "policy": {"defaultMode": "advisory", "unmatchedPathPolicy": "warn-allow"},
  "modules": [
    {"name":"core", "priority": 10, "doc":"edc-context/modules/core.md", "match":{"prefixes":["src/"]}}
  ]
}
EOF
  printf 'UPDATE_SKILL_MARKER\n' > .edc/skills/edc-update-impl/SKILL.md
  printf 'REVIEW_SKILL_MARKER\n' > .edc/skills/edc-review/SKILL.md
  printf 'METHODOLOGY_MARKER\n' > .edc/skills/edc-review/methodology.md
  printf 'ADVERSARIAL_MARKER\n' > .edc/skills/edc-review/adversarial.md
  printf 'REPORTING_MARKER\n' > .edc/skills/edc-review/reporting.md
  printf 'PATTERNS_MARKER\n' > .edc/skills/edc-review/patterns.md

  echo 'two' > src/a.txt
  git add src/a.txt
  git commit -q -m change
}

write_mock_pi() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/pi" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> pi-calls.log
prompt=""
for arg in "$@"; do
  case "$arg" in
    @*) prompt="$(cat "${arg#@}")" ;;
  esac
done
if printf '%s' "$prompt" | grep -q 'UPDATE_SKILL_MARKER'; then
  head=$(git rev-parse HEAD)
  tmp=$(mktemp)
  jq --arg head "$head" '.sourceCommit = $head' edc-context/manifest.json > "$tmp"
  mv "$tmp" edc-context/manifest.json
  printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"updated context"}}\n'
  printf '{"type":"result","is_error":false,"result":"ok"}\n'
  exit 0
fi
if printf '%s' "$prompt" | grep -q 'REVIEW_SKILL_MARKER'; then
  mkdir -p edc-context/review-tasks
  printf '## Summary\n\nmock pi review\n' > edc-context/review-tasks/report-core.md
  printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"reviewed"}}\n'
  printf '{"type":"result","is_error":false,"result":"ok"}\n'
  exit 0
fi
printf '{"type":"result","is_error":true,"result":"unexpected prompt"}\n'
exit 1
MOCK
  chmod +x "$TMP/bin/pi"
}

setup_repo
write_mock_pi
PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=pi EDC_KEEP_REVIEW_TASKS=1 bash "$SCRIPT" HEAD --base HEAD~1 >out.log 2>err.log
rc=$?

if [ "$rc" -eq 0 ] && [ -f review-HEAD.md ] && grep -q 'mock pi review' review-HEAD.md; then
  check "18.1: EDC_AGENT_CLI=pi completes stale-context review via pi CLI" 1
else
  check "18.1: EDC_AGENT_CLI=pi completes stale-context review via pi CLI" 0
  cat out.log err.log
fi

if [ -f pi-calls.log ] && grep -q -- '--mode json' pi-calls.log && grep -q -- '--no-context-files' pi-calls.log; then
  check "18.2: pi backend uses json clean-slate CLI mode" 1
else
  check "18.2: pi backend uses json clean-slate CLI mode" 0
  cat pi-calls.log 2>/dev/null || true
fi

echo
check_summary "T18"
