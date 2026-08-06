-- mimgui menu: profile CRUD, general settings (keybinds/axes/physics
-- access via the Profiles tab), and the Replay tab (VLC-style transport +
-- saved-flight list). Opened via testCheat(cfg.cheat_menu).
--
-- Key-listen/button-listen capture happens in :processInput(), called from
-- the entry-point's main loop, NOT inside the imgui button handlers -- see
-- startPlayback's own note in replay/player.lua and the pendingPlayback
-- field below: imgui.Button callbacks run inside mimgui's own C render
-- callback, where a blocking wait() (as createFrozenVehicle needs while a
-- model streams in) raises "attempt to yield across C-call boundary".
local ffi = require 'ffi'
local imgui = require 'mimgui'
local new = imgui.new
local Class = require 'class'
local vecmath = require 'vecmath'
local Config = require 'config'
local Recorder = require 'replay.recorder'
local fmt = require 'replay.format'

local UI = Class('UI')

-- eExplosionType (plugin-sdk): the index of each name here, 0-based, IS the
-- enum value passed to addExplosion -- keep the order exactly.
UI.EXPLOSION_TYPES = {
    'Grenade', 'Molotov', 'Rocket', 'Weak rocket', 'Car', 'Quick car',
    'Boat', 'Aircraft', 'Mine', 'Object', 'Tank shell', 'Small', 'RC vehicle',
}

function UI:init(configObj, drone, receiver, recorder, player)
    self.configObj = configObj
    self.cfg = configObj.data
    self.drone = drone
    self.receiver = receiver
    self.recorder = recorder
    self.player = player

    self.show = new.bool(false)
    self.cfgDirty, self.cfgDirtyClock = false, 0

    self.keyListen = nil    -- nil | cfg field name currently being (re)bound
    self.btnListen = nil    -- nil | cfg field name currently being (re)bound
    self.btnListenSnap = 0  -- buttonsRaw at the moment listening started -- only NEW bits count
    self.axisCalib = nil    -- nil | {axis=, min=, max=}
    self.nameAction = nil   -- nil | 'new' | 'duplicate' | 'rename'
    self.nameBuf = new.char[64]('')
    self.pendingPlaybackName = nil -- see the module comment above

    self.floatBufs, self.boolBufs, self.intBufs, self.textBufs = {}, {}, {}, {}

    self.replayFileList = nil -- cached, refreshed on tab-open and via the explicit button
    self.replayLoadNameBuf = new.char[64]('')
    self.scrubBuf = new.float()

    self:buildWindow()
end

function UI:markDirty() self.cfgDirty = true; self.cfgDirtyClock = os.clock() end

function UI:uiSliderFloat(label, tbl, field, mn, mx, format)
    local f = self.floatBufs[label]
    if not f then f = new.float(); self.floatBufs[label] = f end
    f[0] = tbl[field] or 0
    if imgui.SliderFloat(label, f, mn, mx, format or '%.2f') then
        tbl[field] = f[0]
        self:markDirty()
    end
end

function UI:uiCheckbox(label, tbl, field)
    local b = self.boolBufs[label]
    if not b then b = new.bool(); self.boolBufs[label] = b end
    b[0] = tbl[field] and true or false
    if imgui.Checkbox(label, b) then
        tbl[field] = b[0]
        self:markDirty()
    end
end

function UI:uiInputInt(label, tbl, field, step)
    local n = self.intBufs[label]
    if not n then n = new.int(); self.intBufs[label] = n end
    n[0] = tbl[field] or 0
    if imgui.InputInt(label, n, step or 1) then
        tbl[field] = n[0]
        self:markDirty()
    end
end

-- Dropdown over a fixed list of names; tbl[field] stores the 0-based index
-- (matching the game enum the list mirrors).
function UI:uiCombo(label, tbl, field, items)
    local cur = (tbl[field] or 0) + 1
    local preview = items[cur] or tostring(tbl[field])
    if imgui.BeginCombo(label, preview) then
        for i, name in ipairs(items) do
            if imgui.Selectable(name, i == cur) then
                tbl[field] = i - 1
                self:markDirty()
            end
        end
        imgui.EndCombo()
    end
