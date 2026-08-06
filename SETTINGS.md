# Settings guide

Everything in the in-game menu, section by section. Open it by typing the
menu cheat phrase (`CFGD` by default, rebindable — see Controller → Buttons
below).

## Default controls

| Action | Default |
|---|---|
| Spawn/despawn drone | type `DRONE` |
| Open settings menu | type `CFGD` |
| Arm/disarm motors | `X` |
| Recall (teleport drone back to you) | `R` |
| Cycle ACRO/LEVEL/HORIZON | `M` |
| Toggle 3D throttle | `N` |
| Save current flight replay | `J` |

Every keybind and both cheat phrases are rebindable from the menu — see
Controller → Buttons below.

## Finding your way around

- **Status bar** (top): the red dot closes the menu. Next to it, the
  current flight state (Standby / Flying / Landed / Crashed / Replay).
  Center shows the active flight mode and profile. On the right: your
  connected controller's name (or "No controller"), an EN/UA language
  switch, and the **Expert** toggle — off by default, it hides the deeper
  physics/timing settings so the menu isn't overwhelming; flip it on for
  full control. Custom profiles show their physics editor regardless of
  this toggle, since editing them is the point.
- **Dock** (bottom): eight sections — Fly, Controller, Camera, World,
  Audio, OSD, Replay, Advanced. Hover to magnify and see the name, click
  to switch.
- **Search** (top of the content area): type 2+ characters and every
  matching setting across all sections lists here — click one to jump to
  its section.
- **First-run setup wizard**: opens automatically the first time you open
  the menu on a fresh install. Walks through language, controller
  detection, stick calibration, and a **graphical deadzone step** — watch
  the dots on screen while your sticks are at rest; if they drift outside
  the circle, raise the deadzone until they settle. This step matters:
  skipping it is the most common cause of a drone that slowly spins on its
  own in ACRO mode. Then key/button bindings and a starting profile. Every
  step is skippable, and you can re-run the whole thing later from
  OSD → Appearance → **Run setup wizard**.

## Fly

- **Drone profiles**: four built-in cards — **Standard** (balanced
  all-rounder), **Whoop** (tiny, gentle, indoor-scale), **Racer** (fast,
  twitchy), **Heavy** (big, stable, cinematic). Click **Select** to fly
  one. Every card has a duplicate button (⧉); duplicating creates an
  editable custom profile, shown in its own scrollable row below the
  built-ins with its own icon. Custom profile cards additionally get a
  share button (import/export as text — see below), a rename (pencil),
  and delete (X).
- **Sharing profiles**: the share button opens a text box containing the
  profile as JSON. Copy it (Ctrl+A, Ctrl+C) to send to someone; paste a
  friend's text in and hit **Apply** to adopt their tune. Built-in
  profiles are export-only (they're the reference set) — duplicate one
  first if you want to import into it.
- **Flight mode**: ACRO (full manual rate control, no self-leveling — how
  real FPV quads fly) / LEVEL (stick = tilt angle, releases to level
  itself — easiest) / HORIZON (LEVEL near stick center, full ACRO flips at
  the edges).
- **3D throttle**: stick center = hover, bottom half = downward thrust —
  inverted-flight capable, like real acro quads.
- **Profile physics** (Expert, or always on a custom profile): mass,
  max thrust, gravity, motor lag, rotation lag, max rate, stick expo,
  deadzone, model scale (collision-only), ground/ceiling effect strength
  and radius, plus linear and quadratic drag per axis (forward/right/up).
  Changes apply live — feel the difference mid-flight.

## Controller

- **Device picker**: lists every controller the bridge daemon sees, plus
  "Auto" (picks the lowest-numbered live device). Switch anytime, even
  mid-flight.
- **Axes**: which controller axis (1-8) drives roll/pitch/throttle/yaw,
  each with a **live preview bar** next to it — wiggle the stick and watch
  the dot move, so the mapping is instantly verifiable. Invert toggles for
  pitch and yaw.
- **Arming**: "Require throttle at idle to spawn" (on by default, a real
  safety habit — no takeoff with the throttle already up) and its idle
  threshold (Expert).
- **Buttons**: every bindable action, each as a key AND a controller
  button/switch, both fire the bound action:
  - **Arm/disarm motors** — the classic FPV kill switch. Disarming
    mid-air cuts the motors instantly and the drone drops; re-arming goes
    through the same throttle-at-idle check as spawning. Bind an RC
    transmitter switch here for the authentic feel.
  - **Recall drone** — teleports it back to you.
  - **Cycle flight mode**, **3D throttle toggle**, **save flight
    recording** (key only for the last one).

  To bind: click the button, then either press a key or move a
  controller button/switch. RC transmitter switches usually arrive as
  axis jumps rather than button presses — the bridge detects this
  automatically and shows it as e.g. `A5+`/`A5-`. Click a controller bind
  a second time to clear it.
- **Connection** (Expert): the bridge daemon's port (restart the script
  after changing) and the failsafe timeout — no packets for this long and
  the drone treats it as signal loss.
