import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const scripts = resolve("plugins/edc/scripts");

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "edc-no-build."));
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
    p = pathlib.Path(path); p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text('## Findings\\n\\nverified candidate source; no findings.\\n')
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
