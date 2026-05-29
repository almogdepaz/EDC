#!/bin/bash
# Public pi-facing installer wrapper. The implementation lives in agents/pi/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/../agents/pi/install.sh" "$@"
