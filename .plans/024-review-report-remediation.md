# Review Report Remediation

## Goal
Fix actionable findings from the 2026-07-07 `review-all` reports without broad refactors.

## Scope
- Security report BLOCK/HIGH/MEDIUM findings.
- Delivery partial-delivery findings.
- Quality `issues.md` promoted findings where actionable.
- Small low-risk hygiene findings: fixed `/tmp`, version drift, path boundary.

## Non-goals
- Oversized-file refactors not required to fix a finding.
- Generated report cleanup unless produced by verification reruns.

## Tasks
- [x] delivery-review prompt uses commit SHAs only for executable shell snippets; hostile refs regression.
- [x] review containment detects `.git` metadata mutation; regression for `.git/hooks/pre-commit`.
- [x] generic slash-command/wrapper review routes to combined review; tests/docs/wrappers aligned.
- [x] CLI default branch detection handles remote-only non-main defaults; Pi remains compatible.
- [x] delivery diff scope includes dirty tracked changes or reports limitation consistently; prefer inclusion.
- [x] Pi detached background spawn failure is handled and status is failed.
- [x] distribution metadata versions match package version; release check coverage.
- [x] plugin route path normalization rejects sibling-prefix paths.
- [x] fixed `/tmp` writable diagnostics/log paths moved to `mktemp` dirs.
- [x] Bash/`EDC_BASH` contract contradiction resolved across tests/context.
- [x] sibling-source policy conflict resolved between skill and generated task prompt.
- [x] delivery-review treats repo-controlled specs/plans/commit text as untrusted evidence.
- [x] security-review C/C++ fast path restores recursive parser stack-overflow coverage.

## Status Log
- 2026-07-07: created plan after successful differential `review-all`; starting TDD fixes.
- 2026-07-07: implemented report remediation and verified with focused tests, `npm run lint:shell`, and full `npm test`.
