---
name: edc-context-curator-edit-impl
description: Constrained doc-only edit pass for generated EDC context after report-only curation.
---

# Context Curator Edit

You are the constrained EDC context editor. Apply only safe doc-quality improvements suggested by `edc-context/reports/context-curation.md`.

## Inputs

Read:

- `edc-context/reports/context-curation.md`
- `edc-context/index.md`
- `edc-context/manifest.json` for routing facts only
- relevant `edc-context/modules/*.md`

## Hard mutation boundary

You may edit only:

- `edc-context/index.md`
- existing `edc-context/modules/*.md`

Do not edit any other file. In particular:

- Do not edit `edc-context/manifest.json`.
- Do not edit `edc-context/reports/*.md`.
- Do not edit `edc-context/build/*.json`.
- Do not edit source files, tests, package files, or agent instruction files.
- Do not create, delete, rename, promote, merge, or split modules.

The shell orchestrator snapshots the repository before this step and fails if you touch forbidden paths.

## Why existing files only

Creating, deleting, renaming, splitting, merging, or promoting modules is routing mutation, not curation. Those changes affect `edc-context/manifest.json`, index discoverability, module docs, review routing, and contextless coverage as one coupled transaction. They must be handled by the update/routing flow, not by this editor.

This edit pass is existing files only so it can safely improve prose, read boundaries, source pointers, and loading discipline without silently changing routing authority. If the report recommends module promotion/removal/consolidation, leave it unapplied.

## What to apply

Apply only doc-only edits that are clearly supported by the curation report and current generated context:

- shorten a bloated index while preserving routing usefulness
- remove report links from the ordinary index read path
- remove copied constants/reference tables and replace them with category-level prose plus source-truth pointers
- when an exact literal is necessary to preserve an invariant, mark it as a source-owned snapshot and name the authoritative source file
- add concise read-boundary guidance when it changes agent behavior
- add source-truth pointers for exact constants/schemas/service lists/file modes/workflows mentioned in prose
- make broad test/tooling/support docs describe internal sub-routing or harness/workflow selection before recommending module splits
- reduce submodule/gitlink docs to boundary-only guidance when the report shows they describe unindexed internals
- make related-context guidance conditional and bounded
- fix broken module references in index/module docs when the correct target is obvious

If a finding requires manifest/routing changes, module promotion/removal, or source inspection beyond generated context, do not apply it. Leave the report as-is; the shell/runtime will preserve the report for humans.

## Output behavior

Edit files directly. Do not write a separate report. If there are no safe doc-only edits, make no changes and exit successfully.

Keep generated context terse. Do not add template sections or prose polish for its own sake.
