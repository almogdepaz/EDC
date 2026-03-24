---
description: Performs differential review of code changes using codebase context
---

# Review

1. **Always run `edc-build` first** before any review analysis.
   - Missing `.context/.meta.json` -> full context build.
   - Existing but stale context -> incremental update.
   - Existing and current context -> no-op verification.
2. **Validate freshness after `edc-build`**:
   - Read `.context/.meta.json`.
   - Compare `lastCommit` with `git rev-parse HEAD`.
   - If mismatched, run `edc-build` again (or `edc-build --force` if needed) and do not start review until they match.
3. **Load context files before any broad search**:
   - `.context/context.md`
   - `.context/issues.md`
   - relevant `.context/{module}.md` files for changed modules
4. Then invoke the `edc-review` skill for the full review workflow, using context files as primary evidence and code search only to validate specific hypotheses.
