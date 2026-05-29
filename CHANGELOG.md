# Changelog

All notable changes to EDC are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses semantic versioning for npm releases.

## [Unreleased]

### Added
- Added GitHub Actions CI for the hardening suite and package dry-run.
- Added contributor and security documentation.
- Added a quick pi path to the README.
- Added package author and issue tracker metadata.

## [1.1.0] - 2026-05-29

### Added
- Published EDC as the pi package `@sgtbeatdown/edc`.
- Added a strict npm package `files` allowlist so generated context, benchmarks, tests, and local planning artifacts are not shipped.
- Added pi package compatibility documentation for provider, context-pruning, permission, sandbox, and SSH extensions.
- Added npm prepublish checks for the hardening suite and package dry-run.
- Added package-publish metadata regression coverage.

### Changed
- Raised the pi package Node.js engine baseline to `>=20.6.0`.
- Updated pi peer dependency metadata to the current `@earendil-works/pi-coding-agent` package namespace.
- Updated pi documentation links to `https://pi.dev`.

### Security
- Added an MIT license file and documented that EDC package consumers should review source and generated runtime state before installing/running local automation.
