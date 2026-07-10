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
ok('package version is aligned to EDC 1.1.4', pkg.version === '1.1.4');
ok('package description is pi.dev-searchable', /pi/i.test(pkg.description || '') && /context-aware code review/i.test(pkg.description || '') && /repository architecture/i.test(pkg.description || ''));
for (const keyword of [
  'ai-agent',
  'agent-context',
  'repo-map',
  'repository-architecture',
  'security-review',
  'quality-review',
]) {
  ok(`package keyword includes ${keyword}`, Array.isArray(pkg.keywords) && pkg.keywords.includes(keyword));
}
ok('package is public (not private)', pkg.private !== true);
ok('package declares author', typeof pkg.author === 'string' && pkg.author.length > 0);
ok('package declares bugs url', pkg.bugs?.url === 'https://github.com/almogdepaz/edc/issues');
ok('node engine follows pi package baseline', pkg.engines?.node === '>=20.6.0');
ok('publishConfig exposes scoped package publicly', pkg.publishConfig?.access === 'public');
ok('pi manifest exposes the pi extension', Array.isArray(pkg.pi?.extensions) && pkg.pi.extensions.includes('./pi/index.mjs'));
ok('pi manifest omits gallery image', pkg.pi && !Object.hasOwn(pkg.pi, 'image'));
ok('current pi peer dependency namespace is used', pkg.peerDependencies?.['@earendil-works/pi-coding-agent'] === '*');
ok('legacy pi peer dependency namespace is absent', !pkg.peerDependencies?.['@mariozechner/pi-coding-agent']);
ok('package has a runtime files allowlist', Array.isArray(pkg.files) && pkg.files.length > 0);
for (const required of [
  'pi/**',
  'plugins/edc/scripts/**',
  'plugins/edc/hooks/**',
  'plugins/edc/skills/**',
  'plugins/edc/prompt-bundles/**',
  'README.md',
  'CONTRIBUTING.md',
  'LICENSE',
  'llms.txt',
  'docs/**',
  'examples/**',
]) {
  ok(`files allowlist includes ${required}`, files.has(required));
}
for (const forbidden of ['CHANGELOG.md', 'SECURITY.md', 'benchmark/**', 'edc-context/**', 'tests/**', 'review-tasks/**']) {
  ok(`files allowlist excludes ${forbidden}`, !files.has(forbidden));
}
NODE

while IFS=$'\t' read -r desc cond; do
  check "$desc" "$cond"
done < /tmp/edc-t22-package-checks
rm -f /tmp/edc-t22-package-checks

check_summary "T22"
