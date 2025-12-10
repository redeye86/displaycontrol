#!/usr/bin/env bash
set -euo pipefail

if ! [ -x /usr/bin/yq ];
then
  echo "yq not found, please install"
  exit 1
fi

# Verzeichnis des Skripts (auch bei Symlinks) ermitteln
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Preset-File **immer relativ zum Script-Verzeichnis**
CONFIG_FILE="$SCRIPT_DIR/monitor_presets.yaml"



PLASMA_PID=$(pgrep --uid $(id --user) --newest plasmashell)

DISPLAY_ENVIRONMENT_VARS=$(tr '\0' '\n' < /proc/$PLASMA_PID/environ | grep -E 'WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS')

export $DISPLAY_ENVIRONMENT_VARS


#Terminal Coloring
if [[ -t 1 ]]; then
  GREEN=$(printf '\e[32m')
  RED=$(printf '\e[31m')
  RESET=$(printf '\e[0m')
else
  GREEN=""
  RED=""
  RESET=""
fi

# ============= EDID aus sysfs einlesen ==================
declare -A PORTS
load_edids() {
  for edidfile in /sys/class/drm/*/edid; do
    [[ -f "$edidfile" ]] || continue
    port=$(basename "$(dirname "$edidfile")")
    hash=$(sha256sum "$edidfile" | awk '{print substr($1,1,12)}')
    PORTS["$hash"]="$port"
  done
}



# ============= MONITOR-LISTING ==================
list_monitors() {
  echo "=== Verfügbare Monitore ==="

  # KScreen JSON – nur wenn gültiges JSON geliefert wird
  local kscreen_json=""
  local raw_json
  raw_json=$(kscreen-doctor --json 2>/dev/null || true)
  if [[ -n "$raw_json" ]] && jq -e . >/dev/null 2>&1 <<<"$raw_json"; then
    kscreen_json="$raw_json"
  fi

  for edidfile in /sys/class/drm/*/edid; do
    [[ -f "$edidfile" ]] || continue

    port=$(basename "$(dirname "$edidfile")")        # card1-DP-1
    short_port=$(echo "$port" | sed 's/^card[0-9]-//')  # DP-1
    hash=$(sha256sum "$edidfile" | awk '{print substr($1,1,12)}')
    status=$(cat "$(dirname "$edidfile")/status" 2>/dev/null || echo "?")

    # Farben für Status
    if [[ "$status" == "connected" ]]; then
      status_color="${GREEN}connected${RESET}"
    else
      status_color="${RED}${status}${RESET}"
    fi

    # Hersteller aus EDID Bytes 8–9 (standardisiert)
    manuf_hex=$(xxd -p -s 8 -l 2 "$edidfile" 2>/dev/null || echo "0000")
    manuf_code=$((0x$manuf_hex))
    manufacturer=$(printf "%c%c%c" \
      $((( (manuf_code >> 10) & 31) + 64)) \
      $((( (manuf_code >> 5)  & 31) + 64)) \
      $(((  manuf_code        & 31) + 64)) )

    # Modellname und Seriennummer (aus EDID ASCII Blocks)
    model=$(strings "$edidfile" | grep -m1 -E "([A-Za-z0-9][A-Za-z0-9 _-]{3,})" || echo "-")
    serial=$(strings "$edidfile" | grep -m1 -E "^[A-Za-z0-9]{6,}$" || echo "-")

    # Maximal-Auflösung inkl. RefreshRate über kscreen-doctor --json
    max_res="-"
    if [[ -n "$kscreen_json" ]]; then
      # Schritt 1: höchste Auflösung finden
      read max_w max_h <<<"$(jq -r --arg port "$short_port" '
        .outputs[]? | select(.name == $port) | .modes[]? |
        "\(.size.width) \(.size.height)"
      ' <<<"$kscreen_json" |
      sort -n -k1,1 -k2,2 |
      tail -n1)"

      # Schritt 2: innerhalb dieser Auflösung höchste RefreshRate wählen
      if [[ -n "$max_w" && -n "$max_h" ]]; then
        max_res=$(jq -r --arg port "$short_port" --arg w "$max_w" --arg h "$max_h" '
          .outputs[]? | select(.name == $port) |
          .modes[]? |
          select((.size.width|tostring)==$w and (.size.height|tostring)==$h) |
          "\(.size.width)x\(.size.height)@\(.refreshRate|floor)"
        ' <<<"$kscreen_json" |
        sort -n -t @ -k2,2 |
        tail -n1)
      fi

      [[ -z "$max_res" ]] && max_res="-"
    fi



    echo "- Port: $port | ID: $hash | Status: $status_color"
    echo "    Hersteller: $manufacturer"
    echo "    Modell:      ${model:-"-"}"
    echo "    Seriennr.:   ${serial:-"-"}"
    echo "    Max. Auflösung: ${max_res:-"-"}"
    echo
  done
}




