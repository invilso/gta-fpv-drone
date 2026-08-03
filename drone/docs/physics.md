# Flight model tuning notes

## The two "drone won't fall" bugs (most expensive bug of the original build)

Symptom: the drone never fell even at high simulated gravity, and
`motor_tau` appeared to have no effect. Two independent causes, both found
via a live debug overlay printing the actual per-frame accel breakdown
(thrust/gravity/dragUp/ground/ceiling/windZ → accelZ) — guessing at
parameters did not find either of these; the numeric overlay did, on the
first look.

1. **`surfaceProximityAccel` (ground/ceiling effect) didn't filter the
   drone's own entity**, unlike `checkCollision` which already did. The ray
   starts at the drone's own center, so with `car=true` it immediately hit
   *itself* at ~0 distance, applying near-maximum ground effect *and*
   ceiling effect simultaneously every tick — nearly canceling gravity
   outright regardless of throttle or actual surroundings.
2. **`uint`/`int` pointer-type mismatch**: `getCarPointer` returns `uint`,
   but `processLineOfSight`'s `colPoint.entity` is documented `int` (signed).
   For real heap addresses ≥ `0x80000000` these come back as different-signed
   Lua numbers, so a plain `==` self-pointer comparison silently never
   matched anywhere it was used. Fixed by normalizing both sides through
   `bit.tobit()` before comparing (see `samePtr` in `vecmath.lua`).

**Lesson for future physics work:** a sudden "nothing falls / nothing
reacts" symptom is much more likely a self-collision bug than a tuning
problem — check entity-self-filtering first, before touching any physics
constant.

## Drag tuning — overcorrection story

Vertical (`up`-axis) drag was originally too strong — the drone had a
noticeably slower-than-real free-fall terminal velocity (~8.7 m/s vs. the
expected ~19.6 m/s after 2s of real gravity), i.e. it behaved like it had
wings. Cutting `up`-axis drag fixed that, but cutting `fwd`/`right` drag by
the same factor *at the same time* was an overcorrection — with almost no
horizontal drag, a throttle cut at speed just glided for a very long
distance instead of dropping. **Final tuning**: `fwd`/`right` restored to
their original (draggier) values — a real frame/props are draggy sideways-on
even with motors off — only `up`-axis drag stayed reduced, since vertical
free-fall speed was the actual complaint.

`motor_tau` (motor spool time constant) was reduced 0.15s → 0.06s — it felt
mushy/laggy on throttle release at the higher value; real small FPV
motors/ESCs respond in tens of ms, not hundreds.

## Ground/ceiling effect

A downward/upward ray each physics tick finds the nearest surface within
range and adds a world-vertical push, falling off as `strength * (1 -
dist/radius)^2`. Both effects end up as world `+z` — they just trigger off
opposite-facing rays (ground pushes away from a surface below, ceiling pulls
toward a surface above, both "up" in the push-direction sense). See the
self-collision bug above — this is the function that had it.

## Flight modes (ACRO / LEVEL / HORIZON)

- **ACRO**: stick directly commands a target body angular rate — no
  self-leveling, allows full flips.
- **LEVEL**: stick commands a target bank/pitch *angle* instead; a
  P-controller (`level_gain`) drives the current angle (read straight off the
  maintained `fwd`/`right`/`up` basis) toward that target, clamped to the
  profile's own `rate_max_deg` so leveling out never spins faster than acro's
  own top rate.
- **HORIZON**: blends ACRO's rate target and LEVEL's angle-seeking target by
  how far the stick is deflected past `horizon_blend_start` — near center it
  self-levels, past the blend threshold it progressively allows full
  acro-style rotation (so flips/rolls are still possible at full stick).
- **3D-throttle**: swaps the throttle axis from unidirectional (`axisUni`,
  0..1) to bidirectional (`axisBi`, -1..1) around stick center — negative
  thrust pushes along `-up`, letting the drone hold "upside-down hover"
  instead of just free-falling when inverted. No other code needs to change
  for this; the existing `thrustAccel = thrust * (max_thrust/mass)` formula
  already handles the sign.

Orientation is always kept as an orthonormal basis (`fwd`/`right`/`up`), not
Euler angles, specifically to avoid gimbal lock during flips — display-only
values (OSD pitch/roll/heading) are extracted from this basis, never fed
back into the physics.
