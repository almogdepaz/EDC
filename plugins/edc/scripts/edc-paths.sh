#!/usr/bin/env bash
# edc-paths: single source of truth for the context directory layout.
#
# Sourced (not exec'd) by every orchestrator and helper that touches
# .context-style state. Defines the canonical paths so future work to
# make this configurable (env var, manifest field, CLI flag) is a
# one-edit change here, not a 50-file sweep.
#
# All variables are exported as plain shell strings, repo-relative.
# Callers that need absolute paths should resolve them with `pwd` /
# `realpath` themselves.

EDC_CONTEXT_DIR="${EDC_CONTEXT_DIR:-edc-context}"
EDC_MANIFEST="$EDC_CONTEXT_DIR/manifest.json"
EDC_INDEX="$EDC_CONTEXT_DIR/index.md"
EDC_MODULES_DIR="$EDC_CONTEXT_DIR/modules"
EDC_REPORTS_DIR="$EDC_CONTEXT_DIR/reports"
EDC_BUILD_DIR="$EDC_CONTEXT_DIR/build"
EDC_ISSUES="$EDC_REPORTS_DIR/issues.md"
EDC_COMPLEXITY="$EDC_REPORTS_DIR/complexity.md"
EDC_BUILD_INFO="$EDC_BUILD_DIR/build.json"
