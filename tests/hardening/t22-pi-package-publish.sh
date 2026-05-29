#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/hardening/lib/check.sh"
check_init

cd "$ROOT"

echo "=== T22: pi package publish metadata ==="

node <<'NODE' > /tmp/edc-t22-package-checks
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const files = new Set(pkg.files || []);
function ok(name, cond) {
  console.log(`${name}\t${cond ? '1' : '0'}`);
}
ok('scoped npm package name is @sgtbeatdown/edc', pkg.name === '@sgtbeatdown/edc');
ok('package version is aligned to EDC 1.1.0', pkg.version === '1.1.0');
ok('package is public (not private)', pkg.private !== true);
ok('node engine follows pi package baseline', pkg.engines?.node === '>=20.6.0');
ok('publishConfig exposes scoped package publicly', pkg.publishConfig?.access === 'public');
ok('pi manifest exposes the pi extension', Array.isArray(pkg.pi?.extensions) && pkg.pi.extensions.includes('./agents/pi/index.mjs'));
ok('current pi peer dependency namespace is used', pkg.peerDependencies?.['@earendil-works/pi-coding-agent'] === '*');
ok('legacy pi peer dependency namespace is absent', !pkg.peerDependencies?.['@mariozechner/pi-coding-agent']);
ok('package has a runtime files allowlist', Array.isArray(pkg.files) && pkg.files.length > 0);
for (const required of [
  'agents/pi/**',
  'plugins/edc/scripts/**',
  'plugins/edc/hooks/**',
  'plugins/edc/skills/**',
  'plugins/edc/prompt-bundles/**',
  'README.md',
  'LICENSE',
]) {
  ok(`files allowlist includes ${required}`, files.has(required));
}
for (const forbidden of ['benchmark/**', 'edc-context/**', 'tests/**', 'review-tasks/**']) {
  ok(`files allowlist excludes ${forbidden}`, !files.has(forbidden));
}
NODE

while IFS=$'\t' read -r desc cond; do
  check "$desc" "$cond"
done < /tmp/edc-t22-package-checks
rm -f /tmp/edc-t22-package-checks

check_summary "T22"
