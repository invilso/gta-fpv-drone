-- The Drone entity: pose, spawn/despawn/recall, and the frozen-vehicle
-- trick shared with replay playback. Flight physics lives in physics.lua,
-- collision/crash in collision.lua -- both extend this same class table.
-- See docs/orientation.md for why the vehicle is driven by a direct matrix
-- write instead of setCarCoordinates/setObjectRotation.
local ffi = require 'ffi'
local Class = require 'class'
local vecmath = require 'vecmath'
local vNorm, vCross = vecmath.vNorm, vecmath.vCross

-- for the vehicleAudio mute in createFrozenVehicle
local SAMemory = require 'SAMemory'
SAMemory.require('CVehicle')

local Drone = Class('Drone')

-- setCharCoordinates/warp opcodes place peds with a z convention that does
-- not match getCharCoordinates (ped centre vs feet -- off by the model's
-- ~1 m half-height, which reads as the ped popping into the air on every
-- placement). Instead of hardcoding the offset: place, read back, and
-- re-place once with the measured delta -- exact under either convention.
local function placeCharExactly(char, x, y, z)
    setCharCoordinates(char, x, y, z)
    local ax, ay, az = getCharCoordinates(char)
    if math.abs(az - z) > 0.05 then
        setCharCoordinates(char, x, y, z - (az - z))
    end
end
Drone.placeCharExactly = placeCharExactly -- replay/player.lua places its decoy the same way

-- RCCAM (594, lib/game/models.lua) is mislabeled -- spawns a plant pot, not
-- an RC vehicle. RCRAIDER, a small RC helicopter, is the closest vanilla
-- silhouette to an FPV quad. See docs/dead-ends.md.
Drone.MODEL = 465

function Drone:init(cfg, audio)
    self.cfg = cfg
    self.audio = audio

    self.spawned = false
    self.armed = false
    self.obj = nil
    self.decoyPed = nil     -- stand-in ped left at the launch point, see :spawn()
    self.launchPos = nil    -- player's exact coords at spawn time -- despawn warps back to these
    self.launchHeading = 0
    self.prevCamMode = 0
    self.grounded = false   -- resting after a soft belly landing, see collision.lua
    self.exploding = false  -- crashed, watching the wreck before despawn, see collision.lua

    self.pos = {x = 0, y = 0, z = 0}
    self.fwd = {x = 0, y = 1, z = 0}
    self.right = {x = 1, y = 0, z = 0}
    self.up = {x = 0, y = 0, z = 1}
    self.vel = {x = 0, y = 0, z = 0}
    self.thrust = 0          -- spooled 0..1 throttle, see profile.motor_tau
    self.angRate = {p = 0, q = 0, r = 0} -- body rates (rad/s) about fwd/right/up

    -- Physics-accel breakdown, for the OSD's thrust-breakdown panel and the
    -- replay's own physics fields (see docs/replay.md).
    self.lastPhysicsDebug = {thrust = 0, gravity = 0, dragUp = 0, ground = 0, ceiling = 0, windZ = 0, accelZ = 0, velZ = 0, posZ = 0}

    self.lastCrashClock = -1000
    self.crashWatchUntil = nil
    self.pendingFuses = {}  -- {car, at} -- scripted car detonations, see collision.lua
    self.lastCollisionKind = 'none' -- 'none' | 'belly' | 'slide' | 'bounce' | 'crash'
    self.collisionHitCount, self.collisionHitsPerSec, self.collisionCountWindowStart = 0, 0, 0
    self.stickCandidateIndex = 1 -- see collision.lua's debug cycler

    self.lastSpawnReject = nil -- {reason, clock} -- shown on screen
    self.flightStartClock = 0  -- set on spawn; live flightElapsed = os.clock() - this
end

function Drone:resetOrientationFromHeading(headingDeg)
    local h = math.rad(headingDeg)
    self.fwd = {x = -math.sin(h), y = math.cos(h), z = 0}
    -- Same cross() argument order as the per-frame re-orthonormalization in
    -- physics.lua (right = up x fwd) -- keep these in agreement, or "right"
    -- flips once on the very first tick after spawn.
    self.right = vNorm(vCross({x = 0, y = 0, z = 1}, self.fwd))
    self.up = vNorm(vCross(self.fwd, self.right))
