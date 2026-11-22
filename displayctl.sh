#!/usr/bin/env bash
set -euo pipefail

# Bei nicht-interaktivem SSH (`ssh host displayctl.sh ...`) wird ~/.bashrc
# oft nicht ausgewertet -> ~/bin und ~/.local/bin fehlen im PATH.
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq not found, please install"
  exit 1
fi

# Verzeichnis des Skripts (auch bei Symlinks) ermitteln
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Preset-File **immer relativ zum Script-Verzeichnis**
CONFIG_FILE="$SCRIPT_DIR/monitor_presets.yaml"

# ============= GRAFISCHE SESSION ANKOPPELN ==================
# kscreen-doctor und pactl brauchen die Umgebung der laufenden Plasma-Session.
# Per SSH (oder aus Hooks) fehlt die, bzw. XDG_SESSION_TYPE=tty lässt Qt auf
# X11/xcb zurückfallen. Daher Variablen aus dem Session-Prozess übernehmen.
SESSION_VARS=(WAYLAND_DISPLAY DISPLAY XAUTHORITY XDG_RUNTIME_DIR
              DBUS_SESSION_BUS_ADDRESS XDG_SESSION_TYPE XDG_CURRENT_DESKTOP
              QT_QPA_PLATFORM)

find_session_pid() {
  local uid_opt=()
  [[ -n "${1:-}" ]] && uid_opt=(--uid "$1")
  pgrep "${uid_opt[@]}" --newest plasmashell \
    || pgrep "${uid_opt[@]}" --newest kwin_wayland \
    || true
}

# Als root (z.B. `ssh root@host` oder `sudo displayctl.sh`): als Besitzer der
# Plasma-Session neu starten – kscreen/PipeWire laufen nur in dessen Kontext.
if [[ "$EUID" -eq 0 && -z "${DISPLAYCTL_NO_REEXEC:-}" ]]; then
  pid=$(find_session_pid)
  if [[ -n "$pid" ]]; then
    session_user=$(ps -o user= -p "$pid" | tr -d ' ')
    if [[ -n "$session_user" && "$session_user" != "root" ]]; then
      exec runuser -u "$session_user" -- env DISPLAYCTL_NO_REEXEC=1 "$SCRIPT_DIR/$(basename "$0")" "$@"
    fi
  fi
fi

import_session_env() {
  local pid line var
  pid=$(find_session_pid "$(id --user)")

  if [[ -n "$pid" && -r "/proc/$pid/environ" ]]; then
    while IFS= read -r -d '' line; do
      var="${line%%=*}"
      for v in "${SESSION_VARS[@]}"; do
        [[ "$var" == "$v" ]] && export "$line"
      done
    done < "/proc/$pid/environ"
  else
    echo "WARN: keine laufende Plasma-Session gefunden – rate Umgebung" >&2
  fi

  # Fallbacks, falls der Prozess nicht gefunden/lesbar war
  : "${XDG_RUNTIME_DIR:=/run/user/$(id --user)}"
  export XDG_RUNTIME_DIR
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  fi
  if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    local sock
    sock=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-[0-9]*' -printf '%f\n' 2>/dev/null | sort | head -n1)
    [[ -n "$sock" ]] && export WAYLAND_DISPLAY="$sock"
  fi

  # Qt (kscreen-doctor) explizit auf Wayland zwingen – sonst wählt es per SSH xcb
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    export QT_QPA_PLATFORM=wayland
    export XDG_SESSION_TYPE=wayland
  fi
}
import_session_env


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
# Sink-Namen zur Laufzeit ermitteln: ALSA-Karten-ID (stabil, z.B. "Creative")
# -> aktuelle Kartennummer -> Sink mit passender alsa.card-Property.
# Optional filtert $2 (Regex) den Sink-Namen, z.B. "hdmi" oder "analog".
resolve_sink() {
  local card="$1" match="${2:-}" link idx
  link=$(readlink "/proc/asound/$card" 2>/dev/null || true)   # -> card2
  idx="${link#card}"
  if [[ -z "$idx" ]]; then
    echo "WARN: ALSA-Karte '$card' nicht gefunden" >&2
    return 0
  fi
  pactl -f json list sinks | jq -r --arg c "$idx" --arg m "$match" '
    .[] | select(.properties["alsa.card"] == $c) | select(.name | test($m)) | .name
  ' | head -n1
}

