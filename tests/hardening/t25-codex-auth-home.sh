#!/usr/bin/env bash
# Regression coverage for Codex OAuth auth handling.
# EDC must not hide ~/.codex/auth.json behind a temporary CODEX_HOME by default,
# and Codex auth failures should be summarized with actionable guidance.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LIB="$ROOT/plugins/edc/scripts/edc-lib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${CODEX_HOME-__UNSET__}" >> "$CODEX_HOME_CAPTURE"
if [ "${CODEX_AUTH_FAIL:-0}" = "1" ]; then
  echo '2026-06-08T00:00:00Z ERROR codex_api::endpoint::responses_websocket: failed to connect to websocket: HTTP error: 401 Unauthorized' >&2
  sleep 10
  cat <<'JSON'
{"type":"thread.started","thread_id":"t"}
{"type":"error","message":"Reconnecting... 2/5 (Failed to refresh token: 400 Bad Request: Your session has ended. Please log in again.)"}
{"type":"error","message":"Reconnecting... 3/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: wss://api.openai.com/v1/responses)"}
{"type":"turn.failed","error":{"message":"Failed to refresh token: 400 Bad Request: Your session has ended. Please log in again."}}
JSON
  exit 1
fi
if [ "${CODEX_MODEL_FAIL:-0}" = "1" ]; then
  cat <<'JSON'
{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The model is not supported when using Codex with a ChatGPT account.\"}}"}
JSON
  exit 1
fi
printf '{"msg":{"type":"agent_message","message":"ok"}}\n'
MOCK
chmod +x "$TMP/bin/codex"

export PATH="$TMP/bin:$PATH"
export EDC_AGENT_CLI=codex
export CODEX_HOME_CAPTURE="$TMP/codex-home-capture"

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

unset EDC_CODEX_HOME CODEX_EXEC_HOME CODEX_EXEC_HOME_OWNED CODEX_AUTH_FAIL
: > "$CODEX_HOME_CAPTURE"
edc_require_agent_cli
set +e
edc_spawn edc-review-smoke 20 'prompt' >default.out 2>default.err
default_rc=$?
set -e
if [ "$default_rc" -eq 0 ] && [ "$(tail -1 "$CODEX_HOME_CAPTURE")" = "__UNSET__" ]; then
  check "codex spawn inherits default CODEX_HOME instead of forcing temp home" 1
else
  check "codex spawn inherits default CODEX_HOME instead of forcing temp home" 0
  cat "$CODEX_HOME_CAPTURE"
fi

export EDC_CODEX_HOME="$TMP/custom-codex-home"
unset CODEX_EXEC_HOME CODEX_EXEC_HOME_OWNED CODEX_AUTH_FAIL
: > "$CODEX_HOME_CAPTURE"
edc_require_agent_cli
set +e
edc_spawn edc-review-smoke 20 'prompt' >custom.out 2>custom.err
custom_rc=$?
set -e
if [ "$custom_rc" -eq 0 ] && [ "$(tail -1 "$CODEX_HOME_CAPTURE")" = "$EDC_CODEX_HOME" ]; then
  check "EDC_CODEX_HOME explicitly overrides CODEX_HOME" 1
else
  check "EDC_CODEX_HOME explicitly overrides CODEX_HOME" 0
  cat "$CODEX_HOME_CAPTURE"
fi

unset EDC_CODEX_HOME CODEX_EXEC_HOME CODEX_EXEC_HOME_OWNED
export CODEX_AUTH_FAIL=1
: > "$CODEX_HOME_CAPTURE"
set +e
edc_require_agent_cli
auth_start=$(date +%s)
edc_spawn edc-review-smoke 20 'prompt' >auth.out 2>auth.err
rc=$?
auth_duration=$(( $(date +%s) - auth_start ))
set -e
if [ "$rc" -ne 0 ] \
  && [ "$auth_duration" -lt 5 ] \
  && grep -q "Codex authentication failed" auth.err \
  && grep -q "codex logout && codex login" auth.err \
  && ! grep -q "responses_websocket" auth.err \
  && [ "$(grep -c "Codex authentication failed" auth.err)" -eq 1 ]; then
  check "codex auth failure is summarized once with login guidance" 1
else
  check "codex auth failure is summarized once with login guidance" 0
  echo "--- stdout ---"; cat auth.out
  echo "--- stderr ---"; cat auth.err
fi

unset CODEX_AUTH_FAIL
export CODEX_MODEL_FAIL=1
set +e
edc_require_agent_cli
edc_spawn edc-review-smoke 20 'prompt' >model.out 2>model.err
rc=$?
set -e
if [ "$rc" -ne 0 ] \
  && grep -q "ERROR: model was rejected by codex" model.err \
  && grep -q "The model is not supported" model.err \
  && ! grep -q '"type":"error"' model.err; then
  check "codex structured provider errors print readable model guidance" 1
else
  check "codex structured provider errors print readable model guidance" 0
  echo "--- stdout ---"; cat model.out
  echo "--- stderr ---"; cat model.err
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi

echo "t25-codex-auth-home: all checks passed"
