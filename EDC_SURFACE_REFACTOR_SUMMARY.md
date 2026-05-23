# EDC Surface Refactor Summary

## Goal

Clean up EDC's agent/TUI user experience so users see only real user-facing actions and methodology skills, not internal worker prompts or implementation shims.

## Before

Agent UIs exposed a confusing mix of commands and implementation skills:

```text
commands:
  edc-build
  edc-update
  edc-audit
  edc-run-review
  edc-review
  edc-doctor

skills:
  edc-context
  edc-build-impl
  edc-update-impl
  edc-review-impl
  edc-audit-impl
```

Problems:

- `/edc-review` looked user-facing but was an internal worker entrypoint.
- `/edc-audit` duplicated the audit methodology skill.
- `edc-review-impl` and `edc-audit-impl` were bad user-facing names.
- `edc-context` sounded like generated context, but was actually module-context methodology/prompt material.
- Pi autocomplete showed implementation details instead of product-level actions.

## After

Visible agent UI commands:

```text
edc-build
edc-update
edc-run-review
edc-doctor
```

Visible user-facing skills:

```text
edc-review
edc-audit
```

Private/internal prompt bundles:

```text
edc-build-impl
edc-update-impl
edc-module-context-impl
```

Terminal CLI still keeps:

```bash
edc build
edc update
edc review
edc audit
edc doctor
```

Rationale: terminal commands do not pollute TUI/autocomplete, so keeping `edc audit` is fine.

## Main Changes

### Renamed user-facing skills

```text
edc-review-impl -> edc-review
edc-audit-impl  -> edc-audit
```

### Renamed/moved hidden implementation prompts

```text
edc-context     -> edc-module-context-impl
edc-build-impl  -> prompt-bundles/edc-build-impl
edc-update-impl -> prompt-bundles/edc-update-impl
```

Internal prompt bundles now live outside public `skills/`:

```text
plugins/edc/prompt-bundles/
  edc-build-impl/
  edc-update-impl/
  edc-module-context-impl/
```

Public skills now live under:

```text
plugins/edc/skills/
  edc-review/
  edc-audit/
```

### Removed public command shims

Deleted from public command discovery:

```text
plugins/edc/commands/edc-audit.md
plugins/edc/commands/edc-review.md
```

Only these command files remain public:

```text
plugins/edc/commands/edc-build.md
plugins/edc/commands/edc-update.md
plugins/edc/commands/edc-run-review.md
plugins/edc/commands/edc-doctor.md
```

### Updated installers

Installers now enforce the intended surface:

- public skill dirs receive only `edc-review` and `edc-audit`
- private `~/.edc/skills` receives all prompt bundles needed by subprocesses
- cursor command wrappers expose only build/update/run-review/doctor
- codex command skills expose only build/update/run-review/doctor
- stale old names are cleaned up on reinstall

### Updated Pi extension

Pi now:

- registers only `/edc-build`, `/edc-update`, `/edc-run-review`, `/edc-doctor`
- exposes only `edc-review` and `edc-audit` as skills
- installs project-local `.edc/scripts/`
- installs private project-local `.edc/skills/` for subprocess prompt resolution

### Updated prompt resolution

- review orchestration resolves `edc-review`
- audit orchestration resolves `edc-audit`
- build/update use private prompt bundles
- cursor/codex subprocesses prefer `.edc/skills` and `~/.edc/skills` before public skill dirs

### Added PR-number review support

Users can now run:

```text
/edc-run-review --pr 147 --base main --ignore-context
```

Internally this maps to `gh pr diff 147 --name-only`.

## Installed Surface Verified

Cursor commands:

```text
edc-build.md
edc-doctor.md
edc-run-review.md
edc-update.md
```

Cursor skills:

```text
edc-audit
edc-review
```

Codex top-level commands/skills:

```text
edc-audit
edc-build
edc-doctor
edc-review
edc-run-review
edc-update
```

Private `~/.edc/skills`:

```text
edc-audit
edc-build-impl
edc-module-context-impl
edc-review
edc-update-impl
```

## Tests Run

Passing:

```bash
bash tests/hardening/t5-portability-install.sh
bash tests/hardening/t10-pi-extension.sh
bash tests/hardening/t11-audit-orchestrator.sh
bash tests/hardening/t14-resolve-prompt-decoupled.sh
bash tests/hardening/t15-review-routing.sh
bash tests/hardening/t16-context-dir-source-of-truth.sh
bash tests/hardening/t6-auto-mode.sh
bash tests/hardening/t7-codex-auto-mode.sh
```

Also smoke-tested PR task generation in `wolfpack`:

```bash
bash .edc/scripts/edc-review.sh --build --pr 147 --base main --ignore-context
```

## Remaining Caveat

Full test suite still fails immediately at:

```bash
tests/hardening/t1-tool-lockdown.sh
```

That failure is unrelated/stale: the test greps for old `claude -p` formatting and exits before useful assertions.
