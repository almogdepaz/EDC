#!/usr/bin/env bash
# t25-pi-tarball-install-smoke: install the packed npm tarball into an isolated pi config and load it through pi.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v pi >/dev/null 2>&1; then
  PI_CLI_ROOT="$TMP/pi-cli"
  npm install --prefix "$PI_CLI_ROOT" --silent @earendil-works/pi-coding-agent
  export PATH="$PI_CLI_ROOT/node_modules/.bin:$PATH"
fi
if ! command -v pi >/dev/null 2>&1; then
  echo "FAIL: pi CLI is required for t25-pi-tarball-install-smoke; install @earendil-works/pi-coding-agent"
  exit 1
fi

PACK_DIR="$TMP/pack"
INSTALL_ROOT="$TMP/npm-install"
AGENT_DIR="$TMP/pi-agent"
PROJECT_DIR="$TMP/project"
mkdir -p "$PACK_DIR" "$INSTALL_ROOT" "$AGENT_DIR" "$PROJECT_DIR"

tarball="$(npm pack --pack-destination "$PACK_DIR" --silent)"
tarball_path="$PACK_DIR/$tarball"

npm install --prefix "$INSTALL_ROOT" --ignore-scripts --silent "$tarball_path"
installed_pkg="$INSTALL_ROOT/node_modules/@sgtbeatdown/edc"

if [ ! -f "$installed_pkg/package.json" ]; then
  echo "FAIL: tarball install produced package.json"
  exit 1
fi
if [ ! -f "$installed_pkg/pi/index.mjs" ]; then
  echo "FAIL: tarball install produced pi/index.mjs"
  exit 1
fi

cat > "$AGENT_DIR/settings.json" <<EOF
{
  "packages": ["$installed_pkg"]
}
EOF

(
  cd "$PROJECT_DIR"
  git init -q
)

list_output="$(PI_CODING_AGENT_DIR="$AGENT_DIR" pi list 2>&1)"
case "$list_output" in
  *"$installed_pkg"*) ;;
  *)
    echo "FAIL: pi list shows installed tarball package"
    echo "$list_output"
    exit 1
    ;;
esac

rpc_output="$(
  cd "$PROJECT_DIR"
  printf '{"id":"cmds","type":"get_commands"}\n' \
    | PI_CODING_AGENT_DIR="$AGENT_DIR" pi --mode rpc --no-session --offline 2>"$TMP/rpc.stderr"
)"

node --input-type=module - "$rpc_output" "$TMP/rpc.stderr" "$PROJECT_DIR" <<'NODE'
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const [rawOutput, stderrPath, projectDir] = process.argv.slice(2);
const stderr = readFileSync(stderrPath, "utf-8");
assert.equal(stderr.trim(), "", `pi rpc stderr should be empty, got: ${stderr}`);

const lines = rawOutput.trim().split(/\n/).filter(Boolean).map((line) => JSON.parse(line));
const response = lines.find((line) => line.id === "cmds" && line.command === "get_commands");
assert.ok(response, `get_commands response missing: ${rawOutput}`);
assert.equal(response.success, true, `get_commands failed: ${rawOutput}`);

const commands = response.data?.commands ?? [];
const extensionCommands = commands.filter((command) => command.source === "extension").map((command) => command.name).sort();
assert.deepEqual(extensionCommands, ["edc"]);

const skillCommands = commands.filter((command) => command.source === "skill").map((command) => command.name).sort();
assert.deepEqual(skillCommands, ["skill:edc-audit", "skill:edc-delivery-review", "skill:edc-review"]);

assert.equal(existsSync(join(projectDir, ".edc")), false, "command discovery/session startup must not create project-local EDC cache");
NODE

echo "PASS: pi tarball install smoke"
