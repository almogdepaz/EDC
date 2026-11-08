#!/usr/bin/env bash
# Clean benchmark harness entry point (plan 041). See clean_harness.py.
#   benchmark/clean.sh --arm edc-module|edc-review-skill|edc-security|enemy-3|edc-deep \
#     --project <p> --entry <CVE-...|PLANT-...> [--gt-root DIR] [--run N] [--skip-judge] ...
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clean_harness.py" "$@"
