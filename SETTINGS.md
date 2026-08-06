# Settings guide

Everything in the in-game menu, tab by tab. Open the menu by typing the
menu cheat phrase (`CFGD` by default, rebindable — see General → Cheat
phrases below).

## Default controls

| Action | Default |
|---|---|
| Spawn/despawn drone | type `DRONE` |
| Open settings menu | type `CFGD` |
| Recall (teleport drone back to you) | `R` |
| Cycle ACRO/LEVEL/HORIZON | `M` |
| Toggle 3D throttle | `N` |
| Save current flight replay | `J` |

Every keybind and both cheat phrases are rebindable from the menu — see below.

## Profiles tab

A **profile** is a full set of physics numbers for one "aircraft" — you can
have several (a nimble whoop, a fast racer, a heavy hauler, whatever) and
switch between them without losing any of them.

- **Profile list**: click a name to make it the active profile.
- **New**: creates a fresh profile with default values, under a name you type.
- **Duplicate**: copies the currently active profile under a new name — the
  easiest way to make a variant of one you like without editing it directly.
- **Rename**: renames the active profile.
- **Delete**: removes the active profile (blocked if it's the only one left).

### Physics sliders (apply to whichever profile is active)

- **Mass**: heavier drones accelerate less for the same thrust and feel more
  stable in wind/turbulence; lighter drones feel twitchier.
- **Max thrust**: full-throttle acceleration along the drone's up axis. This
  relative to Mass is what determines how "overpowered" the drone feels —
  a low thrust-to-mass ratio can't even hover.
- **Gravity**: how hard it falls. Higher gravity needs more thrust to
  compensate; mostly for making an unusual profile (very heavy, or
  deliberately floaty) rather than something you'd normally touch.
- **Drag lin/quad fwd/right/up**: air resistance along each of the drone's
  own three axes (forward, sideways, up), split into a linear term (matters
  most at low speed) and a quadratic term (matters most at high speed and
  sets your effective top speed). Keeping `up` drag lower than `fwd`/`right`
  is what makes the drone fall close to real free-fall speed while still
  feeling draggy/stable flying sideways — see `drone/docs/physics.md` if
  you want the full reasoning before changing these.
- **Motor tau**: how many seconds it takes the motors to spool from one
  throttle level to another. Small values (real FPV territory) feel snappy;
  large values feel mushy/laggy on throttle changes.
- **Angular tau**: same idea but for how fast the drone's rotation rate
  catches up to what the stick is asking for — small values snap into
  rotation, large values feel like they have rotational inertia/momentum.
- **Rate max**: the fastest the drone can rotate (degrees/second) at full
  stick deflection in ACRO mode.
- **Expo**: how much the stick response curves near center — higher expo
  means small stick movements near center are gentler (finer control),
  while full deflection is unchanged.
- **Deadzone**: how far you have to move a stick from center before it
  registers at all — raise this if your stick doesn't rest exactly at
  center (drift).
- **Model scale (collision only)**: does not resize the visible model
  (not currently possible — see `drone/docs/orientation.md`), only shrinks
  or grows the collision check's ray spread, i.e. how much clearance you
  need to fit through a gap.
- **Ground/ceiling effect strength/radius**: an upward push near the ground
  and a "suction" toward a low ceiling, both fading out with distance —
  strength is how strong the push is right at the surface, radius is how
  far away it starts being felt.

## General tab

### Connection

- **UDP port**: the bridge daemon's port. The drone doesn't listen on it —
  it subscribes to the daemon there and receives the stream on its own
  automatically-assigned port, so several game instances (SAMP +
  singleplayer at once) all get controller input with no extra setup
  (paired with the controller bridge's own `--ports` setting). Changing this
  only takes effect after restarting the script.
- **Failsafe timeout, ms**: how long without a fresh packet from the
  controller before the drone treats it as "signal lost" and cuts throttle
  to zero (falls, doesn't hover). Don't set this too low — a little UDP
  packet loss is normal even on localhost.

### Controller

Live list of every connected controller the bridge daemon can see, with an
**Auto** entry. With one controller connected, Auto uses it automatically;
with several, Auto picks one and you can override the pick from this list
any time. See `drone/docs/controller-bridge.md` for how device selection
actually works under the hood.

### Cheat phrases

- **Spawn/despawn phrase**: the chat/console phrase that spawns or despawns
  the drone (`DRONE` by default).
- **Menu phrase**: the phrase that opens this settings window (`CFGD` by default).

### Keybinds

- **Recall** (keyboard key and/or controller button — both bindable,
  whichever fires first works): teleports the drone instantly back to you,
  resetting its velocity and rotation — an emergency "get me out of here"
  button, not a precision maneuver.

### Arm

- **Require idle throttle to arm**: if enabled (default), the throttle
  stick must be near zero at the moment you spawn, mirroring a real
  transmitter's arm safety — prevents the drone launching itself the
  instant it appears because your stick was already pushed up.
- **Arm throttle max**: how close to zero "near zero" means, above.
- **Liftoff throttle min**: after a soft landing (the drone is resting,
  ignoring stick input in its `grounded` state), how much throttle you need
  to apply before it's willing to take off again.

### Axis assignment

- **Roll/Pitch/Throttle/Yaw axis**: which of your controller's 8 raw axis
  channels (1-8) maps to each flight control. Match these to your specific
  transmitter/gamepad's actual channel order.
- **Invert pitch/yaw**: flips the direction of that axis if it feels backwards.
- **Calibration**: click an axis button (A1-A8), move that stick through
  its full range, then click **Finish** while the stick is centered — this
  records the real min/center/max values your hardware reports, so the
  normalized -1..1 (or 0..1 for throttle) range is accurate even if your
  controller doesn't report a perfectly centered/symmetric raw range.

### Spawn / camera mount

- **Spawn offset forward/up**: where the drone appears relative to you when
  it spawns — needs to be far enough forward that its collision box doesn't
  overlap yours and launch you.
- **Camera mount forward/up**: reserved for future FPV camera-mount
  positioning (currently not wired into the render path).
- **Camera tilt**: downward camera tilt in degrees, like a real FPV rig's
  camera angle — positive values tilt the view down.

### Collision / crash

- **Collision ray spread**: how wide a margin around the drone counts as a
  hit — wider means safer (harder to clip through thin gaps) but also less
  forgiving of tight spaces.
- **Crash speed threshold (into surface)**: hitting anything other than the
  drone's underside destroys it when the velocity *into* the surface is at
  or above this — a grazing scrape along a wall at speed doesn't count,
  only how hard you actually hit it. Below the threshold the drone scrapes
  and slides instead. A belly hit *always* survives regardless of speed —
  matches a real "landed" touchdown.
- **Indestructible (bounce instead of crash)**: rubber mode — impacts hard
  enough to destroy the drone bounce it off the surface instead. Off by
  default.
- **Bounce restitution**: how bouncy the rubber mode is — the fraction of
  the impact speed thrown back off the surface (1.0 = perfectly elastic,
  0.0 = just stops against the wall).
- **Slide friction**: how quickly a surviving contact bleeds off speed
  while skidding along a surface (higher = stops sooner). The drone slides
  on its belly like a real quad instead of stopping dead where it touched
  down.
- **Slide full-stop speed**: once a belly slide gets slower than this, the
  drone settles into the resting (grounded) state and waits for throttle
  (see **Liftoff throttle min**) to take off again.
- **Crash FX particle name**: which particle effect plays on crash
  (SAMP — visual only, no real explosion; see below).
- **SP explosion type**: in singleplayer only, a crash triggers a real
  `addExplosion` of the chosen GTA explosion type (Grenade, Rocket, Car,
  Tank shell...) — it genuinely damages nearby peds, vehicles and you,
  with each type's own blast radius and force. In SA-MP, crashes are
  visual-only (the drone is fully client-side).
- **Crash cooldown, ms**: minimum time after a crash before you (or
  auto-respawn) can spawn a new drone.
- **Crash view delay, ms**: how long the camera holds an external view of
  the wreck before returning control to you.
- **Auto-respawn after crash**: automatically spawns a fresh drone at your
  location once the cooldown elapses, instead of requiring a manual
  spawn-phrase retype.

### Singleplayer (no effect in SAMP)

Wanted stars accrue naturally — the SP crash explosion is a real
`addExplosion`, so crashing near police (or witnesses) raises your wanted
level the same way any explosion does, and police then chase the drone
itself (your character is technically flying it). While the drone is
spawned, your character is protected from its own crash explosion and from
being busted, so a wanted chase can't end the game mid-flight.

- **Police can shoot the drone down**: police fire damages the drone;
  enough accumulated hits crash it on the spot, wherever it is.
- **Drone health**: the damage pool while shoot-downable. Stock GTA
  vehicles have 1000 — the oversized default stands in for how hard a
  small, fast target is to actually hit.
- **Ped density / Traffic density while flying**: population multipliers
  applied while the drone is spawned (restored to normal on despawn) — turn
  these up to make flyover streets feel alive.
- **Boost population limits (memory patch)**: additionally raises the
  engine's caps on simultaneously-live peds/cars (**Max live peds** /
  **Max live cars**, engine defaults 25/30) for the duration of the flight.
  More of the world stays alive around you at speed, at some FPS cost.
  Previous values are saved and restored on despawn, so it coexists with
  other mods that touch the same limits.
- **No despawn around the drone** / **No-despawn radius**: the engine
  normally removes its peds and cars the moment they're off-screen and past
  a short distance — at drone speed, streets empty out the instant you look
  away. With this on, everything within the radius of the drone is pinned
  against removal while you fly; whatever falls behind (or the flight
  ending) releases it back to normal cleanup.

### Wind

Off by default. When enabled, a steady directional push plus turbulence
(randomized gust noise) is added to the physics every tick — direction,
strength, and turbulence amount are all independently adjustable.

### Signal interference (visual only)

A purely cosmetic static/noise effect that gets worse as you fly farther
from where you're standing — **Clear range** is the distance before any
static appears at all, **Dead range** is the distance at which it's
essentially a solid static screen. This is unrelated to the real failsafe
above (which reacts to actual dropped UDP packets, not distance).

### Flight mode

- **Cycle ACRO/LEVEL/HORIZON**: a keybind and/or a controller button that
  switches flight mode — see `drone/docs/physics.md` for what each mode
  actually does; in short, ACRO is raw rate control (full flips allowed),
  LEVEL self-levels to a target angle, HORIZON blends the two by how far
  you push the stick.
- **Toggle 3D throttle**: switches the throttle stick between one-directional
  (bottom = 0% thrust) and bidirectional (center = 0%, pulling down commands
  negative/inverted thrust) — lets you hold an upside-down hover instead of
  just falling when flipped.
- **LEVEL max angle**: the bank/pitch angle (degrees) you get at full stick
  deflection in LEVEL mode.
- **LEVEL/HORIZON gain**: how aggressively the self-leveling controller
  corrects toward the target angle — higher gain snaps to the target angle
  faster but can overshoot/oscillate if pushed too high.
- **HORIZON blend start**: the stick-deflection fraction (0-1) at which
  HORIZON starts blending away from pure self-leveling toward full ACRO
  response — lower values reach full-rate control sooner.

### Motor audio

- **Enabled**: turns the motor hum on/off entirely.
- **Max range**: distance from you at which the motor sound fades to silence.
- **Max volume (>1 amplifies)**: the loudest the motor sound ever gets.
  Values above 1.0 amplify the sample beyond its recorded level — useful if
  the game's own audio buries it (slight distortion at high gain is normal).
- **Pitch at idle / at full throttle**: the playback-rate range the motor
  sample is pitched across as you move the throttle — wider gaps make
  throttle changes sound more dramatic.

## Replay tab

### Capture settings

- **Ring buffer frames**: how many frames of flight the recorder can hold
  at once — the live "~X MB" estimate below updates as you change this, so
  you can see the memory cost before committing. Takes effect on your next
  spawn, not instantly.
- **Max entities/frame**: how many nearby vehicles/peds/objects get
  recorded per frame, capped and distance-sorted so the closest ones always
  win if there are more than this nearby.
- **Capture radius**: how far from the drone entities get recorded at all.

### Saving

- **Save replay** (keybind): saves the current/most recent flight to disk
  without opening the menu.
- **Save current flight** (button): the same save, from the menu.

### Saved flights

A list of every `.drpl` file on disk, each with **Play** and **Delete**
buttons. If file listing isn't available for some reason, a plain
"load by filename" text box is shown instead.

### Playback controls (shown while a replay is active)

VLC-style: a scrub bar (drag it to seek instantly), **Play/Pause**, **<<
5s** / **5s >>** skip buttons, **Restart**, a row of speed presets
(0.25x-4x), and **Stop playback** to end the session early. The game's own
in-vehicle camera — including the standard `V` camera-cycle key — works
normally throughout playback, exactly like it does during a live flight.
