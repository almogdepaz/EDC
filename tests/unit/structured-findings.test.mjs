import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, symlinkSync, linkSync, realpathSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const modulePath = '../../plugins/edc/hooks/lib/review-findings.mjs';
const record = () => ({ id: 'F1', title: 'preserve zero', severity: 'medium', primaryLocation: { path: 'a.js', startLine: 1, endLine: 1 }, relatedLocations: [{ path: 'b.js', startLine: 1, endLine: 2 }], description: 'zero becomes the default', impact: 'extra attempts occur', recommendation: 'default only absent values', verification: { evidence: ['source and consumer read'], limitations: ['not executed'] } });
const block = (findings = [record()], status = 'complete') => '\n```edc-findings-v1\n' + JSON.stringify({ schemaVersion: 1, status, findings, limitations: status === 'complete' ? [] : ['coverage incomplete'] }) + '\n```\n';
function fixture(sources = { 'a.js': 'one\ntwo\n', 'b.js': 'three\nfour\n' }) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'edc-findings-')));
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8', env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null' } }).trim();
  git('init', '-q'); git('config', 'user.name', 'Test'); git('config', 'user.email', 'test@example.com');
  for (const [path, contents] of Object.entries(sources)) writeFileSync(join(root, path), contents);
  symlinkSync('a.js', join(root, 'link.js'));
  git('add', '.'); git('-c', 'commit.gpgsign=false', 'commit', '-qm', 'candidate');
  const candidate = git('rev-parse', 'HEAD');
  const reports = join(root, '.git', 'reports'); mkdirSync(reports);
  const report = join(reports, 'module.md'); writeFileSync(report, '# Any human format\n' + block());
  return { root, candidate, reports, report, close: () => rmSync(root, { recursive: true, force: true }) };
}
test('structured records validate against immutable source, preserve related locations and namespace local IDs', async () => {
  const { readSourceReport } = await import(modulePath); const f = fixture();
  try {
    writeFileSync(join(f.root, 'b.js'), 'working tree poison');
    const parsed = readSourceReport({ path: f.report, root: f.reports, phase: 'security', namespace: 'module' }, f.root, f.candidate);
    assert.equal(parsed.findings[0].id, 'security:module:F1');
    assert.equal(parsed.findings[0].relatedLocations[0].endLine, 2);
    assert.match(parsed.provenance.sha256, /^[a-f0-9]{64}$/);
    for (const namespace of [undefined, 12, true, null]) {
      assert.throws(() => readSourceReport({ path: f.report, root: f.reports, phase: 'security', namespace }, f.root, f.candidate), /namespace/);
    }
  } finally { f.close(); }
});
test('strict blocks reject malformed/missing records, duplicates, false empty success, paths and ranges', async () => {
  const { readSourceReport } = await import(modulePath); const f = fixture();
  try {
    const invalid = ['No findings', block() + block(), '```edc-findings-v1\n{}\n```', block([record(), record()])];
    for (const mutate of [
      x => { x.primaryLocation.path = '../a.js'; }, x => { x.primaryLocation.path = '/a.js'; },
      x => { x.primaryLocation.path = 'link.js'; }, x => { x.relatedLocations[0].endLine = 3; },
      x => { x.primaryLocation.startLine = true; }, x => { x.extra = 'unknown'; },
      x => { x.description = ''; }, x => { x.severity = 'unknown'; },
    ]) { const r = record(); mutate(r); invalid.push(block([r])); }
    for (const value of invalid) {
      writeFileSync(f.report, value);
      assert.throws(() => readSourceReport({ path: f.report, root: f.reports, phase: 'security', namespace: 'module' }, f.root, f.candidate));
    }
    writeFileSync(f.report, block([], 'unavailable'));
    assert.equal(readSourceReport({ path: f.report, root: f.reports, phase: 'security', namespace: 'module' }, f.root, f.candidate).status, 'unavailable');
    writeFileSync(f.report, block([]));
    assert.equal(readSourceReport({ path: f.report, root: f.reports, phase: 'security', namespace: 'module' }, f.root, f.candidate).findings.length, 0);
    assert.throws(() => readSourceReport({ path: f.report, root: f.reports, phase: 'security', namespace: 'module' }, f.root, 'HEAD'));
  } finally { f.close(); }
});
test('duplicate JSON keys cannot hide records behind an empty successful array', async () => {
  const { parseBlock } = await import(modulePath);
  assert.throws(() => parseBlock(block().replace('"findings":[', '"findings":[],"findings":[')), /duplicate JSON key/);
});

