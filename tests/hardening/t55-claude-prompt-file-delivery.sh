#!/usr/bin/env bash
# t55-claude-prompt-file-delivery: prompt-file spawns must deliver the user
# prompt in a way claude's variadic --allowed-tools cannot swallow.
# claude 2.1.x parses `--allowed-tools <tools...>` greedily, so a positional
# prompt placed after it becomes a tool name and `claude -p` exits 1 with
# "Input must be provided either through stdin or as a prompt argument".
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LIB="$ROOT/plugins/edc/scripts/edc-lib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
# Fake claude reproducing the real CLI's argument handling: --allowed-tools /
# --allowedTools consume every following non-flag argument; the prompt is the
# remaining positional argument or, failing that, non-empty stdin.
cat > "$TMP/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
prompt="" variadic=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allowed-tools|--allowedTools|--disallowed-tools|--disallowedTools)
      variadic=1; shift ;;
    -p|--print|--verbose|--dangerously-skip-permissions|--exclude-dynamic-system-prompt-sections)
      variadic=0; shift ;;
    --*)
      variadic=0; shift 2 ;;
    *)
      if [ "$variadic" -eq 0 ]; then prompt="$1"; fi
      shift ;;
  esac
done
if [ -z "$prompt" ] && [ ! -t 0 ]; then
  prompt=$(cat)
fi
if [ -z "$prompt" ]; then
  echo "Error: Input must be provided either through stdin or as a prompt argument when using --print" >&2
  exit 1
fi
printf '%s' "$prompt" > "$FAKE_CLAUDE_PROMPT_OUT"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0,"num_turns":1}'
MOCK
chmod +x "$TMP/bin/claude"

export PATH="$TMP/bin:$PATH"
export EDC_AGENT_CLI=claude
export EDC_SPAWN_LOG="$TMP/spawn-log.jsonl"
export FAKE_CLAUDE_PROMPT_OUT="$TMP/prompt.txt"
unset EDC_REVIEW_MODEL EDC_BUILD_MODEL

printf 'system prompt body\n' > "$TMP/system.md"

# shellcheck source=/dev/null
source "$LIB"

set +e
edc_spawn edc-review-smoke 20 --prompt-file "$TMP/system.md" >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "FAIL: prompt-file spawn exited $rc"
  sed 's/^/  /' "$TMP/err"
  exit 1
fi
if [ "$(cat "$TMP/prompt.txt" 2>/dev/null)" != "execute the task per the system prompt." ]; then
  echo "FAIL: claude did not receive the prompt-file user prompt"
  exit 1
fi
echo "PASS: prompt-file spawn delivers its user prompt past --allowed-tools"
