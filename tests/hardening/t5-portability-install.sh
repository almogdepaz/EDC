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
  && grep -q '"lint:hardening": "shellcheck -S error tests/hardening/\*.sh tests/hardening/lib/\*.sh"' package.json \
  && grep -q '"test:modules": "node --test tests/unit/\*.test.mjs"' package.json \
  && grep -q '"test": "npm run lint:hardening && npm run test:modules && npm run test:benchmark && bash tests/hardening/run-all.sh"' package.json \
  && grep -q 'npm run lint:shell' .github/workflows/ci.yml \
  && grep -q 'npm test' .github/workflows/ci.yml; then
  echo "PASS: shellcheck and focused unit tests are wired into CI"
else
  echo "FAIL: shellcheck, focused unit test, or CI wiring missing"
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
const manifest = JSON.parse(fs.readFileSync('edc-context/manifest.json', 'utf8'));
const installer = fs.readFileSync('install.sh', 'utf8');
if (packageVersion !== '1.1.5') process.exit(1);
if (marketplace.metadata.version !== packageVersion) process.exit(1);
if (!marketplace.plugins.every((entry) => entry.version === packageVersion)) process.exit(1);
if (plugin.version !== packageVersion) process.exit(1);
if (manifest.edcVersion !== packageVersion) process.exit(1);
if (!installer.includes(`EDC_INSTALL_REF="\${EDC_INSTALL_REF:-v${packageVersion}}"`)) process.exit(1);
NODE
then
  echo "PASS: v1.1.5 distribution, context, and installer versions match"
else
  echo "FAIL: v1.1.5 distribution, context, or installer versions drift"
  exit 1
fi

if grep -Fq 'Marketplace installation provides the package-backed Claude commands, hooks, and skills' README.md \
  && grep -Fq 'The standalone terminal CLI requires the direct installer' README.md \
  && ! grep -Fq 'Both paths install the plugin surface' README.md; then
  echo "PASS: README distinguishes marketplace plugin setup from terminal runtime install"
else
  echo "FAIL: README conflates marketplace setup with terminal runtime installation"
  exit 1
fi

if [ -f CHANGELOG.md ] \
  && grep -q '^## \[1.1.5\]' CHANGELOG.md \
  && [ -f SECURITY.md ] \
  && grep -q 'https://github.com/almogdepaz/edc/security/advisories/new' SECURITY.md; then
  echo "PASS: release and vulnerability-reporting policy files exist"
else
  echo "FAIL: release or vulnerability-reporting policy files missing"
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
  && [ -f "plugins/edc/hooks/lib/runtime-bootstrap.mjs" ] \
  && [ -f "plugins/edc/hooks/lib/stream-filter.mjs" ]; then
  echo "PASS: plugin runtime includes review/review-all + trusted node bootstrap/helper CLIs"
else
  echo "FAIL: plugin runtime missing review/review-all/trusted node bootstrap/helper CLI — install hook cannot copy"
  exit 1
fi

# User-facing wrappers must enter through trusted package/global bootstrap code;
# repo-local scripts are never execution targets.
if grep -q 'runtime-bootstrap.mjs' plugins/edc/commands/edc-build.md \
  && grep -q 'runtime-bootstrap.mjs' plugins/edc/commands/edc-update.md \
  && grep -q 'runtime-bootstrap.mjs' plugins/edc/commands/edc-run-review.md \
  && grep -q 'runtime-bootstrap.mjs' plugins/edc/commands/edc-doctor.md \
  && ! grep -R -E 'bash ("?\.edc/scripts|"?\$HOME/\.edc/scripts)' plugins/edc/commands >"$TMPDIR_T5/direct-command-runtime.txt"; then
  echo "PASS: static slash wrappers never invoke project-local runtime directly"
else
  echo "FAIL: static slash wrappers bypass trusted runtime bootstrap"
  cat "$TMPDIR_T5/direct-command-runtime.txt" 2>/dev/null || true
  exit 1
fi

if grep -q '\$HOME/.edc/hooks/lib/runtime-bootstrap.mjs' install.sh \
  && ! grep -E 'if \[ -f "?\.edc/scripts/edc-\$script\.sh"? \]' install.sh >"$TMPDIR_T5/direct-generated-runtime.txt"; then
  echo "PASS: generated Cursor/Codex wrappers use trusted HOME bootstrap only"
else
  echo "FAIL: generated Cursor/Codex wrappers can invoke project-local runtime directly"
  cat "$TMPDIR_T5/direct-generated-runtime.txt" 2>/dev/null || true
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

# ── 5f: passive/help Pi paths are inert; execution uses trusted bootstrap ──
if ! grep -q 'installOrchestratorScript' "$HOOK" \
  && ! grep -q 'installOrchestratorScript' plugins/edc/hooks/lib/route.mjs \
  && ! grep -q 'installOrchestratorScript(ctx.cwd, PLUGIN_ROOT)' pi/index.mjs \
  && grep -q 'runtime-bootstrap.mjs' pi/index.mjs; then
  echo "PASS: session/help paths avoid project cache writes; Pi execution uses trusted bootstrap"
else
  echo "FAIL: passive Pi path or trusted execution bootstrap contract regressed"
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

