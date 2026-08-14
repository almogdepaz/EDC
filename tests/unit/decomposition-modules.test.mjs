import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { argTokens, renderArgs, renderShellArgs, shellQuote, tokenizeArgs } from "../../pi/lib/args.mjs";
import {
  backgroundJobAlreadyRunningMessage,
  backgroundJobStartedMessage,
  formatBackgroundElapsed,
  renderBackgroundFooterStatus,
} from "../../pi/lib/background-result.mjs";
import {
  applyDirtyReviewPolicy,
  DIRTY_REVIEW_MENU,
  hasReviewableWorkingTreeChanges,
  reviewContextSummary,
  reviewDeclinedMessage,
} from "../../pi/lib/review-scope.mjs";
import { dispatchResultCommand } from "../../plugins/edc/hooks/lib/json-result-commands.mjs";

test("argument helpers preserve token and shell rendering contracts", () => {
  assert.deepEqual(tokenizeArgs("  HEAD   --base main  "), ["HEAD", "--base", "main"]);
  assert.deepEqual(argTokens(["HEAD", "", 12]), ["HEAD", "12"]);
  assert.equal(renderArgs(["HEAD", "--full"]), "HEAD --full");
  assert.equal(shellQuote("it's"), "'it'\\''s'");
  assert.equal(renderShellArgs(["HEAD", "feature branch"]), "'HEAD' 'feature branch'");
});

test("review scope helpers render explicit full scope and injected freshness", () => {
  const declined = reviewDeclinedMessage([], "quality", "full");
  assert.match(declined, /`edc quality full --agent pi`/);
  assert.doesNotMatch(declined, /edc quality diff/);

  const summary = reviewContextSummary(
    { cwd: "/unused" },
    { state: "missing", reason: "manifest missing" },
  );
  assert.match(summary, /EDC context: missing\/incomplete\./);
  assert.match(summary, /reason: manifest missing/);
});

test("dirty review policy prompts for complete or committed candidate", async () => {
  const root = mkdtempSync(join(tmpdir(), "edc-dirty-policy-test."));
  try {
    const git = (...args) => execFileSync("git", args, {
      cwd: root,
      stdio: "ignore",
      env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" },
    });
    git("init", "-q");
    git("config", "user.email", "test@example.com");
    git("config", "user.name", "Test");
    git("config", "commit.gpgsign", "false");
    writeFileSync(join(root, "tracked.txt"), "original\n");
    git("add", "tracked.txt");
    git("commit", "-q", "-m", "initial");
    writeFileSync(join(root, "tracked.txt"), "dirty\n");
    writeFileSync(join(root, "new.txt"), "untracked\n");

    assert.equal(hasReviewableWorkingTreeChanges(root), true);
    const committed = await applyDirtyReviewPolicy(["HEAD~1", "--base", "main"], {
      cwd: root,
      ui: { select: async () => DIRTY_REVIEW_MENU.COMMITTED },
    });
    assert.deepEqual(committed.args, ["HEAD~1", "--base", "main", "--committed-only"]);

    const included = await applyDirtyReviewPolicy(["HEAD~1", "--base", "main"], {
      cwd: root,
      ui: { select: async () => DIRTY_REVIEW_MENU.INCLUDE },
    });
    assert.deepEqual(included.args, ["HEAD", "--base", "main", "--include-working-tree"]);

    const cancelled = await applyDirtyReviewPolicy(["HEAD", "--base", "main"], {
      cwd: root,
      ui: { select: async () => DIRTY_REVIEW_MENU.CANCEL },
    });
    assert.equal(cancelled.cancelled, true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("background result helpers render stable elapsed and status messages", () => {
  const running = { kind: "review", status: "running", started_at: "2026-01-01T00:00:00Z" };
  assert.equal(formatBackgroundElapsed(running, Date.parse("2026-01-01T01:02:03Z")), "1h 2m");
  assert.equal(renderBackgroundFooterStatus({ kind: "review", status: "running" }), "edc review: running");
  assert.equal(renderBackgroundFooterStatus({ kind: "review", status: "success" }), "edc review: ✓ complete");
  assert.match(backgroundJobStartedMessage({ kind: "review", runId: "run-1", pid: 42, logFile: "/tmp/run.log" }), /Run ID: run-1/);
  assert.match(backgroundJobAlreadyRunningMessage({ runId: "run-1", status: { kind: "review", log: "/tmp/run.log" } }), /already running/);
});

test("result command dispatch writes scoped durable result data", () => {
  const root = mkdtempSync(join(tmpdir(), "edc-result-command-test."));
  const output = join(root, "nested", "result.json");
  const previousScope = process.env.EDC_RESULT_SCOPE;
  process.env.EDC_RESULT_SCOPE = "full";
  try {
    assert.equal(dispatchResultCommand("result-write", [output, "audit", "0", "success", "", "", "", "", "start", "finish"]), true);
    const result = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(result.kind, "audit");
    assert.equal(result.status, "success");
    assert.equal(result.scope, "full");
    assert.deepEqual(result.outputs, ["edc-context/reports/issues.md", "edc-context/reports/complexity.md"]);
    assert.equal(dispatchResultCommand("not-a-command", []), false);
  } finally {
    if (previousScope === undefined) delete process.env.EDC_RESULT_SCOPE;
    else process.env.EDC_RESULT_SCOPE = previousScope;
    rmSync(root, { recursive: true, force: true });
  }
});
