# Context Directory Migration

Migrate from hidden `.context/` to non-hidden `edc-context/`. Route all
references through a single shared variable for future configurability.

## Decisions (locked)

- New name: **`edc-context/`** (hardcoded for now)
- No env var, no config file, no flag (yet)
- Skills/prompts use the new name literally
- Only migrate code we already touch + production-critical paths
- Single source of truth for the path so future configurability is one-edit-away

## Single Source of Truth

### Shell layer
New file: `plugins/edc/scripts/edc-paths.sh` (sourced, not exec'd):

```bash
# edc-paths: single source of truth for .context/ → edc-context/ migration.
# Every orchestrator script sources this BEFORE referencing context paths.
# To make context dir configurable later: change defaults here, no other edits.

EDC_CONTEXT_DIR="edc-context"
EDC_MANIFEST="$EDC_CONTEXT_DIR/manifest.json"
EDC_INDEX="$EDC_CONTEXT_DIR/index.md"
EDC_MODULES_DIR="$EDC_CONTEXT_DIR/modules"
EDC_REPORTS_DIR="$EDC_CONTEXT_DIR/reports"
EDC_BUILD_DIR="$EDC_CONTEXT_DIR/build"
```

Sourcing pattern (mirroring how existing scripts source edc-runtime.sh):
```bash
. "$SCRIPT_DIR/edc-paths.sh"
```

### Hooks layer (.mjs)
New file: `plugins/edc/hooks/lib/paths.mjs`:

```js
export const EDC_CONTEXT_DIR = "edc-context";
export const EDC_MANIFEST_REL = `${EDC_CONTEXT_DIR}/manifest.json`;
export const EDC_INDEX_REL = `${EDC_CONTEXT_DIR}/index.md`;
export const EDC_MODULES_DIR_REL = `${EDC_CONTEXT_DIR}/modules`;
```

Hooks import from `./lib/paths.mjs`.

### Skills/prompts (.md)
Skills are markdown the agent reads. They cannot dynamically read shell
vars. We hardcode `edc-context/` in skill text.

If we ever go configurable, plan is for `resolve_prompt` to prepend a
"NOTE: this repo's context dir is X (replacing default 'edc-context')"
prefix. NOT building that today.

## Files Modified

### MIGRATE (production code, currently uses `.context/`)
- `plugins/edc/scripts/edc-paths.sh` — NEW
- `plugins/edc/scripts/edc-review.sh` (15 occurrences)
- `plugins/edc/scripts/edc-clean-slate.sh` (14, plus the `CTX` local)
- `plugins/edc/scripts/edc-audit.sh` (7)
- `plugins/edc/scripts/edc-update.sh` (5)
- `plugins/edc/scripts/edc-build.sh` (4)
- `plugins/edc/scripts/edc-assert-fresh.sh` (4)
- `plugins/edc/scripts/edc-recover-context.sh` (2)
- `plugins/edc/scripts/edc-doctor.sh` (2)
- `plugins/edc/scripts/edc-build-plan.sh` (2)
- `plugins/edc/hooks/lib/paths.mjs` — NEW
- `plugins/edc/hooks/lib/route.mjs` (4)
- `install.sh` — adds edc-paths.sh to install list
- `.edc/scripts/*` — synced from plugins/edc/scripts/

### MIGRATE (skill content — hardcoded literal `edc-context/`)
- `plugins/edc/skills/edc-build-impl/SKILL.md`
- `plugins/edc/skills/edc-build-impl/adapter-contract.md`
- `plugins/edc/skills/edc-update-impl/SKILL.md`
- `plugins/edc/skills/edc-audit-impl/SKILL.md`
- `plugins/edc/skills/edc-review-impl/*.md`
- `plugins/edc/skills/edc-context/**`
- `plugins/edc/commands/edc-*.md`
- `plugins/edc/README.md`
- `README.md`

### TESTS — UPDATE
- All hardening tests with `.context/` literals (assertions about
  production behavior) — sed to `edc-context/`. Fixture-internal temp
  dirs that mock manifests stay as-is if they just exercise routing
  with arbitrary paths, but our orchestrators read the literal
  `edc-context/`, so test fixtures MUST also write to `edc-context/`.
  → all `.context/` in test fixtures becomes `edc-context/`.
- New: `tests/hardening/t16-context-dir-source-of-truth.sh`:
  - Pin that no production shell script under `plugins/edc/scripts/`
    contains the literal `\.context/` (only `$EDC_CONTEXT_DIR` /
    `$EDC_MANIFEST` etc, or the literal `edc-context/` if absolutely
    needed).
  - Pin that every orchestrator script sources `edc-paths.sh`.
  - Pin that hooks import from `./lib/paths.mjs`.
  - Skills are allowed to contain literal `edc-context/` (they're prompt
    content).

## Files NOT Touched (per scope)

- This repo's own `.context/` directory contents — user said don't migrate
- Planning docs (`PLAN-*.md`, `BUILD_REGRESSION_*.md`, `external_context_plan.md`)
- `benchmark/.edc-bench/**` — benchmark scratch
- `agents/pi/**` — verify if it uses `.context/`; if yes, migrate; if no,
  skip
- `.edcignore`, `.edc/scripts/` (the dot-hidden cli scratch dir) — user
  said no rename

## Migration Steps

1. Write `edc-paths.sh` and `paths.mjs`
2. Update each orchestrator script: source paths file, replace literals
   with vars
3. Sync `.edc/scripts/` and `~/.edc/scripts/`
4. Update hooks
5. Update skills + commands + README (literal sed `edc-context/`)
6. Update install.sh to copy edc-paths.sh
7. Update hardening test fixtures (sed `\.context/` → `edc-context/`)
8. Write t16
9. Run full hardening suite
10. Manual smoke test: rm -rf .context && edc build (verify it builds
    edc-context/ instead) — but skip per user request, they'll do it

## Out of Scope (explicit)

- Configurability (env var, config file, flag). Plumbing is in place
  to add later by changing defaults in `edc-paths.sh` / `paths.mjs`
- Migrating this repo's existing `.context/` directory
- Renaming `.edcignore`, `.edc/scripts/`
- Changing any benchmark scratch state

## Status

- [x] approval to start
- [x] edc-paths.sh + paths.mjs (single source of truth, future-configurable)
- [x] orchestrator scripts migrated (review/clean-slate/audit/build/update/
      assert-fresh/recover/doctor/build-plan)
- [x] hooks migrated (route.mjs)
- [x] skills/commands/READMEs migrated (literal `edc-context/`)
- [x] install.sh updated (installs edc-paths.sh + edc-build-plan.sh)
- [x] ~/.edc/scripts/ synced via reinstall
- [x] hardening fixtures migrated
- [x] t16-context-dir-source-of-truth.sh added (9 PASS / 0 FAIL)
- [x] full hardening suite green (17 / 17 PASS)
