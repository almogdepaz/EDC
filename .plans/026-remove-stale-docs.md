# Remove Stale Docs

## Goal
Remove stale documentation/scratch docs without deleting canonical runtime docs, generated EDC context that is still source-controlled, or user-owned work by accident.

## Candidate buckets

### Safe stale scratch candidates
- `EDC_WIZARD.html` — untracked root HTML artifact.
- `benchmark/EDC_COLLECTION_PR_DRAFTS.md` — untracked benchmark/launch draft.
- `benchmark/EDC_LAUNCH_PACK.md` — untracked benchmark/launch draft.

### likely stale root planning/status docs, but needs confirmation
These appear in the filesystem but are not tracked by git status output; verify ignore rules before deletion:
- `BENCHMARK_FORWARD_PLAN.md`
- `BUILD_VALUE_PLAN.md`
- `CURSOR_PR_BENCH_PLAN.md`
- `EDC_BASH_ALIGNMENT_STATUS.md`
- `EDC_PI_BACKGROUND_REVIEW_STATUS.md`
- `EDC_PI_MENU_STATUS.md`
- `EDC_SURFACE_REFACTOR_STATUS.md`
- `EDC_SURFACE_REFACTOR_SUMMARY.md`
- `external_context_plan.md`
- `FINDINGS.md`
- `GEPA_PLAN.md`
- `PI_PLUGIN_PUBLISH_STRATEGY.md`
- `PLAN-cleanup.md`
- `PLAN.md`
- `REVIEW_FIX_STATUS.md`
- `STATUS.md`

### do not delete unless explicitly requested
- tracked public docs: `README.md`, `CONTRIBUTING.md`, `pi/README.md`, `plugins/edc/README.md`.
- `SECURITY.md` and `CHANGELOG.md` were explicitly approved for deletion on 2026-07-08.
- tracked command/skill/prompt docs under `plugins/edc/**`.
- tracked EDC context docs under `edc-context/**`.
- tracked benchmark ground truth/report docs.
- `.plans/024-*`, `.plans/025-*`, `.plans/026-*` while active/recent.
- `.edc/skills/**` installed runtime cache unless the request is specifically to clean local runtime caches.
- `review-tasks/**` unless confirmed stale generated scratch should be removed from the working tree.

## Plan
1. verify ignore/tracking status for candidate docs.
2. delete confirmed stale scratch docs only.
3. run `git status --short` and relevant docs/package tests if tracked files change.
4. commit/push the cleanup if tracked state changes; otherwise report working-tree cleanup only.

## Status
- [x] inventory candidates.
- [x] await user confirmation of deletion scope.
- [x] delete approved docs.
- [x] verify candidates no longer exist.

## Result
Deleted 19 stale untracked/ignored scratch docs. No tracked canonical product docs, runtime docs, skill docs, prompt docs, EDC context docs, or benchmark ground-truth docs were deleted in that pass.

Follow-up: removed tracked `SECURITY.md` and `CHANGELOG.md` after explicit user approval, and removed them from the npm package allowlist/test contract.