test('collector requires every source, namespaces local IDs, and preserves partial phase results', async () => {
  const { collectFindings } = await import(modulePath); const f = fixture();
  try {
    const registry = join(f.reports, 'registry'); mkdirSync(registry);
    const source = (phase, namespace, content = block()) => {
      const path = join(f.reports, `${phase}-${namespace}.md`); writeFileSync(path, content);
      return { phase, namespace, path, root: f.reports };
    };
    const security = [source('security', 'one'), source('security', 'two'), { ...source('security', 'account', '# explicitly excluded by policy'), accountOnly: true }];
    const delivery = [source('delivery', 'main', block([], 'unavailable'))];
    const quality = [source('quality', 'mapping', block([{ ...record(), id: 'quality:mapping:F1' }]))];
    const synthesis = join(f.reports, 'issues.md'), complexity = join(f.reports, 'complexity.md');
    writeFileSync(synthesis, block([{ ...record(), id: 'quality:mapping:F1' }]));
    writeFileSync(complexity, '# quality summary\nsee quality:mapping:F1\n');
    for (const [phase, sources] of [['security', security], ['delivery', delivery], ['quality', quality]]) {
      writeFileSync(join(registry, `${phase}.json`), JSON.stringify({ root: f.reports, sources, synthesis, complexity }));
    }
    const phaseResults = ['security', 'delivery', 'quality'].map(phase => ({ phase, status: 'success', exitCode: 0, childExitCode: 0 }));
    const collect = () => collectFindings({ repo: f.root, commit: f.candidate, base: f.candidate, kind: 'committed', registry, phaseResults });
    const result = collect();
    assert.equal(result.status, 'success-with-warning');
    assert.deepEqual(result.findings.map(x => x.id), ['security:one:F1', 'security:two:F1', 'quality:mapping:F1']);
    assert.equal(result.reports.find(r => r.namespace === 'account').status, 'account-only');
    writeFileSync(security[1].path, '# missing structured block');
    let partial = collect();
    assert.equal(partial.status, 'failed'); assert.equal(partial.findings.length, 2);
    assert.equal(partial.phases.length, 3); assert.match(partial.errors[0].message, /exactly one/);
    writeFileSync(security[1].path, block());
    writeFileSync(synthesis, block([]));
    assert.match(collect().errors[0].message, /synthesis lost/);
    writeFileSync(synthesis, block([{ ...record(), id: 'quality:mapping:F1' }]));
    writeFileSync(complexity, block([]));
    assert.match(collect().errors[0].message, /complexity must reference/);
    writeFileSync(complexity, 'human summary only');
    phaseResults[0] = { phase: 'security', status: 'failed', exitCode: 1, childExitCode: 1 };
    partial = collect(); assert.equal(partial.status, 'failed'); assert.equal(partial.findings.length, 3);
  } finally { f.close(); }
});

