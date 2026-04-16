#!/usr/bin/env bash
set -euo pipefail

# Suspend-Watchdog:
# - Läuft in Dauerschleife
# - Schläft INTERVAL Sekunden
# - Prüft, ob seit letztem Tick mehr als INTERVAL+THRESHOLD vergangen sind
#   => interpretiert als Suspend/Resume und führt Hooks aus post-sleep.d aus

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HOOK_DIR="${HOOK_DIR:-$SCRIPT_DIR/post-sleep.d}"
STATE_FILE="${STATE_FILE:-${XDG_RUNTIME_DIR:-/tmp}/suspend_watchdog.last_ts}"
LOG_TAG="suspend-watchdog"

INTERVAL="${INTERVAL:-${1:-10}}"
THRESHOLD="${THRESHOLD:-${2:-5}}"

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 [INTERVAL_SECONDS] [THRESHOLD_SECONDS]" >&2
  echo "or set env vars INTERVAL / THRESHOLD" >&2
  exit 2
fi

log() {
  local msg="$*"
  printf '[%(%F %T)T] %s\n' -1 "$msg"
  command -v logger >/dev/null 2>&1 && logger -t "$LOG_TAG" -- "$msg" || true
}

run_hooks() {
  if [[ ! -d "$HOOK_DIR" ]]; then
    log "Hook-Verzeichnis nicht gefunden: $HOOK_DIR"
    return 0
  fi

  local ran_any=0
  while IFS= read -r -d '' hook; do
    if [[ -x "$hook" ]]; then
      ran_any=1
      log "Führe Hook aus: $hook"
      if "$hook"; then
        log "Hook OK: $hook"
      else
        log "Hook FEHLER ($?): $hook"
      fi
    fi
  done < <(find "$HOOK_DIR" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)

  if [[ "$ran_any" -eq 0 ]]; then
    log "Keine ausführbaren Hooks in $HOOK_DIR gefunden"
  fi
}

# Initialer Counter = aktuelle Unixzeit
last_ts="$(date +%s)"
printf '%s\n' "$last_ts" > "$STATE_FILE" || true
log "Gestartet (INTERVAL=${INTERVAL}s, THRESHOLD=${THRESHOLD}s, HOOK_DIR=$HOOK_DIR)"

while true; do
  sleep "$INTERVAL"
  now_ts="$(date +%s)"
  elapsed=$(( now_ts - last_ts ))

  # Counter auf aktuelle Unixzeit updaten
  last_ts="$now_ts"
  printf '%s\n' "$last_ts" > "$STATE_FILE" || true

  if (( elapsed > INTERVAL + THRESHOLD )); then
    log "Suspend/Resume erkannt (elapsed=${elapsed}s > $((INTERVAL + THRESHOLD))s)"
    run_hooks
  fi
done