- **Calibration**: click **Start calibration**, sweep every stick to its
  full range, then finish with the sticks centered. Live bars show each
  axis's tracked min/max/current position while you sweep.

## Camera

- **Spawn distance ahead** / **Spawn height**: where the drone appears
  relative to you.
- **Camera mount forward/up** (Expert): the FPV camera's position along
  the drone's body.
- **Camera tilt**: downward tilt in degrees, like a real FPV rig. Hold the
  Up/Down arrow keys in flight to adjust it smoothly, in fractions of a
  degree, mid-air.

## World

Everything here is singleplayer-only — all no-ops in SA-MP (the drone is
purely client-side there, and SA-MP has no police AI or population system
to hook into).

- **Police**: "Police can shoot the drone down" (bullet damage only — the
  drone stays proofed against fire/explosion/collision from its own
  physics) with a toughness slider (the damage pool before it goes down).
  Wanted stars accrue naturally from crash explosions, and — since your
  character is technically piloting it — the police chase the drone
  itself, not you.
- **Crash explosion**: which real GTA explosion type a crash triggers
  (Grenade, Rocket, Car, Tank shell, RC vehicle, ...) — each has its own
  blast radius and force, and genuinely damages nearby peds/vehicles/you.
- **Streets stay alive**: ped/traffic density multipliers while the drone
  is flying, and "No despawn around the drone" (with a radius) — pins
  nearby peds/cars against the engine's normal off-screen removal, so
  streets don't empty out the instant you look away at speed. "Boost
  engine population limits" (Expert) additionally raises the game's
  hard caps on simultaneously-live peds/cars (engine defaults 25/30) for
  the duration of the flight.
- **Wind**: on/off, direction, steady strength, and gust turbulence.
- **Signal interference** (visual only, controls keep working): clean
  range around the pilot, and the range at which it's full static.

## Audio

- **Enabled**, **max volume** (values above 1.0 amplify past the recorded
  level), **audible range**, and (Expert) the motor's pitch at idle vs.
  full throttle.

## OSD

- **Style**, four to choose from:
  - **Classic** — the original text readout.
  - **Skyline** — clean white HD: artificial horizon with pitch ladder,
    speed/altitude tapes with vario, heading compass, home arrow +
    distance + flight timer, stick position boxes.
  - **Recon** — the same layout, mono green, analog-camera look.
  - **Circuit** — race-sim style: center grid, crosshair reticle, boxed
    corner readouts, a millisecond-precision timer.

  All styles show a blinking REC indicator with the buffered recording
  length while the flight recorder is capturing, status banners
  (DISARMED / FAILSAFE / LANDED / CRASHED / REPLAY), and — whenever
  police can shoot the drone down — a color-coded HP readout (a small
  drone icon that shifts green → yellow → red as damage accumulates).
- **Appearance**: accent color presets for the menu itself, dock icon
  style (color or mono glass), **Debug lines** (bottom-right on-screen
  physics/collision telemetry for tuning and troubleshooting — off by
  default, meant for development, not everyday flying), and the
  **Run setup wizard** button to redo the first-run flow anytime.

## Replay

- **Recording** (Expert): ring buffer size in frames (bigger = longer
  recordings, more RAM), max entities recorded per frame, and the capture
  radius around the drone.
- **Saved flights**: shows the buffered flight's frame count with a
  **Save** button (also bound to the save key above), a file list with
  each recording's length and size, a total files/space counter, **Play**
  (starts it immediately, opens the video-style player), and a delete
  button per file.
- **Player overlay**: while a replay is running, the menu is replaced by
  an auto-hiding player bar (shows on mouse movement or while paused,
  fades after idling) with a scrub bar, play/pause, speed presets
  (0.25x-2x), frame-step buttons, and Stop. Hotkeys work whether the bar
  is visible or not: Space (pause), Left/Right (±5s), Up/Down (speed),
  `,`/`.` (frame step).

## Advanced

- **Collision & crashes**: collision ray spread (Expert), the crash speed
  threshold (measured as velocity *into* the surface, not total speed — a
  fast graze along a wall doesn't count, only a real hit), "Indestructible"
  rubber mode (crash-grade impacts bounce instead of exploding, with a
  springiness slider), slide friction and full-stop speed (Expert — how a
  surviving belly-first impact skids to a stop instead of freezing dead),
  liftoff throttle (Expert), crash cooldown and wreck-view time (Expert),
  and auto-respawn after a crash.
- **Cheat phrases**: the spawn/despawn phrase and the menu phrase itself.
