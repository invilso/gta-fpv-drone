-- Config + drone profiles. See docs/physics.md for the tuning history behind
-- the profile numbers below. Uses MoonLoader's own native decodeJson/
-- encodeJson (no external JSON library needed -- same functions
-- autologin.lua and lib/jsoncfg.lua already use directly).
local Class = require 'class'

local Config = Class('Config')

local function defaultProfile()
    return {
        name = 'default',
        mass = 0.5,             -- kg-ish (arbitrary sim units)
        max_thrust = 14.0,      -- world-units/s^2 at full throttle (>~2g so it can climb)
        gravity = 9.8,
        -- Drag, decomposed into the drone's own body frame (fwd/right/up),
        -- both linear (dominates at low speed) and quadratic (v*|v|, gives a
        -- real top speed instead of accelerating forever). See docs/physics.md
        -- "drag tuning" for why up is cut relative to fwd/right.
        drag_linear = {fwd = 0.2, right = 0.5, up = 0.04},
        drag_quadratic = {fwd = 0.02, right = 0.05, up = 0.004},
        motor_tau = 0.06,       -- seconds: thrust spool time constant, see docs/physics.md
        angular_tau = 0.12,     -- seconds: body rotation rate eases toward the stick's target rate
        rate_max_deg = 400.0,   -- acro: max body rotation rate at full stick, deg/s
        expo = 0.35,            -- 0..1, stick response curve toward center
        deadzone = 0.04,
        model_scale = 1.0,      -- collision-only (checkCollision ray spread), see docs/orientation.md
        -- Ground/ceiling effect, see docs/physics.md.
        ground_effect_strength = 6.0,  -- world-units/s^2 at zero distance
        ground_effect_radius = 1.5,    -- meters
        ceiling_effect_strength = 4.0,
        ceiling_effect_radius = 1.0,
    }
end

