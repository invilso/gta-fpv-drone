# Collision, "sticking", and crash detection

## `setCarCoordinates` is not a raw position setter

The model repeatedly "stuck" to nearby horizontal surfaces (roofs/ground)
from a few meters away, self-correcting once past them. Tracked
`pos`/`vel` stayed correct the whole time — it was the *render* matrix being
repositioned after the script's own write, not a physics bug. Ruled out:
`setCarCollision(false)`, a direct `CEntity.UsesCollision` write, and a
CVehicle-flags live cycler (`bIsRCVehicle`, `bRestingOnPhysical`,
`IsInSafePosition`, `HasContacted`, `IsStuck`, `bVehicleColProcessed`) — none
of these fixed it, and two of them (`setCarCollision`, direct
`UsesCollision`) actively broke orientation as a side effect.

**Real cause**: `setCarCoordinates()` itself. It performs its own
nearby-ground search/snap as an anti-clip safety measure — calling it every
tick kept re-triggering that snap near any roof/ground. **Fix**: write
`mat.pos` directly (same mechanism already used for orientation) — no native
involved, nothing to snap.

## `processLineOfSight`: `checkSolid`+`car` must be separate calls

Combining `checkSolid=true` and `car=true` in a single `processLineOfSight`
call reliably missed plain ground/terrain (the drone fell straight through).
`checkSolid` alone, in its own call, is the standard idiom other
ground-height CLEO/moonloader scripts use — not worth relying on an
undocumented flag interaction. World geometry and vehicles are always cast
as two separate calls per ray in this codebase.

## Multi-ray collision, not a single centerline ray

The drone is small and fast; at 30-60 FPS a single centerline ray from the
previous to the predicted position can tunnel through thin geometry (fences,
thin walls, sheet fencing). A small cross pattern (center + 4 rays offset by
the drone's own `right`/`up`) is cast instead.

## Self-hit filtering

`car=true` in a collision ray means the drone's own vehicle is itself a
valid hit target — since rays start at/inside its own model, the nearest hit
was always the drone itself, producing an instant false "crash" every tick.
Filtered by comparing `colPoint.entity` against the drone's own vehicle
pointer via `samePtr()` (see `physics.md` for the `uint`/`int` mismatch this
depends on getting right). This same self-hit pattern bit the ground/ceiling
effect raycasts too — see `physics.md`.

## Crash logic

A hit on the drone's belly (below its local center) always survives
regardless of speed and enters a `grounded` resting state — matches a real
FPV "landed" experience. Any other hit (side/top/props) crashes if speed is
≥ `crash_prop_speed`, otherwise it's a soft bump-back to the previous
position. There is no spawn-time grace period — an earlier version had one
(30s, then 3s, then 400ms) to work around false "instant crash on spawn"
triggers, but the real cause was always the self-hit bug above; once that
was fixed the grace period was removed entirely, no cooldown needed on the
very first tick.

## `explosion_huge` never existed

`createFxSystem` silently plays nothing (no error) if given a particle name
that isn't real. `explosion_huge` looked plausible but isn't in the actual
`effects.fxp` particle list — the correct biggest explosion particle is
`explosion_large`. **Lesson: never guess GTA SA asset/particle names** —
verify against an actual particles reference before using one, since a wrong
name fails completely silently.
