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
boolean. This crashed the entity scanner in-game
(`attempt to perform arithmetic on local 'x' (a boolean value)`) before it
was caught, because the generic per-kind scan code assumed all three shared
the same 3-value shape. Fixed via a normalizing wrapper,
`getObjectCoordinatesXYZ()`, used instead of the raw native everywhere in
the scan path. Also: `setObjectRotation` is a 3-axis Euler setter (same
axis-order-ambiguity family as the drone's own orientation saga, see
`orientation.md`) — the correct single-heading setter for objects is
`setObjectHeading(obj, angle)`.

**Lesson**: don't assume a "same family" native (`getObjectX` vs.
`getCarX`/`getCharX`) shares a signature just because the other two do —
check each one, ideally against an official native reference.

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
playback, not just the bare pose. This is a breaking format change —
`.drpl` files saved before v2 are cleanly rejected as "incompatible
version", not readable, and there was no migration written (not worth it for
a debug/fun feature).

## `osdTelemetry`: a single source of truth, live and replay

The OSD used to read `drone.vel` directly for the speed readout, but
`tickPlayback()` never updated `drone.vel` during replay (only pos/fwd/up/
thrust) — so **SPD silently showed 0 for an entire replay** before this was
caught. Fixed by giving the OSD one telemetry table it always reads from,
populated either by a live-tick sync function or a replay-tick sync function
that unpacks the recorded frame's own velocity/flags. Any new OSD field
should go through this table, not read `drone.*`/`connected`/`cfg.*`
directly, or it will have the same live-only bug.

## Entity proxies: known, accepted tradeoff

Recorded entities are keyed by their **live native handle at capture time**
(`entityId`). If the game frees and reissues that same handle to an
unrelated entity mid-recording (rare, more likely in heavy traffic), one
frame of playback shows the "wrong" proxy for a moment instead of a clean
despawn+spawn. Not a crash risk and not worth defending against — documented
as an accepted tradeoff, don't "fix" this without a real reported problem.
