# Motor audio

## File + live attribute, not live Lua synthesis

Two approaches were considered for motor sound:

1. **Pre-baked looped sample + live pitch/volume** (chosen): a short (~1s)
   looped `.wav` plays continuously via BASS while the drone is spawned, and
   only `BASS_ChannelSetAttribute(BASS_ATTRIB_FREQ/VOL)` on the
   already-playing channel gets retuned every tick from throttle and
   distance-to-pilot. Cheap, and doesn't depend on precise Lua-side timing.
2. **Live Lua `STREAMPROC` synthesis** (rejected): generating raw samples in
   a Lua callback every buffer refill. Rejected because LuaJIT's GC can
   pause for a few ms at an unpredictable moment — invisible for a dropped
   game frame, but audible as a click/stutter in a continuous audio buffer.

## `bass.dll` is already present, nothing to bundle

Confirmed present at the game's own root (next to `gta_sa.exe`, i.e. on the
default DLL search path) — `ffi.load("bass")` in
`moonloader/lib/bass.lua` resolves with nothing extra needed. BASS's device
is process-wide (the DLL is a single native module, not per-script) — if
another script already called `BASS_Init` first, this script's own call
returns `BASS_ERROR_ALREADY`, which is expected and not a real failure; the
already-initialized device is reused. Correspondingly, `onScriptTerminate`
only frees this script's own stream (`BASS_StreamFree`), never
`BASS_Free()` — that would yank audio out from under any other script still
using the shared device.

## The WAV file itself

`moonloader/drone/resources/drone_motor.wav` was generated offline via a one-off
Python script (stdlib `wave`/`struct` only, no numpy) — four detuned
integer-Hz sawtooth-harmonic oscillators summed over an exact 1.0-second
buffer. Any integer-Hz sine wave is perfectly periodic over a 1-second
window, so the loop has zero click at the seam regardless of phase offset —
pure math, not downloaded, no licensing question.
