#!/usr/bin/env bash
# t41-review-all-orchestrator: combined review runs security, delivery, quality in order.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/plugins/edc/scripts/edc-review-all.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '=== T41: review-all orchestrator ===\n'

mkdir -p "$TMP/.edc/scripts"
cp "$SCRIPT" "$TMP/.edc/scripts/edc-review-all.sh"
cp "$ROOT/plugins/edc/scripts/edc-lib.sh" "$TMP/.edc/scripts/edc-lib.sh"
mkdir -p "$TMP/.edc/hooks/lib"
cp "$ROOT/plugins/edc/hooks/lib/json-cli.mjs" "$TMP/.edc/hooks/lib/json-cli.mjs"
chmod +x "$TMP/.edc/scripts/edc-review-all.sh" "$TMP/.edc/scripts/edc-lib.sh"

cat > "$TMP/.edc/scripts/edc-review.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'security|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
SH
cat > "$TMP/.edc/scripts/edc-delivery-review.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'delivery|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
SH
cat > "$TMP/.edc/scripts/edc-audit.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'quality|agent=%s|ctx=%s|args=%s\n' "${EDC_AGENT_CLI:-}" "${EDC_CONTEXT_MODE:-}" "$*" >> "$EDC_T41_LOG"
SH
chmod +x "$TMP/.edc/scripts/edc-review.sh" "$TMP/.edc/scripts/edc-delivery-review.sh" "$TMP/.edc/scripts/edc-audit.sh"

(
  cd "$TMP"
  export EDC_AGENT_CLI=pi
  export EDC_CONTEXT_MODE=advisory
  export EDC_T41_LOG="$TMP/phases.log"
  bash .edc/scripts/edc-review-all.sh HEAD --base main --ignore 'generated/**' --context-mode advisory
)

expected=$'security|agent=pi|ctx=advisory|args=HEAD --base main --ignore generated/** --context-mode advisory\ndelivery|agent=pi|ctx=advisory|args=HEAD --base main --ignore generated/** --context-mode advisory\nquality|agent=pi|ctx=advisory|args=--ignore generated/** --context-mode advisory'
actual=$(cat "$TMP/phases.log")
if [ "$actual" = "$expected" ]; then
  echo "PASS: review-all runs security, delivery, quality with correct args"
else
  echo "FAIL: review-all phase log mismatch"
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual"
  exit 1
fi

printf '\nAll T41 checks passed.\n'
