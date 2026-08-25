#!/bin/bash
# Install EDC as a pi extension.
#
# Usage:
#   ./install.sh                   # global install via git url
#   ./install.sh --from-source     # global install from this checkout
#   ./install.sh --context-mode advisory|inject
#                                  # toggle edc-context/manifest.json default mode
#
# Requires: pi (https://pi.dev) on PATH.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_SOURCE="git:github.com/almogdepaz/edc"

FROM_SOURCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local|-l)
      echo "edc: --local is unsupported; EDC installs globally only" >&2
      exit 2
      ;;
    --from-source)
      FROM_SOURCE=1
      shift
      ;;
    --context-mode)
      mode="${2:-}"
      case "$mode" in
        advisory|inject)
          manifest="$REPO_ROOT/edc-context/manifest.json"
          if [ ! -f "$manifest" ]; then
            echo "edc: no edc-context/manifest.json in $REPO_ROOT — build first" >&2
            exit 2
          fi
          json_cli="$REPO_ROOT/plugins/edc/hooks/lib/json-cli.mjs"
          command -v node >/dev/null 2>&1 || { echo "edc: node required to update $manifest" >&2; exit 2; }
          [ -f "$json_cli" ] || { echo "edc: json-cli.mjs not found at $json_cli" >&2; exit 2; }
          tmp="$(mktemp)"
          node "$json_cli" mode-set "$manifest" "$mode" > "$tmp"
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
  echo "edc: pi CLI not found on PATH. Install pi first: https://pi.dev" >&2
  exit 1
fi

if [ "$FROM_SOURCE" -eq 1 ]; then
  SOURCE="$REPO_ROOT"
else
  SOURCE="$REPO_SOURCE"
fi

echo "Installing EDC as pi extension globally (source: $SOURCE)..."
pi install "$SOURCE"

cat <<EOF

Done. Available command in pi:
  /edc             interactive EDC menu (review, delivery-review, status, build, update, audit, doctor)

Visible skills:
  edc-review       security/adversarial review methodology
  edc-audit        code quality / maintainability audit methodology
  edc-delivery-review
                   goal/spec delivery + architecture-fit review methodology

Mode toggle (per-project, after context has been built):
  bash pi/install.sh --context-mode advisory   # docs only (default)
  bash pi/install.sh --context-mode inject     # auto-inject context
EOF
