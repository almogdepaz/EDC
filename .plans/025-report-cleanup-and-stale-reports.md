# Report Cleanup and Stale Report Removal

## Goal
Triage current generated review reports, fix remaining actionable findings not already addressed by `98d9ab1`, then remove stale generated report artifacts.

## Report Inventory
- `review-HEAD.md` — generated security review for old HEAD `3a8f943`; stale after `98d9ab1`.
- `delivery-review-HEAD.md` — generated delivery review for old HEAD `3a8f943`; stale after `98d9ab1`.
- `edc-context/reports/issues.md` — generated quality known-issues report; currently dirty and stale after fixes.
- `edc-context/reports/complexity.md` — generated quality complexity report; currently dirty and stale after fixes.

## Already Fixed by `98d9ab1`
- delivery ref injection
- review/delivery/audit `.git` write containment
- generic review wrapper route to combined review-all
- cli remote-only default branch detection
- delivery dirty tracked context
- pi detached spawn error handling
- plugin metadata version drift
- route path normalization boundary
- fixed `/tmp` report/test outputs and clean-slate diagnostics
- Bash/`EDC_BASH` context contradiction
- sibling-source prompt conflict
- delivery spec untrusted-input boundary
- C/C++ recursive stack-overflow coverage

## Remaining Actionable Cleanup From Reports
- [x] remove or justify dead private helpers/wrappers:
  - `pi/index.mjs` `reviewArgsWithDefaultTarget`
  - `plugins/edc/hooks/lib/route.mjs` `manifestPath`, private `routeFile`
  - `plugins/edc/scripts/edc-lib.sh` stale diagnostic helpers if truly unused
- [x] expand shellcheck lint to include hardening scripts or consciously exclude them with a test-backed contract.
- [x] fix `tests/hardening/t15-review-routing.sh` trap clobber.
- [x] decide/remove stale Pi legacy review flow cases/helpers if unreachable, or keep as compatibility intentionally.
- [x] renumber module-context checklist without content changes.
- [x] remove unused `pluginRoot` parameter from `buildToolCallInjection` and callers if test-backed.
- [x] remove stale generated report artifacts after fixes.

## Verification Plan
- focused hardening tests for touched contracts
- `npm run lint:shell`
- full `npm test`
- exact staged patch verification in clean detached worktree before commit

## Status Log
- 2026-07-07: created after user asked to fix all report issues and delete stale reports.
- 2026-07-07: removed true dead helpers/wrappers, added hardening shellcheck gate, fixed t15 cleanup trap, renumbered module checklist, removed unused injection parameter, deleted stale generated run artifacts, and reset canonical reports to non-stale summaries.
- 2026-07-07: Pi legacy top-level review switch cases intentionally retained because hardening tests still exercise them as compatibility paths; new scope-first menu remains primary UX.
- 2026-07-07: rechecked prior `issues.md` contents after user asked to make sure every review item was fixed; found two items needed stronger proof/fixes beyond stale-report cleanup.

## Final Remediation Report

### Review inputs checked
- `review-HEAD.md` from run `20260707T083000Z-review-all-19982`: stale security review for pre-remediation HEAD `3a8f943`.
- `delivery-review-HEAD.md` from the same run: stale delivery review for pre-remediation HEAD `3a8f943`.
- `edc-context/reports/issues.md` as tracked before cleanup: contained three concrete quality findings.
- `edc-context/reports/complexity.md` as tracked before cleanup: contained dead-helper/wrapper/duplication/oversized-file observations.

### Issues and fixes
1. `edc-manifest.sh` did not consume ignore rules.
   - Status: already fixed before this cleanup; verified, not reimplemented.
   - Evidence: `edc-manifest.sh` accepts repeated `--ignore`, reads `.edcignore` when no flags are supplied, forwards ignore args into `classify-cli.mjs`, and records `coverage.ignoreSource` / `coverage.ignoreGlobs`.
   - Regression proof: `tests/hardening/t29-manifest-contextless-coverage.sh` checks ignored counts and ignore provenance.

2. Bash context extraction was heuristic and missed complex paths.
   - Fix: added an explicit deterministic escape hatch for bash tool calls: `# edc-context-path: <path>` comments are consumed before regex token extraction, so paths with spaces or shell syntax can still receive routed context.
   - Regression proof: `tests/hardening/t10-pi-extension.sh` now verifies a bash command with `# edc-context-path: src/path with spaces.ts` injects the routed module context for the full hinted path.

3. Benchmark runner requested legacy `edc-context/full-context.md`.
   - Fix: changed `benchmark/run.sh` to create `edc-context/modules/` and prompt agents to write scoped benchmark analysis to `edc-context/modules/security-benchmark.md`, while keeping security findings in `edc-context/reports/issues.md`.
   - Regression proof: `tests/hardening/t27-index-context-contract.sh` now rejects the legacy `edc-context/full-context.md` path and requires the v2 module path.

4. Complexity report dead/helper findings.
   - Fix: removed dead private helpers/wrappers in `pi/index.mjs`, `plugins/edc/hooks/lib/route.mjs`, and `plugins/edc/scripts/edc-lib.sh`; removed the unused `pluginRoot` parameter from `buildToolCallInjection` callers.
   - Intentionally retained: large orchestrator/test files and compatibility Pi paths where tests encode them as supported behavior. These are maintenance debt, not stale unverified findings.

5. Hardening shellcheck gap and t15 trap clobber.
   - Fix: added `lint:hardening`, made `npm test` run it before the hardening suite, updated CI-facing test assertions, and fixed `tests/hardening/t15-review-routing.sh` cleanup trap composition.

6. Stale generated artifacts.
   - Fix: removed root `review-HEAD.md`, root `delivery-review-HEAD.md`, and transient `edc-context/build/review-all-*.json`, `last-run.json`, and `spawn-log.jsonl` artifacts. Kept canonical tracked audit reports but rewrote them as current empty summaries instead of deleting schema-owned report files.

### Verification run
- `bash tests/hardening/t10-pi-extension.sh` — passed.
- `bash tests/hardening/t27-index-context-contract.sh` — passed.
- `bash tests/hardening/t29-manifest-contextless-coverage.sh` — passed.
- `npm run lint:shell` — passed.
- `npm run lint:hardening` — passed.
- `npm test` — passed after wiring `lint:hardening` into the test script.
