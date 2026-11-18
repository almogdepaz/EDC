# Changelog

Notable user-facing changes to EDC are documented here.

## [1.1.6] - 2026-11-18

### Added
- build/update, no-context, and cancel choices for missing or stale context in Pi and terminal reviews
- explicit `--refresh-context` consent for automated reviews
- opt-in `--findings-json` output for combined differential reviews, with validated candidate anchors and provenance

### Changed
- non-interactive public CLI reviews with missing or stale context require `--refresh-context`, `--ignore-context`, or `--no-context-refresh`; they no longer generate context implicitly
- review guidance checks source/consumer behavioral contracts and preserves established contract details in structured findings

### Fixed
- Pi subprocess output drains before shutdown, with bounded failure instead of silently truncated stdout or stderr
- context changing after review preflight cannot trigger unapproved recovery
- malformed context manifests cannot pass freshness validation through a textual commit match

## [1.1.5] - 2026-11-12

### Added
- canonical global/package runtime inventory, transactional managed-global installation, and structured runtime diagnostics
- staged multi-phase review results and Pi status projection
- macOS CI coverage and deterministic benchmark scorer tests
- vulnerability reporting policy
- explicit no-refresh and ignore-context review modes across all review lenses
- optional Octocode v19 research support with repository-path validation

### Changed
- global/package runtime validation now fails closed before managed helpers execute
- review workers remain read-only by contract and fail when forbidden paths change
- release, plugin, context, and installer versions are aligned

### Fixed
- remote installer archive drift
- quality-review ignore handling and full-scope recovery guidance
- runtime install lock ownership
- benchmark recall aggregation and scorer pattern matching
- hardening test checkout pollution
- context recovery preserves existing context until the replacement build succeeds
- reviews fail explicitly when legacy unmapped rules skip every in-scope file
- Claude prompt-file delivery uses stdin
- Pi background status updates are atomic

## [1.1.4] - 2026-07-22

- improved deterministic review orchestration and package/runtime robustness

## [1.1.3] - 2026-07-08

- expanded public review and discoverability surfaces

## [1.1.2] - 2026-07-01

- published the Pi package surface and aligned plugin distribution metadata
