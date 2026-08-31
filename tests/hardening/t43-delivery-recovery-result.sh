#!/usr/bin/env bash
# t43-delivery-recovery-result: delivery-review context recovery failures write structured status.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/plugins/edc/scripts/edc-delivery-review.sh"
TMP=$(mktemp -d)
MOCK_BIN="$TMP/bin"
trap 'rm -rf "$TMP"' EXIT

printf '=== T43: delivery recovery structured result ===\n'

mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'mock update/build failure\n' >&2
exit 1
SH
chmod +x "$MOCK_BIN/claude"

mkdir -p "$TMP/repo"
cd "$TMP/repo"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
git init -q
git config user.email t@example.com
git config user.name T
git config commit.gpgsign false
mkdir -p src edc-context/modules
echo one > src/app.ts
git add src/app.ts
git commit -q -m init
source_commit=$(git rev-parse HEAD)
echo two > src/app.ts
git add src/app.ts
git commit -q -m change
printf '# Repo\n\n## Module Map\n- app\n' > edc-context/index.md
printf '# app\n\n## Files\n- src/app.ts\n' > edc-context/modules/app.md
printf '{"schemaVersion":2,"sourceCommit":"%s","policy":{"defaultMode":"advisory","unmatchedPathPolicy":"warn-allow"},"modules":[{"name":"app","priority":10,"doc":"edc-context/modules/app.md","match":{"prefixes":["src/"]}}]}\n' "$source_commit" > edc-context/manifest.json
export PATH="$MOCK_BIN:$PATH"
export EDC_AGENT_CLI=claude
result=0
out=$(bash "$SCRIPT" HEAD --base HEAD~1 --committed-only 2>&1) || result=$?
if [ "$result" -ne 0 ] \
  && grep -q 'EDC context recovery failed' <<<"$out" \
  && node -e 'const j=require("./edc-context/build/last-run.json"); process.exit(j.kind === "delivery-review" && j.status === "failed" && j.exitCode === 1 && j.reasonCode === "context-recovery-failed" && /context recovery failed/.test(j.message) && /edc update/.test(j.hint) ? 0 : 1)'; then
  echo "PASS: delivery recovery failure writes structured context-recovery result"
else
  echo "FAIL: delivery recovery failure did not write specific structured result. exit=$result"
  echo "--- output ---"; echo "$out"; echo "--- result ---"; cat edc-context/build/last-run.json 2>/dev/null || true; echo "--- end ---"
  exit 1
fi

printf '\nAll T43 checks passed.\n'
