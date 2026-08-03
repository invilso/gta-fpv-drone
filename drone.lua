script_name("FPV Drone")
script_author("invilso")
script_version("0.2")

-- FPV drone: a standalone flight object driven by any connected controller
-- via drone/bridge/controllerd.py (own UDP port, own state, independent of
-- tx12.lua). Spawn/despawn via a typed cheat phrase (testCheat), works in
-- both SAMP and pure singleplayer.
--
-- This file is a thin entry-point -- the actual logic lives under
-- moonloader/drone/ as require()'d modules/classes; see
-- moonloader/drone/docs/ and ARCHITECTURE.md for the design.

if not doesDirectoryExist(getWorkingDirectory() .. '\\drone') then
    print("FPV Drone: moonloader/drone/ not found -- if you installed in " ..
        "Link mode and moved or deleted the folder you cloned, either " ..
        "restore it or re-run the installer in Copy mode.")
    return
end

package.path = getWorkingDirectory() .. '\\drone\\?.lua;' .. package.path

local Config = require 'config'
local Receiver = require 'net'
local MotorAudio = require 'audio'
require 'physics'
local Drone = require 'collision' -- pulls in drone.lua's core + physics.lua + collision.lua, see their own requires
local camera = require 'camera'
local Recorder = require 'replay.recorder'
local Player = require 'replay.player'
local OSD = require 'osd'
local UI = require 'ui'
local font = require 'font'
local vecmath = require 'vecmath'

-- Config:load() must run before anything else captures a reference to
-- configObj.data -- it may reassign that table wholesale when merging a
-- saved file, and every other class below stores its own `self.cfg` pointer
-- at construction time (explicit-dependency style, not a shared upvalue
-- like the old monolithic file used).
local configObj = Config.new()
configObj:load()
local cfg = configObj.data

local receiver = Receiver.new(cfg)
local audio = MotorAudio.new(cfg)
local drone = Drone.new(cfg, audio)
local recorder = Recorder.new(cfg)
local player = Player.new()
local osd = OSD.new(cfg)
local ui = UI.new(configObj, drone, receiver, recorder, player)

local autoRespawnPending = false

-- Shared by the DRONE cheat-toggle, the Replay tab's "Stop playback"
-- button, and a manual respawn -- covers "either a live flight or a replay
-- session just ended", same as the old monolithic despawnDrone() did.
local function despawnAll()
    if player:isActive() then player:stop() end
    drone:despawn()
    recorder:stop()
end

