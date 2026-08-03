# Confirmed dead ends — don't retry these

| What was tried | Result |
|---|---|
| `RCCAM` (id 594) as the drone model | Mislabeled in `lib/game/models.lua` — actually a plant pot/urn, not any RC vehicle. Use `RCRAIDER` (465), the closest vanilla RC-vehicle silhouette to a quad. |
| `createObject()` for the drone | RCRAIDER is a vehicle model (`vehicles.ide`), not a static object — `createObject` silently creates nothing. Use `createCar`. |
| Camera tilt via `CCam.aCams[0].fTilt` | Confirmed dead — engine recomputes CCam's vectors from scratch every frame, write is lost or never read. See `orientation.md`. |
| Camera roll via `CCamera.mCameraMatrix` / `RwCamera.matrix` in `onD3DPresent` | No effect — `onD3DPresent` fires after the 3D scene is already rendered for that frame. See `orientation.md`. |
| Camera roll via `CCam.fRoll` | Crashes the script if `aCams` is indexed with `nActiveCam` directly (it's a `bool`, not an int). Even after fixing that, no visible roll. |
| Visual model scaling via matrix `right`/`up`/`at` magnitude | No visual effect at all. |
| Visual model scaling via `setObjectScale` | **Crashes the script** — typed for `Object` handles, called on a `Vehicle`-pool handle. |
| `switchSecurityCamera` (green scan-line effect) as a ready-made "signal interference" look | Officially a NOP in San Andreas — only worked in Vice City. |
| `setWeather()` as a stand-in for signal interference | Global effect on the whole world, and server-controlled in SAMP — not usable for a per-player visual effect. |
| Instant (no-lag) throttle release as a fix for "drone doesn't fall" | Didn't help — the real cause was the ground-effect self-hit + uint/int pointer bug, see `physics.md`. |
| `setCarCollision(false)` / direct `CEntity.UsesCollision` write as a fix for "sticking" to surfaces | Didn't fix the sticking, and broke orientation as a side effect. Real cause was `setCarCoordinates`'s own anti-clip snap, see `collision.md`. |
| `os.execute('mkdir ...')` for creating the replay directory | Silently no-ops in this MoonLoader sandbox, no error surfaced. Use the native `createDirectory`/`doesDirectoryExist`, see `replay.md`. |
| `explosion_huge` as a particle name | Not a real particle in `effects.fxp` — `createFxSystem` silently plays nothing. Correct name: `explosion_large`. |

## General lessons

1. **`getCarPointer` (`uint`) and `colPoint.entity` from `processLineOfSight`
   (`int`) can't be compared directly** — normalize both through
   `bit.tobit()` first (`samePtr` in `vecmath.lua`). This bug hid in two
   places at once (collision self-filtering and ground/ceiling effect).
2. **`setCarCoordinates()` is not a raw position setter** — it has its own
   anti-clip snap logic that fights per-tick calls. Write the entity's matrix
   directly for anything that needs a per-tick transform.
3. **Never guess GTA SA asset/particle names** — verify against an official
   reference list first; a wrong name fails completely silently.
4. **A sudden "nothing reacts"/"stuck" symptom is more often a self-collision
   or self-hit bug than a tuning problem** — check entity self-filtering
   before touching physics constants.
5. **A live debug overlay with real per-frame numbers** (accel breakdown,
   velocity, last-collision-kind) resolved bugs that several rounds of
   guessing didn't — reach for this pattern early when a symptom doesn't have
   an obvious cause, rather than trying fixes one at a time blind.
