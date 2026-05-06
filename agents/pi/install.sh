#!/bin/bash
# Install EDC as a pi extension.
#
# Usage:
#   ./install.sh                   # global install via git url
#   ./install.sh --local           # project-local install (.pi/settings.json)
#   ./install.sh --from-source     # install from this checkout (local path)
#   ./install.sh --context-mode advisory|inject
#                                  # toggle .context/manifest.json default mode
#
# Requires: pi (https://github.com/mariozechner/pi) on PATH.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REPO_SOURCE="git:github.com/almogdepaz/edc"

LOCAL=0
FROM_SOURCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local|-l)
      LOCAL=1
      shift
      ;;
    --from-source)
      FROM_SOURCE=1
      shift
      ;;
    --context-mode)
      mode="${2:-}"
      case "$mode" in
        advisory|inject)
          manifest="$REPO_ROOT/.context/manifest.json"
          if [ ! -f "$manifest" ]; then
            echo "edc: no .context/manifest.json in $REPO_ROOT — build first" >&2
            exit 2
          fi
          tmp="$(mktemp)"
          jq --arg m "$mode" '.policy.defaultMode = $m' "$manifest" > "$tmp"
          mv "$tmp" "$manifest"
          echo "edc: set policy.defaultMode = $mode"
          exit 0
          ;;
        *)
          echo "ERROR: --context-mode must be advisory or inject" >&2
          exit 2
          ;;
      esac
      ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "edc: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v pi >/dev/null 2>&1; then
  echo "edc: pi CLI not found on PATH. Install pi first: https://github.com/mariozechner/pi" >&2
  exit 1
fi

ARGS=()
if [ "$LOCAL" -eq 1 ]; then
  ARGS+=("-l")
fi

if [ "$FROM_SOURCE" -eq 1 ]; then
  SOURCE="$REPO_ROOT"
else
  SOURCE="$REPO_SOURCE"
fi

echo "Installing EDC as pi extension (source: $SOURCE${LOCAL:+, project-local})..."
pi install "$SOURCE" "${ARGS[@]}"

cat <<EOF

Done. Available commands in pi:
  /edc-build       build deep architectural context
  /edc-update      incremental update from branch diff
  /edc-audit       overengineering / bloat audit
  /edc-run-review  differential code review
  /edc-doctor      validate context tree
  /edc-review      internal: per-module review

Mode toggle (per-project, after /edc-build has run):
  bash agents/pi/install.sh --context-mode advisory   # docs only (default)
  bash agents/pi/install.sh --context-mode inject     # auto-inject context
EOF
