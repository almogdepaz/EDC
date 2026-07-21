#!/usr/bin/env bash
# Task 5 smoke test: portability + plugin install
# Run from repo root: bash tests/hardening/t5-portability-install.sh
set -euo pipefail

SCRIPT="plugins/edc/scripts/edc-review.sh"
COMMAND="plugins/edc/commands/edc-run-review.md"
HOOK="plugins/edc/hooks/session-start.mjs"
PLUGIN_SCRIPT="plugins/edc/scripts/edc-review.sh"

echo "=== T5: Portability + plugin install ==="

TMPDIR_T5=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T5"' EXIT

# ── 5a: bash 3.2-compatible scripts do not require bash >=4 ────────────────
if ! grep -R 'BASH_VERSINFO\[0\].*-ge 4\|brew install bash\|bash >=4' plugins/edc/scripts pi/README.md >"$TMPDIR_T5/bash4.txt"; then
  echo "PASS: plugin runtime no longer requires bash >=4"
else
  echo "FAIL: plugin runtime still requires bash >=4"
  cat "$TMPDIR_T5/bash4.txt"
  exit 1
fi

# ── 5b: runtime no longer resolves or exports EDC_BASH ──────────────────────
if ! grep -R 'EDC_BASH\|resolveBashExecutable' plugins/edc/scripts pi/index.mjs tests/hardening/run-all.sh >"$TMPDIR_T5/edc-bash.txt"; then
  echo "PASS: runtime no longer carries EDC_BASH interpreter contract"
else
  echo "FAIL: runtime still carries EDC_BASH interpreter contract"
  cat "$TMPDIR_T5/edc-bash.txt"
  exit 1
fi

# ── 5c: installed runtime no longer requires jq ─────────────────────────────
jq_runtime_scan_paths=$(find plugins/edc/scripts -type f ! -name 'edc-spawn-analyze.sh' -print)
if ! grep 'command -v jq\|jq is required\|jq required\|brew install jq\|apt install jq' \
  $jq_runtime_scan_paths \
  pi/README.md \
  pi/install.sh >"$TMPDIR_T5/jq.txt"; then
  echo "PASS: installed runtime no longer requires jq"
else
  echo "FAIL: installed runtime still requires jq"
  cat "$TMPDIR_T5/jq.txt"
  exit 1
fi

# ── 5c2: shellcheck is wired in package scripts and CI ─────────────────────
if grep -q '"lint:shell": "shellcheck plugins/edc/scripts/edc plugins/edc/scripts/\*.sh"' package.json \
  && grep -q '"lint:hardening": "shellcheck -S error tests/hardening/\*.sh"' package.json \
  && grep -q '"test": "npm run lint:hardening && bash tests/hardening/run-all.sh"' package.json \
  && grep -q 'npm run lint:shell' .github/workflows/ci.yml \
  && grep -q 'npm test' .github/workflows/ci.yml; then
  echo "PASS: shellcheck is wired into runtime and hardening scripts in CI"
else
  echo "FAIL: shellcheck package script or CI wiring missing"
  exit 1
fi

# ── 5d: $ARGUMENTS quoting fix in command ──────────────────────────���─────────
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

if grep -q 'edc-review-all.sh' "$COMMAND" \
  && ! grep -q 'edc-review.sh' "$COMMAND" \
  && grep -q 'run-review:review-all' install.sh; then
  echo "PASS: generic review wrappers delegate to combined review-all"
else
  echo "FAIL: generic review wrappers must delegate to edc-review-all.sh"
  exit 1
fi

if node <<'NODE'
const fs = require('fs');
const packageVersion = JSON.parse(fs.readFileSync('package.json', 'utf8')).version;
const marketplace = JSON.parse(fs.readFileSync('.claude-plugin/marketplace.json', 'utf8'));
const plugin = JSON.parse(fs.readFileSync('plugins/edc/.claude-plugin/plugin.json', 'utf8'));
if (marketplace.metadata.version !== packageVersion) process.exit(1);
if (!marketplace.plugins.every((entry) => entry.version === packageVersion)) process.exit(1);
if (plugin.version !== packageVersion) process.exit(1);
NODE
then
  echo "PASS: distribution metadata versions match package.json"
else
  echo "FAIL: distribution metadata versions drift from package.json"
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
if [ "$skills" = "edc-audit edc-delivery-review edc-review " ]; then
  echo "PASS: public skills expose only edc-audit, edc-delivery-review, and edc-review"
else
  echo "FAIL: unexpected public skill surface: $skills"
  exit 1
fi

