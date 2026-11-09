import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import edcExtension from "../../pi/index.mjs";
import { reviewDeclinedMessage } from "../../pi/lib/review-scope.mjs";

for (const scope of ["full repo review", "changes vs default branch"]) {
  for (const lens of ["combined review", "security review", "delivery review", "quality review"]) {
    for (const flag of ["--no-context-refresh", "--ignore-context"]) {
      test(`/edc ${flag}: ${scope}, ${lens} skips context recovery confirmation`, async () => {
        const root = mkdtempSync(join(tmpdir(), "edc-no-build-pi."));
        const handlers = new Map();
        let command;
        let confirmations = 0;
        try {
          execFileSync("git", ["init", "-q"], { cwd: root });
          mkdirSync(join(root, ".git/edc"));
          writeFileSync(join(root, ".git/edc/status"), `status=running\npid=${process.pid}\nkind=audit\nrun_id=existing\n`);
          const pi = {
            on: (name, handler) => handlers.set(name, handler),
            registerCommand: (_name, config) => { command = config.handler; },
            sendMessage: () => {},
          };
          edcExtension(pi);
          const selections = [scope, lens];
          const ctx = { cwd: root, hasUI: true, ui: {
            select: async () => selections.shift(),
            confirm: async () => { confirmations++; return false; },
          } };
          await command(flag, ctx);
          assert.equal(confirmations, 0, "explicit no-build policy must reach review preflight");
          assert.equal(selections.length, 0);
        } finally {
          await handlers.get("session_shutdown")?.({}, { ui: {} });
          rmSync(root, { recursive: true, force: true });
        }
      });
    }
  }
}

test("decline guidance keeps the selected lens in no-build commands", () => {
  for (const lens of ["review", "security", "delivery", "quality"]) {
    assert.ok(reviewDeclinedMessage([], lens, "full").includes(`edc ${lens} full --agent pi --ignore-context`));
  }
});
