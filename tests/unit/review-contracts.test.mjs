import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

for (const path of [
  'plugins/edc/skills/edc-review/methodology.md',
  'plugins/edc/skills/edc-delivery-review/references/architecture-axis.md',
  'plugins/edc/skills/edc-audit/references/quality-checks.md',
]) {
  test(`${path}: bounded behavioral preservation contract`, () => {
    const text = readFileSync(path, 'utf8');
    for (const term of ['source and consumer', 'small valid counterexample', 'observable values and effects', 'existing real-code tests', 'not a new mandatory pass']) {
      assert.ok(text.includes(term), `missing ${term}`);
    }
  });
}
for (const [phase, namespace] of [['security', 'module'], ['delivery', 'main'], ['quality', 'module']]) {
  test(`${phase}: authored machine records retain established contract details without inventing effects`, () => {
    const prompt = execFileSync(process.execPath, ['plugins/edc/hooks/lib/review-findings.mjs', 'prompt', phase, namespace], { encoding: 'utf8' });
    assert.match(prompt, /description.*expected versus actual input arity\/types and output shape\/types/i);
    assert.match(prompt, /impact.*affected consumer and consequence/i);
    assert.match(prompt, /grouping.*shortening.*retain.*contract distinctions/i);
    assert.match(prompt, /relatedLocations.*do not replace.*explanation/i);
    assert.match(prompt, /source-observed behavior.*conditional downstream consequences/i);
    assert.match(prompt, /verification\.evidence.*verification\.limitations/i);
    assert.match(prompt, /only established contract facts.*do not.*invent effects.*add findings/i);
  });
  test(`${phase}: machine status measures assigned source review, not verification or delivery verdict`, () => {
    const prompt = execFileSync(process.execPath, ['plugins/edc/hooks/lib/review-findings.mjs', 'prompt', phase, namespace], { encoding: 'utf8' });
    assert.match(prompt, /status describes completion of the assigned source review/i);
    assert.match(prompt, /complete:.*findings may be empty or nonempty/i);
    assert.match(prompt, /No spec available.*partially delivered.*do not determine/i);
    assert.match(prompt, /Unexecuted tests.*ignored generated context.*unavailable optional tools.*do not by themselves/i);
    assert.match(prompt, /partial:.*source or necessary supporting evidence.*not.*inspected/i);
    assert.match(prompt, /Name the unreviewed paths or contracts/i);
    assert.match(prompt, /unavailable:.*no substantive.*review.*no findings/i);
    assert.match(prompt, /Never upgrade an explicit partial or unavailable report/i);
  });
}

test('quality checks correctness before extracting duplicate mappings', () => {
  assert.match(readFileSync('plugins/edc/skills/edc-audit/references/quality-checks.md', 'utf8'), /before extracting duplicate mapping logic/i);
});
