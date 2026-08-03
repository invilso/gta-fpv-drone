-- Flight recorder: a fixed-size FFI ring buffer (no per-tick GC pressure)
-- capturing drone pose + nearby vehicles/peds/objects, dumpable to disk. See
-- docs/replay.md for the full design rationale and the format version
-- history.
local ffi = require 'ffi'
local Class = require 'class'
local fmt = require 'replay.format'

local Recorder = Class('Recorder')

-- gps.lua already uses these exact natives (pcall-wrapped, capped-iteration
-- sphere search) to enumerate nearby vehicles/peds safely -- same proven
-- pattern reused here. Object equivalent is unconfirmed in this MoonLoader
-- build, feature-detected the same way. See docs/replay.md.
local hasFindVehiclesInSphere = type(findAllRandomVehiclesInSphere) == 'function'
local hasFindCharsInSphere = type(findAllRandomCharsInSphere) == 'function'
local hasFindObjectsInSphere = type(findAllRandomObjectsInSphere) == 'function'

-- getObjectCoordinates has a different signature than getCarCoordinates/
-- getCharCoordinates -- see docs/replay.md.
local function getObjectCoordinatesXYZ(handle)
    local ok, x, y, z = getObjectCoordinates(handle)
    if not ok then return nil end
    return x, y, z
end

-- Reused scratch arrays for the per-frame entity scan -- zero per-tick heap
-- allocation, same goal as the ring buffer itself. Only one Recorder is ever
-- live in this script, so module-level scratch is fine.
local SCAN_CAP = 40
local scanBuf = {}
for i = 1, SCAN_CAP * 3 do
    scanBuf[i] = {handle = 0, kind = 0, x = 0, y = 0, z = 0, heading = 0, modelId = 0, dist = 0}
end
local scanOrder, scanOrderLen = {}, 0
local function scanOrderCompare(a, b) return scanBuf[a].dist < scanBuf[b].dist end

-- One kind (vehicles/peds/objects) of the entity scan: enumerate via the
-- sphere-find native, pack surviving candidates into scanBuf starting at
-- index n+1. Distance-sorted truncation happens once, after all three kinds
-- are collected, not here -- otherwise a busy scene could lose nearby
-- vehicles to a first-scanned kind eating the whole cap.
local function scanKind(findFn, getCoordsFn, getHeadingFn, getModelFn, kind, n, px, py, pz, radius)
    if not findFn then return n end
    local findNext = false
    for _ = 1, SCAN_CAP do
        local ok, found, handle = pcall(findFn, px, py, pz, radius, findNext, false)
        if not ok or not found then break end
        findNext = true
        if handle and n < #scanBuf then
            -- Type-checked, not just pcall-checked -- see docs/replay.md.
            local ok2, x, y, z = pcall(getCoordsFn, handle)
            if ok2 and type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
                n = n + 1
                local c = scanBuf[n]
                c.handle, c.kind = handle, kind
                c.x, c.y, c.z = x, y, z
                local ok3, hdg = pcall(getHeadingFn, handle)
                c.heading = (ok3 and type(hdg) == 'number') and hdg or 0
                local ok4, m = pcall(getModelFn, handle)
                c.modelId = (ok4 and type(m) == 'number') and m or 0
                local dx, dy, dz = x - px, y - py, z - pz
                c.dist = dx * dx + dy * dy + dz * dz
            end
        end
    end
    return n
end

local REPLAY_DIR = getWorkingDirectory() .. '\\replay'
local ok_lfs, lfs = pcall(require, 'lfs')

local function ensureReplayDir()
    if not doesDirectoryExist(REPLAY_DIR) then
        createDirectory(REPLAY_DIR)
    end
end