# ── 5f2: terminal runtime install derives copy/chmod from canonical manifest ─
if bash -n install.sh \
  && grep -q 'node "\$runtime_manifest" install "\$HOME"' install.sh \
  && ! grep -q 'runtime_install_entries=(' install.sh \
  && grep -q 'worker-pool.mjs' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'worker-manifest.mjs' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'build-dag.mjs' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'runtime-bootstrap.mjs' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'edc-worker.sh' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && [ "$(grep -c 'copy_or_download "plugins/edc/scripts/' install.sh)" -eq 0 ]; then
  echo "PASS: terminal runtime install derives copy/chmod from canonical manifest"
else
  echo "FAIL: terminal runtime install still duplicates copy/chmod lists"
  exit 1
fi

# ── 5g: pi install path relies on runtime manifest for private subprocess skills ─
install_terminal_fn=$(awk '/^install_terminal_cli\(\) \{/,/^}/' install.sh)
install_public_skills_fn=$(awk '/^install_public_edc_skills\(\) \{/,/^}/' install.sh)
pi_branch=$(awk '/^  pi\)/,/^    ;;/' install.sh)
if ! grep -q 'remove_legacy_edc_skills' install.sh \
  && ! echo "$pi_branch" | grep -q 'install_edc_skills "\$HOME/.edc/skills"' \
  && echo "$install_terminal_fn" | grep -Fq '"$HOME/.edc/skills/edc-review-impl"' \
  && echo "$install_terminal_fn" | grep -Fq '"$HOME/.edc/skills/edc-audit-impl"' \
  && echo "$install_terminal_fn" | grep -Fq '"$HOME/.edc/skills/edc-context"' \
  && echo "$install_public_skills_fn" | grep -Fq '"$target/edc-review-impl"' \
  && echo "$install_public_skills_fn" | grep -Fq '"$target/edc-audit-impl"' \
  && echo "$install_public_skills_fn" | grep -Fq '"$target/edc-context"' \
  && grep -q 'edc-context-curator-impl/SKILL.md' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'edc-context-curator-edit-impl/SKILL.md' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'edc-audit/references/quality-checks.md' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'edc-delivery-review/references/architecture-axis.md' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'classify-cli.mjs' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'json-cli.mjs' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'pi-supervisor.mjs' plugins/edc/hooks/lib/runtime-manifest.mjs \
  && grep -q 'stream-filter.mjs' plugins/edc/hooks/lib/runtime-manifest.mjs; then
  echo "PASS: installer centralizes legacy cleanup and uses runtime manifest for private skills/helpers"
else
  echo "FAIL: installer legacy cleanup shape or private runtime helper contract regressed"
  exit 1
fi

if echo "$pi_branch" | grep -q 'bash "\$SCRIPT_DIR/pi/install.sh" --from-source' \
  && ! echo "$pi_branch" | grep -q 'agents/pi/install.sh'; then
  echo "PASS: root installer uses current pi/install.sh source path"
else
  echo "FAIL: root installer does not use current pi/install.sh source path"
  exit 1
fi

PI_INSTALL_BIN="$TMPDIR_T5/pi-install-bin"
PI_INSTALL_LOG="$TMPDIR_T5/pi-install-args"
mkdir -p "$PI_INSTALL_BIN"
cat >"$PI_INSTALL_BIN/pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${PI_INSTALL_LOG:?}"
EOF
chmod +x "$PI_INSTALL_BIN/pi"
set +e
PATH="$PI_INSTALL_BIN:$PATH" PI_INSTALL_LOG="$PI_INSTALL_LOG" bash pi/install.sh --local >"$TMPDIR_T5/pi-local.out" 2>&1
pi_local_rc=$?
set -e
if [ "$pi_local_rc" -eq 2 ] \
  && grep -q -- '--local is unsupported' "$TMPDIR_T5/pi-local.out" \
  && [ ! -e "$PI_INSTALL_LOG" ]; then
  echo "PASS: pi installer rejects unsupported repo-local installs"
else
  echo "FAIL: pi installer accepted or unclearly rejected --local"
  cat "$TMPDIR_T5/pi-local.out"
  exit 1
fi

PATH="$PI_INSTALL_BIN:$PATH" PI_INSTALL_LOG="$PI_INSTALL_LOG" bash pi/install.sh --from-source >"$TMPDIR_T5/pi-source.out" 2>&1
if [ "$(sed -n '1p' "$PI_INSTALL_LOG")" = "install" ] \
  && [ "$(sed -n '2p' "$PI_INSTALL_LOG")" = "$(pwd)" ] \
  && [ "$(wc -l <"$PI_INSTALL_LOG" | tr -d ' ')" -eq 2 ]; then
  echo "PASS: explicit Pi source install remains global"
else
  echo "FAIL: explicit Pi source install forwarded local-install flags"
  cat "$PI_INSTALL_LOG" "$TMPDIR_T5/pi-source.out"
  exit 1
fi

if grep -q 'restart pi or run /reload' install.sh \
  && grep -q 'installed extension/source path' install.sh; then
  echo "PASS: pi installer reminds users to reload existing sessions"
else
  echo "FAIL: pi installer missing reload guidance"
  exit 1
fi

runtime_docs=(README.md pi/README.md docs/index.md docs/agent-discovery.md examples/pi-quickstart.md plugins/edc/prompt-bundles/edc-build-impl/manifest-schema.md)
if ! rg -n 'pi install .* (-l|--local)|project-local install|runtime cache is created' "${runtime_docs[@]}" >"$TMPDIR_T5/local-runtime-docs.txt" \
  && ! grep -qx '\.edc/' README.md \
  && grep -qi 'repo-local `.edc/` is never read, repaired, created, or executed' README.md; then
  echo "PASS: source docs describe package/global runtime without repo cache guidance"
else
  echo "FAIL: source docs retain project-local runtime install/cache guidance"
  cat "$TMPDIR_T5/local-runtime-docs.txt"
  exit 1
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
