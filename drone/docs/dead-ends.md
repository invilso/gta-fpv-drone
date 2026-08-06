# Rejected approaches — don't retry these

| Approach | Why it doesn't work |
|---|---|
| `RCCAM` (id 594) as the drone model | Mislabeled in `lib/game/models.lua` — actually a plant pot/urn, not any RC vehicle. Use `RCRAIDER` (465), the closest vanilla RC-vehicle silhouette to a quad. |
| `createObject()` for the drone | RCRAIDER is a vehicle model (`vehicles.ide`), not a static object — `createObject` silently creates nothing. Use `createCar`. |
| Camera tilt via `CCam.aCams[0].fTilt` | The engine recomputes CCam's vectors from scratch every frame — a raw field write is lost or never read. See `orientation.md`. |
| Camera roll via `CCamera.mCameraMatrix` / `RwCamera.matrix` in `onD3DPresent` | `onD3DPresent` fires after the 3D scene is already rendered for that frame, so a write there has no effect on that frame's roll. See `orientation.md`. |
| Camera roll via `CCam.fRoll` | Crashes the script if `aCams` is indexed with `nActiveCam` directly (it's a `bool`, not an int). Even indexed correctly, has no visible effect on roll. |
| Visual model scaling via matrix `right`/`up`/`at` magnitude | No visual effect on the rendered mesh. |
| Visual model scaling via `setObjectScale` | Typed for `Object` handles — called on a `Vehicle`-pool handle, **crashes the script**. |
| `switchSecurityCamera` (green scan-line effect) for "signal interference" | A NOP in San Andreas — only functional in Vice City. |
| `setWeather()` as a stand-in for signal interference | A global effect on the whole world, and server-controlled in SAMP — not usable for a per-player visual effect. |
| Instant (no-lag) throttle release as a "drone doesn't fall" fix | Doesn't address the actual cause — see the ground-effect self-hit + uint/int pointer note in `physics.md`. |
| `setCarCollision(false)` / direct `CEntity.UsesCollision` write to stop "sticking" to surfaces | Doesn't fix the sticking, and breaks orientation as a side effect. The actual cause is `setCarCoordinates`'s own anti-clip snap — see `collision.md`. |
| `os.execute('mkdir ...')` for creating the replay directory | Silently no-ops in this MoonLoader sandbox, no error surfaced. Use the native `createDirectory`/`doesDirectoryExist` — see `replay.md`. |
| `explosion_huge` as a particle name | Not a real particle in `effects.fxp` — `createFxSystem` silently plays nothing. Correct name: `explosion_large`. |

## General constraints

1. **`getCarPointer` (`uint`) and `colPoint.entity` from `processLineOfSight`
   (`int`) can't be compared directly** — normalize both through
   `bit.tobit()` first (`samePtr` in `vecmath.lua`). Any new collision- or
   proximity-check code that compares entity pointers needs this.
2. **`setCarCoordinates()` is not a raw position setter** — it has its own
   anti-clip snap logic that fights per-tick calls. Write the entity's matrix
   directly for anything that needs a per-tick transform.
3. **Never guess GTA SA asset/particle names** — verify against an official
   reference list first; a wrong name fails completely silently.
4. **A sudden "nothing reacts"/"stuck" symptom is more often a self-collision
   or self-hit bug than a tuning problem** — check entity self-filtering
   before touching physics constants.
5. **A live debug overlay with real per-frame numbers** (accel breakdown,
   velocity, last-collision-kind) is the fastest way to root-cause a
   physics symptom with no obvious cause — cheaper than guessing at
   parameters one at a time.
