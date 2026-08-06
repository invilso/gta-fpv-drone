# Flight model tuning notes

## Ground/ceiling effect must filter the drone's own entity

`surfaceProximityAccel` casts a ray from the drone's own center. Any such
ray must filter out the drone's own vehicle as a valid hit — otherwise it
hits itself at ~0 distance and reports near-maximum ground effect *and*
ceiling effect simultaneously every tick, which nearly cancels gravity
outright regardless of throttle or actual surroundings. `checkCollision`
already filters this way (see `docs/collision.md`); `surfaceProximityAccel`
must match it.

This pointer comparison must go through `samePtr()` (`vecmath.lua`), not a
plain `==`: `getCarPointer` returns `uint`, but `processLineOfSight`'s
`colPoint.entity` is documented `int` (signed). For real heap addresses
≥ `0x80000000` these come back as different-signed Lua numbers, so a plain
`==` self-pointer comparison silently never matches.

**A sudden "nothing falls / nothing reacts" symptom is far more likely a
self-collision filtering bug than a tuning problem** — check entity-self-
filtering first, before touching any physics constant.

## Drag is anisotropic on purpose

`up`-axis drag is deliberately much lower than `fwd`/`right` drag in every
profile. A real quad frame/props are draggy sideways-on even with motors
off (`fwd`/`right`), but vertical free-fall should approach real-gravity
terminal velocity, not float down — keeping `fwd`/`right` drag high and
`up`-axis drag low is what makes both true at once. Cutting all three axes
uniformly under-dampens horizontal flight (a throttle cut glides for a very
long distance instead of dropping); raising `up`-axis drag to match the
others makes free-fall too slow. Tune these independently, not as one
scalar.

`motor_tau` (motor spool time constant, ~0.06s by default) should stay in
the tens-of-ms range — real small FPV motors/ESCs respond that fast; larger
values feel mushy/laggy on throttle release.

## Ground/ceiling effect

A downward/upward ray each physics tick finds the nearest surface within
range and adds a world-vertical push, falling off as `strength * (1 -
dist/radius)^2`. Both effects end up as world `+z` — they just trigger off
opposite-facing rays (ground pushes away from a surface below, ceiling pulls
toward a surface above, both "up" in the push-direction sense).

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

## LEVEL/HORIZON's roll and pitch angle readouts have opposite sign conventions

`rollAngle = atan2(right.z, up.z)` and `pitchAngle = -asin(fwd.z)` (note the
negation) are **not** interchangeable formulas with a sign swapped for
convenience — the negation on pitch is required by this basis's handedness
(`up = fwd × right`, `right = up × fwd`). A positive roll rate (about
`fwd`) increases `right.z`, so `rollAngle` grows in the same direction the
rate turns it. A positive pitch rate (about `right`) *decreases* `fwd.z`,
so `pitchAngle` must be negated for its sign to also grow in the direction
its own rate turns it. Both P-controllers (`levelP`/`levelQ`) rely on
`target - currentAngle` being negative feedback — an un-negated
`pitchAngle` makes the pitch controller positive feedback instead (the
commanded rate pushes the angle further from center, not back toward it),
which diverges to a continuous spin rather than leveling. If LEVEL/HORIZON
pitch (or, by extension, HORIZON's blended output) ever misbehaves again,
check this sign first before adjusting `level_gain` or any other tuning
constant.

## `rollAngle`/`pitchAngle` are only valid well under 90° combined tilt

Both formulas depend on `up.z` (`atan2(right.z, up.z)` directly; `asin(fwd.z)`
indirectly, since a large pitch also drives `up.z` toward 0). As the
combined tilt from vertical approaches 90°, `up.z` approaches 0, and
`atan2(right.z, up.z)` becomes discontinuous there — a pure zero-roll pitch
past ~90° can flip the reading from 0° to 180° from floating-point noise
alone, which the roll P-controller reads as a large fake roll error and
corrects by spinning roll at full rate, even though the pilot never touched
the roll stick.

`levelP`/`levelQ` are scaled by `levelValidity = clamp(up.z / 0.3, 0, 1)`,
fading the self-level contribution to zero as `up.z` approaches the
singularity so a large excursion (HORIZON's acro-blended pitch routinely
passes 90°) hands off to pure rate control instead of reacting to a
garbage angle. LEVEL's own default `level_max_angle_deg` (45°, `up.z` ≈
0.7) never reaches this fade zone, so this only matters for HORIZON's
large-deflection behavior (or a `level_max_angle_deg` pushed unusually
high).
