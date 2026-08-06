-- Flight replay playback: drives a loaded recording through the exact same
-- mechanism as live flight (a frozen vehicle, the player warped inside it,
-- native in-vehicle camera including the vanilla V camera-cycle). See
-- docs/replay.md for the format/versioning and the entity-proxy tradeoff.
local ffi = require 'ffi'
local Class = require 'class'
local fmt = require 'replay.format'
local vecmath = require 'vecmath'
local Drone = require 'drone'

local Player = Class('Player')

local REPLAY_DIR = getWorkingDirectory() .. '\\replay'

-- Returns {frames=replay_frame_t*, count=n, keepAlive=<Lua string>, ...} or nil, err.
-- keepAlive must be held by the caller for as long as `frames` is used --
-- the ffi.cast is a view into that Lua string's own memory, not a copy.
local function loadReplayFile(name)
    local path = name
    if not path:find('[\\/]') then path = REPLAY_DIR .. '\\' .. path end
    local f = io.open(path, 'rb')
    if not f then return nil, 'open failed: ' .. path end
    local data = f:read('*a')
    f:close()

    local hdrSize = ffi.sizeof('replay_header_t')
    if #data < hdrSize then return nil, 'truncated (no header)' end
    local hdr = ffi.cast('replay_header_t*', data)
    if ffi.string(hdr.magic, 4) ~= fmt.MAGIC then return nil, 'not a replay file' end
    if hdr.version ~= fmt.VERSION then return nil, 'incompatible version ' .. hdr.version end
    if hdr.frameSize ~= ffi.sizeof('replay_frame_t') or hdr.maxEntities ~= fmt.MAX_ENTITIES then
        return nil, 'incompatible frame layout (saved with a different build)'
    end

    local body = data:sub(hdrSize + 1)
    if #body < hdr.frameCount * hdr.frameSize then return nil, 'truncated (short body)' end

    local frames = ffi.cast('replay_frame_t*', body)
    return {
        frames = frames, count = tonumber(hdr.frameCount), keepAlive = body,
        profileName = ffi.string(hdr.profileName), -- ffi.string stops at the first \0, safe for a fixed char[16]
        profileMass = hdr.profileMass, profileMaxThrust = hdr.profileMaxThrust,
    }
end

function Player:init()
    self.active = false
    self.lastReject = nil -- {reason, clock} -- shown on screen, same overlay as spawn rejects
end

function Player:isActive() return self.active end

function Player:reject(reason)
    self.lastReject = {reason = 'replay: ' .. reason, clock = os.clock()}
    return false
end

-- Kicks off playback of a saved .drpl file. Rejects if a live flight or
-- another replay is already active.
function Player:start(name, drone)
    if drone.spawned then return self:reject('drone already flying') end
    local rs, err = loadReplayFile(name)
    if not rs then return self:reject(err) end
    if rs.count == 0 then return self:reject('empty file') end

    local first = rs.frames[0]
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local heading = getCharHeading(PLAYER_PED)

    local pedModel = getCharModel(PLAYER_PED)
    local decoy = createChar(4, pedModel, px, py, pz)
    setCharHeading(decoy, heading)
    setCharProofs(decoy, true, true, true, true, true)
    setCharCollision(decoy, false)
    drone.decoyPed = decoy
    drone.launchHeading = heading

    local obj = Drone.createFrozenVehicle(first.px, first.py, first.pz)
    drone.obj = obj
    drone.pos = {x = first.px, y = first.py, z = first.pz}
    drone.fwd = {x = first.fwdx, y = first.fwdy, z = first.fwdz}
    drone.up = {x = first.upx, y = first.upy, z = first.upz}
    -- right isn't stored on disk (derivable) -- same re-orthonormalization
    -- convention physics.lua uses every live-flight tick.
    drone.right = vecmath.vNorm(vecmath.vCross(drone.up, drone.fwd))
    drone.vel = {x = 0, y = 0, z = 0}
    drone.thrust = first.thrust
    drone.spawned = true -- reuses every existing spawned-state guard elsewhere
    drone.audio:start()

    warpCharIntoCar(PLAYER_PED, obj)
    setPlayerControl(PLAYER_HANDLE, false)
    setCharVisible(PLAYER_PED, false)
    drone.prevCamMode = getPlayerInCarCameraMode()
    setPlayerInCarCameraMode(0)

    self.frames, self.count, self.keepAlive = rs.frames, rs.count, rs.keepAlive
    self.idx = 0
    self.baseTs = first.timestamp
    -- VLC-style transport: playbackTime is virtual seconds since baseTs,
    -- advanced by dt*speed each tick -- pause/speed-change/seek are all just
    -- edits to this one number, not separate code paths.
    self.playbackTime = 0
    self.durationSec = rs.frames[rs.count - 1].timestamp - first.timestamp
    self.speed = 1.0
    self.paused = false
    self.profileName, self.profileMass, self.profileMaxThrust = rs.profileName, rs.profileMass, rs.profileMaxThrust
    self.active = true
    return true