apply_audio() {
  local preset="$1" card match
  AUDIO_SINK=$(yq -r ".presets[] | select(.name == \"$preset\") | .audio.sink // \"\"" "$CONFIG_FILE")
  AUDIO_PORT=$(yq -r ".presets[] | select(.name == \"$preset\") | .audio.port" "$CONFIG_FILE")
  card=$(yq -r ".presets[] | select(.name == \"$preset\") | .audio.card // \"\"" "$CONFIG_FILE")
  match=$(yq -r ".presets[] | select(.name == \"$preset\") | .audio.sink_match // \"\"" "$CONFIG_FILE")

  # "card" hat Vorrang; "sink" bleibt als fester Name/Fallback möglich
  if [[ -n "$card" ]]; then
    local resolved
    resolved=$(resolve_sink "$card" "$match")
    if [[ -n "$resolved" ]]; then
      AUDIO_SINK="$resolved"
    else
      echo "WARN: kein Sink für Karte '$card' (Filter: '${match:-*}') gefunden" >&2
    fi
  fi
  if [[ -z "$AUDIO_SINK" ]]; then
    echo "Kein Audio-Sink ermittelbar, überspringe Audio" >&2
    return 0
  fi

  echo "Set audio port: $AUDIO_PORT"
  pactl set-sink-port "$AUDIO_SINK" "$AUDIO_PORT" || true
  
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

  # Kein "-d" hier: kscreen-doctors -d/--dpms erwartet einen Wert (on/off/show)
  # und würde den ersten output-Befehl (z.B. das TV-Disable) verschlucken.
  local CMD="kscreen-doctor"

  # Erst disable, dann enable/konfig
  local -a DISABLE_CMDS=()
  local -a ENABLE_CMDS=()

  IFS=$'\n'
  for row in $(yq -r ".presets[] | select(.name == \"$preset\") | .outputs[] | @json | @base64" "$CONFIG_FILE"); do
    _jq() { echo "$row" | base64 --decode | jq -r "$1"; }

    id=$(_jq '.id')
    active=$(_jq '.active')
    resolution=$(_jq '.resolution')
    position=$(_jq '.position')
    priority=$(_jq '.priority')

    port="${PORTS[$id]:-}"
    [[ -z "$port" ]] && { echo "Warnung: Monitor-ID $id nicht angeschlossen."; continue; }
    short_port=$(echo "$port" | sed 's/^card[0-9]-//')

    echo "Port: $short_port"

    if [[ "$active" == "true" ]]; then
      ENABLE_CMDS+=("output.$short_port.enable")
      ENABLE_CMDS+=("output.$short_port.mode.$resolution")
      ENABLE_CMDS+=("output.$short_port.position.$position")
      ENABLE_CMDS+=("output.$short_port.priority.$priority")
    else
      DISABLE_CMDS+=("output.$short_port.disable")
    fi
  done

  # Reihenfolge erzwingen: disable zuerst
  for c in "${DISABLE_CMDS[@]}"; do
    CMD+=" $c"
  done
  for c in "${ENABLE_CMDS[@]}"; do
    CMD+=" $c"
  done

  echo "--- Running ---"
  echo "$CMD"
  eval "$CMD"
}

# ============= DDC DETECTION ==================
declare -A DDC_DISPLAY_BY_PORT

run_ddcutil() {
  # Erst sudo ohne Prompt versuchen (für systemd/hooks), dann direkt ohne sudo
  if sudo -n true >/dev/null 2>&1; then
    sudo -n ddcutil "$@"
  else
    ddcutil "$@"
  fi
}

