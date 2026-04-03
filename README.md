# displaycontrol

## Usage

```bash
./displayctl.sh list
./displayctl.sh switch monitors
./displayctl.sh switch tv
./displayctl.sh wake            # default preset: monitors
./displayctl.sh wake monitors
```

## Wake-Logik

`wake` nutzt das Preset und weckt **alle aktiven Outputs** dynamisch auf:

- Mapping von Preset-Output (`id`) -> aktuell angeschlossener Port via EDID/sysfs
- Mapping Port -> `ddcutil --display` via `ddcutil detect`
- pro aktivem Output: `ddcutil setvcp D6 01`
- danach `apply_display` für konsistente Re-Aktivierung per kscreen-doctor

Optional kann pro Output ein fester ddcutil-Index gesetzt werden:

```yaml
outputs:
  - id: "..."
    active: true
    resolution: 2560x1440@165
    position: 1920,0
    priority: 1
    ddc_display: 2
```