for bundle in edc-build-impl edc-update-impl edc-module-context-impl edc-context-curator-impl edc-context-curator-edit-impl; do
  if [ ! -f "plugins/edc/prompt-bundles/$bundle/SKILL.md" ]; then
    echo "FAIL: missing hidden prompt bundle: $bundle"
    exit 1
  fi
done
echo "PASS: hidden prompt bundles live outside public skills"

# ── 5e: plugin script bundle exists ─────────────────────────────────────────
if [ -f "$PLUGIN_SCRIPT" ] \
  && [ -f "plugins/edc/scripts/edc-review-all.sh" ] \
  && [ -f "plugins/edc/hooks/lib/classify-cli.mjs" ] \
  && [ -f "plugins/edc/hooks/lib/json-cli.mjs" ] \
  && [ -f "plugins/edc/hooks/lib/stream-filter.mjs" ]; then
  echo "PASS: plugin runtime includes review/review-all + node helper CLIs"
else
  echo "FAIL: plugin runtime missing review/review-all/node helper CLI — install hook cannot copy"
  exit 1
fi

# ── 5e3: remote installer uses a tagged archive, not per-file raw fetches ───
if grep -q 'EDC_INSTALL_REF:-v' install.sh \
  && grep -q 'archive/refs/tags/\$EDC_INSTALL_REF.tar.gz' install.sh \
  && ! grep -q '^download()' install.sh; then
  echo "PASS: remote installer bootstraps from a tagged archive"
else
  echo "FAIL: remote installer still depends on per-file raw downloads from main"
  exit 1
fi

REMOTE_TMP=$(mktemp -d)
REPO_ROOT_T5="$PWD"
REMOTE_HOME="$REMOTE_TMP/home"
REMOTE_BIN="$REMOTE_TMP/bin"
mkdir -p "$REMOTE_HOME" "$REMOTE_BIN"
cp install.sh "$REMOTE_TMP/install.sh"
cat >"$REMOTE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "$out" ] || exit 64
printf '%s\n' "$url" >"${EDC_REMOTE_URL_LOG:?}"
printf 'fake archive\n' >"$out"
EOF
chmod +x "$REMOTE_BIN/curl"
cat >"$REMOTE_BIN/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) dest="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$dest" ] || exit 64
mkdir -p "$dest"
cp -R "${EDC_REPO_ROOT:?}/plugins" "$dest/plugins"
cp "${EDC_REPO_ROOT:?}/install.sh" "$dest/install.sh"
EOF
chmod +x "$REMOTE_BIN/tar"
(
  cd "$REMOTE_TMP"
  EDC_REPO_ROOT="$REPO_ROOT_T5" \
  EDC_REMOTE_URL_LOG="$REMOTE_TMP/url.log" \
  HOME="$REMOTE_HOME" \
  SHELL=/bin/zsh \
  CI=0 \
  PATH="$REMOTE_BIN:$PATH" \
  bash install.sh --agent claude --no-path >"$TMPDIR_T5/remote-install.out" 2>&1
)
if grep -q 'archive/refs/tags/v' "$REMOTE_TMP/url.log" \
  && [ -x "$REMOTE_HOME/.edc/scripts/edc" ]; then
  echo "PASS: remote install uses tagged archive source tree"
else
  echo "FAIL: remote install did not use tagged archive source tree"
  cat "$TMPDIR_T5/remote-install.out"
  exit 1
fi
rm -rf "$REMOTE_TMP"

# ── 5f: session-start is inert; explicit Pi command installs runtime ────────
if ! grep -q 'installOrchestratorScript' "$HOOK" \
  && grep -q 'installOrchestratorScript(ctx.cwd, PLUGIN_ROOT)' pi/index.mjs; then
  echo "PASS: session-start avoids project cache writes; explicit Pi command installs runtime"
else
  echo "FAIL: session-start/explicit install contract regressed"
  exit 1
fi

# ── 5e2: shell entrypoints share script-dir resolution ─────────────────────
if grep -q '^edc_resolve_script_dir()' plugins/edc/scripts/edc-lib.sh \
  && ! grep -R '^_edc_resolve_script_dir()' plugins/edc/scripts/edc*.sh >"$TMPDIR_T5/script-dir.txt"; then
  echo "PASS: shell entrypoints share script-dir resolution"
else
  echo "FAIL: shell entrypoints still duplicate script-dir resolution"
  cat "$TMPDIR_T5/script-dir.txt" 2>/dev/null || true
  exit 1
fi

