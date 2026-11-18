#!/usr/bin/env node
// Opt-in machine records. Human prose is never parsed into findings.
import { closeSync, constants, fstatSync, fsyncSync, lstatSync, openSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

const marker = '```edc-findings-v1';
const phases = ['security', 'delivery', 'quality'];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function requireThat(condition, message) { if (!condition) throw new Error(message); }
function text(value, label) { requireThat(typeof value === 'string' && value.trim().length > 0, `${label} must be nonempty text`); }
function keys(value, expected, label) {
  requireThat(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`);
  requireThat(isDeepStrictEqual(Object.keys(value).sort(), [...expected].sort()), `${label} has missing or unknown fields`);
}
function texts(value, label) { requireThat(Array.isArray(value), `${label} must be an array`); value.forEach(x => text(x, label)); }
function inside(root, path) { const rel = relative(root, path); return rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel); }
function unlinkedParents(path) {
  for (let parent = dirname(resolve(path)); ; parent = dirname(parent)) {
    const st = lstatSync(parent);
    requireThat(st.isDirectory() && !st.isSymbolicLink(), `linked/non-directory parent: ${parent}`);
    if (parent === dirname(parent)) break;
  }
}
export function privateBytes(path, root) {
  const absolute = resolve(path), allowed = resolve(root);
  requireThat(inside(allowed, absolute), `report outside private root: ${path}`);
  // Check all lexical ancestors, not just realpath containment.
  unlinkedParents(absolute);
  requireThat(realpathSync(allowed) === allowed, 'linked private root');
  const fd = openSync(absolute, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const st = fstatSync(fd);
    requireThat(st.isFile() && st.nlink === 1, `not a single-link regular report: ${path}`);
    return readFileSync(fd);
  } finally { closeSync(fd); }
}
function outputIdentity(path) {
  // Reserved paths cannot contain parent traversal. Native ancestor resolution
  // preserves aliases with ordinary missing suffixes and fails closed on errors.
  let existing = path;
  const missing = [];
  for (;;) {
    try { lstatSync(existing); break; } catch (error) {
      if (error.code !== 'ENOENT' || dirname(existing) === existing) throw error;
      missing.unshift(basename(existing));
      existing = dirname(existing);
    }
  }
  const canonical = resolve(realpathSync.native(existing), ...missing);
  // Conservatively reserve case aliases on platforms normally using case-insensitive volumes.
  return ['darwin', 'win32'].includes(process.platform) ? canonical.normalize('NFC').toLowerCase() : canonical;
}
export function checkOutputPath(path, reserved = []) {
  text(path, 'output path');
  for (const destination of reserved) {
    text(destination, 'reserved coordinator output path');
    requireThat(!destination.split(sep === '\\' ? /[\\/]/ : '/').includes('..'),
      `unsupported reserved coordinator output path (parent-directory components are not allowed in structured mode): ${destination}`);
  }
  const absolute = resolve(path);
  unlinkedParents(absolute);
  const identity = outputIdentity(absolute);
  for (const destination of reserved) {
    requireThat(identity !== outputIdentity(destination), `findings destination collides with coordinator output: ${destination}`);
  }
  try { lstatSync(absolute); } catch (error) { if (error.code === 'ENOENT') return absolute; throw error; }
  throw new Error(`findings output already exists: ${absolute}`);
}
export function publishArtifact(path, value) {
  const absolute = checkOutputPath(path);
  const fd = openSync(absolute, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`); fsyncSync(fd); } finally { closeSync(fd); }
  return { path: absolute, sha256: hash(readFileSync(absolute)), schemaVersion: 1 };
}
function candidateGit(repo, commit, ...args) {
  requireThat(typeof commit === 'string' && /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(commit), 'immutable candidate commit required');
  return execFileSync('git', args, { cwd: repo, maxBuffer: 32 * 1024 * 1024 });
}
function sourceBounds(repo, commit) {
  const cache = new Map();
  return path => {
    text(path, 'source path');
    requireThat(!isAbsolute(path) && !/[\\\x00-\x1f\x7f]/.test(path) && !path.split('/').some(p => ['', '.', '..'].includes(p)), 'unsafe relative source path');
    if (!cache.has(path)) {
      const tree = candidateGit(repo, commit, 'ls-tree', '-z', commit, '--', `:(literal)${path}`).toString('utf8');
      const match = /^(100644|100755) blob ([a-f0-9]+)\t([^\0]+)\0$/.exec(tree);
      requireThat(match && match[3] === path, `source is not a regular candidate blob: ${path}`);
      const bytes = candidateGit(repo, commit, 'cat-file', 'blob', match[2]);
      const source = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
      requireThat(!source.includes('\0'), `binary source: ${path}`);
      cache.set(path, source === '' ? 0 : source.split('\n').length - (source.endsWith('\n') ? 1 : 0));
    }
    return cache.get(path);
  };
}
function location(value, bounds) {
  keys(value, ['path', 'startLine', 'endLine'], 'location');
  requireThat(Number.isSafeInteger(value.startLine) && Number.isSafeInteger(value.endLine) && value.startLine >= 1 && value.endLine >= value.startLine && value.endLine <= bounds(value.path), 'source line range outside immutable candidate');
}
function validateRecord(value, source, bounds) {
  keys(value, ['id', 'title', 'severity', 'primaryLocation', 'relatedLocations', 'description', 'impact', 'recommendation', 'verification'], 'finding');
  for (const field of ['id', 'title', 'description', 'impact', 'recommendation']) text(value[field], field);
  requireThat(['critical', 'high', 'medium', 'low', 'blocker', 'important', 'advisory'].includes(value.severity), 'invalid severity');
  const prefix = `${source.phase}:${source.namespace}:`;
  let id = value.id;
  if (source.namespace === null) {
    requireThat(new RegExp(`^${source.phase}:[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$`).test(id), 'invalid canonical finding ID');
  } else {
    if (id.startsWith(prefix)) id = id.slice(prefix.length);
    requireThat(/^[A-Za-z0-9._-]+$/.test(id), 'invalid module-local finding ID');
    id = prefix + id;
  }
  location(value.primaryLocation, bounds);
  requireThat(Array.isArray(value.relatedLocations), 'relatedLocations must be an array');
  value.relatedLocations.forEach(x => location(x, bounds));
  keys(value.verification, ['evidence', 'limitations'], 'verification');
  texts(value.verification.evidence, 'verification evidence');
  requireThat(value.verification.evidence.length > 0, 'verification evidence required');
  texts(value.verification.limitations, 'verification limitations');
  return { ...value, id };
}
function strictJson(value) {
  const parsed = JSON.parse(value);
  // JSON.parse accepts repeated keys. Scan validated JSON tokens solely to reject
  // that ambiguity; strings are consumed whole, including escaped delimiters.
  const containers = [];
  for (const token of value.matchAll(/"(?:\\.|[^"\\])*"|[{}\[\]]/g)) {
    if (token[0] === '{') containers.push(new Set());
    else if (token[0] === '[') containers.push(null);
    else if (token[0] === '}' || token[0] === ']') containers.pop();
    else if (value.slice(token.index + token[0].length).trimStart().startsWith(':')) {
      const key = JSON.parse(token[0]), keys = containers.at(-1);
      requireThat(!keys.has(key), `duplicate JSON key: ${key}`);
      keys.add(key);
    }
  }
  return parsed;
}
export function parseBlock(markdown) {
  const lines = markdown.split(/\r?\n/);
  const starts = lines.flatMap((line, i) => line === marker ? [i] : []);
  requireThat(starts.length === 1, 'expected exactly one declared edc-findings-v1 block');
  const end = lines.indexOf('```', starts[0] + 1);
  requireThat(end > starts[0] + 1, 'unterminated/empty findings block');
  const block = strictJson(lines.slice(starts[0] + 1, end).join('\n'));
  keys(block, ['schemaVersion', 'status', 'findings', 'limitations'], 'findings block');
  requireThat(block.schemaVersion === 1, 'unsupported findings schema');
  requireThat(['complete', 'partial', 'unavailable'].includes(block.status), 'invalid source review status');
  texts(block.limitations, 'report limitations');
  requireThat(block.status === 'complete' || block.limitations.length > 0, 'incomplete review requires limitations');
  requireThat(Array.isArray(block.findings), 'findings must be an array');
  requireThat(block.status !== 'unavailable' || block.findings.length === 0, 'unavailable review cannot contain findings');
  return block;
}
export function readSourceReport(source, repo, commit) {
  requireThat(phases.includes(source.phase), 'invalid source phase');
  requireThat((source.namespace === null && source.phase === 'quality') || (typeof source.namespace === 'string' && /^[A-Za-z0-9._-]+$/.test(source.namespace)), 'invalid source namespace');
  candidateGit(repo, commit, 'cat-file', '-e', `${commit}^{commit}`);
  const bytes = privateBytes(source.path, source.root);
  const block = parseBlock(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  const bounds = sourceBounds(repo, commit);
  const findings = block.findings.map(x => validateRecord(x, source, bounds));
  requireThat(new Set(findings.map(x => x.id)).size === findings.length, 'duplicate/conflicting finding IDs');
  return { status: block.status, limitations: block.limitations, findings, provenance: { phase: source.phase, namespace: source.namespace, path: resolve(source.path), sha256: hash(bytes) } };
}

export function collectFindings({ repo, commit, base, kind, registry, phaseResults }) {
  candidateGit(repo, commit, 'cat-file', '-e', `${commit}^{commit}`);
  const artifact = { schemaVersion: 1, kind: 'edc-findings', candidate: { commit, base, kind }, status: 'success', phases: phaseResults, reports: [], findings: [], errors: [] };
  const ids = new Set();
  for (const phase of phases) {
    try {
      const descriptor = strictJson(privateBytes(join(registry, `${phase}.json`), registry).toString('utf8'));
      const runRoot = dirname(dirname(resolve(registry)));
      requireThat(typeof descriptor.root === 'string' && inside(runRoot, resolve(descriptor.root)), 'source root outside private runs');
      requireThat(Array.isArray(descriptor.sources) && descriptor.sources.length > 0, `${phase}: no expected sources`);
      const phaseFindings = [];
      for (const source of descriptor.sources) {
        try {
          requireThat(source.phase === phase && source.root === descriptor.root, 'source phase/root mismatch');
          if (source.accountOnly === true) {
            const bytes = privateBytes(source.path, source.root);
            artifact.reports.push({ phase, namespace: source.namespace, path: source.path, sha256: hash(bytes), status: 'account-only', limitations: ['explicit policy exclusion; not reviewed'] });
            continue;
          }
          const report = readSourceReport(source, repo, commit);
          artifact.reports.push({ ...report.provenance, status: report.status, limitations: report.limitations });
          if (report.status !== 'complete') artifact.status = 'success-with-warning';
          for (const finding of report.findings) {
            requireThat(!ids.has(finding.id), `duplicate/conflicting ID: ${finding.id}`);
            ids.add(finding.id); phaseFindings.push(finding);
            artifact.findings.push({ ...finding, phase, report: report.provenance });
          }
        } catch (error) { artifact.errors.push({ phase, path: source.path, message: error.message }); }
      }
      if (phase === 'quality') {
        const synthesis = readSourceReport({ path: descriptor.synthesis, root: descriptor.root, phase, namespace: null }, repo, commit);
        const order = xs => [...xs].sort((a, b) => a.id.localeCompare(b.id));
        requireThat(isDeepStrictEqual(order(synthesis.findings), order(phaseFindings)), 'quality synthesis lost, changed, or duplicated canonical records');
        const complexity = privateBytes(descriptor.complexity, descriptor.root).toString('utf8');
        requireThat(!complexity.split(/\r?\n/).includes(marker), 'complexity must reference IDs, not duplicate machine records');
        artifact.reports.push({ ...synthesis.provenance, status: synthesis.status, limitations: synthesis.limitations });
        if (synthesis.status !== 'complete') artifact.status = 'success-with-warning';
      }
    } catch (error) { artifact.errors.push({ phase, message: error.message }); }
  }
  if (artifact.errors.length || phaseResults.some(p => p.status === 'failed' || p.exitCode !== 0)) artifact.status = 'failed';
  else if (phaseResults.some(p => p.status !== 'success' || p.childExitCode !== 0)) artifact.status = 'success-with-warning';
  return artifact;
}

function prompt(phase, namespace) {
  return `\nMACHINE FINDINGS CONTRACT (opt-in; keep the human report):
Append exactly one fenced edc-findings-v1 JSON block to your declared report, no extra output file.
The status describes completion of the assigned source review, not correctness of the implementation or certainty of every conclusion.
- complete: all assigned source and necessary supporting evidence were inspected and the scoped analysis finished; findings may be empty or nonempty, and limitations may be nonempty.
- partial: some assigned source or necessary supporting evidence was not inspected, or the scoped analysis did not finish. Name the unreviewed paths or contracts and their effect in limitations.
- unavailable: no substantive assigned-source review was possible; emit no findings and explain the blocker in limitations.
Delivery verdicts such as No spec available or partially delivered, and unresolved requirement intent, do not determine source-review status. Review observable claims without inventing requirements.
Unexecuted tests, builds or external services, ignored generated context, and unavailable optional tools do not by themselves make source coverage partial. Record these verification limits honestly in limitations; use partial if they actually prevented necessary source inspection or analysis.
A complete source review does not claim tests passed, exhaustive bug discovery, or complete architectural understanding. Never upgrade an explicit partial or unavailable report by guessing from its prose.
Use {"schemaVersion":1,"status":"complete","findings":[],"limitations":[]} only for a completed review with no findings or limitations; retain any actual limitations even when status is complete.
Each finding has exactly: id, title, severity, primaryLocation, relatedLocations, description, impact, recommendation, verification.
Use IDs ${phase}:${namespace}:F1, F2, etc. (full prefix on each ID). Severity is lowercase critical/high/medium/low/blocker/important/advisory.
Locations have exactly path (repository-relative), startLine, endLine (positive integers in immutable candidate regular source blobs).
verification has evidence (nonempty array of concrete source/check evidence strings) and limitations (array of strings).
All text fields must be complete and nonempty. Keep independent repairable defects separate; one shared defect across callers uses relatedLocations, not duplicate records.
For input/output contract findings, description retains already-established expected versus actual input arity/types and output shape/types; impact states the affected consumer and consequence.
When grouping a shared defect or shortening prose, retain these contract distinctions; relatedLocations identify affected callers but do not replace the explanation.
Distinguish source-observed behavior from conditional downstream consequences; retain concrete support in verification.evidence and genuine evidence limits in verification.limitations.
Record only established contract facts; do not infer missing details, invent effects, or add findings to satisfy this guidance.
Human summaries reference canonical IDs. Do not author candidate identity or provenance. Do not claim tests executed without evidence.
This contract adds no source permissions, subprocesses, or write surfaces. Never reconstruct records from another report's prose.\n`;
}
function register(phase, root, sources, extras = {}) {
  const registry = process.env.EDC_FINDINGS_REGISTRY;
  requireThat(registry, 'findings registry required');
  publishArtifact(join(registry, `${phase}.json`), { root, sources, ...extras });
}
function command() {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === 'check-output') console.log(checkOutputPath(args[0], args.slice(1)));
  else if (cmd === 'prompt') console.log(prompt(...args));
  else if (cmd === 'register-security') {
    const [manifest, root] = args;
    const modules = JSON.parse(privateBytes(manifest, root)).modules;
    register('security', root, modules.map(m => ({ phase: 'security', namespace: m.name, root, path: join(dirname(manifest), `report-${m.name}.md`), accountOnly: m.reviewPolicy === 'account-only' })));
  } else if (cmd === 'register-quality') {
    const [manifest, root, synthesis, complexity] = args;
    const tasks = JSON.parse(privateBytes(manifest, root)).tasks;
    register('quality', root, tasks.map(t => ({ phase: 'quality', namespace: t.module, root, path: t.outputs[0] })), { synthesis, complexity });
  } else if (cmd === 'register-delivery') {
    const [path, root] = args;
    register('delivery', root, [{ phase: 'delivery', namespace: 'main', path, root }]);
  } else throw new Error(`unknown findings command: ${cmd}`);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { command(); } catch (error) { console.error(`findings: ${error.message}`); process.exitCode = 1; }
}
