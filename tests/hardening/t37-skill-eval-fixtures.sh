#!/usr/bin/env bash
# Task 37: skill eval fixture corpus contract.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/tests/hardening/lib/check.sh"
check_init

FIXTURES="$ROOT/tests/fixtures/skill-evals"

echo "=== T37: skill eval fixtures ==="

check "skill eval fixture root exists" "$([ -d "$FIXTURES" ] && [ -f "$FIXTURES/README.md" ] && echo 1 || echo 0)"

for lens in audit security delivery; do
  count=$(find "$FIXTURES/$lens" -mindepth 2 -maxdepth 2 -name expected.json 2>/dev/null | wc -l | tr -d ' ')
  check "$lens has at least 3 fixtures" "$([ "${count:-0}" -ge 3 ] && echo 1 || echo 0)"
done

node_ok=0
if node --input-type=module - "$FIXTURES" <<'NODE'
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = process.argv[2];
const lensSkill = new Map([
  ["audit", "edc-audit"],
  ["security", "edc-review"],
  ["delivery", "edc-delivery-review"],
]);

const failures = [];
function fail(message) { failures.push(message); }
function readJson(path) {
  try { return JSON.parse(readFileSync(path, "utf8")); }
  catch (error) { fail(`${relative(root, path)} invalid json: ${error.message}`); return null; }
}
function hasTextUnder(dir, needle) {
  const entries = readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (hasTextUnder(path, needle)) return true;
    } else if (entry.isFile()) {
      const text = readFileSync(path, "utf8");
      if (text.includes(needle)) return true;
    }
  }
  return false;
}

for (const [lens, skill] of lensSkill) {
  const lensDir = join(root, lens);
  if (!existsSync(lensDir)) {
    fail(`${lens} directory missing`);
    continue;
  }
  for (const name of readdirSync(lensDir)) {
    const fixtureDir = join(lensDir, name);
    if (!statSync(fixtureDir).isDirectory()) continue;
    const promptPath = join(fixtureDir, "prompt.md");
    const expectedPath = join(fixtureDir, "expected.json");
    if (!existsSync(promptPath)) fail(`${lens}/${name} missing prompt.md`);
    if (!existsSync(expectedPath)) { fail(`${lens}/${name} missing expected.json`); continue; }
    const expected = readJson(expectedPath);
    if (!expected) continue;

    try {
      assert.equal(expected.skill, skill);
      assert.equal(expected.fixture, name);
      assert.ok(Array.isArray(expected.requiredFindings));
      assert.ok(Array.isArray(expected.forbiddenFindings));
      assert.ok(Array.isArray(expected.requiredEvidence));
      assert.ok(expected.requiredEvidence.length > 0);
    } catch (error) {
      fail(`${lens}/${name} schema mismatch: ${error.message}`);
    }

    const prompt = existsSync(promptPath) ? readFileSync(promptPath, "utf8") : "";
    if (!prompt.includes(`\`${skill}\``)) fail(`${lens}/${name} prompt does not name ${skill}`);

    for (const item of [...expected.requiredFindings, ...expected.forbiddenFindings]) {
      if (typeof item !== "object" || item === null) {
        fail(`${lens}/${name} finding assertion is not an object`);
        continue;
      }
      if (!item.category && !item.evidence) fail(`${lens}/${name} finding assertion lacks category/evidence`);
    }
    for (const evidence of expected.requiredEvidence) {
      if (typeof evidence !== "string" || evidence.length === 0) {
        fail(`${lens}/${name} requiredEvidence has non-string value`);
      } else if (evidence !== "No security findings" && evidence !== "Requirement" && !hasTextUnder(fixtureDir, evidence)) {
        fail(`${lens}/${name} evidence not found in fixture files: ${evidence}`);
      }
    }

    if (lens === "audit") {
      const text = JSON.stringify(expected.requiredFindings).toLowerCase();
      if (text.includes("attack path") || text.includes("scope creep")) fail(`${lens}/${name} audit required output crosses into security/delivery`);
    }
    if (lens === "security") {
      if (!expected.attackPathRequired && !expected.noSecurityFindings) fail(`${lens}/${name} must require attack path or no-security-findings`);
      const text = JSON.stringify(expected.requiredFindings).toLowerCase();
      if (text.includes("possible smell") || text.includes("architecture fit")) fail(`${lens}/${name} security required output crosses into audit/delivery`);
    }
    if (lens === "delivery") {
      if (!existsSync(join(fixtureDir, "spec.md"))) fail(`${lens}/${name} missing spec.md`);
      if (!existsSync(join(fixtureDir, "edc-context", "index.md"))) fail(`${lens}/${name} missing edc-context/index.md`);
      if (!expected.deliveryVerdict || !expected.architectureFit) fail(`${lens}/${name} missing delivery/architecture verdicts`);
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(failure);
  process.exit(1);
}
NODE
then
  node_ok=1
fi
check "fixture schemas and evidence validate" "$node_ok"

check_summary "T37"