end

-- Frame with the greatest timestamp <= ts (frames are chronological, so a
-- binary search finds it in O(log count)) -- used every tick since
-- seeking/rewinding can move idx backward too, not just forward.
local function findFrameIndex(frames, count, ts)
    local lo, hi = 0, count - 1
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if frames[mid].timestamp <= ts then lo = mid else hi = mid - 1 end
    end
    return lo
end

-- Jump to an absolute point in the recording, clamped to [0, durationSec].
function Player:seek(seconds)
    if not self.active then return end
    self.playbackTime = vecmath.clamp(seconds, 0, self.durationSec)
end

-- Background vehicles/peds/objects during playback, reproduced as
-- lightweight proxy entities keyed by the recorded entityId. See
-- docs/replay.md for the accepted handle-reuse tradeoff.
function Player:spawnProxy(kind, modelId, x, y, z, heading)
    requestModel(modelId)
    repeat wait(0) until hasModelLoaded(modelId)
    local handle
    if kind == 1 then
        handle = createCar(modelId, x, y, z)
        markModelAsNoLongerNeeded(modelId)
        pcall(setCarHeading, handle, heading)
        pcall(setCarProofs, handle, true, true, true, true, true)
        pcall(setCarCanBeDamaged, handle, false)
    elseif kind == 2 then
        handle = createChar(4, modelId, x, y, z)
        markModelAsNoLongerNeeded(modelId)
        pcall(setCharHeading, handle, heading)
        pcall(setCharProofs, handle, true, true, true, true, true)
        pcall(setCharCollision, handle, false)
    elseif kind == 3 then
        handle = createObject(modelId, x, y, z)
        markModelAsNoLongerNeeded(modelId)
        pcall(setObjectHeading, handle, heading) -- single-axis setter, not setObjectRotation's 3-axis one
    end
    return handle
end

function Player:repositionProxy(p, x, y, z, heading)
    if p.kind == 1 then
        pcall(setCarCoordinates, p.handle, x, y, z)
        pcall(setCarHeading, p.handle, heading)
    elseif p.kind == 2 then
        pcall(setCharCoordinates, p.handle, x, y, z)
        pcall(setCharHeading, p.handle, heading)
    elseif p.kind == 3 then
        pcall(setObjectCoordinates, p.handle, x, y, z)
        pcall(setObjectHeading, p.handle, heading)
    end
end

local seenProxyIds = {} -- reused "still present this frame" marker set, cleared in place every tick

function Player:updateEntityProxies(fr)
    self.entityProxies = self.entityProxies or {}
    local proxies = self.entityProxies
    for k in pairs(seenProxyIds) do seenProxyIds[k] = nil end

    local n = fr.entityCount
    for i = 0, n - 1 do
        local e = fr.entities[i]
        local id = e.entityId
        seenProxyIds[id] = true
        local p = proxies[id]
        if not p then
            local ok, handle = pcall(function() return self:spawnProxy(e.kind, e.modelId, e.x, e.y, e.z, e.heading) end)
            if ok and handle then
                proxies[id] = {handle = handle, kind = e.kind, modelId = e.modelId}
            end
        else
            self:repositionProxy(p, e.x, e.y, e.z, e.heading)
        end
    end

    for id, p in pairs(proxies) do
        if not seenProxyIds[id] then
            if p.kind == 1 and doesVehicleExist(p.handle) then deleteCar(p.handle)
            elseif p.kind == 2 and doesCharExist(p.handle) then deleteChar(p.handle)
            elseif p.kind == 3 and doesObjectExist(p.handle) then deleteObject(p.handle)
            end
            proxies[id] = nil
        end
    end