end

-- Shared by :spawn() and ReplayPlayer:start() -- a frozen, scripted-transform
-- RCRAIDER at a given position, with its own GTA physics/damage/health
-- disabled so nothing but a per-frame matrix write ever moves or destroys
-- it. See docs/orientation.md/docs/collision.md for why freeze+matrix beats
-- setCarCoordinates, and collision.lua for why proofs/no-damage are needed
-- (the script's own collision check is the only thing allowed to "crash" it).
function Drone.createFrozenVehicle(px, py, pz)
    requestModel(Drone.MODEL)
    repeat wait(0) until hasModelLoaded(Drone.MODEL)
    local obj = createCar(Drone.MODEL, px, py, pz)
    markModelAsNoLongerNeeded(Drone.MODEL)
    -- A vehicle has its own physics sim (gravity, suspension, ground
    -- contact) running every frame regardless of the script -- freeze it so
    -- the flight model is the only thing moving it.
    freezeCarPosition(obj, true)
    setCarEngineOn(obj, true) -- it's a heli (CHeli), never actually started otherwise
    setCarProofs(obj, true, true, true, true, true)
    setCarCanBeDamaged(obj, false)
    -- RCRAIDER is a CHeli -- GTA's own rotor/engine audio for it is loud
    -- enough to drown out the script's motor sound (audio.lua), which is
    -- meant to be the drone's only sound source. Disabling the per-vehicle
    -- audio entity silences all of it; the rotors still spin visually.
    local veh = ffi.cast('CVehicle*', getCarPointer(obj))
    veh.vehicleAudio.bEnabled = false
    return obj
end

function Drone:rejectSpawn(reason)
    self.lastSpawnReject = {reason = reason, clock = os.clock()}
    return false
end

-- receiver: net.Receiver, for the arm-throttle-idle check. recorder:
-- replay.Recorder, to auto-persist the outgoing flight before its buffer is
-- reset (see docs/replay.md). playerActive: true if a ReplayPlayer session
-- is currently live (spawn is rejected while a replay is playing).
function Drone:spawn(receiver, recorder, playerActive)
    if self.spawned then return end
    if playerActive then return self:rejectSpawn('replay in progress') end
    if isCharInAnyCar(PLAYER_PED) then return self:rejectSpawn('in a vehicle') end
    if (os.clock() - self.lastCrashClock) * 1000 < self.cfg.crash_cooldown_ms then
        return self:rejectSpawn('crash cooldown')
    end

    local throttle = vecmath.axisUni(self.cfg.calib, receiver.axesRaw, self.cfg.axis_throttle)
    if self.cfg.arm_enabled and throttle > self.cfg.arm_throttle_max then
        return self:rejectSpawn(string.format('throttle not at idle (%.0f%%, need <%.0f%%)', throttle * 100, self.cfg.arm_throttle_max * 100))
    end

    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local heading = getCharHeading(PLAYER_PED)
    local h = math.rad(heading)
    local fwdX, fwdY = -math.sin(h), math.cos(h)

    local sx, sy, sz = px + fwdX * self.cfg.spawn_offset_fwd, py + fwdY * self.cfg.spawn_offset_fwd, pz + self.cfg.spawn_offset_up
    local obj = Drone.createFrozenVehicle(sx, sy, sz)

    self.obj = obj
    self.pos = {x = sx, y = sy, z = sz}
    self.vel = {x = 0, y = 0, z = 0}
    self.thrust = 0
    self.angRate = {p = 0, q = 0, r = 0}
    self:resetOrientationFromHeading(heading)
    self.spawned = true
    self.armed = true -- arm gate (if enabled) was already checked above
    self.launchPos = {x = px, y = py, z = pz}
    self.launchHeading = heading
    self.flightStartClock = os.clock()
    self.audio:start()

    -- Auto-persist the outgoing recording before it's overwritten -- without
    -- this, auto-respawn-after-crash would wipe the very flight that just
    -- crashed before the player gets a chance to save it (see docs/replay.md).
    if recorder.count > 0 then recorder:save() end
    recorder:beginFlight()

    -- Warp the player into the (frozen, our-matrix-driven) vehicle so GTA's
    -- own in-vehicle camera pipeline is active -- see docs/orientation.md
    -- "camera roll" for why. A decoy ped, immune and non-colliding, is left
    -- standing at the launch point in the player's place.
    local pedModel = getCharModel(PLAYER_PED)
    -- Created 1.5 m behind the player, NOT on their exact spot: two solid
    -- peds overlapping for even a frame makes the engine's overlap
    -- resolution shove the player upward (the tossed-into-the-air-on-spawn
    -- bug). Only after its collision is off does the decoy move onto the
    -- player's actual position.
    local decoy = createChar(4, pedModel, px - fwdX * 1.5, py - fwdY * 1.5, pz)
    setCharProofs(decoy, true, true, true, true, true)
    setCharCollision(decoy, false)
    -- Despawn warps the player back to the decoy's coordinates, so any
    -- placement error here would ratchet the player's position every
    -- spawn/despawn cycle (in SAMP, accumulated airborne teleports read
    -- as a fly-hack).
    placeCharExactly(decoy, px, py, pz)
    setCharHeading(decoy, heading)
    self.decoyPed = decoy

    warpCharIntoCar(PLAYER_PED, obj)
    setPlayerControl(PLAYER_HANDLE, false)
    -- RCRAIDER has no proper seat for a full-size ped -- vanilla RC vehicles
    -- are piloted with the character hidden, not visibly riding them.
    setCharVisible(PLAYER_PED, false)
    self.prevCamMode = getPlayerInCarCameraMode()
    setPlayerInCarCameraMode(0)

    return true
end

-- Common warp-out/cleanup, shared by a live-flight end and a replay session
-- end (both cover "the player is currently riding the frozen vehicle").
function Drone:despawn()
    if not self.spawned then return end

    -- The player returns to their own coords as read at spawn time -- the
    -- ground truth, untouched by any placement opcode's z convention. Going
    -- through the decoy's coordinates instead would inherit whatever error
    -- its own placement introduced, compounding per spawn/despawn cycle
    -- under auto-respawn.
    local dx, dy, dz = self.launchPos.x, self.launchPos.y, self.launchPos.z
    warpCharFromCarToCoord(PLAYER_PED, dx, dy, dz)
    -- ...and the warp's own placement convention still applies to this very
    -- call, so re-pin with the measured delta.
    placeCharExactly(PLAYER_PED, dx, dy, dz)
    setCharHeading(PLAYER_PED, self.launchHeading)
    setCharVisible(PLAYER_PED, true)
    setPlayerInCarCameraMode(self.prevCamMode)

    if self.decoyPed and doesCharExist(self.decoyPed) then
        deleteChar(self.decoyPed)
    end
    self.decoyPed = nil

    if self.obj and doesVehicleExist(self.obj) then
        deleteCar(self.obj)
    end
    self.obj = nil
    self.spawned = false
    self.armed = false
    self.grounded = false
    self.audio:stop()

    restoreCameraJumpcut()
    setPlayerControl(PLAYER_HANDLE, true)
end

function Drone:recall()
    if not self.spawned then return end
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local heading = getCharHeading(PLAYER_PED)
    local h = math.rad(heading)
    local fwdX, fwdY = -math.sin(h), math.cos(h)
    self.pos = {x = px + fwdX * self.cfg.spawn_offset_fwd, y = py + fwdY * self.cfg.spawn_offset_fwd, z = pz + self.cfg.spawn_offset_up}
    self.vel = {x = 0, y = 0, z = 0}
    self.thrust = 0
    self.angRate = {p = 0, q = 0, r = 0}
    self.grounded = false
    self:resetOrientationFromHeading(heading)
end

-- Distance from the decoy ped (where the pilot is physically standing) --
-- called once per live tick. Silently no-ops if audio never loaded.
function Drone:tickMotorAudio()
    if not (self.decoyPed and doesCharExist(self.decoyPed)) then return end
    local px, py, pz = getCharCoordinates(self.decoyPed)
    local dist = vecmath.vLen(vecmath.vSub(self.pos, {x = px, y = py, z = pz}))
    self.audio:update(math.abs(self.thrust), dist)
end

return Drone
