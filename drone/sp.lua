-- Singleplayer-only extras: police interaction and population boost.
-- Every effect here is a no-op in SAMP -- proofing the player ped or
-- patching population memory client-side on a server reads as
-- godmode/cheating to anticheats, and SP police/population don't exist
-- there anyway.
local Class = require 'class'
local ffi = require 'ffi'
local SAMemory = require 'SAMemory'
SAMemory.require('CPed')
SAMemory.require('CVehicle')

local SP = Class('SPExtras')

-- plugin-sdk ePedCreatedBy / eVehicleCreatedBy: 1 = spawned by the game's
-- own population system (auto-removed by it too), 2 = mission-owned (never
-- auto-removed).
local CREATED_RANDOM, CREATED_MISSION = 1, 2

-- Static game variables, addresses from plugin-sdk (gta_sa.exe US 1.0):
-- https://github.com/DK22Pac/plugin-sdk plugin_sa/game_sa/CPopulation.cpp
-- and CCarCtrl.cpp.
SP.ADDR_MAX_PEDS = 0x8D2538 -- CPopulation::MaxNumberOfPedsInUse (default 25)
SP.ADDR_MAX_CARS = 0x8A5B24 -- CCarCtrl::MaxNumberOfCarsInUse (default 30)

-- Vehicles auto-ignite once health drops below ~250 -- the damage watch
-- must crash the drone before GTA's own fire/explosion sequence takes over
-- the frozen vehicle.
SP.CRASH_HEALTH = 350

function SP:init(cfg)
    self.cfg = cfg
    self.active = false
    self.bulletWatch = false
    self.savedMaxPeds = nil
    self.savedMaxCars = nil
    -- Population pinned against despawn while the drone flies: handle ->
    -- true. Only entities that were CREATED_RANDOM at pin time go in here,
    -- so restoring them to CREATED_RANDOM is always correct.
    self.pinnedChars = {}
    self.pinnedCars = {}
end

-- Called right after a successful Drone:spawn(). The player ped is riding
-- the frozen vehicle: the SP crash explosion is a real addExplosion, and
-- police shoot at/pull out the driver of a wanted vehicle -- without proofs
-- and the dragged-out lock, the drone's own crash can waste the player and
-- a ground stop near police can bust them mid-flight.
function SP:onSpawn(drone)
    if isSampAvailable() then return end
    local cfg = self.cfg
    setCharProofs(PLAYER_PED, true, true, true, true, true)
    setCharCantBeDraggedOut(PLAYER_PED, true)

    -- Drone:spawn()'s setPlayerControl(false) maps to the game's
    -- MakePlayerSafe, which besides locking input also raises the wanted
    -- system's "ignored by police"/"ignored by everyone" flags -- stars
    -- keep accruing but no pursuit ever comes. Clear the flags so police
    -- chase the drone; input stays locked.
    setPoliceIgnorePlayer(PLAYER_HANDLE, false)
    setEveryoneIgnorePlayer(PLAYER_HANDLE, false)

    if cfg.sp_bullet_vulnerable then
        -- Bullets only -- fire/explosion/collision/melee proofs stay, GTA's
        -- own physics damage must never fight the script's collision model.
        setCarProofs(drone.obj, false, true, true, true, true)
        setCarCanBeDamaged(drone.obj, true)
        setCarHealth(drone.obj, cfg.sp_drone_health)
        self.bulletWatch = true
    else
        self.bulletWatch = false
    end

    if cfg.sp_population_boost then
        -- Save whatever the limits currently are (another mod may have
        -- already raised them) and restore exactly that on despawn.
        self.savedMaxPeds = readMemory(SP.ADDR_MAX_PEDS, 4, false)
        self.savedMaxCars = readMemory(SP.ADDR_MAX_CARS, 4, false)
        writeMemory(SP.ADDR_MAX_PEDS, 4, cfg.sp_max_peds, false)
        writeMemory(SP.ADDR_MAX_CARS, 4, cfg.sp_max_cars, false)
    end
    self.active = true
end

