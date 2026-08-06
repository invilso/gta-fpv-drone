# Controller bridge: any device, two wire formats

## Why SDL2

`bridge/controllerd.py` reads input via SDL2 (`pysdl2` — pure ctypes
bindings, no compilation, works against the system's runtime
`libSDL2-2.0.so.0`/`.dll`). SDL2's low-level Joystick API (not the
higher-level GameController API, which needs a known mapping database and
wouldn't recognize an RC transmitter) reads raw axes/buttons uniformly for
RC transmitters and modern gamepads alike, on Linux, Windows, and macOS —
so the drone flies from any connected controller, selected live from its
own menu, with no per-device code.

SDL reports axes as signed `int16` (-32768..32767); the daemon renormalizes
with `(raw + 32768) >> 5`, mapping that range onto exactly 0..2047 with
center exactly 1024 — matching `cfg.calib`'s default (`min=0, center=1024,
max=2047`).

Note: SDL enumerates buttons in its own per-device order, so a given bit
index isn't guaranteed to mean the same physical switch across different
controllers or driver versions — if a learn-mode button binding
(`flight_mode_cycle_btn` etc.) ever seems to fire from the wrong switch,
re-bind it from the menu; axis order is a direct, stable 0-7 pass-through
so axis bindings aren't affected by this.

## Why two wire formats

`moonloader/tx12.lua` (vehicle control) only understands a single-device,
28-byte packet — one axes/buttons snapshot per tick, no device identity.
`moonloader/drone.lua` needs to see *every* connected controller at once
(for its live device picker), which means each packet must carry which
device it came from.

Rather than force one shared, more complex format on both scripts, the
daemon emits **both**, from the same live device set:

- **v1** (28 bytes) — one "primary" device (lowest deviceId currently
  open), sent to `--legacy-ports` (default 42012). Consumed by
  `moonloader/tx12.lua`.
- **v2** (45 bytes) — one packet *per connected device*, each tagged with
  `deviceId` (uint8) and `name` (16-byte UTF-8, NUL-padded), streamed to
  every **subscriber**. Consumed by `moonloader/drone/protocol.lua` +
  `net.lua`.

v2 delivery is subscription-based: the daemon owns the one well-known port
(`--port`, default 42013); each consumer binds an *ephemeral* port (the OS
picks a free one, so any number of game instances — SAMP + singleplayer —
can run at once with zero configuration) and sends the 5-byte magic
`TXSUB` to the daemon at least every ~3 s. The daemon streams v2 packets
back to every subscriber it heard from recently and drops the ones that go
quiet — the keepalive doubles as the subscription, so there is no
connect/disconnect handshake to get wrong. A unicast datagram can't be
delivered to two sockets bound to one port, which rules out the naive
"everyone listens on 42013" layout for multi-instance use; subscription
keeps exactly one fixed port occupied on the whole system (the daemon's).
On shutdown the daemon sends v2 packets flagged FAILSAFE to all
subscribers, on top of each receiver's own silence timeout.

`name` is embedded in every v2 packet rather than sent via a separate
"announce" packet type — simplest option, no extra timing/staleness logic
to get right, and negligible bandwidth on loopback at 100Hz.

## Device selection: client-side, in `net.lua`

The daemon stays agnostic about *which* device should drive anything —
`net.lua`'s `Receiver` tracks every device it's heard from recently
(`self.devices[deviceId] = {name=, lastSeen=}`, pruned after 3s of silence
— see `DEVICE_STALE_SEC`) and resolves the *effective* device each poll:

- If `cfg.selected_device_id` (persisted, `-1` = auto) names a device
  that's still live, use it.
- Otherwise, auto-select the lowest live `deviceId` — one device connected
  is used automatically; with several connected and nothing chosen, the
  first one is used, overridable any time from `ui.lua`'s Controller
  picker (General tab).

Only packets from the effective device update `axesRaw`/`buttonsRaw`;
packets from other devices still update the tracking table (so they show up
in the picker) but are otherwise ignored. Switching the effective device
(auto-resolution changing, or a manual pick) resets `lastSeq` so a stale
sequence number from the previous device can't reject the new one's first
packet.

## Files

- `bridge/controllerd.py` (+ `.sh`/`.service`) — the daemon. Declares
  `pysdl2` as an inline dependency (PEP 723), run via `uv run` and it
  installs automatically.
- `protocol.lua` — v2 parser (used only by `drone.lua`; `tx12.lua` has its
  own separate v1 parser).
- `net.lua` — `Receiver`, device tracking + selection.
- `ui.lua` — `drawControllerPicker()`, General tab.
- `config.lua` — `cfg.selected_device_id`.
