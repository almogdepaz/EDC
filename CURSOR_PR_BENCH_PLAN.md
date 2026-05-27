# Cursor PR benchmark plan

Status: implemented and focused tests passing

## Goal

Allow apples-to-apples PR review benchmarking with Cursor:

1. no-refresh review: run review without building/updating EDC context; use existing context if available
2. ignore-context review: force pure no-context baseline
3. context review: normal EDC context-backed review with recovery
4. collect spend/usage telemetry and output artifacts for manual finding adjudication

## Tasks

- [x] Add `edc-review.sh --no-context-refresh` mode: skip build/update/recovery, use existing context if usable
- [x] Add `edc-review.sh --ignore-context` mode: skip build/update/recovery and force pure no-context baseline
- [x] Remove ambiguous `--no-context` alias
- [x] Update hardening tests
- [x] Update Cursor PR benchmark runner/docs
- [x] Run focused tests

## Verification

- `bash -n plugins/edc/scripts/edc-review.sh benchmark/pr-review/run-cursor-pr-benchmark.sh tests/hardening/t15-review-routing.sh` → ok
- `bash tests/hardening/t15-review-routing.sh` → 23 passed, 0 failed
- mocked Cursor smoke test of `benchmark/pr-review/run-cursor-pr-benchmark.sh --mode ignore-context` → generated summary + review artifact

## Non-goals

- No automatic judging of real PR findings
- No forced context rebuild on every benchmark run unless `--force-build-context` is passed
- No Cursor-specific prompt fork unless evidence says it is needed