function SP:onDespawn()
    if not self.active then return end
    setCharProofs(PLAYER_PED, false, false, false, false, false)
    setCharCantBeDraggedOut(PLAYER_PED, false)
    setPedDensityMultiplier(1.0)
    setCarDensityMultiplier(1.0)
    self:restorePinned()
    if self.savedMaxPeds then
        writeMemory(SP.ADDR_MAX_PEDS, 4, self.savedMaxPeds, false)
        writeMemory(SP.ADDR_MAX_CARS, 4, self.savedMaxCars, false)
        self.savedMaxPeds, self.savedMaxCars = nil, nil
    end
    self.active = false
end

-- Per live tick. Returns true when accumulated damage (police fire) should
-- crash the drone -- the caller owns the actual crash() call.
function SP:tick(drone)
    if not self.active then return false end
    setPedDensityMultiplier(self.cfg.sp_ped_density)
    setCarDensityMultiplier(self.cfg.sp_car_density)
    if self.cfg.sp_no_despawn then self:pinPopulation(drone) end
    if self.bulletWatch and not drone.exploding
        and drone.obj and doesVehicleExist(drone.obj)
        and getCarHealth(drone.obj) <= SP.CRASH_HEALTH then
        return true
    end
    return false
end

-- The population system instantly removes its own (CREATED_RANDOM) peds and
-- cars once they're off-screen and past a short engine-hardcoded distance --
-- at drone speed that empties every street the moment the camera turns.
-- Mission-owned (CREATED_MISSION) entities are never auto-removed, so:
-- everything random within sp_keep_radius of the drone is re-tagged as
-- mission-owned, and re-tagged back to random once it falls behind by 1.2x
-- the radius (or on despawn), at which point the engine cleans it up
-- normally. Only entities seen as CREATED_RANDOM are ever pinned, so the
-- restore value is always correct; script-created entities (the decoy,
-- replay proxies, other mods' peds) are mission-tagged already and
-- untouched.
function SP:pinPopulation(drone)
    local keepR = self.cfg.sp_keep_radius
    local keep2, drop2 = keepR * keepR, (keepR * 1.2) * (keepR * 1.2)
    local px, py, pz = drone.pos.x, drone.pos.y, drone.pos.z

    for ped in pairs(self.pinnedChars) do
        if not doesCharExist(ped) then self.pinnedChars[ped] = nil end
    end
    for car in pairs(self.pinnedCars) do
        if not doesVehicleExist(car) then self.pinnedCars[car] = nil end
    end

    for _, ped in ipairs(getAllChars()) do
        if ped ~= PLAYER_PED and ped ~= drone.decoyPed then
            local x, y, z = getCharCoordinates(ped)
            local dx, dy, dz = x - px, y - py, z - pz
            local d2 = dx * dx + dy * dy + dz * dz
            local p = ffi.cast('CPed*', getCharPointer(ped))
            if self.pinnedChars[ped] then
                if d2 > drop2 then
                    p.nCreatedBy = CREATED_RANDOM
                    self.pinnedChars[ped] = nil
                end
            elseif p.nCreatedBy == CREATED_RANDOM and d2 <= keep2 then
                p.nCreatedBy = CREATED_MISSION
                self.pinnedChars[ped] = true
            end
        end
    end

    for _, car in ipairs(getAllVehicles()) do
        if car ~= drone.obj then
            local x, y, z = getCarCoordinates(car)
            local dx, dy, dz = x - px, y - py, z - pz
            local d2 = dx * dx + dy * dy + dz * dz
            local v = ffi.cast('CVehicle*', getCarPointer(car))
            if self.pinnedCars[car] then
                if d2 > drop2 then
                    v.nCreatedBy = CREATED_RANDOM
                    self.pinnedCars[car] = nil
                end
            elseif v.nCreatedBy == CREATED_RANDOM and d2 <= keep2 then
                v.nCreatedBy = CREATED_MISSION
                self.pinnedCars[car] = true
            end
        end
    end
end

function SP:restorePinned()
    for ped in pairs(self.pinnedChars) do
        if doesCharExist(ped) then
            ffi.cast('CPed*', getCharPointer(ped)).nCreatedBy = CREATED_RANDOM
        end
    end
    for car in pairs(self.pinnedCars) do
        if doesVehicleExist(car) then
            ffi.cast('CVehicle*', getCarPointer(car)).nCreatedBy = CREATED_RANDOM
        end
    end
    self.pinnedChars, self.pinnedCars = {}, {}
end

return SP
