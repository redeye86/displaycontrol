#!/usr/bin/env bash
set -euo pipefail

# Verzeichnis des Skripts (auch bei Symlinks) ermitteln
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Optionales Preset, Default: monitors
PRESET="${1:-monitors}"

exec "$SCRIPT_DIR/displayctl.sh" wake "$PRESET"
