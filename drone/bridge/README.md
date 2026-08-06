# controllerd — any joystick/gamepad → GTA SA (MoonLoader)

Bridge between any controller (RC transmitter such as a RadioMaster TX12,
DualSense, Xbox pad, generic joystick) and the game:

```
Controller (USB/BT) → controllerd.py (SDL2, cross-platform) → UDP 127.0.0.1:42012 (single-device) → moonloader/tx12.lua
                                                              └─ UDP 127.0.0.1:42013 (multi-device)  → moonloader/drone.lua
```

Reads via **SDL2** (`pysdl2`), so any joystick/gamepad is recognized the
same way, and the daemon runs on both Linux and Windows. Run via
[`uv`](https://docs.astral.sh/uv/getting-started/installation/) — the
dependency is declared inline in `controllerd.py` and installed
automatically on first run. See
[`../docs/controller-bridge.md`](../docs/controller-bridge.md) for the wire
format and why two protocols are sent at once.

## Quick start

1. Plug in a controller (USB or Bluetooth).
2. Run the daemon: `./controllerd.sh` (or `uv run controllerd.py --debug`
   to see live axis values in the console).
3. Launch the game. `moonloader/tx12.lua` (vehicle control) and
   `moonloader/drone.lua` (FPV drone) pick up input independently, each on
   its own port.
4. In the drone menu (`CFGD` → Controller) — a live list of
   connected devices, pick one manually if needed; with only one connected
   it's used automatically.

## Auto-start (systemd user service)

```sh
cp controllerd.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now controllerd.service
journalctl --user -u controllerd -f     # logs
```

## Daemon options

```
uv run controllerd.py [--ports 42013] [--legacy-ports 42012] [--rate 100] [--debug]
```

- `--ports` — where to send the multi-device protocol, for `drone.lua`.
- `--legacy-ports` — where to send the single-device protocol, for `tx12.lua`.

## Troubleshooting

- **Does the daemon see the device?** `uv run controllerd.py --debug` —
  axis values should change as you move the sticks.
- **Are packets arriving?** `socat -u udp-recv:42012 - | xxd | head` (for
  `tx12.lua`) or `42013` (for the drone); stop the Lua script/game first,
  the port may already be bound.
- **Button bindings feel wrong**: SDL numbers buttons in its own order —
  re-bind any learn-mode button bindings once if they seem off.

## Files

- `controllerd.py` — the daemon (Python; declares `pysdl2` as an inline
  dependency, run via `uv` and it's installed automatically)
- `controllerd.sh` — manual launcher
- `controllerd.service` — systemd `--user` unit
- `../protocol.lua`, `../net.lua`, `../ui.lua` — receive + device selection on the `drone.lua` side
- `../../tx12.lua` — receives the single-device protocol
