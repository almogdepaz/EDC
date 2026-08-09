# Changelog

Notable user-facing changes to EDC are documented here.

## [1.1.5] - Unreleased

### Added
- canonical project-runtime inventory, transactional installation, and structured runtime diagnostics
- staged multi-phase review results and Pi status projection
- macOS CI coverage and deterministic benchmark scorer tests
- vulnerability reporting policy

### Changed
- project-local runtime inconsistencies now fail before managed helpers execute
- review workers remain read-only by contract and fail when forbidden paths change
- release, plugin, context, and installer versions are aligned

### Fixed
- remote installer archive drift
- quality-review ignore handling and full-scope recovery guidance
- runtime install lock ownership
- benchmark recall aggregation and scorer pattern matching
- hardening test checkout pollution

## [1.1.4] - 2026-07-22

- improved deterministic review orchestration and package/runtime robustness

## [1.1.3] - 2026-07-08

- expanded public review and discoverability surfaces

## [1.1.2] - 2026-07-01

- published the Pi package surface and aligned plugin distribution metadata
