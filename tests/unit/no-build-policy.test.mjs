import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const cli = resolve("plugins/edc/hooks/lib/json-cli.mjs");
const entry = { id: "metadata", globs: ["metadata/**"], reason: "accounting only", reviewPolicy: "account-only" };
for (const state of ["valid", "invalid-entry", "missing-reason", "invalid-glob", "symlink", "ambiguous"]) {
  test(`optional no-refresh policy: ${state} never excludes uncovered source`, () => {
    const root = mkdtempSync(join(tmpdir(), "edc-optional-policy."));
    try {
      mkdirSync(join(root, "edc-context"));
      const manifest = { modules: [], policy: { unmatchedPathPolicy: "fail" }, contextless: { entries: [{ ...entry }] } };
      if (state === "invalid-entry") manifest.contextless.entries[0].id = "not valid!";
      if (state === "missing-reason") delete manifest.contextless.entries[0].reason;
      if (state === "invalid-glob") manifest.contextless.entries[0].globs = ["[broken"];
      if (state === "ambiguous") manifest.modules.push({ name: "overlap", priority: 1, match: { prefixes: ["metadata/"] } });
      if (state === "symlink") {
        writeFileSync(join(root, "outside.json"), JSON.stringify(manifest));
        symlinkSync(join(root, "outside.json"), join(root, "edc-context/manifest.json"));
      } else writeFileSync(join(root, "edc-context/manifest.json"), JSON.stringify(manifest));
      const r = spawnSync("node", [cli, "review-optional-policy-files"], { cwd: root, encoding: "utf8", input: "src/new.js\nmetadata/info.md\n" });
      assert.equal(r.status, 0, r.stderr);
      assert.match(r.stdout, /src\/new\.js/);
      if (state === "valid") {
        assert.doesNotMatch(r.stdout, /metadata\/info.md/);
        assert.match(r.stderr, /account-only excluded: metadata\/info.md/);
      } else assert.match(r.stdout, /metadata\/info.md/);
    } finally { rmSync(root, { recursive: true, force: true }); }
  });
}
