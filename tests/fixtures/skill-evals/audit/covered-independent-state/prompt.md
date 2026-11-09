Use the `edc-audit` skill on this scoped module.

Scope: `src/loader.mjs` and `test/loader.test.mjs`.
Review state ownership, failure/cleanup paths, test value, and justified simplification opportunities. Compare existing tests before claiming a gap. Write only a scoped audit report; do not edit source or tests.

The existing harness is `node --test test/loader.test.mjs` from this fixture directory. Treat any test recommendation as a suggestion, not an executed or verified failing test.
