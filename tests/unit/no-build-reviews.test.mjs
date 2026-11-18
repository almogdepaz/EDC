import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync, realpathSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import { createHash } from "node:crypto";

const scripts = resolve("plugins/edc/scripts");

function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "edc-no-build.")));
  const env = { ...process.env, EDC_AGENT_CLI: "claude", EDC_REVIEW_MODEL: "test-model", EDC_BUILD_MODEL: "test-model", EDC_PARALLEL: "0", GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" };
  const git = (...args) => execFileSync("git", args, { cwd: root, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  git("init", "-q");
  git("config", "user.name", "Test");
  git("config", "user.email", "test@example.com");
  git("config", "commit.gpgsign", "false");
  mkdirSync(join(root, "src"));
  writeFileSync(join(root, "src/old.js"), "export const old = 1;\n");
  git("add", "."); git("commit", "-qm", "base");
  const base = git("rev-parse", "HEAD");
  writeFileSync(join(root, "src/new.js"), "export const evidence = 'candidate-only';\n");
  git("add", "."); git("commit", "-qm", "candidate");
  const candidate = git("rev-parse", "HEAD");
  mkdirSync(join(root, ".git/mock-bin"));
  mkdirSync(join(root, ".git/prompts"));
  writeFileSync(join(root, ".git/mock-bin/claude"), `#!/usr/bin/env python3
import sys, pathlib, re, uuid, subprocess
prompt = sys.stdin.read()
for i, arg in enumerate(sys.argv[1:], 1):
    if arg == '--system-prompt-file': prompt = pathlib.Path(sys.argv[i+1]).read_text()
    elif arg.startswith('@') and pathlib.Path(arg[1:]).is_file(): prompt = pathlib.Path(arg[1:]).read_text()
pathlib.Path('.git/prompts/' + str(uuid.uuid4())).write_text(prompt)
sha = re.search(r'(?:git show |DELIVERY_TARGET_COMMIT: )([a-f0-9]{40})', prompt)
if sha and 'src/new.js' in prompt:
    evidence = subprocess.check_output(['git', 'show', sha.group(1)+':src/new.js'], text=True)
    with open('.git/evidence', 'a') as log: log.write(evidence)
if 'AUDIT SYNTHESIS TASK' in prompt:
    report_dir = pathlib.Path(re.search(r'^AUDIT_WORKER_REPORTS_DIR: (.+)$', prompt, re.M).group(1))
    staged = {str(p): p.read_text() for p in report_dir.glob('*.md')}
    import json
    pathlib.Path('.git/synthesis-inputs.json').write_text(json.dumps(staged))
    if sha:
        pathlib.Path('.git/synthesis-evidence').write_text(subprocess.check_output(['git', 'show', sha.group(1)+':src/new.js'], text=True))
    paths = re.findall(r'^CANONICAL_(?:COMPLEXITY|ISSUES)_REPORT: (.+)$', prompt, re.M)
elif 'AUDIT WORKER TASK' in prompt:
    paths = re.findall(r'^AUDIT_REPORT_PATH: (.+)$', prompt, re.M)
elif 'DELIVERY REVIEW TASK' in prompt:
    paths = re.findall(r'^DELIVERY_REPORT_PATH: (.+)$', prompt, re.M)
else:
    paths = re.findall(r'Write your report to \x60([^\x60]+report-[^\x60]+\\.md)\x60', prompt)
if not paths:
    print('unexpected prompt (possible hidden context build)', file=sys.stderr); sys.exit(9)
for path in paths:
    import os
    if os.environ.get('EDC_TEST_MISSING_COMPLEXITY') == '1' and 'CANONICAL_COMPLEXITY_REPORT: '+path in prompt:
        continue
    p = pathlib.Path(path); p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text('## Findings\\n\\nverified candidate source; no findings.\\n')
    import os, json
    if os.environ.get('EDC_TEST_STRUCTURED') == '1' and 'CANONICAL_COMPLEXITY_REPORT: '+path not in prompt:
        if os.environ.get('EDC_TEST_MISSING_BLOCK') != '1' or 'DELIVERY REVIEW TASK' not in prompt:
            records = []
            if os.environ.get('EDC_TEST_FINDING') == '1':
                if 'AUDIT SYNTHESIS TASK' in prompt:
                    for contents in staged.values():
                        records.extend(json.loads(contents.split('\x60\x60\x60edc-findings-v1\\n')[1].split('\\n\x60\x60\x60')[0])['findings'])
                else:
                    namespace = re.search(r'Use IDs ([A-Za-z0-9:._-]+):F1', prompt).group(1)
                    records = [{'id':namespace+':F1', 'title':'preserve zero', 'severity':'medium',
                                'primaryLocation':{'path':'src/new.js','startLine':1,'endLine':1},
                                'relatedLocations':[{'path':'src/old.js','startLine':1,'endLine':1}],
                                'description':'zero becomes three', 'impact':'extra attempts occur', 'recommendation':'default only absence',
                                'verification':{'evidence':['candidate blobs inspected'], 'limitations':['not executed']}}]
            if os.environ.get('EDC_TEST_SYNTHESIS_LOSS') == '1' and 'AUDIT SYNTHESIS TASK' in prompt:
                records = []
            limitations = json.loads(os.environ.get('EDC_TEST_REPORT_LIMITATIONS', '[]'))
            status = 'complete'
            if 'DELIVERY REVIEW TASK' in prompt:
                status = os.environ.get('EDC_TEST_DELIVERY_STATUS', 'complete')
                if status != 'complete': limitations.append('Assigned source src/old.js could not be inspected.')
                if limitations: p.write_text('## Delivery / Architecture Review\\n\\nDelivery verdict: No spec available. Observable claims reviewed; verification limits retained.\\n')
            if status == 'unavailable': records = []
            with p.open('a') as output:
                output.write('\\n\x60\x60\x60edc-findings-v1\\n'+json.dumps({'schemaVersion':1, 'status':status, 'findings':records, 'limitations':limitations})+'\\n\x60\x60\x60\\n')
`, { mode: 0o755 });
  writeFileSync(join(root, ".git/mock-bin/octocode"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  env.PATH = `${join(root, ".git/mock-bin")}:${env.PATH}`;
  env.EDC_KEEP_REVIEW_TASKS = "1";
  env.EDC_KEEP_AUDIT_TASKS = "1";
  const run = (script, args) => spawnSync(process.env.BASH_BIN || "bash", [join(scripts, script), ...args], { cwd: root, env, encoding: "utf8", timeout: 60000 });
  const promptList = () => readdirSync(join(root, ".git/prompts")).map(p => readFileSync(join(root, ".git/prompts", p), "utf8"));
  const prompts = () => promptList().join("\n");
  return { root, env, git, base, candidate, run, prompts, promptList, close: () => rmSync(root, { recursive: true, force: true }) };
}

test('opt-in findings output uses immutable candidate and exposes provenance; missing block fails without dropping phases', () => {
  const f = fixture();
  try {
    f.env.EDC_TEST_STRUCTURED = '1';
    f.env.EDC_RESULT_FILE = join(f.root, '.git/combined-result.json');
    for (const missing of [false, true]) {
      f.env.EDC_TEST_MISSING_BLOCK = missing ? '1' : '0';
      const path = join(f.root, missing ? 'partial.json' : 'findings.json');
      const r = f.run('edc', ['review', '--agent', 'claude', '--diff', `${f.base}...HEAD`, '--committed-only', '--ignore-context', '--findings-json', path]);
      assert.equal(r.status, missing ? 1 : 0, r.stdout + r.stderr);
      const artifact = JSON.parse(readFileSync(path, 'utf8'));
      assert.equal(artifact.candidate.commit, f.candidate);
      assert.equal(artifact.status, missing ? 'failed' : 'success');
      assert.equal(artifact.phases.length, 3);
      assert.equal(artifact.findings.length, 0);
      assert.ok(artifact.reports.length >= 3);
      const result = JSON.parse(readFileSync(f.env.EDC_RESULT_FILE, 'utf8'));
      assert.equal(result.findings.path, path);
      assert.equal(artifact.kind, 'edc-findings');
      assert.equal(result.findings.sha256, createHash('sha256').update(readFileSync(path)).digest('hex'));
      assert.equal(result.phases.length, 3);
    }
  } finally { f.close(); }
});

for (const status of ['complete', 'partial', 'unavailable']) {
  test(`structured source completeness: ${status} with verification limitations`, () => {
    const f = fixture();
    try {
      const limitations = ['No formal spec found; observable claims reviewed.', 'Tests and external services were not run.', 'Generated context ignored; optional semantic tools unavailable.'];
      f.env.EDC_TEST_STRUCTURED = '1'; f.env.EDC_TEST_FINDING = '1';
      f.env.EDC_TEST_DELIVERY_STATUS = status;
      f.env.EDC_TEST_REPORT_LIMITATIONS = JSON.stringify(limitations);
      f.env.EDC_RESULT_FILE = join(f.root, '.git/combined.json');
      const path = join(f.root, 'findings.json');
      const r = f.run('edc-review-all.sh', ['HEAD', '--base', f.base, '--committed-only', '--ignore-context', '--findings-json', path]);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      const artifact = JSON.parse(readFileSync(path, 'utf8'));
      const result = JSON.parse(readFileSync(f.env.EDC_RESULT_FILE, 'utf8'));
      const expected = status === 'complete' ? 'success' : 'success-with-warning';
      assert.equal(artifact.status, expected); assert.equal(result.status, expected);
      assert.equal(result.findings.status, expected);
      assert.equal(result.findings.sha256, createHash('sha256').update(readFileSync(path)).digest('hex'));
      assert.deepEqual(artifact.errors, []);
      assert.equal(artifact.findings.length, status === 'unavailable' ? 2 : 3);
      const delivery = artifact.reports.find(report => report.phase === 'delivery');
      assert.equal(delivery.status, status);
      assert.deepEqual(delivery.limitations.slice(0, limitations.length), limitations);
      assert.match(readFileSync(delivery.path, 'utf8'), /Delivery verdict: No spec available/);
      if (status !== 'complete') assert.match(delivery.limitations.at(-1), /could not be inspected/);
      if (status === 'complete') {
        for (const prompt of f.promptList()) {
          if (prompt.includes('AUDIT SYNTHESIS TASK')) {
            assert.match(prompt, /When every source review is complete.*retain status complete even when limitations are nonempty/);
          } else {
            assert.match(prompt, /status describes completion of the assigned source review/i);
          }
        }
      }
    } finally { f.close(); }
  });
}

for (const fault of ['EDC_TEST_MISSING_BLOCK', 'EDC_TEST_SYNTHESIS_LOSS']) {
  test(`invalid machine coverage (${fault}) preserves canonical reports and failed artifact receipts`, () => {
    const f = fixture();
    try {
      f.env.EDC_TEST_STRUCTURED = '1'; f.env.EDC_TEST_FINDING = '1'; f.env[fault] = '1';
      f.env.EDC_RESULT_FILE = join(f.root, '.git/combined.json');
      mkdirSync(join(f.root, 'edc-context/reports'), { recursive: true });
      const prior = ['review-HEAD.md', 'delivery-review-HEAD.md', 'edc-context/reports/issues.md', 'edc-context/reports/complexity.md'];
      for (const path of prior) writeFileSync(join(f.root, path), '# prior validated ' + path + '\n');
      const path = join(f.root, 'findings.json');
      const r = f.run('edc-review-all.sh', ['HEAD', '--base', f.base, '--committed-only', '--ignore-context', '--findings-json', path]);
      assert.equal(r.status, 1, r.stdout + r.stderr);
      for (const path of prior) assert.equal(readFileSync(join(f.root, path), 'utf8'), '# prior validated ' + path + '\n', fault + ': ' + path);
      const artifact = JSON.parse(readFileSync(path, 'utf8'));
      const result = JSON.parse(readFileSync(f.env.EDC_RESULT_FILE, 'utf8'));
      assert.equal(artifact.status, 'failed'); assert.equal(result.status, 'failed');
      assert.equal(result.findings.status, 'failed');
      assert.equal(result.findings.sha256, createHash('sha256').update(readFileSync(path)).digest('hex'));
      assert.match(JSON.stringify(artifact.errors), fault === 'EDC_TEST_MISSING_BLOCK' ? /exactly one declared/ : /synthesis lost/);
      assert.deepEqual(artifact.phases, result.phases);
      assert.equal(result.phases.length, 3);
      for (const phase of result.phases) assert.equal(JSON.parse(readFileSync(phase.resultFile, 'utf8')).status, 'success');
      for (const report of artifact.reports) assert.ok(readFileSync(report.path).length > 0);
    } finally { f.close(); }
  });
}

test('findings reject coordinator destination collisions before dispatch', () => {
  for (const destination of ['edc-context/build/last-run.json', '.git/../.git/combined.json', 'review-HEAD.md', 'delivery-review-HEAD.md', 'edc-context/reports/issues.md', 'edc-context/reports/complexity.md', 'edc-context/build/spawn-log.jsonl']) {
    const f = fixture();
    try {
      f.env.EDC_TEST_STRUCTURED = '1';
      delete f.env.EDC_RESULT_FILE;
      if (destination.includes('combined.json')) f.env.EDC_RESULT_FILE = join(f.root, '.git/combined.json');
      mkdirSync(join(f.root, 'edc-context/build'), { recursive: true });
      mkdirSync(join(f.root, 'edc-context/reports'), { recursive: true });
      const r = f.run('edc-review-all.sh', ['HEAD', '--base', f.base, '--committed-only', '--ignore-context', '--findings-json', destination]);
      assert.notEqual(r.status, 0, destination + ': ' + r.stdout + r.stderr);
      assert.equal(f.promptList().length, 0, destination);
      assert.match(r.stderr, /collides with coordinator output/, destination);
    } finally { f.close(); }
  }
});

for (const [label, destination] of [
  ['missing-prefix', '.git/not-created/../result-alias/../findings.json'],
  ['present-prefix', '.git/present/../result-alias/../findings.json'],
  ['nested-prefix', '.git/not-created/deeper/../../result-alias/../findings.json'],
  ['direct-symlink', '.git/result-alias/../findings.json'],
  ['ordinary', '.git/present/../ordinary.json'],
]) {
  test(`structured reserved paths reject ${label} parent traversal before dispatch`, () => {
    const f = fixture();
    try {
      f.env.EDC_TEST_STRUCTURED = '1';
      mkdirSync(join(f.root, '.git/target/deep'), { recursive: true });
      mkdirSync(join(f.root, '.git/present'));
      symlinkSync(join(f.root, '.git/target/deep'), join(f.root, '.git/result-alias'));
      // Keep raw components: join/resolve would erase the failing spelling.
      const resultPath = f.root + '/' + destination;
      f.env.EDC_RESULT_FILE = label === 'ordinary' ? destination : resultPath;
      const output = join(f.root, '.git/target/findings.json');
      assert.equal(realpathSync.native(f.root + '/.git/result-alias/..'), join(f.root, '.git/target'));
      if (label === 'missing-prefix') assert.throws(() => realpathSync.native(f.root + '/.git/not-created/..'), /ENOENT/);
      const r = f.run('edc-review-all.sh', ['HEAD', '--base', f.base, '--committed-only', '--ignore-context', '--findings-json', output]);
      assert.notEqual(r.status, 0, r.stdout + r.stderr);
      assert.equal(f.promptList().length, 0);
      assert.match(r.stderr, /unsupported reserved coordinator output path.*parent-directory/);
      assert.ok(r.stderr.includes(f.env.EDC_RESULT_FILE));
      const result = JSON.parse(readFileSync(resultPath, 'utf8'));
      assert.equal(result.status, 'failed');
      assert.equal(result.findings, undefined, 'rejected paths must not advertise a success findings receipt');
    } finally { f.close(); }
  });
}

for (const mode of ['relative', 'absolute', 'alias', 'legacy-traversal']) {
  test(`reserved path contract preserves ${mode} writer behavior`, () => {
    const f = fixture();
    try {
      const structured = mode !== 'legacy-traversal';
      f.env.EDC_TEST_STRUCTURED = structured ? '1' : '0';
      mkdirSync(join(f.root, '.git/target/deep'), { recursive: true });
      symlinkSync(join(f.root, '.git/target/deep'), join(f.root, '.git/result-alias'));
      const destination = mode === 'legacy-traversal' ? '.git/not-created/../result-alias/../legacy.json'
        : mode === 'alias' ? '.git/result-alias/missing/result.json' : '.git/missing/result.json';
      const resultPath = f.root + '/' + destination;
      f.env.EDC_RESULT_FILE = mode === 'relative' ? destination : resultPath;
      const output = join(f.root, 'findings.json');
      const args = ['HEAD', '--base', f.base, '--committed-only', '--ignore-context'];
      if (structured) args.push('--findings-json', output);
      const r = f.run('edc-review-all.sh', args);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      const result = JSON.parse(readFileSync(resultPath, 'utf8'));
      assert.equal(result.status, 'success');
      assert.equal(f.promptList().length, 4);
      if (structured) {
        const bytes = readFileSync(output);
        assert.equal(JSON.parse(bytes).kind, 'edc-findings');
        assert.equal(result.findings.sha256, createHash('sha256').update(bytes).digest('hex'));
      } else assert.equal(result.findings, undefined);
    } finally { f.close(); }
  });
}

test('opt-in nonempty records flow through all lenses and quality synthesis without semantic deduplication', () => {
  const f = fixture();
  try {
    f.env.EDC_TEST_STRUCTURED = '1'; f.env.EDC_TEST_FINDING = '1';
    const path = join(f.root, 'findings.json');
    writeFileSync(join(f.root, 'src/new.js'), 'mutable poison');
    const r = f.run('edc-review-all.sh', ['HEAD', '--base', f.base, '--committed-only', '--ignore-context', '--findings-json', path]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const artifact = JSON.parse(readFileSync(path, 'utf8'));
    assert.equal(artifact.findings.length, 3);
    assert.equal(new Set(artifact.findings.map(x => x.id)).size, 3);
    for (const finding of artifact.findings) assert.equal(finding.relatedLocations[0].path, 'src/old.js');
    assert.equal(artifact.candidate.commit, f.candidate);
  } finally { f.close(); }
});

test('opt-in working-tree snapshot preserves immutable identity without moving HEAD', () => {
  const f = fixture();
  try {
    f.env.EDC_TEST_STRUCTURED = '1'; f.env.EDC_TEST_FINDING = '1';
    writeFileSync(join(f.root, 'src/new.js'), 'snapshot-only\n');
    const path = join(f.root, 'findings.json');
    const r = f.run('edc-review-all.sh', ['HEAD', '--base', f.base, '--include-working-tree', '--ignore-context', '--findings-json', path]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const artifact = JSON.parse(readFileSync(path, 'utf8'));
    assert.equal(artifact.candidate.kind, 'working-tree-snapshot');
    assert.notEqual(artifact.candidate.commit, f.candidate);
    assert.equal(f.git('rev-parse', 'HEAD'), f.candidate);
    assert.equal(f.git('show', `${artifact.candidate.commit}:src/new.js`).trim(), 'snapshot-only');
    assert.equal(artifact.findings.length, 3);
  } finally { f.close(); }
});

test('opt-in deterministic complexity coverage gap remains a warning, not duplicate machine output', () => {
  const f = fixture();
  try {
    f.env.EDC_TEST_STRUCTURED = '1'; f.env.EDC_TEST_MISSING_COMPLEXITY = '1';
    const path = join(f.root, 'findings.json');
    const r = f.run('edc-review-all.sh', ['HEAD', '--base', f.base, '--committed-only', '--ignore-context', '--findings-json', path]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const artifact = JSON.parse(readFileSync(path, 'utf8'));
    assert.equal(artifact.status, 'success-with-warning');
    assert.deepEqual(artifact.errors, []);
    assert.equal(artifact.phases.find(p => p.phase === 'quality').status, 'success-with-warning');
  } finally { f.close(); }
});

test('findings full scope, missing base, and existing destination reject before model dispatch', () => {
  const f = fixture();
  try {
    const missingBase = f.run('edc-review-all.sh', ['HEAD', '--committed-only', '--ignore-context', '--findings-json', join(f.root, 'new.json')]);
    assert.notEqual(missingBase.status, 0);
    assert.match(missingBase.stderr, /requires an explicit --base/);
    assert.equal(f.promptList().length, 0);
    const out = join(f.root, 'existing.json'); writeFileSync(out, 'keep');
    for (const args of [['--full'], ['HEAD', '--base', f.base, '--committed-only']]) {
      const r = f.run('edc-review-all.sh', [...args, '--ignore-context', '--findings-json', out]);
      assert.notEqual(r.status, 0);
      assert.equal(f.promptList().length, 0);
      assert.equal(readFileSync(out, 'utf8'), 'keep');
    }
  } finally { f.close(); }
});

for (const [script, full] of [["edc-review.sh", ["--full"]], ["edc-delivery-review.sh", ["--full"]], ["edc-audit.sh", []], ["edc-review-all.sh", ["--full"]]]) {
  for (const flag of ["--no-context-refresh", "--ignore-context"]) {
    for (const mode of ["diff", "full"]) {
      test(`${script} ${mode} ${flag}: no context dependency, scoped evidence, reports`, () => {
        const f = fixture();
        try {
          const args = mode === "full" ? full : ["HEAD", "--base", f.base, "--committed-only"];
          if (mode === "diff") writeFileSync(join(f.root, "src/new.js"), "mutable-working-tree-poison\n");
          const result = f.run(script, [...args, flag]);
          assert.equal(result.status, 0, result.stdout + result.stderr);
          const prompts = f.prompts();
          assert.match(prompts, /src\/new\.js/);
          assert.match(prompts, /DO NOT build or update EDC context/);
          if (mode === "diff") {
            assert.match(prompts, new RegExp(f.candidate));
            assert.match(prompts, /mutable working tree/);
            assert.match(readFileSync(join(f.root, ".git/evidence"), "utf8"), /candidate-only/);
            assert.doesNotMatch(readFileSync(join(f.root, ".git/evidence"), "utf8"), /mutable-working-tree-poison/);
          } else assert.match(prompts, /src\/old\.js/);
          if (flag === "--ignore-context") assert.match(prompts, /DO NOT use prebuilt EDC context/);
          const reports = script === "edc-audit.sh" ? ["edc-context/reports/complexity.md", "edc-context/reports/issues.md"]
            : script === "edc-delivery-review.sh" ? [mode === "full" ? "delivery-review-current.md" : "delivery-review-HEAD.md"]
              : ["review-HEAD.md"];
          for (const path of reports) assert.match(readFileSync(join(f.root, path), "utf8"), /context.*(?:ignored|no-refresh)|(?:ignored|no-refresh).*context/i);
          assert.equal(readdirSync(f.root).includes("edc-context") && readdirSync(join(f.root, "edc-context")).includes("manifest.json"), false);
        } finally { f.close(); }
      });
    }
  }
}

for (const script of ["edc-audit.sh", "edc-review-all.sh"]) {
  for (const scope of ["full", "diff"]) {
    for (const flag of ["--no-context-refresh", "--ignore-context"]) {
      test(`audit synthesis policy: ${script} ${scope} ${flag} constrains this model stage`, () => {
        const f = fixture();
        try {
          mkdirSync(join(f.root, "edc-context/reports"), { recursive: true });
          writeFileSync(join(f.root, "edc-context/reports/issues.md"), "# Prior issues\n\nprior-generated-evidence\n");
          writeFileSync(join(f.root, "edc-context/reports/complexity.md"), "# Prior complexity\n\nprior-generated-evidence\n");
          if (scope === "diff") writeFileSync(join(f.root, "src/new.js"), "mutable-working-tree-poison\n");
          const args = scope === "diff" ? ["HEAD", "--base", f.base, "--committed-only"] : script === "edc-review-all.sh" ? ["--full"] : [];
          const r = f.run(script, [...args, flag]);
          assert.equal(r.status, 0, r.stdout + r.stderr);
          const stages = f.promptList();
          const syntheses = stages.filter(p => p.startsWith("AUDIT SYNTHESIS TASK\n"));
          assert.equal(syntheses.length, 1);
          const synthesis = syntheses[0];
          const policy = flag === "--ignore-context" ? "ignored" : "no-refresh";
          assert.match(synthesis, new RegExp(`^CONTEXT_POLICY: ${policy}$`, "m"));
          assert.match(synthesis, /DO NOT build or update EDC context/);
          assert.match(synthesis, /Read every markdown report under .*staged\/audit-tasks/);
          assert.match(synthesis, /Synthesis must retain the source\/invariant, sequence, oracle, coverage evidence\/uncertainty, and harness\/target/);
          assert.doesNotMatch(synthesis, /OCTOCODE_STATUS:/, "synthesis must not become another source-research worker");
          if (policy === "ignored") {
            assert.match(synthesis, /do not read or merge pre-existing generated reports/i);
            assert.match(synthesis, /overrides.*prior.*merg/i);
          } else assert.match(synthesis, /prior generated reports.*optional.*unverified/i);
          if (scope === "diff") {
            const sourceWorker = stages.find(p => p.startsWith("AUDIT WORKER TASK\n"));
            const workerContract = sourceWorker.split("Candidate evidence contract:\n")[1].split("\n\n")[0];
            assert.ok(synthesis.includes(workerContract), "synthesis must reuse the source worker's production evidence contract");
            assert.match(synthesis, new RegExp(`git show ${f.candidate}:<path>`));
            assert.match(synthesis, /mutable working tree/);
            assert.match(synthesis, /baseline blob/);
            assert.match(synthesis, /changed gitlink/);
            const evidence = readFileSync(join(f.root, ".git/synthesis-evidence"), "utf8");
            assert.match(evidence, /candidate-only/);
            assert.doesNotMatch(evidence, /mutable-working-tree-poison/);
          } else assert.match(synthesis, /Full audit: inspect the repository source directly/);
          const inputs = JSON.parse(readFileSync(join(f.root, ".git/synthesis-inputs.json"), "utf8"));
          assert.ok(Object.keys(inputs).length > 0);
          for (const [path, content] of Object.entries(inputs)) {
            assert.match(path, /\.git\/edc\/runs\/.*\/staged\/audit-tasks\//);
            assert.match(content, /verified candidate source/);
            assert.doesNotMatch(content, /prior-generated-evidence/);
          }
        } finally { f.close(); }
      });
    }
  }
}

test("audit synthesis default keeps context-backed prior-issues merge instructions", () => {
  const f = fixture();
  try {
    mkdirSync(join(f.root, "edc-context/modules"), { recursive: true });
    mkdirSync(join(f.root, "edc-context/reports"));
    writeFileSync(join(f.root, "edc-context/index.md"), "## Architecture\n");
    writeFileSync(join(f.root, "edc-context/modules/source.md"), "## Source ownership\n");
    writeFileSync(join(f.root, "edc-context/manifest.json"), JSON.stringify({ schemaVersion: 2, sourceCommit: f.candidate, modules: [{ name: "source", doc: "edc-context/modules/source.md", match: { prefixes: ["src/"] } }] }));
    writeFileSync(join(f.root, "edc-context/reports/issues.md"), "# Prior issues\n\nprior-generated-evidence\n");
    const r = f.run("edc-audit.sh", []);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const synthesis = f.promptList().find(p => p.startsWith("AUDIT SYNTHESIS TASK\n"));
    assert.match(synthesis, /merge new findings in rather than overwriting unrelated entries/);
    assert.doesNotMatch(synthesis, /^CONTEXT_POLICY: (?:ignored|no-refresh)$/m);
    assert.doesNotMatch(synthesis.split("SKILL: edc-audit/references/reporting.md")[0], /do not read or merge pre-existing generated reports/i);
  } finally { f.close(); }
});

for (const [command, flag] of [["review", "--ignore-context"], ["review-all", "--no-context-refresh"], ["security", "--no-context-refresh"], ["security-review", "--ignore-context"], ["delivery", "--ignore-context"], ["delivery-review", "--no-context-refresh"], ["quality", "--no-context-refresh"], ["quality-review", "--ignore-context"], ["audit", "--ignore-context"]]) {
  test(`CLI ${command} forwards ${flag} to its actual runtime`, () => {
    const f = fixture();
    try {
      const scope = ["review", "security", "delivery", "quality"].includes(command) ? ["diff", f.base] : ["--diff", `${f.base}...HEAD`];
      const r = f.run("edc", [command, ...scope, "--agent", "claude", "--committed-only", flag]);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      assert.match(f.prompts(), /src\/new\.js/);
      assert.match(f.prompts(), new RegExp(`CONTEXT_POLICY: ${flag === "--ignore-context" ? "ignored" : "no-refresh"}`));
    } finally { f.close(); }
  });
}

for (const scope of ["full", "diff"]) {
test(`direct ${scope} inventory preserves quoted source filenames for every lens`, () => {
  const f = fixture();
  try {
    const path = 'src/quote".js';
    writeFileSync(join(f.root, path), "export const quoted = true;\n");
    f.git("add", path); f.git("commit", "-qm", "quoted path");
    const args = scope === "full" ? ["--full"] : ["HEAD", "--base", f.base, "--committed-only"];
    const r = f.run("edc-review-all.sh", [...args, "--ignore-context"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(f.prompts().split(path).length - 1, 3);
  } finally { f.close(); }
});
}

test("no-refresh security accounts for an entirely account-only diff without a worker", () => {
  const f = fixture();
  try {
    mkdirSync(join(f.root, "edc-context"));
    writeFileSync(join(f.root, "edc-context/manifest.json"), JSON.stringify({ modules: [], contextless: { entries: [{ id: "metadata", globs: ["src/new.js"], reason: "account only", reviewPolicy: "account-only" }] } }));
    const r = f.run("edc-review.sh", ["HEAD", "--base", f.base, "--committed-only", "--no-context-refresh"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(f.prompts(), "");
    assert.match(readFileSync(join(f.root, "review-HEAD.md"), "utf8"), /src\/new\.js/);
  } finally { f.close(); }
});

test("combined no-refresh preserves and records valid explicit account-only exclusions", () => {
  const f = fixture();
  try {
    mkdirSync(join(f.root, "edc-context"));
    writeFileSync(join(f.root, "edc-context/manifest.json"), JSON.stringify({ modules: [], contextless: { entries: [{ id: "excluded", globs: ["src/new.js"], reason: "explicit accounting only", reviewPolicy: "account-only" }] } }));
    const r = f.run("edc-review-all.sh", ["--full", "--no-context-refresh"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.doesNotMatch(f.prompts(), /src\/new\.js/);
    assert.match(f.prompts(), /src\/old\.js/);
    assert.equal((r.stderr.match(/account-only excluded: src\/new\.js/g) || []).length, 3);
    for (const report of ["review-HEAD.md", "delivery-review-current.md", "edc-context/reports/complexity.md", "edc-context/reports/issues.md"]) {
      assert.match(readFileSync(join(f.root, report), "utf8"), /src\/new\.js/);
    }
  } finally { f.close(); }
});

for (const flag of ["--no-context-refresh", "--ignore-context"]) {
  test(`combined ${flag} applies explicit ignore globs instead of .edcignore`, () => {
    const f = fixture();
    try {
      writeFileSync(join(f.root, ".edcignore"), "src/old.js\n");
      const r = f.run("edc-review-all.sh", ["--full", flag, "--ignore", "src/new.js"]);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      assert.match(f.prompts(), /src\/old\.js/);
      assert.doesNotMatch(f.prompts(), /src\/new\.js/);
    } finally { f.close(); }
  });
}

for (const flags of [["--no-context-refresh", "--ignore-context"], ["--ignore-context", "--no-context-refresh"]]) {
  test(`combined explicit ignore wins in either order: ${flags.join(" ")}`, () => {
    const f = fixture();
    try {
      mkdirSync(join(f.root, "edc-context"));
      writeFileSync(join(f.root, "edc-context/manifest.json"), JSON.stringify({ modules: [], contextless: { entries: [{ id: "excluded", globs: ["src/**"], reason: "explicit exclusion", reviewPolicy: "account-only" }] } }));
      const r = f.run("edc-review-all.sh", ["HEAD", "--base", f.base, "--committed-only", ...flags]);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      const prompts = f.prompts();
      const stages = f.promptList();
      assert.equal(stages.length, 4, "security, delivery, quality source and quality synthesis must all run");
      for (const stage of stages) assert.match(stage, /^CONTEXT_POLICY: ignored$/m);
      assert.doesNotMatch(prompts, /CONTEXT_POLICY: no-refresh/);
      assert.doesNotMatch(r.stderr, /account-only excluded/);
      assert.match(prompts, /src\/new\.js/);
    } finally { f.close(); }
  });
}

for (const flag of ["--ignore-context", "--no-context-refresh"]) {
  test(`combined ${flag} retains one immutable working-tree candidate and real index`, () => {
    const f = fixture();
    try {
      writeFileSync(join(f.root, "src/new.js"), "synthetic-candidate-evidence\n");
      writeFileSync(join(f.root, "src/untracked.js"), "untracked-candidate-evidence\n");
      const index = readFileSync(join(f.root, ".git/index"));
      const r = f.run("edc-review-all.sh", ["HEAD", "--base", f.base, "--include-working-tree", flag]);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      const result = JSON.parse(readFileSync(join(f.root, "edc-context/build/last-run.json"), "utf8"));
      assert.equal(result.candidateKind, "working-tree-snapshot");
      assert.notEqual(result.candidateCommit, f.candidate);
      assert.equal(result.dirtyTrackedIncluded, true);
      assert.equal(result.untrackedIncluded, true);
      assert.equal(f.git("rev-parse", "HEAD"), f.candidate);
      assert.deepEqual(readFileSync(join(f.root, ".git/index")), index);
      const evidence = readFileSync(join(f.root, ".git/evidence"), "utf8");
      assert.equal(evidence.split("synthetic-candidate-evidence").length - 1, 3);
      assert.match(f.prompts(), /src\/untracked\.js/);
    } finally { f.close(); }
  });
  test(`CLI ${flag} does not require valid generated context mode`, () => {
    const f = fixture();
    try {
      mkdirSync(join(f.root, "edc-context"));
      writeFileSync(join(f.root, "edc-context/manifest.json"), "{invalid-context");
      const r = f.run("edc", ["delivery", "diff", f.base, "--agent", "claude", "--committed-only", flag]);
      assert.equal(r.status, 0, r.stdout + r.stderr);
    } finally { f.close(); }
  });
}

for (const script of ["edc-review.sh", "edc-delivery-review.sh", "edc-audit.sh", "edc-review-all.sh"]) {
 for (const state of ["stale", "invalid", "incomplete"]) {
  test(`no-refresh ${script} includes unmapped source with ${state} context`, () => {
    const f = fixture();
    try {
      mkdirSync(join(f.root, "edc-context/modules"), { recursive: true });
      writeFileSync(join(f.root, "edc-context/index.md"), "## stale architecture\n");
      const manifest = state === "invalid" ? "{broken" : JSON.stringify({ schemaVersion: 2, sourceCommit: f.base, modules: [{ name: "old", doc: "edc-context/modules/old.md", priority: 1, match: { exactFiles: ["src/old.js"] } }], policy: { unmatchedPathPolicy: "fail" } });
      writeFileSync(join(f.root, "edc-context/manifest.json"), manifest);
      if (state !== "incomplete") writeFileSync(join(f.root, "edc-context/modules/old.md"), "## old source\n");
      const r = f.run(script, ["HEAD", "--base", f.base, "--committed-only", "--no-context-refresh"]);
      assert.equal(r.status, 0, r.stdout + r.stderr);
      assert.match(f.prompts(), /src\/new\.js/);
      assert.equal(readFileSync(join(f.root, "edc-context/manifest.json"), "utf8"), manifest);
      assert.equal(readFileSync(join(f.root, "edc-context/index.md"), "utf8"), "## stale architecture\n");
    } finally { f.close(); }
  });
 }
}