load_ddc_mapping() {
  DDC_DISPLAY_BY_PORT=()

  command -v ddcutil >/dev/null 2>&1 || return 0

  local detect_output
  detect_output=$(run_ddcutil detect 2>/dev/null || true)
  [[ -z "$detect_output" ]] && return 0

  while read -r display_idx drm_port; do
    [[ -z "$display_idx" || -z "$drm_port" ]] && continue
    local short_port
    short_port=$(echo "$drm_port" | sed 's/^card[0-9]-//')
    DDC_DISPLAY_BY_PORT["$short_port"]="$display_idx"
  done < <(
    awk '
      /^Display[[:space:]]+[0-9]+/ {
        idx=$2
        next
      }
      /^Invalid display/ {
        idx=""
        next
      }
      /DRM connector:/ {
        conn=$0
        sub(/^[[:space:]]*DRM connector:[[:space:]]*/, "", conn)
        if (idx != "") {
          print idx, conn
        }
      }
    ' <<<"$detect_output"
  )
}

# ============= WAKE APPLY ==================
apply_wake() {
  local preset="$1"

  load_edids
  load_ddc_mapping

  local targets=0
  local -a fallback_ports=()

  IFS=$'\n'
  for row in $(yq -r ".presets[] | select(.name == \"$preset\") | .outputs[] | @json | @base64" "$CONFIG_FILE"); do
    _jq() { echo "$row" | base64 --decode | jq -r "$1"; }

    local id active short_port ddc_override ddc_idx
    id=$(_jq '.id')
    active=$(_jq '.active')

    # Nur aktive Outputs des Presets aufwecken
    [[ "$active" == "true" ]] || continue

    local port
    port="${PORTS[$id]:-}"
    if [[ -z "$port" ]]; then
      echo "Warnung: Monitor-ID $id nicht angeschlossen, überspringe Wake."
      continue
    fi

    short_port=$(echo "$port" | sed 's/^card[0-9]-//')
    ddc_override=$(_jq '.ddc_display // ""')

    if [[ -n "$ddc_override" ]]; then
      ddc_idx="$ddc_override"
    else
      ddc_idx="${DDC_DISPLAY_BY_PORT[$short_port]:-}"
    fi

    echo "Wake target: $short_port (id: $id)"

    if [[ -n "$ddc_idx" ]]; then
      if run_ddcutil --display="$ddc_idx" setvcp D6 01 2>/dev/null; then
        echo "  ✔ DDC/CI Power-On gesendet (Display $ddc_idx)"
      else
        echo "  ✘ DDC/CI fehlgeschlagen (Display $ddc_idx)"
        fallback_ports+=("$short_port")
      fi
    else
      echo "  ⚠ Kein DDC-Mapping gefunden für $short_port (ddcutil detect)."
      fallback_ports+=("$short_port")
    fi

    targets=$((targets + 1))
  done

  if [[ "$targets" -eq 0 ]]; then
    echo "Keine aktiven Output-Targets im Preset '$preset' gefunden."
    return 1
  fi

  # Display-Zustand aus Preset danach sauber anwenden (dynamisch für alle Outputs)
  apply_display "$preset"

  # Zusätzlicher Fallback für Ports, bei denen DDC nicht verfügbar/fehlgeschlagen ist
  if [[ "${#fallback_ports[@]}" -gt 0 ]]; then
    echo "Fallback: gezieltes Output-Toggle für problematische Ports..."
    declare -A seen=()
    for p in "${fallback_ports[@]}"; do
      [[ -n "${seen[$p]:-}" ]] && continue
      seen[$p]=1
      echo "  Toggle $p"
      kscreen-doctor "output.$p.disable" >/dev/null 2>&1 || true
      sleep 1
      kscreen-doctor "output.$p.enable" >/dev/null 2>&1 || true
    done
    sleep 2
    apply_display "$preset"
  fi
}

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
    wake)
      cmd="wake"
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

  wake )
    preset="${preset:-monitors}"

    if ! yq -e ".presets[] | select(.name == \"$preset\")" "$CONFIG_FILE" >/dev/null; then
      echo "Fehler: Preset \"$preset\" existiert nicht in $CONFIG_FILE"
      exit 1
    fi

    apply_wake "$preset"
    ;;

  * )
    echo "Usage:"
    echo "  $0 list"
    echo "  $0 switch <preset>"
    echo "  $0 switch --video-only <preset>"
    echo "  $0 switch --audio-only <preset>"
    echo "  $0 wake [preset]"
    exit 1
    ;;
esac