end

-- bufSize must stay constant per label across frames (mimgui char[] arrays
-- are fixed-size) -- callers all use short config strings, 64 is plenty.
function UI:uiInputText(label, tbl, field, bufSize)
    bufSize = bufSize or 64
    local t = self.textBufs[label]
    if not t then t = new.char[bufSize](tbl[field] or ''); self.textBufs[label] = t end
    if imgui.InputText(label, t, bufSize) then
        tbl[field] = ffi.string(t)
        self:markDirty()
    end
end

-- Keyboard-key capture for recall_vk etc.: click the button, then press the
-- physical key you want bound. Polled from :processInput().
function UI:drawKeyBind(label, field)
    local text = (self.keyListen == field) and 'press a key...' or string.format('0x%02X', self.cfg[field])
    if imgui.Button(label .. ': ' .. text .. '##keybind_' .. field) then
        self.keyListen = (self.keyListen == field) and nil or field
    end
end

-- Same idea as drawKeyBind but for a controller button bit -- rising-edge
-- capture, same pattern as tx12.lua's own handleListen().
function UI:drawBtnBind(label, field)
    local bound = self.cfg[field] >= 0
    local text = (self.btnListen == field) and 'flip a switch...' or (bound and ('bit ' .. self.cfg[field]) or 'unbound')
    if imgui.Button(label .. ': ' .. text .. '##btnbind_' .. field) then
        if self.btnListen == field then
            self.btnListen = nil
        else
            self.btnListen = field
            self.btnListenSnap = self.receiver.buttonsRaw
        end
    end
    if bound then
        imgui.SameLine()
        if imgui.SmallButton('Clear##btnbind_' .. field) then
            self.cfg[field] = -1
            self:markDirty()
        end
    end
end

-- Same start/track/finish capture flow as tx12.lua's per-axis calibration --
-- kept independent here since drone.lua has its own cfg.calib.
function UI:drawCalibration()
    imgui.Text('Calibration:')
    imgui.TextDisabled('Sweep the full range, then finish while centered.')
    local axesRaw = self.receiver.axesRaw
    if self.axisCalib then
        local c = self.axisCalib
        imgui.Text(string.format('A%d  min=%d max=%d  (tracks live)', c.axis, c.min, c.max))
        if imgui.Button('Finish (center = current position)') then
            self.cfg.calib[c.axis] = {min = c.min, max = c.max, center = axesRaw[c.axis]}
            self:markDirty()
            self.axisCalib = nil
        end
        imgui.SameLine()
        if imgui.Button('Cancel##calib') then self.axisCalib = nil end
    else
        for i = 1, 8 do
            if imgui.SmallButton('A' .. i .. '##cal') then
                self.axisCalib = {axis = i, min = axesRaw[i], max = axesRaw[i]}
            end
            if i < 8 then imgui.SameLine() end
        end
    end
end