# ============= AUDIO LISTING ==================
list_audio() {
  echo "=== Audio Sinks ==="
  pactl list short sinks | while read -r index name rest; do
    echo "- Sink: $name"
    pactl list sinks | awk -v sink="$name" '
      $0 ~ ("Name: "sink) {p=1} p && /Ports:/, /^$/ {print "   " $0}
      /^$/ {p=0}
    '
  done
}

list_all() {
  list_monitors
  echo
  list_audio
  echo
  echo "=== Verfügbare Presets ==="
  yq '.presets[].name' "$CONFIG_FILE"
}

# ============= AUDIO APPLY ==================
apply_audio() {
  local preset="$1"
  AUDIO_SINK=$(yq -r ".presets[] | select(.name == \"$preset\") | .audio.sink" "$CONFIG_FILE")
  AUDIO_PORT=$(yq -r ".presets[] | select(.name == \"$preset\") | .audio.port" "$CONFIG_FILE")

  echo "Set audio port: $AUDIO_PORT"
  pactl set-sink-port 0 "$AUDIO_PORT" || true
  
  echo "Set audio sink: $AUDIO_SINK"
  pactl set-default-sink "$AUDIO_SINK" || true

  mapfile -t INPUTS < <(pactl list short sink-inputs | awk '{print $1}')

  for id in "${INPUTS[@]}"; do
    echo "  $id"
    pactl move-sink-input "$id" "$AUDIO_SINK" &>/dev/null || true
  done
}

# ============= KSCREEN APPLY ==================
apply_display() {
  local preset="$1"
  load_edids
  CMD="kscreen-doctor"

  IFS=$'\n'
  for row in $(yq -r ".presets[] | select(.name == \"$preset\") | .outputs[] | @base64" "$CONFIG_FILE"); do
    _jq() { echo "$row" | base64 --decode | jq -r "$1"; }

    id=$(_jq '.id')
    active=$(_jq '.active')
    resolution=$(_jq '.resolution')
    position=$(_jq '.position')
    priority=$(_jq '.priority')

    port="${PORTS[$id]}"
    [[ -z "$port" ]] && { echo "Warnung: Monitor-ID $id nicht angeschlossen."; continue; }
    short_port=$(echo "$port" | sed 's/^card[0-9]-//')

    if [[ "$active" == "true" ]]; then
      CMD+=" output.$short_port.enable"
      CMD+=" output.$short_port.mode.$resolution"
      CMD+=" output.$short_port.position.$position"
      CMD+=" output.$short_port.priority.$priority"
    else
      CMD+=" output.$short_port.disable"
    fi
  done

  echo "--- Running ---"
  echo "$CMD"
  eval "$CMD"
}

# ================== MAIN ==================
# ================== MAIN ==================
video=1
audio=1

# Flags vorab auswerten
while [[ $# -gt 0 ]]; do
  case "$1" in
    --video-only)
      audio=0
      shift
      ;;
    --audio-only)
      video=0
      shift
      ;;
    list)
      cmd="list"
      shift
      ;;
    switch)
      cmd="switch"
      shift
      ;;
    *)
      # Rest sollte das Preset sein
      preset="$1"
      shift
      ;;
  esac
done

case "${cmd:-}" in
  list )
    list_all
    ;;

  switch )
    if [[ -z "${preset:-}" ]]; then
      echo "Bitte ein Preset angeben."
      exit 1
    fi
    
    # Prüfen, ob das Preset existiert
    if ! yq -e ".presets[] | select(.name == \"$preset\")" "$CONFIG_FILE" >/dev/null; then
      echo "Fehler: Preset \"$preset\" existiert nicht in $CONFIG_FILE"
      exit 1
    fi

    # Nur Display?
    if [[ "$video" == "1" ]]; then
      apply_display "$preset"
    fi

    # Nur Audio?
    if [[ "$audio" == "1" ]]; then
      apply_audio "$preset"
    fi
    ;;

  * )
    echo "Usage:"
    echo "  $0 list"
    echo "  $0 switch <preset>"
    echo "  $0 switch --video-only <preset>"
    echo "  $0 switch --audio-only <preset>"
    exit 1
    ;;
esac
