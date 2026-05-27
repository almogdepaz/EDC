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

  mkdir -p edc-context/modules edc-context/reports .edc/skills/edc-build-impl .edc/skills/edc-update-impl .edc/skills/edc-review .edc/skills/edc-audit
  printf '# Repo\n\n## Module Map\n' > edc-context/index.md
  printf '## Issues\n' > edc-context/reports/issues.md
  printf '## Complexity\n' > edc-context/reports/complexity.md
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
  printf 'BUILD_SKILL_MARKER\n' > .edc/skills/edc-build-impl/SKILL.md
  printf 'UPDATE_SKILL_MARKER\n' > .edc/skills/edc-update-impl/SKILL.md
  printf 'REVIEW_SKILL_MARKER\n' > .edc/skills/edc-review/SKILL.md
  printf 'AUDIT_SKILL_MARKER\n' > .edc/skills/edc-audit/SKILL.md
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
write_context() {
  head=$(git rev-parse HEAD)
  mkdir -p edc-context/modules edc-context/reports
  printf '# Repo\n\n## Module Map\n' > edc-context/index.md
  printf '# Core\n\n## Files\n' > edc-context/modules/core.md
  printf '## Issues\n' > edc-context/reports/issues.md
  printf '## Complexity\n' > edc-context/reports/complexity.md
  printf '# Agents\n\n## Context\n' > AGENTS.md
  cat > edc-context/manifest.json <<EOF
{"schemaVersion":2,"sourceCommit":"$head","policy":{"defaultMode":"advisory","unmatchedPathPolicy":"warn-allow"},"modules":[{"name":"core","priority":10,"doc":"edc-context/modules/core.md","match":{"prefixes":["src/"]}}]}
EOF
}
finish_ok() {
  printf '{"type":"result","is_error":false,"result":"ok"}\n'
  if [ "${PI_FAKE_AGENT_END_ERROR:-0}" = "1" ]; then
    printf '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"error","errorMessage":"provider down","content":[{"type":"text","text":""}]}]}\n'
  else
    printf '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"ok"}]}]}\n'
  fi
  if [ "${PI_FAKE_HANG_AFTER_AGENT_END:-0}" = "1" ]; then
    sleep 5
  fi
  exit 0
}
if printf '%s' "$prompt" | grep -q 'BUILD_SKILL_MARKER'; then
  write_context
  printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"built context"}}\n'
  finish_ok
fi
if printf '%s' "$prompt" | grep -q 'UPDATE_SKILL_MARKER'; then
  write_context
  printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"updated context"}}\n'
  finish_ok
fi
if printf '%s' "$prompt" | grep -q 'REVIEW_SKILL_MARKER'; then
  mkdir -p edc-context/review-tasks
  printf '## Summary\n\nmock pi review\n' > edc-context/review-tasks/report-core.md
  printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"reviewed"}}\n'
  finish_ok
fi
if printf '%s' "$prompt" | grep -q 'AUDIT_SKILL_MARKER'; then
  mkdir -p edc-context/reports
  printf '## Complexity\n\nmock pi audit\n' > edc-context/reports/complexity.md
  printf '## Issues\n\nmock pi audit\n' > edc-context/reports/issues.md
  printf '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"audited"}}\n'
  finish_ok
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

PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=pi EDC_BUILD_MODEL=t18-model EDC_REVIEW_MODEL=t18-model bash "$ROOT/plugins/edc/scripts/edc-update.sh" --base HEAD~1 >update.out 2>update.err
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Update OK' update.out; then
  check "18.3: EDC_AGENT_CLI=pi runs update orchestrator" 1
else
  check "18.3: EDC_AGENT_CLI=pi runs update orchestrator" 0
  cat update.out update.err
fi

PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=pi EDC_BUILD_MODEL=t18-model EDC_REVIEW_MODEL=t18-model bash "$ROOT/plugins/edc/scripts/edc-audit.sh" >audit.out 2>audit.err
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Audit reports:' audit.out; then
  check "18.4: EDC_AGENT_CLI=pi runs audit orchestrator" 1
else
  check "18.4: EDC_AGENT_CLI=pi runs audit orchestrator" 0
  cat audit.out audit.err
fi

PATH="$TMP/bin:$PATH" EDC_AGENT_CLI=pi EDC_BUILD_MODEL=t18-model EDC_REVIEW_MODEL=t18-model bash "$ROOT/plugins/edc/scripts/edc-build.sh" --force >build.out 2>build.err
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Build OK' build.out; then
  check "18.5: EDC_AGENT_CLI=pi runs build orchestrator" 1
else
  check "18.5: EDC_AGENT_CLI=pi runs build orchestrator" 0
  cat build.out build.err
fi

PATH="$TMP/bin:$PATH" PI_FAKE_HANG_AFTER_AGENT_END=1 EDC_AGENT_CLI=pi EDC_UPDATE_TIMEOUT=3 EDC_BUILD_MODEL=t18-model EDC_REVIEW_MODEL=t18-model bash "$ROOT/plugins/edc/scripts/edc-update.sh" --base HEAD~1 >hang-update.out 2>hang-update.err
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Update OK' hang-update.out; then
  check "18.6: pi backend stops reading after agent_end" 1
else
  check "18.6: pi backend stops reading after agent_end" 0
  cat hang-update.out hang-update.err
fi

PATH="$TMP/bin:$PATH" PI_FAKE_AGENT_END_ERROR=1 EDC_AGENT_CLI=pi EDC_BUILD_MODEL=t18-model EDC_REVIEW_MODEL=t18-model bash "$ROOT/plugins/edc/scripts/edc-update.sh" --base HEAD~1 >agent-end-error.out 2>agent-end-error.err
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'provider down' agent-end-error.err; then
  check "18.7: pi backend fails on agent_end assistant error" 1
else
  check "18.7: pi backend fails on agent_end assistant error" 0
  cat agent-end-error.out agent-end-error.err
fi

echo
check_summary "T18"