local function deepCopy(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end

-- Whoop: tiny, light, snappy -- near-instant motor/rotation response, strong
-- prop-wash ground effect at very short range, twitchy rate.
local function whoopProfile()
    local p = defaultProfile()
    p.name = 'whoop'
    p.mass = 0.15
    p.max_thrust = 6.0
    p.drag_linear = {fwd = 0.3, right = 0.6, up = 0.047}
    p.drag_quadratic = {fwd = 0.03, right = 0.07, up = 0.0053}
    p.motor_tau = 0.03
    p.angular_tau = 0.05
    p.rate_max_deg = 600.0
    p.model_scale = 0.5
    p.ground_effect_strength = 9.0
    p.ground_effect_radius = 1.0
    p.ceiling_effect_strength = 6.0
    p.ceiling_effect_radius = 0.7
    return p
end

-- Racer: high thrust/weight, aerodynamic (low drag), very high rates.
local function racerProfile()
    local p = defaultProfile()
    p.name = 'racer'
    p.mass = 0.6
    p.max_thrust = 20.0
    p.drag_linear = {fwd = 0.1, right = 0.3, up = 0.027}
    p.drag_quadratic = {fwd = 0.015, right = 0.04, up = 0.0033}
    p.motor_tau = 0.05
    p.angular_tau = 0.08
    p.rate_max_deg = 700.0
    return p
end

-- Heavy ("bomber"): big, sluggish, slow to spool and slow to rotate, low
-- thrust/weight ratio.
local function heavyProfile()
    local p = defaultProfile()
    p.name = 'heavy'
    p.mass = 2.5
    p.max_thrust = 25.0
    p.drag_linear = {fwd = 0.4, right = 0.8, up = 0.06}
    p.drag_quadratic = {fwd = 0.04, right = 0.09, up = 0.0067}
    p.motor_tau = 0.25
    p.angular_tau = 0.35
    p.rate_max_deg = 200.0
    p.model_scale = 1.5
    p.ground_effect_strength = 4.0
    p.ground_effect_radius = 2.0
    p.ceiling_effect_strength = 3.0
    p.ceiling_effect_radius = 1.3
    return p
end

Config.defaultProfile = defaultProfile
Config.deepCopy = deepCopy

local function defaultData()
    local cfg = {
        version = 1,
        port = 42013,
        failsafe_ms = 200,       -- not too tight -- UDP drops single packets on loopback too
        cheat_spawn = 'DRONE',
        cheat_menu = 'CFGD',
        recall_vk = 0x52,        -- 'R'
        recall_btn = -1,         -- controller button bit index, -1 = unbound
        arm_enabled = true,      -- require throttle-near-zero at spawn before it's allowed to fly
        arm_throttle_max = 0.08,
        axis_roll = 1,
        axis_pitch = 2,
        axis_pitch_invert = false, -- empirically backwards for this render mapping
        axis_yaw_invert = true,
        axis_throttle = 3,
        axis_yaw = 4,
        calib = {},
        spawn_offset_fwd = 4.0, -- 2.0 overlapped the player's own collision with the vehicle hitbox at spawn
        spawn_offset_up = 1.0,
        cam_mount_fwd = 0.25,
        cam_mount_up = 0.05,
        cam_tilt_deg = 20.0,     -- downward camera tilt, like a real FPV rig -- see docs/orientation.md
        -- Named profiles (CRUD'd from the menu) plus which one is currently
        -- flying. cfg.profile is a runtime-only alias into cfg.profiles[cfg.active_profile]
        -- -- every physics/render call site reads cfg.profile.* directly.
        profiles = {
            default = defaultProfile(),
            whoop = whoopProfile(),
            racer = racerProfile(),
            heavy = heavyProfile(),
        },
        active_profile = 'default',
        collision_radius = 0.6,     -- multi-ray spread around the flight path, world units
        -- SP only. addExplosion()'s 4th argument is an eExplosionType
        -- (0 grenade, 1 molotov, 2 rocket, 3 weak rocket, 4 car,
        -- 5 quick car, 6 boat, 7 aircraft, 8 mine, 9 object, 10 tank,
        -- 11 small, 12 rc vehicle), NOT a radius -- an out-of-range value
        -- makes an explosion with no damage profile (sound and visuals,
        -- nothing hurt).
        crash_explosion_type = 2,
        crash_cooldown_ms = 0,
        auto_respawn_after_crash = true,
        crash_view_delay_ms = 1000, -- hold an external side-on view of the wreck this long
        crash_fx_name = 'explosion_large', -- SAMP: visual-only FX system, no real explosion -- see docs/collision.md
        crash_prop_speed = 6.0, -- world units/s INTO the surface (normal component) -- non-belly impact at/above this crashes it
        indestructible = false, -- rubber mode: crash-grade impacts bounce off instead of exploding
        bounce_restitution = 0.6, -- 0..1 -- fraction of the approach speed kept (reversed) on an indestructible bounce
        slide_friction = 2.0,   -- 1/s -- exponential decay rate of the sliding (tangential) velocity while scraping a surface
        slide_stop_speed = 1.0, -- world units/s -- a belly slide below this comes to a full stop (grounded)
        liftoff_throttle_min = 0.08, -- throttle needed to leave a grounded/landed state
        -- Singleplayer-only extras (all no-ops in SAMP -- see sp.lua):
        sp_bullet_vulnerable = true, -- police fire damages the drone; enough hits = crash
        sp_drone_health = 4000,     -- vehicle health pool while bullet-vulnerable (stock is 1000 -- oversized pool stands in for how hard a small fast target is to actually hit)
        sp_ped_density = 1.0,       -- ped population multiplier while the drone is flying
        sp_car_density = 1.0,       -- traffic density multiplier while the drone is flying
        sp_population_boost = false, -- raise the engine's max live peds/cars while flying (memory patch, see sp.lua)
        sp_max_peds = 60,           -- boosted CPopulation::MaxNumberOfPedsInUse (engine default 25)
        sp_max_cars = 60,           -- boosted CCarCtrl::MaxNumberOfCarsInUse (engine default 30)
        sp_no_despawn = true,       -- pin peds/cars near the drone against the engine's off-screen removal (see sp.lua)
        sp_keep_radius = 200.0,     -- pin radius around the drone, world units
        -- Wind: off by default. Direction uses the same heading convention as
        -- the rest of the script (0 = +y, 90 = +x). See vecmath.turbulence1D.
        wind_enabled = false,
        wind_dir_deg = 0.0,
        wind_strength = 0.0,   -- world-units/s^2, steady component
        wind_turbulence = 0.0, -- world-units/s^2, gust noise amplitude
        -- Signal interference visual (distance-only, separate from the real
        -- UDP failsafe): no static within signal_clear_range of the pilot,
        -- continuously getting worse out to signal_dead_range.
        signal_clear_range = 60.0,
        signal_dead_range = 600.0,
        -- Flight recorder/replay -- see docs/replay.md.
        replay_ring_frames = 18000, -- ~5 min at 60fps, ~20MB at default entity cap
        replay_max_entities = 48,
        replay_capture_radius = 200.0,
        replay_save_vk = 0x4A, -- 'J'
        -- Which physical controller drives the drone (net.lua's Receiver),
        -- by deviceId from the v2 protocol -- see docs/controller-bridge.md.
        -- -1 = auto (lowest-id live device, or the only one if just one is
        -- connected); set from the menu's Controller picker.
        selected_device_id = -1,
        -- Motor audio -- see docs/audio.md.
        audio_enabled = true,
        audio_max_range = 150.0,
        audio_vol_max = 0.6,
        audio_pitch_min = 0.7,
        audio_pitch_max = 1.6,
        -- Flight mode -- see docs/physics.md.
        flight_mode = 'ACRO',
        throttle_3d = false,
        flight_mode_cycle_vk = 0x4D, -- 'M'
        throttle_3d_toggle_vk = 0x4E, -- 'N'
        flight_mode_cycle_btn = -1, -- controller button bit index, -1 = unbound
        throttle_3d_toggle_btn = -1,
        level_max_angle_deg = 45.0,
        level_gain = 8.0,
        horizon_blend_start = 0.7,
    }
    for i = 1, 8 do cfg.calib[i] = {min = 0, max = 2047, center = 1024} end
    return cfg
end

local function deepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == 'table' and type(dst[k]) == 'table' then
            deepMerge(dst[k], v)
        else
            dst[k] = v
        end
    end
end

function Config:init()
    self.path = getWorkingDirectory() .. '\\config\\drone.json'
    self.data = defaultData()
    self.data.profile = self.data.profiles[self.data.active_profile]
end

-- Re-derive the .profile alias after (re)building .profiles/active_profile
-- from scratch, or after switching the active one from the menu.
function Config:selectProfile(name)
    if not self.data.profiles[name] then return false end
    self.data.active_profile = name
    self.data.profile = self.data.profiles[name]
    return true
end

function Config:load()
    local f = io.open(self.path, 'r')
    if not f then return end
    local data = f:read('*a')
    f:close()
    local ok, parsed = pcall(decodeJson, data)
    if ok and type(parsed) == 'table' then
        self.data = defaultData()
        deepMerge(self.data, parsed)
        if not self.data.profiles[self.data.active_profile] then self.data.active_profile = 'default' end
        self.data.profile = self.data.profiles[self.data.active_profile]
    end
end

function Config:save()
    local f = io.open(self.path, 'w')
    if not f then return end
    -- .profile is a runtime-only alias -- drop it so it isn't serialized as
    -- a stray duplicate top-level `profile` key.
    local toSave = {}
    for k, v in pairs(self.data) do
        if k ~= 'profile' then toSave[k] = v end
    end
    f:write(encodeJson(toSave))
    f:close()
end

return Config
