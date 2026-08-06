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
local OSD2 = require 'osd2'
local SPExtras = require 'sp'
local UI = require 'ui'
local updateCheck = require 'update_check'
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
local sp = SPExtras.new(cfg)
local ui = UI.new(configObj, drone, receiver, recorder, player)
local osd2 = OSD2.new(cfg, osd, drone, player) -- draws itself via its own imgui frame

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
    updateCheck.check()
    audio:load()
    osd:createFont()

    local lastTick = os.clock()

    while true do
        wait(0)
        receiver:poll()
        ui:processInput()

        local pendingName = ui:consumePendingPlayback()
        if pendingName then player:start(pendingName, drone) end
        if ui:consumeStopRequest() then despawnAll() end

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
                elseif drone:spawn(receiver, recorder, player:isActive()) then
                    sp:onSpawn(drone)
                end
            end
            if testCheat(cfg.cheat_menu) then
                ui:toggle()
            end
        end

        if autoRespawnPending and not drone.spawned and (os.clock() - drone.lastCrashClock) * 1000 >= cfg.crash_cooldown_ms then
            if drone:spawn(receiver, recorder, player:isActive()) then
                autoRespawnPending = false
                sp:onSpawn(drone)
            end
        end

        -- State-follow instead of hooking every despawn path (manual toggle,
        -- crash's finishCrash, replay start, script errors) -- whenever the
        -- drone is gone, SP effects must be rolled back.
        if sp.active and not drone.spawned then sp:onDespawn() end

        -- Shared by both branches below (live flight and replay playback).
        local now = os.clock()
        local dt = vecmath.clamp(now - lastTick, 0, 0.1) -- clamp to avoid a huge step after a hitch/pause
        lastTick = now

        if player:isActive() then
            -- Video-player hotkeys, active for the whole replay session.
            if isKeyJustPressed(0x20) then player.paused = not player.paused end -- space
            if isKeyJustPressed(0x25) then player:seek(player.playbackTime - 5) end -- left
            if isKeyJustPressed(0x27) then player:seek(player.playbackTime + 5) end -- right
            if isKeyJustPressed(0x26) then player.speed = math.min(4, player.speed * 2) end -- up
            if isKeyJustPressed(0x28) then player.speed = math.max(0.25, player.speed / 2) end -- down
            if isKeyJustPressed(0xBC) then player.paused = true; player:seek(player.playbackTime - 1 / 30) end -- ,
            if isKeyJustPressed(0xBE) then player.paused = true; player:seek(player.playbackTime + 1 / 30) end -- .
            if not isPauseMenuActive() then
                player:tick(dt, drone, camera, osd)
            end
        elseif drone.spawned then
            if isKeyJustPressed(cfg.recall_vk) or receiver:btnJustPressed(cfg.recall_btn) then
                drone:recall()
            end
            -- ARM/DISARM: motor kill switch, like a real quad. Disarm cuts
            -- motors instantly (it falls, keeping its tumble); re-arm goes
            -- through the same throttle-at-idle gate as spawning.
            if (cfg.arm_toggle_vk > 0 and isKeyJustPressed(cfg.arm_toggle_vk))
                or receiver:btnJustPressed(cfg.arm_toggle_btn) then
                if drone.armed then
                    drone.armed = false
                    drone.thrust = 0
                    drone.audio:stop()
                else
                    local thr = vecmath.axisUni(cfg.calib, receiver.axesRaw, cfg.axis_throttle)
                    if not cfg.arm_enabled or thr <= cfg.arm_throttle_max then
                        drone.armed = true
                        drone.audio:start()
                    end
                end
            end
            if isKeyJustPressed(0x46) then -- 'F', see collision.lua's STICK_CANDIDATES
                drone.stickCandidateIndex = (drone.stickCandidateIndex % #Drone.STICK_CANDIDATES) + 1
            end
            if isKeyJustPressed(0xBD) then cfg.profile.model_scale = vecmath.clamp(cfg.profile.model_scale - 0.1, 0.01, 2.0) end -- '-'
            if isKeyJustPressed(0xBB) then cfg.profile.model_scale = vecmath.clamp(cfg.profile.model_scale + 0.1, 0.01, 2.0) end -- '='
            -- Held, not just-pressed: the tilt glides at a smooth per-second
            -- rate in sub-degree steps instead of 1-degree clicks.
            local TILT_RATE = 25.0 -- deg/s
            if isKeyDown(0x26) then cfg.cam_tilt_deg = vecmath.clamp(cfg.cam_tilt_deg + TILT_RATE * dt, -45, 45) end -- Up arrow
            if isKeyDown(0x28) then cfg.cam_tilt_deg = vecmath.clamp(cfg.cam_tilt_deg - TILT_RATE * dt, -45, 45) end -- Down arrow

            -- Flight mode / 3D-throttle switches: keyboard key OR controller
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
                if sp:tick(drone) then
                    -- Shot down by police -- crash in place.
                    drone.lastCollisionKind = 'crash'
                    drone:crash({pos = {drone.pos.x, drone.pos.y, drone.pos.z}}, recorder)
                end
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
                    if receiver.connected and drone.armed
                        and vecmath.axisUni(cfg.calib, receiver.axesRaw, cfg.axis_throttle) > cfg.liftoff_throttle_min then
                        drone.grounded = false
                    end
                    drone:applyTransform()
                    drone:applyStickDebugCandidate(drone.stickCandidateIndex)
                    camera.update()
                    recorder:captureFrame(drone, receiver.connected, receiver)
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
                        -- Belly = the hit surface faces the drone's underside:
                        -- its normal points along the drone's own up axis
                        -- (within ~45 deg). Classified by the surface NORMAL,
                        -- not by where the impact point sits relative to
                        -- drone.pos -- by the time the ray reports a hit,
                        -- drone.pos has already moved past the surface, which
                        -- puts the impact point on the wrong side of it and
                        -- inverts any position-based test. See docs/collision.md.
                        local n = {x = colPoint.normal[1], y = colPoint.normal[2], z = colPoint.normal[3]}
                        local bellyHit = vecmath.vDot(n, drone.up) > 0.7
                        -- Impact severity = the velocity component INTO the
                        -- surface, not total speed -- grazing a wall or pole
                        -- while moving mostly parallel to it is a scrape, not
                        -- a crash. Belly contact never crashes at any speed.
                        local intoSurface = -vecmath.vDot(drone.vel, n)
                        if not bellyHit and intoSurface >= cfg.crash_prop_speed and cfg.indestructible then
                            -- Rubber mode: a crash-grade impact reflects the
                            -- velocity off the surface instead of exploding,
                            -- keeping bounce_restitution of the approach speed.
                            drone.lastCollisionKind = 'bounce'
                            local vn = vecmath.vDot(drone.vel, n)
                            drone.vel = vecmath.vSub(drone.vel, vecmath.vScale(n, (1 + cfg.bounce_restitution) * vn))
                            drone.pos = prevPos
                            drone:applyTransform()
                            drone:applyStickDebugCandidate(drone.stickCandidateIndex)
                            camera.update()
                            recorder:captureFrame(drone, receiver.connected, receiver)
                        elseif not bellyHit and intoSurface >= cfg.crash_prop_speed then
                            drone.lastCollisionKind = 'crash'
                            drone:crash(colPoint, recorder)
                        else
                            -- Surviving contact: kill the approach velocity
                            -- (the normal component, only when directed INTO
                            -- the surface -- movement away must never be
                            -- stripped, or climbing off the surface becomes
                            -- impossible), keep the tangential one with
                            -- friction, and let the frame's own displacement
                            -- continue along the surface -- the drone skids
                            -- like a real quad on its belly instead of
                            -- stopping dead. A belly slide below
                            -- slide_stop_speed settles into the grounded
                            -- resting state.
                            local slideFactor = math.exp(-cfg.slide_friction * dt)
                            local vn = vecmath.vDot(drone.vel, n)
                            if vn < 0 then
                                drone.vel = vecmath.vSub(drone.vel, vecmath.vScale(n, vn))
                            end
                            drone.vel = vecmath.vScale(drone.vel, slideFactor)
                            local disp = vecmath.vSub(drone.pos, prevPos)
                            local dn = vecmath.vDot(disp, n)
                            if dn < 0 then
                                disp = vecmath.vSub(disp, vecmath.vScale(n, dn))
                            end
                            local newPos = vecmath.vAdd(prevPos, vecmath.vScale(disp, slideFactor))
                            -- Hold the center at the same clearance the ray
                            -- spread detects contact at. Between collision
                            -- ticks a slide sinks by gravity micro-steps too
                            -- small to cross the surface and fire a hit, and
                            -- each such tick permanently lowers the baseline --
                            -- without this push-out the drone ratchets a few
                            -- mm per tick down through the texture and ends up
                            -- resting visibly sunk into the ground.
                            local clearance = cfg.collision_radius * cfg.profile.model_scale
                            local colPos = {x = colPoint.pos[1], y = colPoint.pos[2], z = colPoint.pos[3]}
                            local depth = vecmath.vDot(vecmath.vSub(newPos, colPos), n)
                            if depth < clearance then
                                newPos = vecmath.vAdd(newPos, vecmath.vScale(n, clearance - depth))
                            end
                            drone.pos = newPos
                            if bellyHit and vecmath.vLen(drone.vel) < cfg.slide_stop_speed then
                                drone.lastCollisionKind = 'belly'
                                drone.vel = {x = 0, y = 0, z = 0}
                                drone.thrust = 0
                                drone.angRate = {p = 0, q = 0, r = 0}
                                drone.grounded = true
                                drone:applyTransform()
                                recorder:captureFrame(drone, receiver.connected, receiver)
                            else
                                drone.lastCollisionKind = 'slide'
                                drone:applyTransform()
                                drone:applyStickDebugCandidate(drone.stickCandidateIndex)
                                camera.update()
                                recorder:captureFrame(drone, receiver.connected, receiver)
                            end
                        end
                    else
                        drone.lastCollisionKind = 'none'
                        drone:applyTransform()
                        drone:applyStickDebugCandidate(drone.stickCandidateIndex)
                        camera.update()
                        recorder:captureFrame(drone, receiver.connected, receiver)
                    end
                end
            end
        end
    end
end

function onD3DPresent()
    osd:drawDebugOverlay(drone, cfg, receiver, recorder)
    if drone.spawned then
        if cfg.osd_style == 'classic' then -- the other styles draw via osd2's imgui frame
            osd:draw(drone)
            osd:drawRecIndicator()
            osd:drawHpIndicator()
        end
        osd:drawSignalInterference(drone)
    end
end

function onScriptTerminate(script, quitGame)
    if script == thisScript() then
        if player:isActive() then player:stop() end
        if drone.spawned then drone:despawn() end
        sp:onDespawn()
        if ui.cfgDirty then configObj:save() end
        receiver:close()
        audio:shutdown()
    end
end