end

-- Unpacks a recorded frame's flags bitfield and the per-file profile
-- snapshot into osd's telemetry table -- see docs/replay.md "osdTelemetry".
function Player:syncOsdTelemetry(osd, fr)
    local t = osd.telemetry
    local flags = fr.flags
    t.armed = bit.band(flags, 1) ~= 0
    t.grounded = bit.band(flags, 2) ~= 0
    t.connected = bit.band(flags, 8) ~= 0
    local modeVal = bit.rshift(bit.band(flags, 0x30), 4)
    t.flightMode = fmt.FLIGHT_MODES[modeVal + 1] or 'ACRO'
    t.throttle3d = bit.band(flags, 64) ~= 0
    t.vel.x, t.vel.y, t.vel.z = fr.velx, fr.vely, fr.velz
    t.thrust = fr.thrust
    t.thrustAccel = fr.thrustAccel
    t.gravity = fr.gravity
    t.dragUp = fr.dragUp
    t.ground = fr.ground
    t.ceiling = fr.ceiling
    t.windZ = fr.windZ
    t.accelZ = fr.accelZ
    t.stickRoll, t.stickPitch, t.stickYaw, t.stickThrottle = fr.stickRoll, fr.stickPitch, fr.stickYaw, fr.stickThrottle
    t.profileName = self.profileName
    t.profileMass = self.profileMass
    t.profileMaxThrust = self.profileMaxThrust
    t.flightElapsed = self.playbackTime -- position within the recorded flight, not wall-clock
    t.recording = false
    t.replaying = true
end

-- VLC-style transport, only advanced when not paused. idx is re-derived
-- every tick via binary search rather than a forward-only walk, since
-- seeking can move it backward too. Reaches the end -> pauses on the last
-- frame instead of auto-despawning, so there's something to look at/rewind.
function Player:tick(dt, drone, camera, osd)
    if not self.active then return end
    if not self.paused then
        self.playbackTime = self.playbackTime + dt * self.speed
        if self.playbackTime >= self.durationSec then
            self.playbackTime = self.durationSec
            self.paused = true
        elseif self.playbackTime < 0 then
            self.playbackTime = 0
        end
    end

    self.idx = findFrameIndex(self.frames, self.count, self.baseTs + self.playbackTime)
    local fr = self.frames[self.idx]
    drone.pos.x, drone.pos.y, drone.pos.z = fr.px, fr.py, fr.pz
    drone.fwd.x, drone.fwd.y, drone.fwd.z = fr.fwdx, fr.fwdy, fr.fwdz
    drone.up.x, drone.up.y, drone.up.z = fr.upx, fr.upy, fr.upz
    local right = vecmath.vNorm(vecmath.vCross(drone.up, drone.fwd))
    drone.right.x, drone.right.y, drone.right.z = right.x, right.y, right.z
    drone.thrust = fr.thrust

    drone:applyTransform()
    camera.update()
    self:updateEntityProxies(fr)
    self:syncOsdTelemetry(osd, fr)
    drone:tickMotorAudio() -- reuses the live-flight helper unchanged, see drone.lua
end

-- Despawns all background proxies and clears playback state. Does NOT touch
-- the drone itself (see the entry-point's despawnAll(), which calls this
-- alongside drone:despawn()/recorder:stop() -- all three cover "either a
-- live flight or a replay session just ended").
function Player:stop()
    for _, p in pairs(self.entityProxies or {}) do
        if p.kind == 1 and doesVehicleExist(p.handle) then deleteCar(p.handle)
        elseif p.kind == 2 and doesCharExist(p.handle) then deleteChar(p.handle)
        elseif p.kind == 3 and doesObjectExist(p.handle) then deleteObject(p.handle)
        end
    end
    self.entityProxies = {}
    self.active = false
    self.frames, self.count, self.keepAlive = nil, nil, nil
end

Player.DIR = REPLAY_DIR

return Player