test('collector preserves authored input/output contracts, grouped callers and conditional consequences', async () => {
  const { collectFindings } = await import(modulePath);
  const detail = JSON.parse(readFileSync(new URL('../fixtures/structured-findings/contract-detail.json', import.meta.url), 'utf8'));
  const f = fixture(detail.sources);
  try {
    const registry = join(f.reports, 'registry'); mkdirSync(registry);
    const records = detail.findings.map(finding => ({ ...finding, id: `quality:contracts:${finding.id}` }));
    const synthesis = join(f.reports, 'issues.md'), complexity = join(f.reports, 'complexity.md');
    writeFileSync(synthesis, block(records));
    writeFileSync(complexity, 'see quality:contracts:F1 and quality:contracts:F2');
    for (const phase of ['security', 'delivery', 'quality']) {
      const path = join(f.reports, `${phase}.md`);
      writeFileSync(path, '# human summary may be shorter\n' + block(phase === 'quality' ? records : []));
      writeFileSync(join(registry, `${phase}.json`), JSON.stringify({ root: f.reports,
        sources: [{ phase, namespace: 'contracts', path, root: f.reports }], synthesis, complexity }));
    }
    const phaseResults = ['security', 'delivery', 'quality'].map(phase => ({ phase, status: 'success', exitCode: 0, childExitCode: 0 }));
    const collect = () => collectFindings({ repo: f.root, commit: f.candidate, base: f.candidate, kind: 'committed', registry, phaseResults });
    const result = collect();
    assert.equal(result.status, 'success');
    assert.deepEqual(result.findings.map(({ phase, report, ...finding }) => finding), records);
    const shortened = structuredClone(records);
    shortened[1].impact = 'formatting fails';
    writeFileSync(synthesis, block(shortened));
    assert.equal(collect().status, 'failed', 'synthesis cannot discard the conditional consequence');
    assert.match(collect().errors[0].message, /synthesis lost, changed, or duplicated/);
  } finally { f.close(); }
});

test('destination identity supports aliases and ordinary absent suffixes but rejects parent traversal', async () => {
  const { checkOutputPath } = await import(modulePath); const f = fixture();
  try {
    mkdirSync(join(f.root, 'target/deep'), { recursive: true });
    symlinkSync('target/deep', join(f.root, 'alias'));
    const output = join(f.root, 'target/findings.json');
    for (const reserved of [f.root + '/alias/../missing/../findings.json', '../elsewhere.json', f.root + '/missing/../alias/../findings.json']) {
      assert.throws(() => checkOutputPath(output, [reserved]), /unsupported reserved coordinator output path.*parent-directory/);
      // Raw reserved-path validation precedes even the findings parent's lookup.
      assert.throws(() => checkOutputPath(join(f.root, 'absent/findings.json'), [reserved]), /unsupported reserved coordinator output path.*parent-directory/);
    }
    assert.equal(checkOutputPath(output, [f.root + '/alias/missing/other.json']), output);
    assert.equal(checkOutputPath(output, [f.root + '/ordinary/other.json']), output);
    assert.equal(checkOutputPath(output, [f.root + '/..ordinary/other.json']), output);
    symlinkSync('target', join(f.root, 'target-alias'));
    assert.throws(() => checkOutputPath(output, [f.root + '/target-alias/findings.json']), /collides with coordinator output/);
    symlinkSync(output, join(f.root, 'dangling'));
    assert.throws(() => checkOutputPath(output, [join(f.root, 'dangling')]), /ENOENT/);
  } finally { f.close(); }
});

test('report and publication containment reject symlinks, hardlinks and overwrite', async () => {
  const { readSourceReport, checkOutputPath, publishArtifact } = await import(modulePath); const f = fixture();
  try {
    const read = path => readSourceReport({ path, root: f.reports, phase: 'delivery', namespace: 'main' }, f.root, f.candidate);
    const link = join(f.reports, 'symbol.md'); symlinkSync(f.report, link); assert.throws(() => read(link));
    const hard = join(f.reports, 'hard.md'); linkSync(f.report, hard); assert.throws(() => read(hard));
    const dir = join(f.root, 'alias'); symlinkSync(f.reports, dir); assert.throws(() => read(join(dir, 'module.md')));
    assert.throws(() => checkOutputPath(f.report)); assert.throws(() => checkOutputPath(join(dir, 'output.json')));
    const out = join(f.root, 'findings.json'); publishArtifact(out, { status: 'failed' });
    assert.throws(() => publishArtifact(out, {}));
  } finally { f.close(); }
});
