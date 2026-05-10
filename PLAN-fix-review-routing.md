# Fix Review Task Routing Bug

## Bug

`build_mode` in `plugins/edc/scripts/edc-review.sh` groups changed files
by `dirname $file | cut -d/ -f1` (top-level directory). This ignores
`.context/manifest.json`'s routing rules entirely.

**Real-world consequence (wolfpack):**
- `src/broker/snapshot-render.ts` → grouped under synthetic `src` module
- correct routing: `broker-client` (per `match.prefixes: ["src/broker/"]`)
- review subagent told to read `.context/modules/src.md` (doesn't exist),
  silently skips it, reviews the file with NO module context
- same problem for `src/server/*.ts`, `src/public-assets.ts`, etc.

## Root cause

`build_mode` predates the v2 manifest routing contract. `edc-route.sh`
exists and hooks already use it correctly. `build_mode` was never updated.

## Design

### 1. Replace top-level-dir grouping with edc-route.sh calls

For each changed file, call `edc-route.sh $MANIFEST $file`:
- rc=0 → module name on stdout, file goes into that module's bucket
- rc=1 → no match → file goes into synthetic `unmapped` bucket
- rc=2 → ambiguous → HARD ERROR (manifest bug, refuse to continue)

### 2. Unmapped policy

Read `policy.unmatchedPathPolicy` from manifest. Behavior per value:
- `"warn-allow"` (default) → log warning per unmapped file, continue,
  group into `unmapped` review task
- `"allow"` → silently group into `unmapped` review task (still emits
  one summary line so user knows it happened)
- `"fail"` → exit 2 with list of unmapped files; user must update
  manifest's `unmapped.allowedGlobs` or add a module rule

`unmapped.allowedGlobs` is also consulted: if a file matches a glob
there, it's expected unmapped → no warning, just the synthetic group.
Files NOT in allowedGlobs trigger the policy.

### 3. Ambiguous routing

HARD ERROR. exit 2. clear message:
```
ERROR: file 'src/foo.ts' matches multiple modules at top priority: foo bar
HINT: fix .context/manifest.json — bump priority on the intended module
      or tighten its match rules
```

No silent picking. Aligns with "no silent failures" directive.

### 4. Synthetic `unmapped` review task

When grouped:
- task file: `review-tasks/unmapped.md`
- doc reference: `.context/index.md` only (no module doc, since none exists)
- task instructions clearly state "these files were not assigned to any
  module" and tell the agent to use repo-level context

### 5. Logging

- per file: `→ src/broker/snapshot-render.ts → broker-client`
- per ambiguity: error to stderr, exit 2
- per unmapped (warn-allow): `WARNING: src/foo.ts not mapped to any module`
- summary at end: `routed N files into M modules (K unmapped)`

## Files Changed

- `plugins/edc/scripts/edc-review.sh` (build_mode only)
- `.edc/scripts/edc-review.sh` (synced)

## Tests

### Update existing
- `tests/hardening/t6-auto-mode.sh` fixtures: add `match.prefixes` to the
  stub manifest so the test file (`change.txt`) routes via the real path.
  Currently fixture's manifest has only `{name, doc}` — no match rules,
  every file would route to `unmapped`.
- `tests/hardening/t7-codex-auto-mode.sh`: same.
- `tests/hardening/t12-build-orchestrator.sh`: same (already has
  `match.prefixes: ["src/"]` per the diff context I saw — verify).

### New: `tests/hardening/t15-review-routing.sh`
Pin the routing contract end-to-end:
- file matching `match.prefixes` → correct module bucket
- file matching `match.exactFiles` → correct module bucket
- file with no match + policy=warn-allow → `unmapped` bucket + warning
- file with no match + policy=fail → exit 2
- ambiguous priority → exit 2
- regression guard: review-tasks/manifest.json must NEVER contain a
  module name that doesn't exist in `.context/manifest.json` (except
  the literal string "unmapped")

## Out of Scope

- Hook routing (already uses edc-route.sh correctly)
- Manifest schema changes
- Cursor/codex-specific routing (orchestrator is agent-agnostic)
- Fixing wolfpack's CURRENTLY RUNNING review (orthogonal — user's
  review continues; next run benefits)

## Status

- [x] design approved
- [x] implement build_mode rewrite (uses edc-route.sh, handles policy)
- [x] sync to .edc/scripts/ and ~/.edc/scripts/
- [x] t6/t7/t12 fixtures — NOT TOUCHED. They use minimal manifests with
      no match rules; their changed file `change.txt` correctly routes
      to `unmapped` under default warn-allow policy. Tests still pass
      because assertions only require `report-*.md` to exist, not a
      specific module name. Acceptable.
- [x] t15-review-routing.sh — 12 PASS / 0 FAIL
- [x] full hardening suite — ALL GREEN (15 test files)
- [ ] suggest commit
