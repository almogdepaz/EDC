import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative, resolve } from 'node:path';
import test from 'node:test';
import * as scope from '../../pi/lib/review-scope.mjs';
import edcExtension from '../../pi/index.mjs';
import { getContextFreshness } from '../../plugins/edc/hooks/lib/route.mjs';

const cli = resolve('plugins/edc/scripts/edc');
function fixture(state = 'missing') {
  const root = mkdtempSync(join(tmpdir(), 'edc-context-choice.'));
  const env = { ...process.env, HOME: join(root, '.git/home'), GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', EDC_BUILD_MODEL: 'synthetic', EDC_REVIEW_MODEL: 'synthetic', EDC_OCTOCODE: '0' };
  const git = (...args) => execFileSync('git', args, { cwd: root, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git('init', '-q'); git('config', 'user.name', 'test'); git('config', 'user.email', 'test@example.com'); git('config', 'commit.gpgsign', 'false');
  writeFileSync(join(root, 'source.js'), 'export const value = 1;\n'); git('add', '.'); git('commit', '-qm', 'base');
  const base = git('rev-parse', 'HEAD');
  writeFileSync(join(root, 'source.js'), 'export const value = 2;\n'); git('add', '.'); git('commit', '-qm', 'target');
  mkdirSync(join(root, '.git/bin')); mkdirSync(env.HOME);
  writeFileSync(join(root, '.git/bin/claude'), `#!/usr/bin/env python3
import sys, pathlib
prompt = sys.stdin.read()
for i, arg in enumerate(sys.argv):
    if arg == '--system-prompt-file': prompt = pathlib.Path(sys.argv[i+1]).read_text()
with open('.git/model-calls', 'a') as f: f.write(prompt + '\\n')
sys.exit(9)
`, { mode: 0o755 });
  writeFileSync(join(root, '.git/bin/octocode'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
  env.PATH = `${join(root, '.git/bin')}:${env.PATH}`;
  if (state !== 'missing') {
    mkdirSync(join(root, 'edc-context'));
    writeFileSync(join(root, 'edc-context/index.md'), '# Context\n## Modules\n');
    writeFileSync(join(root, 'edc-context/manifest.json'), JSON.stringify({ schemaVersion: 2, sourceCommit: state === 'stale' ? base : git('rev-parse', 'HEAD'), policy: { defaultMode: 'advisory' }, modules: [] }));
  }
  const run = (args, input) => {
    const command = ['/bin/bash', cli, ...args, '--agent', 'claude'];
    if (input === undefined) return spawnSync(command[0], command.slice(1), { cwd: root, env, encoding: 'utf8', timeout: 45000 });
    // A real PTY exercises the public interactive boundary, including EOF.
    const driver = `import os, pty, select, subprocess, sys, time, json\nm,s=pty.openpty()\np=subprocess.Popen(json.loads(sys.argv[1]),stdin=s,stdout=s,stderr=s)\nos.close(s)\nout=b''; sent=False; deadline=time.monotonic()+40\nwhile time.monotonic()<deadline:\n if select.select([m],[],[],0.1)[0]:\n  try: data=os.read(m,65536)\n  except OSError: break\n  if not data: break\n  out+=data\n  if b'context choice [1/2/3]' in out and not sent:\n   os.write(m,bytes.fromhex(sys.argv[2])); sent=True\n if p.poll() is not None: break\nelse:\n p.kill(); raise RuntimeError('context choice timed out')\np.wait(); os.close(m)\nprint(json.dumps({'status':p.returncode,'stdout':out.decode(errors='replace'),'stderr':''}))`;
    const r = spawnSync('python3', ['-c', driver, JSON.stringify(command), Buffer.from(input).toString('hex')], { cwd: root, env, encoding: 'utf8', timeout: 45000 });
    assert.equal(r.status, 0, r.stderr);
    return JSON.parse(r.stdout);
  };
  return { root, env, base, git, run, calls: () => existsSync(join(root, '.git/model-calls')) ? readFileSync(join(root, '.git/model-calls'), 'utf8') : '', close: () => rmSync(root, { recursive: true, force: true }) };
}

function runSourcedContext(f, contextDir, command, manifest) {
  const env = { ...f.env, EDC_CONTEXT_DIR: contextDir, EDC_AGENT_CLI: 'claude', EDC_REVIEW_CONTEXT_CHOICE: 'check' };
  delete env.MANIFEST;
  if (manifest !== undefined) env.MANIFEST = manifest;
  return spawnSync('/bin/bash', ['-c', `set -e
. "$1/edc-lib.sh"
. "$1/edc-recover-context.sh"
${command}`, 'context-test', resolve('plugins/edc/scripts')], { cwd: f.root, env, encoding: 'utf8', timeout: 15000 });
}

for (const contextDir of ['edc-context', 'ctx2']) {
  test(`A1 sourced ${contextDir}: fresh gate and recovery bypass without model work`, () => {
    const f = fixture('fresh');
    try {
      if (contextDir !== 'edc-context') renameSync(join(f.root, 'edc-context'), join(f.root, contextDir));
      const r = runSourcedContext(f, contextDir, 'assert_context_fresh\nread_canonical_context_source_commit\nrecover_context_if_needed');
      assert.equal(r.status, 0, r.stdout + r.stderr);
      assert.equal(r.stdout.trim(), f.git('rev-parse', 'HEAD'));
      assert.equal(r.stderr, '');
      assert.equal(f.calls(), '');
      assert.equal(getContextFreshness(f.root).state, contextDir === 'edc-context' ? 'fresh' : 'missing');
    } finally { f.close(); }
  });

  for (const escape of ['root-symlink', 'manifest-symlink', 'manifest-override']) {
    test(`A1 ${contextDir}: rejects ${escape} rather than inferring a trust root`, () => {
      const f = fixture('fresh');
      try {
        const contextPath = join(f.root, contextDir);
        if (contextDir !== 'edc-context') renameSync(join(f.root, 'edc-context'), contextPath);
        let manifest;
        if (escape === 'root-symlink') {
          renameSync(contextPath, join(f.root, 'elsewhere'));
          symlinkSync('elsewhere', contextPath);
        } else {
          mkdirSync(join(f.root, 'elsewhere'));
          writeFileSync(join(f.root, 'elsewhere/manifest.json'), readFileSync(join(contextPath, 'manifest.json')));
          if (escape === 'manifest-symlink') {
            rmSync(join(contextPath, 'manifest.json'));
            symlinkSync('../elsewhere/manifest.json', join(contextPath, 'manifest.json'));
          } else manifest = 'elsewhere/manifest.json';
        }
        const r = runSourcedContext(f, contextDir, `if assert_context_fresh; then exit 91; fi
if read_manifest_source_commit; then exit 92; fi
if read_canonical_context_source_commit; then exit 93; fi
_edc_classify_context_state`, manifest);
        assert.equal(r.status, 0, r.stdout + r.stderr);
        assert.equal(r.stdout.trim(), 'MISSING');
        assert.equal(f.calls(), '');
      } finally { f.close(); }
    });
  }
}

for (const fresh of [false, true]) {
  for (const nestedFirst of [false, true]) {
    test(`A1 ctx2 top-level identity: fresh=${fresh}, nestedFirst=${nestedFirst}`, () => {
      const f = fixture('fresh');
      try {
        renameSync(join(f.root, 'edc-context'), join(f.root, 'ctx2'));
        const head = f.git('rev-parse', 'HEAD');
        const sourceCommit = fresh ? head : f.base;
        const nested = { sourceCommit: fresh ? f.base : head };
        writeFileSync(join(f.root, 'ctx2/manifest.json'), JSON.stringify(nestedFirst
          ? { nested, schemaVersion: 2, sourceCommit }
          : { schemaVersion: 2, sourceCommit, nested }));
        const r = runSourcedContext(f, 'ctx2', `read_manifest_source_commit
printf '\\n'
read_canonical_context_source_commit
if assert_context_fresh; then printf 'FRESH\\n'; else _edc_classify_context_state; fi`);
        assert.equal(r.status, 0, r.stdout + r.stderr);
        assert.deepEqual(r.stdout.trim().split('\n'), [sourceCommit, sourceCommit, fresh ? 'FRESH' : 'STALE']);
        assert.equal(f.calls(), '');
      } finally { f.close(); }
    });
  }
}

for (const schemaVersion of [1, 2]) {
  for (const sourceKind of ['missing', 'symbolic', 'unavailable', 'newline']) {
    test(`A1 ctx2 schema ${schemaVersion} keeps ${sourceKind} lineage refusal`, () => {
      const f = fixture('fresh');
      try {
        renameSync(join(f.root, 'edc-context'), join(f.root, 'ctx2'));
        const sourceCommit = { symbolic: 'HEAD', unavailable: 'f'.repeat(40), newline: `${f.git('rev-parse', 'HEAD')}\n` }[sourceKind];
        writeFileSync(join(f.root, 'ctx2/manifest.json'), JSON.stringify({ schemaVersion, sourceCommit }));
        const r = runSourcedContext(f, 'ctx2', '_edc_classify_context_state\nread_canonical_context_source_commit');
        assert.equal(r.status, 1, r.stdout + r.stderr);
        assert.equal(r.stdout.trim(), 'STALE');
        assert.equal(f.calls(), '');
      } finally { f.close(); }
    });
  }
}

for (const absolute of [false, true]) {
  test(`A1 rejects out-of-project containment root: absolute=${absolute}`, () => {
    const f = fixture('fresh');
    const outside = mkdtempSync(join(tmpdir(), 'edc-context-outside.'));
    try {
      writeFileSync(join(outside, 'manifest.json'), readFileSync(join(f.root, 'edc-context/manifest.json')));
      writeFileSync(join(outside, 'index.md'), '# Context\n## Modules\n');
      const r = runSourcedContext(f, absolute ? outside : relative(f.root, outside), `if assert_context_fresh; then exit 91; fi
if read_manifest_source_commit; then exit 92; fi
_edc_classify_context_state`);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      assert.equal(r.stdout.trim(), 'MISSING');
      assert.equal(f.calls(), '');
    } finally { f.close(); rmSync(outside, { recursive: true, force: true }); }
  });
}

for (const state of ['missing', 'stale']) {
  for (const lens of ['review', 'security', 'delivery', 'quality']) {
    test(`CLI ${lens}: noninteractive ${state} requires explicit policy before model work`, () => {
      const f = fixture(state);
      try {
        const r = f.run([lens, 'diff', f.base, '--committed-only']);
        assert.equal(r.status, 2, r.stdout + r.stderr);
        assert.match(r.stdout + r.stderr, /--refresh-context.*--ignore-context.*--no-context-refresh/s);
        assert.equal(f.calls(), '');
      } finally { f.close(); }
    });
  }
}
for (const input of ['3\n', '\x04', 'invalid\n', '\x1b\n', '\n']) {
  test(`terminal cancel/EOF/invalid choice ${JSON.stringify(input)} launches no model`, () => {
    const f = fixture();
    try {
      const r = f.run(['review', 'full'], input);
      assert.equal(r.status, 2, r.stdout + r.stderr);
      assert.match(r.stdout, /1.*build.*2.*without generated context.*3.*cancel/s);
      assert.equal(f.calls(), '');
    } finally { f.close(); }
  });
}
for (const flag of ['--ignore-context', '--no-context-refresh']) {
  test(`refresh conflicts with ${flag}`, () => {
    const f = fixture();
    try {
      const r = f.run(['delivery', 'full', '--refresh-context', flag]);
      assert.equal(r.status, 2, r.stdout + r.stderr);
      assert.match(r.stderr, /--refresh-context.*conflict/);
      assert.equal(f.calls(), '');
    } finally { f.close(); }
  });
}

for (const state of ['missing', 'stale']) {
  test(`terminal ${state}: positive consent uses existing recovery`, () => {
    const f = fixture(state);
    try {
      const r = f.run(['delivery', 'full'], '1\n');
      assert.equal(r.status, 1, r.stdout + r.stderr); // synthetic agent intentionally fails
      assert.match(r.stdout, new RegExp(`1\\) ${state === 'missing' ? 'build' : 'update'} context`));
      assert.notEqual(f.calls(), '');
      assert.match(r.stdout, /context recovery|context stale|context missing/);
    } finally { f.close(); }
  });
}

for (const lens of ['review', 'security', 'delivery', 'quality']) {
  for (const mode of ['full', 'diff']) {
    test(`terminal without-context choice: ${lens} ${mode}`, () => {
      const f = fixture('stale');
      try {
        const args = [lens, mode, ...(mode === 'diff' ? [f.base, '--committed-only'] : []), '--ignore', 'ignored space/**', '--context-mode', 'advisory'];
        const r = f.run(args, '2\n');
        assert.equal((r.stdout.match(/context choice \[1\/2\/3\]/g) || []).length, 1, r.stdout);
        assert.notEqual(f.calls(), '', r.stdout + r.stderr);
        assert.doesNotMatch(f.calls(), /BUILD DISCOVERY TASK/);
        assert.match(f.calls(), /generated context|Generated context/);
        assert.doesNotMatch(r.stdout, /running the coordinator build|context stale, running/);
      } finally { f.close(); }
    });
  }
}

for (const alias of ['review-all', 'security-review', 'delivery-review', 'quality-review', 'audit']) {
  test(`CLI alias ${alias}: explicit no-build and refresh policy`, () => {
    const f = fixture();
    try {
      const r = f.run([alias, '--diff', `${f.base}...HEAD`, '--committed-only', '--no-context-refresh', '--ignore-context']);
      assert.notEqual(f.calls(), '', r.stdout + r.stderr);
      assert.doesNotMatch(f.calls(), /BUILD DISCOVERY TASK/);
      assert.doesNotMatch(r.stdout + r.stderr, /choose --refresh-context/);
      const refresh = f.run([alias, '--diff', `${f.base}...HEAD`, '--committed-only', '--refresh-context']);
      assert.equal(refresh.status, 1, refresh.stdout + refresh.stderr);
      assert.match(f.calls(), /BUILD DISCOVERY TASK/);
    } finally { f.close(); }
  });
}

test('fresh context bypasses consent; malformed context still offers a choice', () => {
  const f = fixture('fresh');
  try {
    const fresh = f.run(['delivery', 'full']);
    assert.notEqual(f.calls(), '', fresh.stdout + fresh.stderr);
    assert.doesNotMatch(fresh.stdout + fresh.stderr, /choose --refresh-context|context choice/);
    writeFileSync(join(f.root, 'edc-context/manifest.json'), '{malformed');
    const malformed = f.run(['delivery', 'full'], '3\n');
    assert.equal(malformed.status, 2, malformed.stdout + malformed.stderr);
    assert.match(malformed.stdout, /context choice/);
  } finally { f.close(); }
});

for (const lens of ['review', 'security', 'delivery', 'quality']) {
  for (const mode of ['required', 'cancelled', 'late-change']) {
    test(`O2 ${lens}: ${mode} writes precise failed result without model work`, () => {
      const f = fixture(mode === 'late-change' ? 'fresh' : 'missing');
      try {
        if (mode === 'late-change') {
          // The external capability probe runs after freshness preflight. Simulate
          // an intervening filesystem change without replacing production logic.
          writeFileSync(join(f.root, '.git/bin/octocode'), '#!/bin/sh\nrm edc-context/index.md\nexit 1\n', { mode: 0o755 });
        }
        const r = f.run([lens, 'full'], mode === 'cancelled' ? '3\n' : undefined);
        const result = JSON.parse(readFileSync(join(f.root, 'edc-context/build/last-run.json'), 'utf8'));
        assert.equal(result.reasonCode, mode === 'cancelled' ? 'review-cancelled' : 'context-policy-required', r.stdout + r.stderr + JSON.stringify(result));
        assert.equal(r.status, 2, r.stdout + r.stderr);
        assert.equal(result.schemaVersion, 1);
        assert.equal(result.status, 'failed');
        assert.equal(result.exitCode, 2);
        assert.match(result.hint, /--refresh-context.*--ignore-context.*--no-context-refresh/);
        assert.doesNotMatch(result.hint, /subprocess error/);
        assert.equal(f.calls(), '');
        if (mode === 'late-change') {
          assert.equal(existsSync(join(f.root, 'edc-context/index.md')), false);
          assert.match(result.message, /changed after preflight/);
        }
      } finally { f.close(); }
    });
  }
}

test('O2 unknown freshness writes an actionable result', () => {
  const f = fixture('fresh');
  try {
    writeFileSync(join(f.root, '.git/HEAD'), 'invalid HEAD\n');
    const r = f.run(['delivery', 'full']);
    const result = JSON.parse(readFileSync(join(f.root, 'edc-context/build/last-run.json'), 'utf8'));
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.equal(result.reasonCode, 'context-freshness-unknown');
    assert.equal(result.status, 'failed');
    assert.match(result.hint, /check the repository/);
    assert.equal(f.calls(), '');
  } finally { f.close(); }
});

test('O2 Pi check-policy bootstrap refusal keeps its structured result', () => {
  const f = fixture('stale');
  try {
    const resultPath = join(f.root, '.git/pi-result.json');
    const r = spawnSync(process.execPath, [resolve('plugins/edc/hooks/lib/runtime-bootstrap.mjs'), 'edc-delivery-review.sh', '--full'], {
      cwd: f.root, env: { ...f.env, EDC_AGENT_CLI: 'claude', EDC_REVIEW_CONTEXT_CHOICE: 'check', EDC_RESULT_FILE: resultPath }, encoding: 'utf8', timeout: 30000,
    });
    const result = JSON.parse(readFileSync(resultPath, 'utf8'));
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.equal(result.reasonCode, 'context-policy-required');
    assert.equal(result.status, 'failed');
    assert.equal(result.exitCode, 2);
    assert.match(result.hint, /--refresh-context.*--ignore-context.*--no-context-refresh/);
    assert.equal(f.calls(), '');
  } finally { f.close(); }
});

for (const input of ['\x04', 'invalid\n']) {
  test(`O2 cancelled input ${JSON.stringify(input)} preserves custom result destination`, () => {
    const f = fixture();
    try {
      f.env.EDC_RESULT_FILE = join(f.root, '.git/custom-result.json');
      const r = f.run(['security', 'full'], input);
      const result = JSON.parse(readFileSync(f.env.EDC_RESULT_FILE, 'utf8'));
      assert.equal(result.reasonCode, 'review-cancelled');
      assert.equal(r.status, 2);
      assert.equal(result.status, 'failed');
      assert.equal(result.exitCode, 2);
      assert.equal(f.calls(), '');
      assert.equal(existsSync(join(f.root, 'edc-context/build/last-run.json')), false);
    } finally { f.close(); }
  });
}

for (const rootValue of [null, [], false, true, 'not a manifest', 42]) {
  test(`O1 non-object manifest ${JSON.stringify(rootValue)} offers and dispatches build`, () => {
    const f = fixture('fresh');
    try {
      writeFileSync(join(f.root, 'edc-context/manifest.json'), JSON.stringify(rootValue));
      const r = f.run(['delivery', 'full'], '1\n');
      assert.match(r.stdout, /1\) build context then review/);
      assert.equal(r.status, 1, r.stdout + r.stderr); // synthetic build worker fails
      assert.match(f.calls(), /BUILD DISCOVERY TASK/, r.stdout + r.stderr);
      assert.equal(getContextFreshness(f.root).state, 'missing');
    } finally { f.close(); }
  });
}

for (const topLevelFresh of [false, true]) {
  test(`O1 top-level provenance wins over earlier nested key: fresh=${topLevelFresh}`, () => {
    const f = fixture('fresh');
    try {
      const head = f.git('rev-parse', 'HEAD');
      writeFileSync(join(f.root, 'edc-context/manifest.json'), JSON.stringify({
        policy: { sourceCommit: topLevelFresh ? f.base : head, defaultMode: 'advisory' },
        schemaVersion: 2, sourceCommit: topLevelFresh ? head : f.base, modules: [],
      }));
      assert.equal(getContextFreshness(f.root).state, topLevelFresh ? 'fresh' : 'stale');
      const r = f.run(['delivery', 'full'], topLevelFresh ? undefined : '1\n');
      if (topLevelFresh) {
        assert.equal(r.status, 0, r.stdout + r.stderr);
        assert.match(f.calls(), /DELIVERY REVIEW TASK/);
        assert.doesNotMatch(r.stdout + r.stderr, /context choice|context stale, spawning|running the coordinator build/);
      } else {
        assert.match(r.stdout, /1\) update context then review/);
        assert.match(r.stdout, /context stale, spawning claude for edc-update/);
        assert.match(f.calls(), new RegExp(f.base));
      }
    } finally { f.close(); }
  });
}

for (const sourceKind of ['missing-top-level', 'trailing-newline', 'array-source']) {
  test(`O1 object provenance is not normalized: ${sourceKind}`, () => {
    const f = fixture('fresh');
    try {
      const head = f.git('rev-parse', 'HEAD');
      const sourceCommit = sourceKind === 'trailing-newline' ? `${head}\n` : sourceKind === 'array-source' ? [head] : undefined;
      writeFileSync(join(f.root, 'edc-context/manifest.json'), JSON.stringify({ nested: { sourceCommit: head }, schemaVersion: 2, sourceCommit, modules: [] }));
      const r = f.run(['delivery', 'full', '--refresh-context']);
      assert.equal(r.status, 1, r.stdout + r.stderr);
      assert.match(r.stderr, /context update requires a canonical/);
      assert.equal(f.calls(), '');
    } finally { f.close(); }
  });
}

for (const consent of ['menu', 'explicit']) {
  test(`F1 malformed context without sourceCommit rebuilds after ${consent} consent`, () => {
    const f = fixture('fresh');
    try {
      writeFileSync(join(f.root, 'edc-context/manifest.json'), '{broken');
      const args = ['delivery', 'full', ...(consent === 'explicit' ? ['--refresh-context'] : [])];
      const r = f.run(args, consent === 'menu' ? '1\n' : undefined);
      if (consent === 'menu') assert.match(r.stdout, /1\) build context then review/);
      assert.equal(r.status, 1, r.stdout + r.stderr); // synthetic build worker intentionally fails
      assert.match(f.calls(), /BUILD DISCOVERY TASK/, r.stdout + r.stderr);
      assert.doesNotMatch(r.stdout + r.stderr, /context update requires a canonical/);
    } finally { f.close(); }
  });
}

for (const schemaVersion of [1, 2]) {
  for (const [label, sourceCommit] of [['missing', undefined], ['noncanonical', 'HEAD'], ['unavailable', 'f'.repeat(40)]]) {
    test(`F1 valid JSON schema ${schemaVersion} refuses ${label} update provenance`, () => {
      const f = fixture('fresh');
      try {
        const manifest = JSON.stringify({ schemaVersion, sourceCommit, policy: { defaultMode: 'advisory' }, modules: [] });
        writeFileSync(join(f.root, 'edc-context/manifest.json'), manifest);
        const r = f.run(['delivery', 'full', '--refresh-context']);
        assert.equal(r.status, 1, r.stdout + r.stderr);
        assert.match(r.stderr, /context update requires a canonical, locally available manifest sourceCommit/);
        assert.equal(f.calls(), '');
        assert.equal(readFileSync(join(f.root, 'edc-context/manifest.json'), 'utf8'), manifest);
        assert.doesNotMatch(r.stdout + r.stderr, /running the coordinator build/);
      } finally { f.close(); }
    });
  }
}

test('positive consent repairs malformed context even when textual sourceCommit matches HEAD', () => {
  const f = fixture('fresh');
  try {
    writeFileSync(join(f.root, 'edc-context/manifest.json'), `{"sourceCommit":"${f.git('rev-parse', 'HEAD')}",broken`);
    const r = f.run(['delivery', 'full'], '1\n');
    assert.match(f.calls(), /BUILD DISCOVERY TASK/, r.stdout + r.stderr);
  } finally { f.close(); }
});

test('fresh observation never authorizes later recovery', () => {
  const f = fixture('fresh');
  try {
    const r = spawnSync('/bin/bash', ['-c', `source "$1/edc-lib.sh"; source "$1/edc-recover-context.sh"; edc_resolve_review_context_choice context || exit $?; rm edc-context/index.md; recover_context_if_needed`, 'test', resolve('plugins/edc/scripts')], { cwd: f.root, env: { ...f.env, EDC_AGENT_CLI: 'claude', EDC_REVIEW_CONTEXT_CHOICE: 'check' }, encoding: 'utf8', timeout: 30000 });
    assert.notEqual(r.status, 0);
    assert.equal(f.calls(), '', r.stdout + r.stderr);
    assert.match(r.stderr, /consent|--refresh-context/);
  } finally { f.close(); }
});

test('invalid refs and dirty scope fail before any context work', () => {
  const f = fixture();
  try {
    for (const args of [ ['review', 'diff', 'no-such-ref'], ['security', 'diff', f.base] ]) {
      writeFileSync(join(f.root, 'source.js'), 'dirty\n');
      const r = f.run([...args, '--refresh-context']);
      assert.notEqual(r.status, 0);
      assert.equal(f.calls(), '');
      assert.doesNotMatch(r.stdout + r.stderr, /context choice|running the coordinator build/);
    }
  } finally { f.close(); }
});

for (const contextSelection of ['cancel', undefined, 'unexpected']) {
  test(`Pi command cancellation ${String(contextSelection)} creates no background job`, async () => {
    const f = fixture();
    const handlers = new Map();
    const messages = [];
    let command;
    try {
      edcExtension({ on: (name, handler) => handlers.set(name, handler), registerCommand: (_name, config) => { command = config.handler; }, sendMessage: message => messages.push(message) });
      const selections = ['full repo review', 'combined review', contextSelection];
      await command('', { cwd: f.root, hasUI: true, ui: { select: async () => selections.shift() } });
      assert.equal(selections.length, 0);
      assert.equal(existsSync(join(f.root, '.git/edc/status')), false);
      assert.equal(f.calls(), '');
      assert.match(messages.at(-1).content, /cancelled/);
    } finally { await handlers.get('session_shutdown')?.({}, { ui: {} }); f.close(); }
  });
}

test('Pi three-way choice preserves argv and cancels closed', async () => {
  assert.equal(typeof scope.chooseReviewContext, 'function');
  const args = ['HEAD', '--base', 'release/base', '--committed-only', '--ignore', 'space glob/**'];
  for (const state of ['missing', 'stale']) {
    for (const index of [0, 1, 2, -1, -2]) {
      let count = 0;
      const result = await scope.chooseReviewContext(args, { cwd: '/unused', hasUI: true, ui: { select: async (_title, items) => { count++; assert.equal(items.length, 3); return index === -2 ? 'invalid' : items[index]; } } }, { state });
      assert.equal(count, 1);
      if (index === 0) { assert.deepEqual(result.args, args); assert.equal(result.contextChoice, 'refresh'); }
      else if (index === 1) assert.deepEqual(result.args, [...args, '--ignore-context']);
      else assert.equal(result.cancelled, true);
    }
  }
});

test('Pi fresh/explicit bypass and unknown/no-UI refusal', async () => {
  assert.equal(typeof scope.chooseReviewContext, 'function');
  const ctx = { cwd: '/unused', hasUI: true, ui: { select: async () => { throw Error('unexpected prompt'); } } };
  assert.deepEqual((await scope.chooseReviewContext(['--full'], ctx, { state: 'fresh' })).args, ['--full']);
  for (const flag of ['--ignore-context', '--no-context-refresh', '--refresh-context']) {
    const result = await scope.chooseReviewContext(['--full', flag], ctx, { state: 'missing' });
    assert.equal(result.cancelled, undefined);
  }
  assert.ok((await scope.chooseReviewContext([], ctx, { state: 'unknown' })).error);
  assert.ok((await scope.chooseReviewContext([], { ...ctx, hasUI: false }, { state: 'missing' })).error);
  assert.ok((await scope.chooseReviewContext(['--refresh-context', '--ignore-context'], ctx)).error);
});