function UI:drawProfilesTab()
    local cfg = self.cfg
    imgui.Text('Active profile: ' .. cfg.active_profile)
    imgui.Separator()

    local names = {}
    for name in pairs(cfg.profiles) do names[#names + 1] = name end
    table.sort(names)

    if imgui.ListBoxHeaderVec2('##profileList', imgui.ImVec2(220, 100)) then
        for _, name in ipairs(names) do
            if imgui.Selectable(name, name == cfg.active_profile) then
                self.configObj:selectProfile(name)
                self:markDirty()
            end
        end
        imgui.ListBoxFooter()
    end

    if imgui.Button('New') then self.nameAction = 'new'; self.nameBuf = new.char[64]('profile') end
    imgui.SameLine()
    if imgui.Button('Duplicate') then self.nameAction = 'duplicate'; self.nameBuf = new.char[64](cfg.active_profile .. '_copy') end
    imgui.SameLine()
    if imgui.Button('Rename') then self.nameAction = 'rename'; self.nameBuf = new.char[64](cfg.active_profile) end
    imgui.SameLine()
    if imgui.Button('Delete') then
        local count = 0
        for _ in pairs(cfg.profiles) do count = count + 1 end
        if count > 1 then
            cfg.profiles[cfg.active_profile] = nil
            self.configObj:selectProfile(cfg.profiles.default and 'default' or next(cfg.profiles))
            self:markDirty()
        end
    end

    if self.nameAction then
        imgui.SetNextItemWidth(200)
        imgui.InputText('##nameAction', self.nameBuf, 64)
        imgui.SameLine()
        if imgui.Button('Confirm##nameAction') then
            local newName = ffi.string(self.nameBuf)
            if #newName > 0 then
                if self.nameAction == 'new' and not cfg.profiles[newName] then
                    local p = Config.defaultProfile()
                    p.name = newName
                    cfg.profiles[newName] = p
                    self.configObj:selectProfile(newName)
                    self:markDirty()
                    self.nameAction = nil
                elseif self.nameAction == 'duplicate' and not cfg.profiles[newName] then
                    local p = Config.deepCopy(cfg.profile)
                    p.name = newName
                    cfg.profiles[newName] = p
                    self.configObj:selectProfile(newName)
                    self:markDirty()
                    self.nameAction = nil
                elseif self.nameAction == 'rename' and (newName == cfg.active_profile or not cfg.profiles[newName]) then
                    if newName ~= cfg.active_profile then
                        cfg.profile.name = newName
                        cfg.profiles[newName] = cfg.profile
                        cfg.profiles[cfg.active_profile] = nil
                        self.configObj:selectProfile(newName)
                        self:markDirty()
                    end
                    self.nameAction = nil
                end
            end
        end
        imgui.SameLine()
        if imgui.Button('Cancel##nameAction') then self.nameAction = nil end
    end

    imgui.Separator()
    imgui.Text('Physics:')
    local prof = cfg.profile
    self:uiSliderFloat('Mass', prof, 'mass', 0.05, 5.0, '%.2f')
    self:uiSliderFloat('Max thrust', prof, 'max_thrust', 1.0, 40.0, '%.1f')
    self:uiSliderFloat('Gravity', prof, 'gravity', 0.0, 20.0, '%.1f')
    imgui.TextDisabled('Drag -- linear / quadratic, fwd/right/up:')
    self:uiSliderFloat('Drag lin fwd', prof.drag_linear, 'fwd', 0, 2, '%.2f')
    self:uiSliderFloat('Drag lin right', prof.drag_linear, 'right', 0, 2, '%.2f')
    self:uiSliderFloat('Drag lin up', prof.drag_linear, 'up', 0, 2, '%.2f')
    self:uiSliderFloat('Drag quad fwd', prof.drag_quadratic, 'fwd', 0, 0.3, '%.3f')
    self:uiSliderFloat('Drag quad right', prof.drag_quadratic, 'right', 0, 0.3, '%.3f')
    self:uiSliderFloat('Drag quad up', prof.drag_quadratic, 'up', 0, 0.3, '%.3f')
    self:uiSliderFloat('Motor tau (s)', prof, 'motor_tau', 0.01, 0.5, '%.3f')
    self:uiSliderFloat('Angular tau (s)', prof, 'angular_tau', 0.01, 0.5, '%.3f')
    self:uiSliderFloat('Rate max (deg/s)', prof, 'rate_max_deg', 50, 1200, '%.0f')
    self:uiSliderFloat('Expo', prof, 'expo', 0, 1, '%.2f')
    self:uiSliderFloat('Deadzone', prof, 'deadzone', 0, 0.3, '%.2f')
    self:uiSliderFloat('Model scale (collision only)', prof, 'model_scale', 0.01, 2.0, '%.2f')
    imgui.Separator()
    self:uiSliderFloat('Ground effect strength', prof, 'ground_effect_strength', 0, 20, '%.1f')
    self:uiSliderFloat('Ground effect radius', prof, 'ground_effect_radius', 0, 5, '%.2f')
    self:uiSliderFloat('Ceiling effect strength', prof, 'ceiling_effect_strength', 0, 20, '%.1f')
    self:uiSliderFloat('Ceiling effect radius', prof, 'ceiling_effect_radius', 0, 5, '%.2f')
end

-- Live-connected controllers, from net.lua's Receiver -- see
-- docs/controller-bridge.md. "Auto" clears cfg.selected_device_id back to
-- -1 (lowest-id live device, or the only one if just one is connected).
function UI:drawControllerPicker()
    local cfg, receiver = self.cfg, self.receiver
    imgui.Text('Controller:')
    local ids = {}
    for id in pairs(receiver.devices) do ids[#ids + 1] = id end
    table.sort(ids)

    if imgui.ListBoxHeaderVec2('##controllerList', imgui.ImVec2(300, 80)) then
        if imgui.Selectable('Auto', cfg.selected_device_id == -1) then
            cfg.selected_device_id = -1
            self:markDirty()
        end
        for _, id in ipairs(ids) do
            local dev = receiver.devices[id]
            local label = string.format('[%d] %s', id, dev.name)
            if imgui.Selectable(label, cfg.selected_device_id == id) then
                cfg.selected_device_id = id
                self:markDirty()
            end
        end
        imgui.ListBoxFooter()
    end

    local active = receiver.effectiveDeviceId
    local activeDev = active and receiver.devices[active]
    if activeDev then
        imgui.TextDisabled(string.format('Active: [%d] %s', active, activeDev.name))
    else
        imgui.TextDisabled('Active: none (no controller detected)')
    end
end

function UI:drawGeneralTab()
    local cfg = self.cfg
    imgui.Text('Connection:')
    self:uiInputInt('UDP port', cfg, 'port')
    self:uiInputInt('Failsafe timeout, ms', cfg, 'failsafe_ms', 50)
    imgui.TextDisabled('Changing the port takes effect after re-running initSocket (script restart).')
    imgui.Separator()

    self:drawControllerPicker()
    imgui.Separator()

    imgui.Text('Cheat phrases:')
    self:uiInputText('Spawn/despawn phrase', cfg, 'cheat_spawn', 32)
    self:uiInputText('Menu phrase', cfg, 'cheat_menu', 32)
    imgui.Separator()

    imgui.Text('Keybinds:')
    self:drawKeyBind('Recall', 'recall_vk')
    imgui.SameLine()
    self:drawBtnBind('Controller', 'recall_btn')
    imgui.Separator()

    imgui.Text('Arm:')
    self:uiCheckbox('Require idle throttle to arm', cfg, 'arm_enabled')
    self:uiSliderFloat('Arm throttle max', cfg, 'arm_throttle_max', 0, 0.5, '%.2f')
    self:uiSliderFloat('Liftoff throttle min (leave grounded state)', cfg, 'liftoff_throttle_min', 0, 0.5, '%.2f')
    imgui.Separator()

    imgui.Text('Axis assignment (1-8):')
    self:uiInputInt('Roll axis', cfg, 'axis_roll')
    self:uiInputInt('Pitch axis', cfg, 'axis_pitch')
    self:uiInputInt('Throttle axis', cfg, 'axis_throttle')
    self:uiInputInt('Yaw axis', cfg, 'axis_yaw')
    self:uiCheckbox('Invert pitch', cfg, 'axis_pitch_invert')
    self:uiCheckbox('Invert yaw', cfg, 'axis_yaw_invert')
    imgui.Separator()
    self:drawCalibration()
    imgui.Separator()

    imgui.Text('Spawn / camera mount:')
    self:uiSliderFloat('Spawn offset forward', cfg, 'spawn_offset_fwd', 0, 10, '%.1f')
    self:uiSliderFloat('Spawn offset up', cfg, 'spawn_offset_up', 0, 5, '%.1f')
    self:uiSliderFloat('Camera mount forward', cfg, 'cam_mount_fwd', -2, 2, '%.2f')
    self:uiSliderFloat('Camera mount up', cfg, 'cam_mount_up', -2, 2, '%.2f')
    self:uiSliderFloat('Camera tilt (deg)', cfg, 'cam_tilt_deg', -45, 45, '%.0f')
    imgui.TextDisabled('Positive = tilt view down, like a real FPV rig.')
    imgui.Separator()

    imgui.Text('Collision / crash:')
    self:uiSliderFloat('Collision ray spread', cfg, 'collision_radius', 0.1, 3.0, '%.2f')
    self:uiSliderFloat('Crash speed threshold (into surface)', cfg, 'crash_prop_speed', 0, 30, '%.1f')
    self:uiCheckbox('Indestructible (bounce instead of crash)', cfg, 'indestructible')
    self:uiSliderFloat('Bounce restitution', cfg, 'bounce_restitution', 0, 1, '%.2f')
    self:uiSliderFloat('Slide friction', cfg, 'slide_friction', 0.2, 10.0, '%.1f')
    self:uiSliderFloat('Slide full-stop speed', cfg, 'slide_stop_speed', 0.1, 5.0, '%.1f')
    self:uiInputText('Crash FX particle name', cfg, 'crash_fx_name', 32)
    self:uiCombo('SP explosion type', cfg, 'crash_explosion_type', UI.EXPLOSION_TYPES)
    self:uiInputInt('Crash cooldown, ms', cfg, 'crash_cooldown_ms', 100)
    self:uiInputInt('Crash view delay, ms', cfg, 'crash_view_delay_ms', 100)
    self:uiCheckbox('Auto-respawn after crash', cfg, 'auto_respawn_after_crash')
    imgui.Separator()

    imgui.Text('Singleplayer (no effect in SAMP):')
    imgui.TextDisabled('Wanted stars accrue naturally (crash explosions count as crimes).')
    self:uiCheckbox('Police can shoot the drone down', cfg, 'sp_bullet_vulnerable')
    self:uiSliderFloat('Drone health', cfg, 'sp_drone_health', 1000, 10000, '%.0f')
    self:uiSliderFloat('Ped density while flying', cfg, 'sp_ped_density', 0, 3, '%.1f')
    self:uiSliderFloat('Traffic density while flying', cfg, 'sp_car_density', 0, 3, '%.1f')
    self:uiCheckbox('Boost population limits (memory patch)', cfg, 'sp_population_boost')
    self:uiInputInt('Max live peds', cfg, 'sp_max_peds', 5)
    self:uiInputInt('Max live cars', cfg, 'sp_max_cars', 5)
    self:uiCheckbox('No despawn around the drone', cfg, 'sp_no_despawn')
    self:uiSliderFloat('No-despawn radius', cfg, 'sp_keep_radius', 50, 500, '%.0f')
    imgui.TextDisabled('Applied on spawn, restored on despawn.')
    imgui.Separator()

    imgui.Text('Wind:')
    self:uiCheckbox('Enabled', cfg, 'wind_enabled')
    self:uiSliderFloat('Direction (deg)', cfg, 'wind_dir_deg', 0, 360, '%.0f')
    self:uiSliderFloat('Strength', cfg, 'wind_strength', 0, 20, '%.1f')
    self:uiSliderFloat('Turbulence', cfg, 'wind_turbulence', 0, 20, '%.1f')
    imgui.Separator()

    imgui.Text('Signal interference (visual only):')
    self:uiSliderFloat('Clear range', cfg, 'signal_clear_range', 0, 300, '%.0f')
    self:uiSliderFloat('Dead range', cfg, 'signal_dead_range', 0, 2000, '%.0f')
    imgui.Separator()

    imgui.Text('Flight mode: ' .. cfg.flight_mode .. (cfg.throttle_3d and ' + 3D throttle' or ''))
    self:drawKeyBind('Cycle ACRO/LEVEL/HORIZON', 'flight_mode_cycle_vk')
    imgui.SameLine()
    self:drawBtnBind('Controller', 'flight_mode_cycle_btn')
    self:drawKeyBind('Toggle 3D throttle', 'throttle_3d_toggle_vk')
    imgui.SameLine()
    self:drawBtnBind('Controller', 'throttle_3d_toggle_btn')
    self:uiSliderFloat('LEVEL max angle (deg)', cfg, 'level_max_angle_deg', 10, 80, '%.0f')
    self:uiSliderFloat('LEVEL/HORIZON gain', cfg, 'level_gain', 1, 20, '%.1f')
    self:uiSliderFloat('HORIZON blend start (stick frac)', cfg, 'horizon_blend_start', 0.1, 0.95, '%.2f')
    imgui.Separator()

    imgui.Text('Motor audio:')
    self:uiCheckbox('Enabled', cfg, 'audio_enabled')
    self:uiSliderFloat('Max range', cfg, 'audio_max_range', 10, 500, '%.0f')
    self:uiSliderFloat('Max volume (>1 amplifies)', cfg, 'audio_vol_max', 0, 3, '%.2f')
    self:uiSliderFloat('Pitch at idle', cfg, 'audio_pitch_min', 0.2, 1.5, '%.2f')
    self:uiSliderFloat('Pitch at full throttle', cfg, 'audio_pitch_max', 0.5, 3.0, '%.2f')
end

function UI:refreshReplayFileList() self.replayFileList = Recorder.listFiles() end

local function formatPlaybackTime(s)
    s = math.max(0, s)
    return string.format('%d:%02d', math.floor(s / 60), math.floor(s) % 60)
end

local REPLAY_SPEEDS = {0.25, 0.5, 1.0, 2.0, 4.0}

function UI:drawReplayTab()
    local player, recorder, cfg = self.player, self.recorder, self.cfg
    if player:isActive() then
        imgui.Text(string.format('%s / %s   frame %d/%d', formatPlaybackTime(player.playbackTime),
            formatPlaybackTime(player.durationSec), player.idx + 1, player.count))

        self.scrubBuf[0] = player.playbackTime
        imgui.SetNextItemWidth(400)
        -- Player:tick() re-derives idx from playbackTime every tick regardless
        -- of pause state, so dragging this immediately moves the drone --
        -- scrubbing doubles as a seek, no separate "commit" step.
        if imgui.SliderFloat('##scrub', self.scrubBuf, 0, math.max(player.durationSec, 0.001), '') then
            player:seek(self.scrubBuf[0])
        end

        if imgui.Button(player.paused and 'Play' or 'Pause') then player.paused = not player.paused end
        imgui.SameLine()
        if imgui.Button('<< 5s') then player:seek(player.playbackTime - 5) end
        imgui.SameLine()
        if imgui.Button('5s >>') then player:seek(player.playbackTime + 5) end
        imgui.SameLine()
        if imgui.Button('Restart') then player:seek(0); player.paused = false end

        imgui.Text('Speed:')
        for _, s in ipairs(REPLAY_SPEEDS) do
            imgui.SameLine()
            local sTxt = string.format('%g', s) -- %g drops trailing .0 (1.0 -> "1", 0.25 stays "0.25")
            local label = (s == player.speed) and ('[' .. sTxt .. 'x]') or (sTxt .. 'x')
            if imgui.SmallButton(label) then player.speed = s end
        end

        imgui.Separator()
        if imgui.Button('Stop playback') then self.despawnRequested = true end
        return
    end

    if self.drone.spawned then
        imgui.Text(string.format('Recording: %d/%d frames buffered', recorder.count, recorder.capacity))
    elseif recorder.count > 0 then
        imgui.Text(string.format('Last flight: %d frames buffered', recorder.count))
    else
        imgui.Text('No recording yet.')
    end
    imgui.Separator()

    imgui.Text('Capture settings:')
    self:uiInputInt('Ring buffer frames', cfg, 'replay_ring_frames', 1000)
    cfg.replay_ring_frames = vecmath.clamp(cfg.replay_ring_frames, 100, 120000)
    self:uiInputInt('Max entities/frame', cfg, 'replay_max_entities', 4)
    cfg.replay_max_entities = vecmath.clamp(cfg.replay_max_entities, 0, fmt.MAX_ENTITIES)
    self:uiSliderFloat('Capture radius', cfg, 'replay_capture_radius', 20, 400, '%.0f')
    local estMB = (50 + cfg.replay_max_entities * 23) * cfg.replay_ring_frames / 1e6
    imgui.TextDisabled(string.format('~%.1f MB, takes effect on next spawn', estMB))
    imgui.Separator()

    self:drawKeyBind('Save replay', 'replay_save_vk')
    imgui.SameLine()
    if imgui.Button('Save current flight') then recorder:save() end
    imgui.Separator()

    imgui.Text('Saved flights:')
    if imgui.Button('Refresh list') then self:refreshReplayFileList() end
    if not self.replayFileList then self:refreshReplayFileList() end

    if self.replayFileList and #self.replayFileList > 0 then
        for _, name in ipairs(self.replayFileList) do
            imgui.Text(name)
            imgui.SameLine()
            if imgui.Button('Play##' .. name) then self.pendingPlaybackName = name end
            imgui.SameLine()
            if imgui.Button('Delete##' .. name) then
                os.remove(Recorder.DIR .. '\\' .. name)
                self:refreshReplayFileList()
            end
        end
    else
        imgui.TextDisabled('No saved flights listed (or listing unavailable) -- load by exact filename:')
        imgui.SetNextItemWidth(220)
        imgui.InputText('##loadByName', self.replayLoadNameBuf, 64)
        imgui.SameLine()
        if imgui.Button('Load by name') then self.pendingPlaybackName = ffi.string(self.replayLoadNameBuf) end
    end
end

function UI:buildWindow()
    imgui.OnFrame(function() return self.show[0] end, function()
        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(460, 620), imgui.Cond.FirstUseEver)
        if imgui.Begin('FPV Drone Config', self.show) then
            if imgui.BeginTabBar('##tabs') then
                if imgui.BeginTabItem('Profiles') then self:drawProfilesTab(); imgui.EndTabItem() end
                if imgui.BeginTabItem('General') then self:drawGeneralTab(); imgui.EndTabItem() end
                if imgui.BeginTabItem('Replay') then self:drawReplayTab(); imgui.EndTabItem() end
                imgui.EndTabBar()
            end
        end
        imgui.End()
    end)
end

function UI:toggle() self.show[0] = not self.show[0] end

-- Key/button-listen capture and the config-dirty autosave debounce -- called
-- once per main-loop tick, outside any imgui callback (see the module
-- comment for why key capture can't happen inside imgui.Button handlers
-- directly for anything that also needs to spawn/despawn -- kept here too
-- for consistency even though key/button capture itself doesn't yield).
function UI:processInput()
    if self.keyListen then
        for vk = 1, 254 do
            if isKeyJustPressed(vk) then
                self.cfg[self.keyListen] = vk
                self:markDirty()
                self.keyListen = nil
                break
            end
        end
    end

    if self.btnListen then
        local newBits = bit.band(self.receiver.buttonsRaw, bit.bnot(self.btnListenSnap))
        if newBits ~= 0 then
            local bitIdx = 0
            while bit.band(newBits, bit.lshift(1, bitIdx)) == 0 do bitIdx = bitIdx + 1 end
            self.cfg[self.btnListen] = bitIdx
            self:markDirty()
            self.btnListen = nil
        end
    end

    if self.cfgDirty and os.clock() - self.cfgDirtyClock > 1.0 then
        self.cfgDirty = false
        self.configObj:save()
    end
end

-- Consumed by the entry-point's main loop, which calls Player:start() from
-- its own (non-imgui-callback) context -- see the module comment.
function UI:consumePendingPlayback()
    local name = self.pendingPlaybackName
    self.pendingPlaybackName = nil
    return name
end

-- Set by the Replay tab's "Stop playback" button (same yield-boundary
-- reason as pendingPlaybackName) -- consumed by the entry-point.
function UI:consumeDespawnRequest()
    local r = self.despawnRequested
    self.despawnRequested = false
    return r
end

return UI
