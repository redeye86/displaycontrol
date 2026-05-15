#!/usr/bin/env bash
set -euo pipefail

# Post-suspend Recovery Hook für einen problematischen DP-Monitor (default: DP-5)
# Strategie:
# 1) KScreen-Status prüfen (connected/enabled)
# 2) ddcutil detect auf "Invalid display" für den Port prüfen
# 3) Bei Auffälligkeit displayctl wake (video-only) ausführen + retry

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
DISPLAYCTL="${DISPLAYCTL:-$REPO_DIR/displayctl.sh}"

TARGET_OUTPUT="${TARGET_OUTPUT:-DP-5}"
PRESET="${PRESET:-monitors}"
INITIAL_SETTLE="${INITIAL_SETTLE:-4}"   # Sekunden nach Resume, bevor geprüft wird
RETRIES="${RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-3}"
LOG_TAG="post-sleep-dp-recovery"

log() {
  local msg="$*"
  printf '[%(%F %T)T] %s\n' -1 "$msg"
  command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" -- "$msg" || true
}

kscreen_flags() {
  local json
  json="$(kscreen-doctor --json 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    echo "unknown unknown"
    return 0
  fi

  jq -r --arg out "$TARGET_OUTPUT" '
    .outputs[]? | select(.name == $out) | "\(.connected) \(.enabled)"
  ' <<<"$json" | head -n1
}

ddc_status_for_output() {
  # Ausgabe: ok | invalid | notfound | noddc
  command -v ddcutil >/dev/null 2>&1 || { echo "noddc"; return 0; }

  local detect
  detect="$(ddcutil detect 2>/dev/null || true)"
  [[ -z "$detect" ]] && { echo "notfound"; return 0; }

  awk -v out="$TARGET_OUTPUT" '
    BEGIN { state="notfound" }
    /^(Display [0-9]+|Invalid display)/ { header=$0 }
    /DRM connector:/ {
      conn=$0
      sub(/^[[:space:]]*DRM connector:[[:space:]]*/, "", conn)
      if (conn ~ ("card[0-9]+-" out "$") ) {
        if (header ~ /^Invalid display/) state="invalid"
        else if (header ~ /^Display [0-9]+/) state="ok"
      }
    }
    END { print state }
  ' <<<"$detect"
}

needs_recovery() {
  local connected enabled ddc
  read -r connected enabled < <(kscreen_flags)
  ddc="$(ddc_status_for_output)"

  log "Check $TARGET_OUTPUT: connected=$connected enabled=$enabled ddc=$ddc"

  # Recovery-Bedingungen:
  # - Output nicht verbunden/aktiv obwohl im monitors-Preset erwartet
  # - ddcutil meldet explizit Invalid display (typisch bei deep sleep vom Monitor)
  if [[ "$connected" != "true" || "$enabled" != "true" ]]; then
    return 0
  fi

  if [[ "$ddc" == "invalid" ]]; then
    return 0
  fi

  return 1
}

recover_once() {
  if [[ ! -x "$DISPLAYCTL" ]]; then
    log "displayctl nicht gefunden/ausführbar: $DISPLAYCTL"
    return 1
  fi

  log "Recovery: $DISPLAYCTL --video-only wake $PRESET"
  "$DISPLAYCTL" --video-only wake "$PRESET"
}

main() {
  sleep "$INITIAL_SETTLE"

  if ! needs_recovery; then
    log "Kein Recovery nötig."
    exit 0
  fi

  log "Recovery erforderlich für $TARGET_OUTPUT"

  local i
  for (( i=1; i<=RETRIES; i++ )); do
    log "Recovery-Versuch $i/$RETRIES"
    recover_once || true

    sleep "$RETRY_DELAY"
    if ! needs_recovery; then
      log "Recovery erfolgreich nach Versuch $i"
      exit 0
    fi
  done

  log "Recovery weiterhin nötig nach $RETRIES Versuchen"
  exit 1
}

main "$@"
