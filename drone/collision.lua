-- Collision detection, crash/landing logic. See docs/collision.md for the
-- setCarCoordinates-sticking saga and the checkSolid/car raycast split.
local ffi = require 'ffi'
local Drone = require 'drone'
local vecmath = require 'vecmath'
local vScale, samePtr, vAdd, vSub, vDot = vecmath.vScale, vecmath.samePtr, vecmath.vAdd, vecmath.vSub, vecmath.vDot

-- for nFlags.bIsRCVehicle etc, see the sticking-bug debug cycler below
local SAMemory = require 'SAMemory'
SAMemory.require('CVehicle')

-- One ray straight along the flight path can tunnel through thin geometry at
-- drone speeds/frame rates -- cast a small cross pattern instead of a single
-- centerline ray. See docs/collision.md for why checkSolid/car are two
-- separate native calls per ray, and why the drone's own vehicle pointer
-- must be filtered out of car=true hits.
function Drone:checkCollision(fromPos, toPos)
    if not (self.obj and doesVehicleExist(self.obj)) then return false end
    local selfPtr = getCarPointer(self.obj)
    local r = self.cfg.collision_radius * self.cfg.profile.model_scale -- shrink the ray spread with the model, see docs/orientation.md
    local offsets = {
        {x = 0, y = 0, z = 0},
        vScale(self.right, r), vScale(self.right, -r),
        vScale(self.up, r), vScale(self.up, -r),
    }
    for _, off in ipairs(offsets) do
        local ox1, oy1, oz1 = fromPos.x + off.x, fromPos.y + off.y, fromPos.z + off.z
        local ox2, oy2, oz2 = toPos.x + off.x, toPos.y + off.y, toPos.z + off.z

        local hit, colPoint = processLineOfSight(ox1, oy1, oz1, ox2, oy2, oz2,
            true, false, false, false, false, false, false, false) -- world/buildings
        if hit then return true, colPoint end

        hit, colPoint = processLineOfSight(ox1, oy1, oz1, ox2, oy2, oz2,
            false, true, false, false, false, false, false, false) -- vehicles (player's own included)
        if hit and not samePtr(colPoint.entity, selfPtr) then return true, colPoint end
    end
    return false
end

-- SP: real addExplosion at the impact point, no radius/power limit (user's
-- explicit choice). SAMP: the drone is purely client-side, so a real
-- addExplosion would still detonate locally with real damage even though no
-- other player sees it -- createFxSystem+playAndKillFxSystem plays the
-- particle effect without the actual explosion instead.
--
-- recorder: replay.Recorder, for the single wreck-pose capture (not one per
-- tick -- the pose is static once crashed, see docs/replay.md).
function Drone:crash(colPoint, recorder)
    local cx, cy, cz = colPoint.pos[1], colPoint.pos[2], colPoint.pos[3]
    if isSampAvailable() then
        local fx = createFxSystem(self.cfg.crash_fx_name, cx, cy, cz, 0)
        if fx then playAndKillFxSystem(fx) end
    else
        addExplosion(cx, cy, cz, self.cfg.crash_explosion_radius)
    end

    -- Side-on external view of the wreck -- the native in-car camera has
    -- nothing meaningful to show once the drone's stopped moving/exploded.
    local sideOffset = vScale(self.right, 6)
    local camPos = vAdd(vAdd({x = cx, y = cy, z = cz}, sideOffset), {x = 0, y = 0, z = 2})
    setFixedCameraPosition(camPos.x, camPos.y, camPos.z, 0.0, 0.0, 0.0)
    pointCameraAtPoint(cx, cy, cz, 2)

    self.exploding = true
    self.audio:stop() -- motors are gone -- immediate cut, not a fade
    self.crashWatchUntil = os.clock() + self.cfg.crash_view_delay_ms / 1000
    if recorder then recorder:captureFrame(self, true) end
end

-- Returns true if auto-respawn should now be pending (caller owns that
-- scheduling, since it also needs to know the cooldown timer).
function Drone:finishCrash()
    self:despawn()
    self.exploding = false
    self.lastCrashClock = os.clock()
    return self.cfg.auto_respawn_after_crash
end

-- ============================== sticking-bug debug cycler ==============================
-- TEMPORARY (see docs/collision.md "sticking" -- setCarCoordinates was the
-- real cause and is already fixed by the direct matrix write in
-- physics.lua). This cycler predates that finding and is kept only as a
-- live debug tool (F key) in case a similar symptom resurfaces; remove
-- outright if it's never needed again.
Drone.STICK_CANDIDATES = {
    {name = 'none (baseline)', apply = function(ent, veh) end},
    {name = 'CVehicle.nFlags.bIsRCVehicle=false', apply = function(ent, veh) veh.nFlags.bIsRCVehicle = false end},
    {name = 'CEntity.IsInSafePosition=false', apply = function(ent, veh) ent.IsInSafePosition = false end},
    {name = 'CVehicle.nFlags.bRestingOnPhysical=false', apply = function(ent, veh) veh.nFlags.bRestingOnPhysical = false end},
    {name = 'CEntity.HasContacted=false', apply = function(ent, veh) ent.HasContacted = false end},
    {name = 'CEntity.IsStuck=false', apply = function(ent, veh) ent.IsStuck = false end},
    {name = 'CVehicle.nFlags.bVehicleColProcessed=false', apply = function(ent, veh) veh.nFlags.bVehicleColProcessed = false end},
}

function Drone:applyStickDebugCandidate(index)
    if not (self.obj and doesVehicleExist(self.obj)) then return end
    local ptr = getCarPointer(self.obj)
    local ent = ffi.cast('CEntity*', ptr)
    local veh = ffi.cast('CVehicle*', ptr)
    Drone.STICK_CANDIDATES[index].apply(ent, veh)
end

return Drone
