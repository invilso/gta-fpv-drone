# Collision, "sticking", and crash detection

## `setCarCoordinates` is not a raw position setter

`setCarCoordinates()` performs its own nearby-ground search/snap as an
anti-clip safety measure — calling it every tick makes the model visibly
snap toward any nearby horizontal surface (roofs/ground) from a few meters
away, then self-correct once past it, even though tracked `pos`/`vel` stay
correct throughout (it's the *render* matrix being repositioned after the
script's own write, not a physics error).

`setCarCollision(false)`, a direct `CEntity.UsesCollision` write, and
CVehicle flags (`bIsRCVehicle`, `bRestingOnPhysical`, `IsInSafePosition`,
`HasContacted`, `IsStuck`, `bVehicleColProcessed`) do not fix this — it
isn't a collision-flag issue, and `setCarCollision`/`UsesCollision` also
break orientation as a side effect. **Fix**: write `mat.pos` directly (the
same mechanism already used for orientation) — no native involved, nothing
to snap.

## `processLineOfSight`: `checkSolid`+`car` must be separate calls

Combining `checkSolid=true` and `car=true` in a single `processLineOfSight`
call unreliably misses plain ground/terrain. `checkSolid` alone, in its own
call, is the standard idiom other ground-height CLEO/moonloader scripts
use — not worth relying on an undocumented flag interaction. World geometry
and vehicles are always cast as two separate calls per ray in this
codebase.

## Multi-ray collision, not a single centerline ray

The drone is small and fast; at 30-60 FPS a single centerline ray from the
previous to the predicted position can tunnel through thin geometry (fences,
thin walls, sheet fencing). A small cross pattern (center + 4 rays offset by
the drone's own `right`/`up`) is cast instead.

## Self-hit filtering

`car=true` in a collision ray means the drone's own vehicle is itself a
valid hit target — since rays start at/inside its own model, any such ray
must filter out its own vehicle pointer or every tick reports an instant
false "crash." Filtered by comparing `colPoint.entity` against the drone's
own vehicle pointer via `samePtr()` (see `physics.md` for the `uint`/`int`
mismatch this depends on getting right). The same filtering requirement
applies to the ground/ceiling-effect raycasts — see `physics.md`.

## Crash logic

A hit on the drone's belly always survives regardless of speed. Any other
hit (side/top/props) crashes if the velocity component **into the surface**
is ≥ `crash_prop_speed`. Total speed is the wrong severity measure —
grazing a wall or pole while moving mostly parallel to it has a near-zero
normal component and must read as a scrape, not a crash, or any fast flight
close to geometry explodes on the slightest touch. There is no spawn-time
grace period: with self-hit filtering (above) in place, a fresh spawn
doesn't false-trigger a crash, so no cooldown is needed on the very first
tick.

With `indestructible` enabled, a crash-grade impact reflects the velocity
off the surface (scaled by `bounce_restitution`) instead of exploding —
the crash branch is otherwise unchanged.

"Belly" is classified by the **hit surface's normal** (`colPoint.normal`
aligned with the drone's own `up` within ~45°, i.e. the surface faces the
underside), never by comparing the impact point's position against
`drone.pos`. The collision ray runs from the pre-move to the post-move
position, so on the tick a hit is reported `drone.pos` has already
penetrated past the surface — the impact point then sits on the *far* side
of the drone relative to its travel, and a position-based "is the impact
below center" test reads a flat belly landing as a side hit (crash) and a
nose-first hit as sign noise (randomly "belly", which then falsely enters
`grounded` and reads as sticking to walls/ground).

## Sliding, not stopping dead

A surviving contact does not zero the velocity — it removes the normal
component and keeps the tangential one, decayed by `slide_friction`
(exponential, per-second rate), and lets the frame's displacement continue
projected along the surface. The drone skids on its belly across ground the
way a real quad does. Gravity re-adds a downward component every physics
tick and the next belly hit strips it again, which is what holds the slide
on the surface — no dedicated "on ground" constraint state exists. Once a
belly slide drops below `slide_stop_speed` it settles into the `grounded`
resting state (position held, sticks ignored, throttle above
`liftoff_throttle_min` releases it). Zeroing velocity on contact instead
reads as the drone glueing itself to every surface it touches.

Two constraints keep the slide from degenerating:

- **Only the approach velocity is stripped** (`dot(vel, normal) < 0`) —
  velocity directed *away* from the surface passes through untouched.
  Stripping any normal component regardless of direction makes climbing off
  the surface impossible whenever a hit fires on the way out.
- **The center is pushed out to a fixed clearance** above the hit surface's
  plane every collision tick (`collision_radius × model_scale`, the same
  distance the ray spread detects contact at). Between collision ticks a
  slide sinks by gravity micro-steps too small to cross the surface and
  fire a hit, and each such tick permanently lowers the baseline — without
  the push-out the drone ratchets a few mm per tick down through the
  texture and ends up resting visibly sunk into the ground, from where
  upward rays can misfire against the surface's backside.

## `explosion_huge` is not a real particle name

`createFxSystem` silently plays nothing (no error) if given a particle name
that isn't real — `effects.fxp`'s actual biggest explosion particle is
`explosion_large`. **Never guess GTA SA asset/particle names** — verify
against an actual particles reference before using one, since a wrong name
fails completely silently.
