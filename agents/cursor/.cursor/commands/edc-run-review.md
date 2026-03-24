---
description: Performs differential review of code changes using codebase context
---

# Review

1. **Always run `edc-run-build` first** before any review analysis.
   - Missing `.context/.meta.json` -> full context build.
   - Existing but stale context -> incremental update.
   - Existing and current context -> no-op verification.
2. **Validate freshness after `edc-run-build`**:
   - Read `.context/.meta.json`.
   - Compare `lastCommit` with `git rev-parse HEAD`.
   - If mismatched, run `edc-run-build` again (or `edc-run-build --force` if needed) and do not start review until they match.
3. **Load context files first** to reduce unnecessary search:
   - `.context/context.md` — module map, invariants, coupling, trust boundaries
   - `.context/issues.md` — known problems to cross-reference
   - relevant `.context/{module}.md` files for changed modules — function-level detail, assumptions, call graphs
   - `.context/complexity.md` — bloat, dead exports, wrappers
   - Use this context to inform and scope your searches. Grep is expected — grep without context is wasteful.
4. **Fix-completeness check**: If the PR claims to fix a pattern (e.g., injection, validation, error handling), grep the codebase for ALL instances of that pattern — not just the changed files. A fix that covers 4/7 call sites is worse than no fix (false sense of security).
5. Then invoke the `edc-review` skill for the full review workflow. The report MUST include a "Context Inputs & Compliance" section listing context files consulted, invariants checked (with pass/fail), and search scope.