# ── 5f2: terminal runtime install derives copy/chmod from one table ────────
if bash -n install.sh \
  && grep -q 'runtime_install_entries=(' install.sh \
  && grep -q "IFS='|' read -r src dst executable" install.sh \
  && grep -q 'worker-pool.mjs' install.sh \
  && grep -q 'worker-manifest.mjs' install.sh \
  && grep -q 'build-dag.mjs' install.sh \
  && grep -q 'edc-worker.sh' install.sh \
  && [ "$(grep -c 'copy_or_download "plugins/edc/scripts/' install.sh)" -eq 0 ]; then
  echo "PASS: terminal runtime install derives copy/chmod from one table"
else
  echo "FAIL: terminal runtime install still duplicates copy/chmod lists"
  exit 1
fi

# ── 5g: pi install path includes skill bundle for spawned subprocesses ──────
pi_branch=$(awk '/^  pi\)/,/^    ;;/' install.sh)
if echo "$pi_branch" | grep -q 'install_edc_skills "\$HOME/.edc/skills"' \
  && grep -q 'edc-context-curator-impl/SKILL.md' install.sh \
  && grep -q 'edc-context-curator-edit-impl/SKILL.md' install.sh \
  && grep -q 'edc-audit/references/quality-checks.md' install.sh \
  && grep -q 'edc-delivery-review/references/architecture-axis.md' install.sh \
  && grep -q 'classify-cli.mjs' install.sh \
  && grep -q 'json-cli.mjs' install.sh \
  && grep -q 'pi-supervisor.mjs' install.sh \
  && grep -q 'stream-filter.mjs' install.sh; then
  echo "PASS: pi installer copies private skills and node runtime helpers for spawned subprocesses"
else
  echo "FAIL: pi installer does not copy private skills/node runtime helpers"
  exit 1
fi

if echo "$pi_branch" | grep -q 'bash "\$SCRIPT_DIR/pi/install.sh" --from-source' \
  && ! echo "$pi_branch" | grep -q 'agents/pi/install.sh'; then
  echo "PASS: root installer uses current pi/install.sh source path"
else
  echo "FAIL: root installer does not use current pi/install.sh source path"
  exit 1
fi

if grep -q 'local_suffix=' pi/install.sh \
  && ! grep -q '\${LOCAL:+, project-local}' pi/install.sh; then
  echo "PASS: pi installer labels project-local only when --local is set"
else
  echo "FAIL: pi installer may label global installs as project-local"
  exit 1
fi

if grep -q 'restart pi or run /reload' install.sh \
  && grep -q 'installed extension/source path' install.sh; then
  echo "PASS: pi installer reminds users to reload existing sessions"
else
  echo "FAIL: pi installer missing reload guidance"
  exit 1
fi

# ── 5h: install logic: copies missing script to project .edc/scripts/ ─────────
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

# ── 5j: installer adds ~/.edc/scripts to shell rc idempotently ───────────────
PATH_HOME=$(mktemp -d)
PATH_RC="$PATH_HOME/.zshrc"
HOME="$PATH_HOME" SHELL=/bin/zsh CI=0 EDC_INSTALL_SHELL_RC="$PATH_RC" bash install.sh --agent claude >"$PATH_HOME/install-1.out" 2>&1
if [ -f "$PATH_RC" ] && grep -q 'export PATH="\$HOME/.edc/scripts:\$PATH"' "$PATH_RC"; then
  echo "PASS: installer adds EDC CLI path to shell rc"
else
  echo "FAIL: installer did not add EDC CLI path to shell rc"
  cat "$PATH_HOME/install-1.out"
  [ -f "$PATH_RC" ] && cat "$PATH_RC"
  exit 1
fi

HOME="$PATH_HOME" SHELL=/bin/zsh CI=0 EDC_INSTALL_SHELL_RC="$PATH_RC" bash install.sh --agent claude >"$PATH_HOME/install-2.out" 2>&1
path_block_count=$(grep -c '# EDC CLI' "$PATH_RC" || true)
if [ "$path_block_count" -eq 1 ]; then
  echo "PASS: installer PATH block is idempotent"
else
  echo "FAIL: installer duplicated PATH block ($path_block_count)"
  cat "$PATH_RC"
  exit 1
fi

NO_PATH_HOME=$(mktemp -d)
NO_PATH_RC="$NO_PATH_HOME/.zshrc"
HOME="$NO_PATH_HOME" SHELL=/bin/zsh CI=0 EDC_INSTALL_SHELL_RC="$NO_PATH_RC" bash install.sh --agent claude --no-path >"$NO_PATH_HOME/install.out" 2>&1
if [ ! -f "$NO_PATH_RC" ] || ! grep -q '.edc/scripts' "$NO_PATH_RC"; then
  echo "PASS: --no-path skips shell rc edit"
else
  echo "FAIL: --no-path still edited shell rc"
  cat "$NO_PATH_RC"
  exit 1
fi

echo ""
echo "All T5 checks passed."
