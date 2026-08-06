# Flight recorder / replay

## Why a hand-rolled FFI recorder, not the game's own replay system

There's no `CReplay` hook in this project (`SAMemory`'s `CVehicle`/`CPed`
only expose a `bUsedForReplay` bit, not the structure itself) — hacking the
built-in replay would mean hardcoding version-dependent memory addresses
that don't exist anywhere else in this codebase. Rejected; the recorder/
player is fully custom Lua/FFI instead.

## No per-tick GC pressure, by construction

Writing into nested Lua tables every tick would mean a GC pass every tick —
exactly the stutter this feature was built to avoid. Instead: a **fixed-size
FFI array** (`ffi.new('replay_frame_t[?]', n)`), allocated once per flight,
used as a ring buffer — zero allocation during recording. Saved to disk as a
raw binary block (`ffi.string` + `io.open(...,'wb')`), not JSON — fine for
the small `cfg` file, wrong for tens of thousands of numeric frames.

## `getObjectCoordinates` has a different signature than the other two

`getCarCoordinates`/`getCharCoordinates` return plain `(x, y, z)`, but
`getObjectCoordinates` returns `(bool result, x, y, z)` — an extra leading
boolean. The generic per-kind entity scanner needs all three kinds to share
one 3-value shape, so it goes through a normalizing wrapper,
`getObjectCoordinatesXYZ()`, instead of the raw native. Also:
`setObjectRotation` is a 3-axis Euler setter with the same axis-order
ambiguity as `orientation.md` describes for the drone's own transform — the
correct single-heading setter for objects is `setObjectHeading(obj, angle)`.

**Don't assume a "same family" native (`getObjectX` vs. `getCarX`/
`getCharX`) shares a signature just because the other two do** — check
each one, ideally against an official native reference.

## Directory creation: use the MoonLoader native, not `os.execute`

`os.execute('mkdir ...')` silently does nothing in this MoonLoader sandbox —
no error surfaces, it just no-ops, so every subsequent `io.open(...,'wb')`
failed with no clue why. MoonLoader ships native
`doesDirectoryExist(path)`/`createDirectory(path)` functions — use
`if not doesDirectoryExist(path) then createDirectory(path) end` for any
"make sure this folder exists" need. Listing a directory's contents uses
the equally-native `findFirstFile`/`findNextFile`/`findClose` (the same
Windows `FindFirstFile`-style natives `moonloader/lib/folder.lua` uses) —
no external filesystem library needed for either.

## Format versioning

`.drpl` files start with a small header (`magic="DRPL"`, `version`,
`frameSize`) so an incompatible old file is rejected cleanly (a clear error,
not silently read as garbage) if the struct layout ever changes. Frames are
written in **chronological order**, not physical ring-buffer order — the
ring buffer is unwrapped at save time so the loader never needs to know the
ring mechanism exists at all.

Version 2 added full velocity plus a physics-accel breakdown
(gravity/dragUp/ground/ceiling/windZ/accelZ/thrustAccel) and a
per-file profile-metadata block (name/mass/max_thrust) to the header, so the
OSD (including its telemetry panels) can be reproduced exactly during
playback, not just the bare pose.

Version 3 added the raw normalized stick position (`stickRoll`/`stickPitch`/
`stickYaw`/`stickThrottle`) — the OSD's stick-position boxes previously read
`net.Receiver.axesRaw` directly regardless of live/replay, so during
playback they showed whatever the live controller was doing at that moment,
not the recorded flight's actual input. Recording the stick values and
routing the OSD's stick display through `osdTelemetry` like every other
field fixes this — see the `osdTelemetry` section above for why this
indirection is the rule for any OSD field, not just an exception made here.

Each version bump is a breaking format change — `.drpl` files saved before
the current version are cleanly rejected as "incompatible version", not
readable, and there is no migration path (not worth writing one for a
debug/fun feature).

## `osdTelemetry`: a single source of truth, live and replay

The OSD reads every value from one telemetry table, populated either by a
live-tick sync function or a replay-tick sync function that unpacks the
recorded frame's own velocity/flags — never `drone.*`/`connected`/`cfg.*`
directly. `tickPlayback()` only updates `drone.pos`/`fwd`/`up`/`thrust`,
not `drone.vel` — any OSD field that bypasses `osdTelemetry` and reads
`drone.*` directly will read stale or zero values during replay. Any new
OSD field must go through this table.

## Entity proxies: known, accepted tradeoff

Recorded entities are keyed by their **live native handle at capture time**
(`entityId`). If the game frees and reissues that same handle to an
unrelated entity mid-recording (rare, more likely in heavy traffic), one
frame of playback shows the "wrong" proxy for a moment instead of a clean
despawn+spawn. Not a crash risk and not worth defending against — documented
as an accepted tradeoff, don't "fix" this without a real reported problem.
