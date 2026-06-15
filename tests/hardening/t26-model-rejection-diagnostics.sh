#!/usr/bin/env bash
# t26-model-rejection-diagnostics: rejected model names get backend-specific guidance.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LIB="$ROOT/plugins/edc/scripts/edc-lib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/pi" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [ "$arg" = "--list-models" ]; then
    cat <<'OUT'
provider      model
openai-codex  gpt-5.5
anthropic     claude-sonnet-4-6
OUT
    exit 0
  fi
done
echo 'Error: Model "bad-model" not found. Use --list-models to see available models.' >&2
exit 1
MOCK
cat > "$TMP/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'bad-model' model is not supported when using Codex with a ChatGPT account.\"}}"}
JSON
exit 1
MOCK
cat > "$TMP/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"type":"result","subtype":"success","is_error":true,"result":"Model 'bad-model' is not supported"}
JSON
exit 1
MOCK
chmod +x "$TMP/bin/pi" "$TMP/bin/codex" "$TMP/bin/claude"

export PATH="$TMP/bin:$PATH"
export EDC_REVIEW_MODEL=bad-model

# shellcheck source=/dev/null
source "$LIB"

failures=0
check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name"
    failures=$((failures + 1))
  fi
}

run_agent() {
  local agent="$1"
  export EDC_AGENT_CLI="$agent"
  unset CODEX_EXEC_HOME EDC_CODEX_HOME
  set +e
  edc_require_agent_cli
  edc_spawn edc-review-smoke 20 'prompt' >"$agent.out" 2>"$agent.err"
  local rc=$?
  set -e
  return "$rc"
}

if ! run_agent pi \
  && grep -q "ERROR: model 'bad-model' was rejected by pi" pi.err \
  && grep -q "available pi models" pi.err \
  && grep -q "openai-codex  gpt-5.5" pi.err; then
  check "pi rejected model prints available models" 1
else
  check "pi rejected model prints available models" 0
  echo "--- stdout ---"; cat pi.out
  echo "--- stderr ---"; cat pi.err
fi

if ! run_agent codex \
  && grep -q "ERROR: model 'bad-model' was rejected by codex" codex.err \
  && grep -q "Codex CLI does not expose a stable model-list command" codex.err \
  && ! grep -q '"type":"error"' codex.err; then
  check "codex rejected model prints readable guidance" 1
else
  check "codex rejected model prints readable guidance" 0
  echo "--- stdout ---"; cat codex.out
  echo "--- stderr ---"; cat codex.err
fi

if ! run_agent claude \
  && grep -q "ERROR: model 'bad-model' was rejected by claude" claude.err \
  && grep -q "Claude CLI does not expose a stable model-list command" claude.err; then
  check "claude rejected model prints readable guidance" 1
else
  check "claude rejected model prints readable guidance" 0
  echo "--- stdout ---"; cat claude.out
  echo "--- stderr ---"; cat claude.err
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi

echo "t26-model-rejection-diagnostics: all checks passed"
