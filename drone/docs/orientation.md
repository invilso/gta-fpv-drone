# Orientation, camera roll, camera tilt

## Why the matrix is written directly, not via `setObjectRotation`

`setObjectRotation()`'s Euler-angle axis order/semantics didn't match a
`(pitch, roll, heading)` mapping (confirmed in-game: the roll stick visually
yawed the object instead). Writing `CEntity.Placeable.Matrix`'s
`right`/`up`/`at` vectors directly sidesteps the whole ambiguity — those are
exactly the basis vectors the flight model (`fwd`/`right`/`up`) already
maintains, so there's no axis-order/sign guessing at all.

## RCRAIDER's local-axis convention (the 8-combination cycler)

The generic assumption (`right = drone.right, up = drone.up, at = drone.fwd`)
does not match RCRAIDER's own model convention. This was found empirically by
cycling all 8 sign/assignment combinations for `up`/`at` live in-game (a
temporary debug key), plus an independently-toggled sign for `right`. The
confirmed-correct mapping (nose forward, right side up, roll/pitch/yaw all
correct):

```lua
mat.right = -drone.right
mat.up    =  drone.fwd
mat.at    = -drone.up
```

If orientation ever looks wrong again after a code change, check that this
mapping (in `applyDroneTransform`/`Drone:applyTransform`) is still intact
before re-litigating it from scratch.

## Camera roll: why the FPV camera isn't a manually-positioned fixed camera

Six approaches were tried before landing on the working one:

1. **`CCamera.mCameraMatrix` direct write** (in `onD3DPresent`) — no effect.
   `onD3DPresent` fires *after* the 3D scene for the frame is already
   rendered (it's a HUD-overlay hook), so writes there are always a frame
   late for anything camera-related.
2. **`RwCamera.matrix`** (low-level RenderWare camera) — also no effect, and
   risky (unconfirmed pointer validity, real risk of process memory
   corruption) — abandoned.
3. **`attachCameraToVehicle`** — worked for third-person, not first-person.
   This is what revealed the `onD3DPresent` timing problem above.
4. **`mCameraMatrix` write moved to the main loop tick** (correct timing,
   same place the drone's own matrix write happens) — position updated, but
   roll still didn't show.
5. **`CCam.fRoll`** — crashed the script (`nActiveCam` is a `bool`, not an
   int; indexing `aCams[nActiveCam]` with it is invalid — fixed by hardcoding
   `aCams[0]`). After the fix: still no visible roll.
6. **The working fix**: `warpCharIntoCar` + a decoy ped left at the launch
   spot + `setPlayerInCarCameraMode(0)`. The player is teleported *inside*
   the (frozen, our-matrix-driven) vehicle purely to activate GTA's own
   in-vehicle camera pipeline — the one that has always correctly banked with
   planes/helis. The drone's own physics/matrix stay fully scripted; only the
   camera activation trick is borrowed. Idea sourced from a reference script
   (`moonloader/reference/drone.lua`, not loaded by the game).

**Conclusion used going forward:** GTA's native in-vehicle camera reads its
view straight off the vehicle's own `CEntity.Placeable.Matrix` every frame —
the same matrix write already used for position/orientation — so there is no
separate camera-matrix write needed or wanted. Don't reintroduce a manual
`setFixedCameraPosition`/`mCameraMatrix` camera path for FPV flight.

## Camera tilt

`CCam.aCams[0].fTilt` was tried first and is confirmed **dead** — the
engine's own `CCam::Process()` recomputes its view vectors from scratch every
frame after any mode-specific logic runs, so a raw field write either loses
that race or is never read in in-car mode 0.

**Working mechanism:** bake the tilt into the *rendered* basis fed into the
same per-frame matrix write used for position/orientation — rotate a copy of
`fwd`/`up` around `right` by `cam_tilt_deg` (negated: positive tilt = look
down, confirmed by a live sign-flip test) before writing `mat.up`/`mat.at`,
while leaving the real `fwd`/`right`/`up` untouched so physics/collision/OSD
attitude are unaffected. This works for the same reason camera roll works —
no engine recompute to race against.

## Visual model scaling — confirmed dead ends, don't retry

- Scaling the magnitude of `right`/`up`/`at` written into the matrix: no
  visual effect at all.
- `setObjectScale(handle, scale)`: typed for `Object` handles, not `Vehicle`
  — called on the drone's vehicle-pool handle it throws inside the native and
  **kills the whole script**.

`profile.model_scale` still exists and is used for `checkCollision`'s ray
spread only (shrinks the effective collision radius) — there is no known way
to shrink the rendered mesh itself. If this comes up again it needs a
genuinely different mechanism (a smaller vanilla model, or a much deeper
RenderWare/RwFrame hook), not another matrix/native attempt.