function main()
    receiver:open()
    font.ensure()
    audio:load()
    osd:createFont()

    local lastTick = os.clock()

    while true do
        wait(0)
        receiver:poll()
        ui:processInput()

        local pendingName = ui:consumePendingPlayback()
        if pendingName then player:start(pendingName, drone) end
        if ui:consumeDespawnRequest() then despawnAll() end

        -- Not gated on drone.spawned: saving "the last flight" is meant to
        -- work right after it ends too, while the recorder still holds it.
        if recorder.count > 0 and not ui.keyListen and isKeyJustPressed(cfg.replay_save_vk) then
            recorder:save()
        end

        local cursorBlocksCheat = isSampAvailable() and sampIsCursorActive()
        if not cursorBlocksCheat then
            if testCheat(cfg.cheat_spawn) then
                autoRespawnPending = false -- manual toggle overrides any pending auto-respawn
                if drone.spawned then
                    despawnAll()
                else
                    drone:spawn(receiver, recorder, player:isActive())
                end
            end
            if testCheat(cfg.cheat_menu) then
                ui:toggle()
            end
        end

        if autoRespawnPending and not drone.spawned and (os.clock() - drone.lastCrashClock) * 1000 >= cfg.crash_cooldown_ms then
            if drone:spawn(receiver, recorder, player:isActive()) then autoRespawnPending = false end
        end

        -- Shared by both branches below (live flight and replay playback).
        local now = os.clock()
        local dt = vecmath.clamp(now - lastTick, 0, 0.1) -- clamp to avoid a huge step after a hitch/pause
        lastTick = now

        if player:isActive() then
            if not isPauseMenuActive() then
                player:tick(dt, drone, camera, osd)
            end
        elseif drone.spawned then
            if isKeyJustPressed(cfg.recall_vk) then
                drone:recall()
            end
            if isKeyJustPressed(0x46) then -- 'F', see collision.lua's STICK_CANDIDATES
                drone.stickCandidateIndex = (drone.stickCandidateIndex % #Drone.STICK_CANDIDATES) + 1
            end
            if isKeyJustPressed(0xBD) then cfg.profile.model_scale = vecmath.clamp(cfg.profile.model_scale - 0.1, 0.01, 2.0) end -- '-'
            if isKeyJustPressed(0xBB) then cfg.profile.model_scale = vecmath.clamp(cfg.profile.model_scale + 0.1, 0.01, 2.0) end -- '='
            if isKeyJustPressed(0x26) then cfg.cam_tilt_deg = vecmath.clamp(cfg.cam_tilt_deg + 1.0, -45, 45) end -- Up arrow
            if isKeyJustPressed(0x28) then cfg.cam_tilt_deg = vecmath.clamp(cfg.cam_tilt_deg - 1.0, -45, 45) end -- Down arrow

            -- Flight mode / 3D-throttle switches: keyboard key OR TX12
            -- button, whichever fires first -- both configurable in the menu.
            if isKeyJustPressed(cfg.flight_mode_cycle_vk) or receiver:btnJustPressed(cfg.flight_mode_cycle_btn) then
                local idx = 1
                for i, m in ipairs(Drone.FLIGHT_MODES) do if m == cfg.flight_mode then idx = i; break end end
                cfg.flight_mode = Drone.FLIGHT_MODES[(idx % #Drone.FLIGHT_MODES) + 1]
                ui:markDirty()
            end
            if isKeyJustPressed(cfg.throttle_3d_toggle_vk) or receiver:btnJustPressed(cfg.throttle_3d_toggle_btn) then
                cfg.throttle_3d = not cfg.throttle_3d
                ui:markDirty()
            end

            if not isPauseMenuActive() then
                osd:syncLive(drone, receiver, recorder)
                if not drone.exploding then drone:tickMotorAudio() end
                if drone.exploding then
                    -- Wreck just sits there with the FX already played;
                    -- camera was already pointed at it in Drone:crash().
                    if now >= drone.crashWatchUntil then
                        autoRespawnPending = drone:finishCrash()
                    end
                elseif drone.grounded then
                    -- Resting after a soft landing: hold position/orientation,
                    -- ignore stick input, until enough throttle is applied
                    -- to take off again.
                    if receiver.connected and vecmath.axisUni(cfg.calib, receiver.axesRaw, cfg.axis_throttle) > cfg.liftoff_throttle_min then
                        drone.grounded = false
                    end
                    drone:applyTransform()
                    drone:applyStickDebugCandidate(drone.stickCandidateIndex)
                    camera.update()
                    recorder:captureFrame(drone, receiver.connected)
                else
                    local prevPos = {x = drone.pos.x, y = drone.pos.y, z = drone.pos.z}
                    drone:updatePhysics(dt, receiver)
                    local hit, colPoint = drone:checkCollision(prevPos, drone.pos)
                    if now - drone.collisionCountWindowStart >= 1.0 then
                        drone.collisionHitsPerSec = drone.collisionHitCount
                        drone.collisionHitCount = 0
                        drone.collisionCountWindowStart = now
                    end
                    if hit then
                        drone.collisionHitCount = drone.collisionHitCount + 1
                        -- Belly = the underside of the drone's own local
                        -- frame -- always survives, no speed check. Anything
                        -- else crashes at speed, or a slow bump just knocks
                        -- it back a bit instead. See docs/collision.md.
                        local impactPos = {x = colPoint.pos[1], y = colPoint.pos[2], z = colPoint.pos[3]}
                        local belowCenter = vecmath.vDot(vecmath.vSub(impactPos, drone.pos), drone.up) < 0
                        local speed = vecmath.vLen(drone.vel)
                        if belowCenter then
                            drone.lastCollisionKind = 'belly'
                            drone.pos = prevPos
                            drone.vel = {x = 0, y = 0, z = 0}
                            drone.thrust = 0
                            drone.angRate = {p = 0, q = 0, r = 0}
                            drone.grounded = true
                            drone:applyTransform()
                            recorder:captureFrame(drone, receiver.connected)
                        elseif speed >= cfg.crash_prop_speed then
                            drone.lastCollisionKind = 'crash'
                            drone:crash(colPoint, recorder)
                        else
                            drone.lastCollisionKind = 'bump'
                            drone.pos = prevPos
                            drone.vel = {x = 0, y = 0, z = 0}
                            drone:applyTransform()
                            drone:applyStickDebugCandidate(drone.stickCandidateIndex)
                            camera.update()
                            recorder:captureFrame(drone, receiver.connected)
                        end
                    else
                        drone.lastCollisionKind = 'none'
                        drone:applyTransform()
                        drone:applyStickDebugCandidate(drone.stickCandidateIndex)
                        camera.update()
                        recorder:captureFrame(drone, receiver.connected)
                    end
                end
            end
        end
    end
end

function onD3DPresent()
    osd:drawDebugOverlay(drone, cfg, receiver, recorder)
    if drone.spawned then
        osd:draw(drone, cfg, receiver)
        osd:drawSignalInterference(drone)
    end
end

function onScriptTerminate(script, quitGame)
    if script == thisScript() then
        if player:isActive() then player:stop() end
        if drone.spawned then drone:despawn() end
        if ui.cfgDirty then configObj:save() end
        receiver:close()
        audio:shutdown()
    end
end
