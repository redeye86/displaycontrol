#!/bin/bash

# Verzeichnis des Skripts (auch bei Symlinks) ermitteln
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"


$SCRIPT_DIR/displayctl.sh switch tv
