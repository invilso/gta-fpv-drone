# GTA FPV Drone

A fully scripted FPV drone for GTA San Andreas (MoonLoader) — spawn a
quadcopter, freeze your character in place, and fly it FPV-style with real
flight physics, flown from **any connected controller** (RC transmitter,
DualSense, Xbox pad, generic joystick). Works in both singleplayer and SA-MP.

## Features

- **Real flight physics** — thrust, gravity, anisotropic drag, motor spool
  lag, ground/ceiling effect, optional wind/turbulence — not GTA's own
  vehicle physics, so full flips and inverted flight work.
- **Three flight modes**: ACRO (direct rate control), LEVEL (self-leveling),
  HORIZON (blends both by stick deflection) — plus an optional bidirectional
  3D-throttle mode. Switchable by keyboard or a controller button.
- **Flight recorder + VLC-style replay**: records every flight (drone pose
  + nearby vehicles/peds/objects) to a fixed-memory ring buffer, save to
  disk, and play it back with speed control, scrubbing, and the game's own
  in-vehicle camera (including the `V` camera cycle).
- **Liftoff-style OSD**: horizon line + attitude indicator, thrust
  breakdown, vertical-speed vario, signal-strength static effect, profile +
  flight timer.
- **Motor audio** with live pitch/volume from throttle and distance.
- **Any controller** — RC transmitters and modern gamepads alike, selected
  live from the in-game menu; plug in more than one and switch anytime.
- **Configurable drone profiles** (whoop / racer / heavy / default, or your
  own) — mass, thrust, drag, rates all editable live.

## Quick start

1. Run the installer for your OS from `installer/`:
   - Linux: `./installer/install.sh`
   - Windows: right-click `installer/install.ps1` → *Run with PowerShell*
     (or `powershell -ExecutionPolicy Bypass -File installer/install.ps1`)
2. Follow the prompts — it asks for your GTA San Andreas folder, checks for
   the MoonLoader libraries this script needs (and tells you exactly what's
   missing and where to get it, all at once), and sets up the controller
   bridge.
3. Plug in a controller, launch the game, type `DRONE` in chat/console to
   spawn (default cheat phrase — throttle must be near zero, like a real
   arm sequence), and `CFGD` to open the settings menu.

See the installer's own summary output for the exact command to start the
controller bridge if you chose manual startup.

### Manual install

If you'd rather not use the installer: copy `drone.lua` and the `drone/`
folder into `<your GTA SA folder>/moonloader/`, then run
`drone/bridge/controllerd.py` (needs Python 3 + `pip install pysdl2`)
whenever you want to fly. See [`drone/bridge/README.md`](drone/bridge/README.md).

## Default controls

| Action | Default |
|---|---|
| Spawn/despawn drone | type `DRONE` |
| Open settings menu | type `CFGD` |
| Recall (teleport back to you) | `R` |
| Cycle ACRO/LEVEL/HORIZON | `M` |
| Toggle 3D throttle | `N` |
| Save current flight replay | `J` |

All keybinds and the cheat phrases themselves are rebindable from the menu.

## Dependencies

This is a MoonLoader script — it assumes you already have (or the
installer will tell you exactly what to get):

- [MoonLoader](https://blast.hk/moonloader/) itself
- [mimgui](https://github.com/THE-FYP/mimgui) — the settings menu
- [dkjson](https://dkolf.de/dkjson-lua/) — config file I/O
- SAMemory — direct memory access for the vehicle/camera matrix writes
  (search blast.hk's MoonLoader library section; no single canonical link
  found for this one)
- `lfs`/`luasocket` — file listing (replay browser) and UDP (controller
  bridge, replay/config); commonly bundled together in MoonLoader "extra
  libraries" packs on blast.hk
- `bass.lua` + `bass.dll` — motor audio, via the
  [BASS audio library](https://www.un4seen.com/) (free for non-commercial use)
- Python 3 + [`pysdl2`](https://pypi.org/project/PySDL2/) — for the
  controller bridge daemon (`drone/bridge/controllerd.py`)

## How it's built

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for a system-level overview, and
[`drone/docs/`](drone/docs/) for design write-ups on specific tricky parts
(camera orientation, the physics model, collision handling, the replay
format, motor audio, the controller bridge).

## License

This project's own code is MIT — see [`LICENSE`](LICENSE). The bundled
Inter font is SIL Open Font License 1.1 — see
[`drone/resources/Inter-OFL.txt`](drone/resources/Inter-OFL.txt). Third-party
MoonLoader libraries listed above are not bundled and keep their own licenses.
