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
-- Explosion damage to a vehicle falls off with distance to the vehicle's
-- CENTRE, not to the surface point hit -- a drone detonating on a bumper is
-- 2-3 m from a long car's centre, so the blast mostly just shoves it (peds
-- are small enough that any contact hit IS a centre hit, which is why they
-- died reliably while cars survived). So: the vehicle actually hit is
-- detonated outright, and every other vehicle near the blast drops below
-- the engine-fire health threshold (~250, see sp.lua) -- GTA's own fire
-- sequence then pops them one by one with natural delays, roadblock-style.
-- Vehicle-ignite radius per eExplosionType (crash_explosion_type) --
-- tiered to match how the engine's own blasts feel, not exact CExplosion
-- dumps. Types absent here (out-of-range = the no-damage visual-only
-- explosion, see config.lua) skip the vehicle pass entirely -- a harmless
-- boom must not torch a roadblock.
local BLAST_RADIUS_BY_TYPE = {
    [0] = 9,   -- grenade
    [1] = 4,   -- molotov (fire, barely any blast)
    [2] = 10,  -- rocket
    [3] = 6,   -- weak rocket
    [4] = 9,   -- car
    [5] = 9,   -- quick car
    [6] = 10,  -- boat
    [7] = 12,  -- aircraft
    [8] = 8,   -- mine
    [9] = 7,   -- object
    [10] = 14, -- tank
    [11] = 5,  -- small
    [12] = 3,  -- rc vehicle
}
local IGNITE_HEALTH = 100
local ENTITY_TYPE_VEHICLE = 2 -- eEntityType, as reported in colPoint.entityType

-- CExplosion::AddExplosion (gta_sa.exe US 1.0, address per plugin-sdk).
-- The addExplosion() opcode calls this with creator=nullptr -- that's why
-- nothing the blast does ever registers as the player's crime and police
-- stay oblivious. Called directly with the player ped as creator, every
-- hit routes through the engine's own crime/wanted pipeline: stars,
-- fleeing witnesses, pursuit -- no hand-written police logic.
local CExplosion_AddExplosion = ffi.cast(
    'bool(__cdecl*)(void*, void*, int, float, float, float, unsigned int, unsigned char, float, unsigned char)',
    0x736A50)

local function addExplosionAsPlayer(x, y, z, expType)
    local creator = ffi.cast('void*', getCharPointer(PLAYER_PED))
    -- args: victim, creator, type, x, y, z, delay, usesSound, camShake(-1 = engine default), bInvisible
    CExplosion_AddExplosion(nil, creator, expType, x, y, z, 0, 1, -1.0, 0)
end

-- The engine only advances a burning vehicle's burn-down-then-explode timer
-- while the vehicle is inside the player's physics processing range. During
-- flight that range follows the drone (the player rides it), but a crash
-- auto-respawn warps the player back to the decoy -- torched cars at the
-- crash site fall out of range and burn forever without ever detonating.
-- So the engine fire is only the visual: every ignited car goes onto
-- self.pendingFuses with its own staggered deadline, and tickFuses()
-- (called from the entry's main loop, NOT gated on the drone being
-- spawned) guarantees the detonation regardless of where the player is.
function Drone:detonateVehiclesAround(colPoint, cx, cy, cz)
    local radius = BLAST_RADIUS_BY_TYPE[self.cfg.crash_explosion_type]
    if not radius then return end
    local r2 = radius * radius
    local hitIsVehicle = colPoint.entityType == ENTITY_TYPE_VEHICLE
    local fuse = 1.2
    for _, car in ipairs(getAllVehicles()) do
        if car ~= self.obj and doesVehicleExist(car) then
            local x, y, z = getCarCoordinates(car)
            local dx, dy, dz = x - cx, y - cy, z - cz
            if dx * dx + dy * dy + dz * dz <= r2 then
                if hitIsVehicle and samePtr(getCarPointer(car), colPoint.entity) then
                    explodeCar(car)
                elseif getCarHealth(car) > IGNITE_HEALTH then
                    setCarCanBeDamaged(car, true)
                    setCarHealth(car, IGNITE_HEALTH) -- engine fire = the visual burn
                    fuse = fuse + 0.4 + math.random() * 0.5
                    table.insert(self.pendingFuses, {car = car, at = os.clock() + fuse})
                end
            end
        end
    end
end

-- Per main-loop tick, always (fuses must keep burning while the drone is
-- despawned or already flying its next sortie).
function Drone:tickFuses()
    if #self.pendingFuses == 0 then return end
    local now = os.clock()
    for i = #self.pendingFuses, 1, -1 do
        local f = self.pendingFuses[i]
        if now >= f.at then
            if doesVehicleExist(f.car) and not isCarDead(f.car) then
                explodeCar(f.car)
            end
            table.remove(self.pendingFuses, i)
        end
    end
end

function Drone:crash(colPoint, recorder)
    local cx, cy, cz = colPoint.pos[1], colPoint.pos[2], colPoint.pos[3]
    if isSampAvailable() then
        local fx = createFxSystem(self.cfg.crash_fx_name, cx, cy, cz, 0)
        if fx then playAndKillFxSystem(fx) end
    else
        addExplosionAsPlayer(cx, cy, cz, self.cfg.crash_explosion_type)
        self:detonateVehiclesAround(colPoint, cx, cy, cz)
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

-- ============================== CVehicle-flag debug cycler ==============================
-- Live in-game tool (F key) for testing whether a given CVehicle/CEntity
-- flag affects a physics/collision symptom, without a full script restart
-- per candidate. Not wired to any known live bug -- see docs/collision.md
-- for the anti-clip-snap issue this class of symptom usually turns out to be.
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
