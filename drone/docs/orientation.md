# Orientation, camera roll, camera tilt

## Why the matrix is written directly, not via `setObjectRotation`

`setObjectRotation()`'s Euler-angle axis order doesn't match a `(pitch,
roll, heading)` mapping — the roll stick visually yaws the object instead.
Writing `CEntity.Placeable.Matrix`'s `right`/`up`/`at` vectors directly
sidesteps the ambiguity entirely — those are exactly the basis vectors the
flight model (`fwd`/`right`/`up`) already maintains, so there's no
axis-order/sign guessing involved.

## RCRAIDER's local-axis convention

The generic assumption (`right = drone.right, up = drone.up, at =
drone.fwd`) does not match RCRAIDER's own model convention. The correct
mapping (nose forward, right side up, roll/pitch/yaw all correct):

```lua
mat.right = -drone.right
mat.up    =  drone.fwd
mat.at    = -drone.up
```

If orientation ever looks wrong after a code change, check that this
mapping (in `applyDroneTransform`/`Drone:applyTransform`) is still intact
before re-deriving it from scratch — it's specific to this model, not a
general convention.

## Why the FPV camera has almost no camera-specific code

Camera roll has real constraints that rule out the obvious approaches:

- **A camera-matrix write must happen before the 3D scene renders for that
  frame.** `onD3DPresent` is a post-render HUD-overlay hook — writes there
  (`CCamera.mCameraMatrix`, low-level `RwCamera.matrix`) can't affect that
  frame's roll, only the next one at the earliest, and in practice show no
  effect at all. `RwCamera.matrix` additionally carries real risk of memory
  corruption if the pointer isn't valid at write time.
- **`CCam.fRoll`** requires indexing `aCams` with an int; `nActiveCam` is
  exposed as a `bool` in this engine build, so `aCams[nActiveCam]` is
  invalid (must hardcode `aCams[0]`) — and even written at the correct
  per-tick timing, it has no visible effect.
- **`attachCameraToVehicle`** only activates the engine's third-person
  cinematic camera, not first-person.

**What works**: `warpCharIntoCar` + a decoy ped left at the launch spot +
`setPlayerInCarCameraMode(0)`. The player is teleported *inside* the
(frozen, script-matrix-driven) vehicle purely to activate GTA's own
in-vehicle camera pipeline — the same one that correctly banks with
planes/helis in vanilla gameplay. The drone's own physics/matrix stay fully
scripted; only the camera activation is borrowed from the vehicle-entry
path. GTA's native in-vehicle camera reads its view straight off the
vehicle's own `CEntity.Placeable.Matrix` every frame — the same matrix
write already used for position/orientation — so no separate camera-matrix
write is needed at all. Don't reintroduce a manual
`setFixedCameraPosition`/`mCameraMatrix` camera path for FPV flight.

## Camera tilt

`CCam.aCams[0].fTilt` cannot be used for this: the engine's own
`CCam::Process()` recomputes its view vectors from scratch every frame
after any mode-specific logic runs, so a raw field write there either loses
that race or is never read in in-car mode 0.

**Working mechanism**: bake the tilt into the *rendered* basis fed into the
same per-frame matrix write used for position/orientation — rotate a copy
of `fwd`/`up` around `right` by `cam_tilt_deg` (negated: positive tilt
looks down) before writing `mat.up`/`mat.at`, while leaving the real
`fwd`/`right`/`up` untouched so physics/collision/OSD attitude are
unaffected. This works for the same reason camera roll works — there's no
engine recompute to race against, since it rides the same matrix write.

## Visual model scaling: not currently possible

- Scaling the magnitude of `right`/`up`/`at` written into the matrix has no
  visual effect on the rendered mesh.
- `setObjectScale(handle, scale)` is typed for `Object` handles, not
  `Vehicle` — calling it on the drone's vehicle-pool handle throws inside
  the native and **kills the whole script**.

`profile.model_scale` exists and is used for `checkCollision`'s ray spread
only (shrinks the effective collision radius) — there is no known way to
shrink the rendered mesh itself. Doing so would need a genuinely different
mechanism (a smaller vanilla model, or a much deeper RenderWare/RwFrame
hook), not a matrix or native-property attempt.
