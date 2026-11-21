#!/bin/bash

sleep 25

# Karten über ihre stabile ALSA-ID ansprechen (siehe /proc/asound/cards),
# nicht über die Nummer – die Reihenfolge ändert sich zwischen Boots.
for card in Device NVidia Creative Generic; do
  amixer -c "$card" set Front on
done
