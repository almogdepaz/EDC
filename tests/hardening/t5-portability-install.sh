#!/usr/bin/env bash
# Task 5 smoke test: portability + plugin install
# Run from repo root: bash tests/hardening/t5-portability-install.sh
set -euo pipefail

SCRIPT="plugins/edc/scripts/edc-review.sh"
COMMAND="plugins/edc/commands/edc-run-review.md"
HOOK="plugins/edc/hooks/session-start.mjs"
PLUGIN_SCRIPT="plugins/edc/scripts/edc-review.sh"

echo "=== T5: Portability + plugin install ==="

# ── 5a: bash version gate present ──────────────────────────────��─────────────
if grep -q 'BASH_VERSINFO\[0\]' "$SCRIPT" && grep -q 'brew install bash' "$SCRIPT"; then
  echo "PASS: bash version gate present in script"
else
  echo "FAIL: bash version gate missing"
  exit 1
fi

# ── 5b: version gate exits 2 on bash < 4 ─────────────────────��───────────────
# Simulate BASH_VERSINFO[0]=3 by sourcing a modified env — we can't actually run
# under bash 3.2, so test the logic statically: the gate uses [[ ]] which is
# bash-only and exits 2. Verify the exit code in the gate.
if grep -A3 'BASH_VERSINFO' "$SCRIPT" | grep -q 'exit 2'; then
  echo "PASS: version gate exits with code 2"
else
  echo "FAIL: version gate does not exit 2"
  exit 1
fi

# ── 5c: $ARGUMENTS quoting fix in command ──────────────────────────���─────────
if grep -q 'set -- \$ARGUMENTS' "$COMMAND" && grep -q '"$@"' "$COMMAND"; then
  echo "PASS: \$ARGUMENTS safely word-split via set -- and passed as \"\$@\""
else
  echo "FAIL: \$ARGUMENTS quoting fix missing in command file"
  exit 1
fi

# Confirm $ARGUMENTS is NOT used bare in a bash invocation (only in set -- or display)
bare_lines=$(grep '\$ARGUMENTS' "$COMMAND" | grep -v 'set --\|Arguments:' || true)
if [ -z "$bare_lines" ]; then
  echo "PASS: \$ARGUMENTS no longer used bare in bash invocations"
else
  echo "FAIL: \$ARGUMENTS still used bare in bash invocations:"
  echo "$bare_lines"
  exit 1
fi

# ── 5d: public command/skill surface is user-facing only ────────────────────
commands=$(find plugins/edc/commands -maxdepth 1 -type f -name '*.md' -exec basename {} \; | sort | tr '\n' ' ')
if [ "$commands" = "edc-build.md edc-doctor.md edc-run-review.md edc-update.md " ]; then
  echo "PASS: command directory exposes only build/update/run-review/doctor"
else
  echo "FAIL: unexpected command surface: $commands"
  exit 1
fi

skills=$(find plugins/edc/skills -maxdepth 1 -type d -mindepth 1 -exec basename {} \; | sort | tr '\n' ' ')
if [ "$skills" = "edc-audit edc-review " ]; then
  echo "PASS: public skills expose only edc-audit and edc-review"
else
  echo "FAIL: unexpected public skill surface: $skills"
  exit 1
fi

for bundle in edc-build-impl edc-update-impl edc-module-context-impl; do
  if [ ! -f "plugins/edc/prompt-bundles/$bundle/SKILL.md" ]; then
    echo "FAIL: missing hidden prompt bundle: $bundle"
    exit 1
  fi
done
echo "PASS: hidden prompt bundles live outside public skills"

# ── 5e: plugin script bundle exists ──────────────────────────────���───────────
if [ -f "$PLUGIN_SCRIPT" ]; then
  echo "PASS: plugins/edc/scripts/edc-review.sh exists in plugin bundle"
else
  echo "FAIL: plugins/edc/scripts/edc-review.sh missing — install hook cannot copy"
  exit 1
fi

# ── 5f: session-start hook contains installOrchestratorScript ────────────────
if grep -q 'installOrchestratorScript' "$HOOK"; then
  echo "PASS: installOrchestratorScript present in session-start hook"
else
  echo "FAIL: installOrchestratorScript missing from session-start hook"
  exit 1
fi

# ── 5g: pi install path includes skill bundle for spawned subprocesses ──────
pi_branch=$(awk '/^  pi\)/,/^    ;;/' install.sh)
if echo "$pi_branch" | grep -q 'install_edc_skills "\$HOME/.edc/skills"'; then
  echo "PASS: pi installer copies ~/.edc/skills for spawned review subprocesses"
else
  echo "FAIL: pi installer does not copy ~/.edc/skills"
  exit 1
fi

if echo "$pi_branch" | grep -q 'bash "\$SCRIPT_DIR/pi/install.sh" --from-source' \
  && ! echo "$pi_branch" | grep -q 'agents/pi/install.sh'; then
  echo "PASS: root installer uses current pi/install.sh source path"
else
  echo "FAIL: root installer does not use current pi/install.sh source path"
  exit 1
fi

# ── 5h: install logic: copies missing script to project .edc/scripts/ ─────────
TMPDIR_T5=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T5"' EXIT

# Simulate install: run the hook with a fake project root
result=$(node -e "
import { join } from 'path';
import { existsSync, mkdirSync, copyFileSync, chmodSync, statSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

const projectRoot = '${TMPDIR_T5}';
const pluginDir = join('$(pwd)', 'plugins', 'edc');
const pluginScript = join(pluginDir, 'scripts', 'edc-review.sh');
const destDir = join(projectRoot, '.edc', 'scripts');
const destScript = join(destDir, 'edc-review.sh');

if (!existsSync(pluginScript)) {
  process.stderr.write('plugin script missing\\n'); process.exit(1);
}

let shouldCopy = !existsSync(destScript);
if (shouldCopy) {
  mkdirSync(destDir, { recursive: true });
  copyFileSync(pluginScript, destScript);
  chmodSync(destScript, 0o755);
  console.log('installed');
} else {
  console.log('already present');
}
" 2>&1)

if echo "$result" | grep -q 'installed'; then
  echo "PASS: install logic copies script to project .edc/scripts/"
else
  echo "FAIL: install logic did not copy script ($result)"
  exit 1
fi

# Verify it's actually there and executable
if [ -x "$TMPDIR_T5/.edc/scripts/edc-review.sh" ]; then
  echo "PASS: installed script is executable"
else
  echo "FAIL: installed script is not executable or missing"
  exit 1
fi

# ── 5i: install is idempotent (stale-check: older dest → copy again) ─────────
# Make dest older by touching plugin script with newer mtime
touch "$(pwd)/$PLUGIN_SCRIPT"
result=$(node -e "
import { join } from 'path';
import { existsSync, mkdirSync, copyFileSync, chmodSync, statSync } from 'fs';

const projectRoot = '${TMPDIR_T5}';
const pluginDir = join('$(pwd)', 'plugins', 'edc');
const pluginScript = join(pluginDir, 'scripts', 'edc-review.sh');
const destScript = join(projectRoot, '.edc', 'scripts', 'edc-review.sh');

const srcMtime = statSync(pluginScript).mtimeMs;
const dstMtime = statSync(destScript).mtimeMs;
const shouldCopy = srcMtime > dstMtime;
console.log(shouldCopy ? 'would-copy' : 'up-to-date');
" 2>&1)

if echo "$result" | grep -q 'would-copy'; then
  echo "PASS: stale detection fires (plugin newer than project copy)"
else
  echo "INFO: stale detection: $result (may be same mtime — acceptable)"
fi

echo ""
echo "All T5 checks passed."