function Recorder:init(cfg)
    self.cfg = cfg
    self.buf = nil
    self.capacity = 0
    self.writeIdx = 0
    self.count = 0     -- frames actually written so far, <= capacity (buffer doesn't "wrap" until first full)
    self.recording = false
    self.lastSave = nil -- {ok, msg, clock} -- shown on screen
end

function Recorder:ensureBuffer()
    local n = math.max(1, math.floor(self.cfg.replay_ring_frames))
    if self.buf and self.capacity == n then return end
    self.buf = ffi.new('replay_frame_t[?]', n)
    self.capacity = n
    self.writeIdx = 0
    self.count = 0
end

-- Fresh recording for this flight -- reset, not append, so the buffer
-- always holds (up to capacity) exactly "the last flight".
function Recorder:beginFlight()
    self:ensureBuffer()
    self.writeIdx, self.count = 0, 0
    self.recording = true
end

function Recorder:stop()
    self.recording = false -- buffer keeps holding this just-finished flight until the next beginFlight() reset
end

-- drone: drone.Drone. connected: net.Receiver.connected (or true for a
-- single crash-frame capture, see drone/collision.lua).
function Recorder:captureFrame(drone, connected)
    if not self.recording then return end
    self:ensureBuffer()
    local cfg = self.cfg
    local f = self.buf[self.writeIdx]
    f.timestamp = os.clock()
    f.px, f.py, f.pz = drone.pos.x, drone.pos.y, drone.pos.z
    f.fwdx, f.fwdy, f.fwdz = drone.fwd.x, drone.fwd.y, drone.fwd.z
    f.upx, f.upy, f.upz = drone.up.x, drone.up.y, drone.up.z
    f.velx, f.vely, f.velz = drone.vel.x, drone.vel.y, drone.vel.z
    f.thrust = drone.thrust
    local dbg = drone.lastPhysicsDebug
    f.thrustAccel = dbg.thrust
    f.gravity = dbg.gravity
    f.dragUp = dbg.dragUp
    f.ground = dbg.ground
    f.ceiling = dbg.ceiling
    f.windZ = dbg.windZ
    f.accelZ = dbg.accelZ
    -- bits: 0=armed 1=grounded 2=exploding 3=connected 4-5=flight_mode(0..2) 6=throttle_3d
    local modeVal = 0
    if cfg.flight_mode == 'LEVEL' then modeVal = 1 elseif cfg.flight_mode == 'HORIZON' then modeVal = 2 end
    f.flags = (drone.armed and 1 or 0) + (drone.grounded and 2 or 0) + (drone.exploding and 4 or 0)
        + (connected and 8 or 0) + modeVal * 16 + (cfg.throttle_3d and 64 or 0)

    local n = 0
    n = scanKind(hasFindVehiclesInSphere and findAllRandomVehiclesInSphere or nil,
        getCarCoordinates, getCarHeading, getCarModel, 1, n, drone.pos.x, drone.pos.y, drone.pos.z, cfg.replay_capture_radius)
    n = scanKind(hasFindCharsInSphere and findAllRandomCharsInSphere or nil,
        getCharCoordinates, getCharHeading, getCharModel, 2, n, drone.pos.x, drone.pos.y, drone.pos.z, cfg.replay_capture_radius)
    n = scanKind(hasFindObjectsInSphere and findAllRandomObjectsInSphere or nil,
        getObjectCoordinatesXYZ, getObjectHeading, getObjectModel, 3, n, drone.pos.x, drone.pos.y, drone.pos.z, cfg.replay_capture_radius)

    for i = 1, n do scanOrder[i] = i end
    for i = n + 1, scanOrderLen do scanOrder[i] = nil end
    scanOrderLen = n
    if n > 1 then table.sort(scanOrder, scanOrderCompare) end

    local cap = math.min(cfg.replay_max_entities, fmt.MAX_ENTITIES, n)
    f.entityCount = cap
    for i = 1, cap do
        local c = scanBuf[scanOrder[i]]
        local e = f.entities[i - 1]
        e.kind, e.modelId, e.entityId = c.kind, c.modelId, c.handle
        e.x, e.y, e.z, e.heading = c.x, c.y, c.z, c.heading
    end

    self.writeIdx = (self.writeIdx + 1) % self.capacity
    self.count = math.min(self.count + 1, self.capacity)
end

function Recorder:markSave(ok, msg)
    self.lastSave = {ok = ok, msg = msg, clock = os.clock()}
end

-- Written in chronological (oldest-first) order, not ring-buffer physical
-- order -- unwrapped here so the loader never needs to know the ring buffer
-- exists.
function Recorder:save()
    if self.count == 0 then
        self:markSave(false, 'no recording')
        return false
    end
    ensureReplayDir()
    local name = os.date('flight_%Y%m%d_%H%M%S.drpl')
    local path = REPLAY_DIR .. '\\' .. name
    local f = io.open(path, 'wb')
    if not f then
        self:markSave(false, 'open failed: ' .. path)
        return false
    end

    local cfg = self.cfg
    local hdr = ffi.new('replay_header_t')
    ffi.copy(hdr.magic, fmt.MAGIC, 4)
    hdr.version = fmt.VERSION
    hdr.frameSize = ffi.sizeof('replay_frame_t')
    hdr.maxEntities = fmt.MAX_ENTITIES
    hdr.frameCount = self.count
    ffi.copy(hdr.profileName, cfg.profile.name:sub(1, 15), math.min(#cfg.profile.name, 15))
    hdr.profileMass = cfg.profile.mass
    hdr.profileMaxThrust = cfg.profile.max_thrust
    f:write(ffi.string(hdr, ffi.sizeof(hdr)))

    local frameSize = ffi.sizeof('replay_frame_t')
    if self.count < self.capacity then
        -- Never wrapped yet -- frames [0, count) are already chronological.
        f:write(ffi.string(self.buf, self.count * frameSize))
    else
        -- Wrapped: writeIdx points at the oldest surviving frame; the
        -- chronological timeline is [writeIdx, capacity) then [0, writeIdx).
        local tail = self.capacity - self.writeIdx
        f:write(ffi.string(self.buf + self.writeIdx, tail * frameSize))
        if self.writeIdx > 0 then
            f:write(ffi.string(self.buf, self.writeIdx * frameSize))
        end
    end
    f:close()
    self:markSave(true, name .. ' (' .. self.count .. ' frames)')
    return true, name
end

function Recorder.listFiles()
    local files = {}
    if ok_lfs and lfs then
        local ok, iter, dirObj = pcall(lfs.dir, REPLAY_DIR)
        if ok and iter then
            for name in iter, dirObj do
                if name:match('%.drpl$') then files[#files + 1] = name end
            end
        end
    end
    -- Filenames are flight_YYYYMMDD_HHMMSS.drpl -- lexical sort is
    -- chronological, descending so the newest flight is on top.
    table.sort(files, function(a, b) return a > b end)
    return files
end

Recorder.DIR = REPLAY_DIR

return Recorder
