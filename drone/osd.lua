-- On-screen display: Liftoff-style horizon/attitude indicator, telemetry
-- text, thrust-breakdown + vario panels, signal-interference overlay, and
-- the pre-OSD debug overlay. Reads a single `telemetry` table populated
-- either live or from a replay frame, so drawing code never needs to know
-- which source it's looking at -- see docs/replay.md "osdTelemetry" for why
-- this indirection exists (it also fixes a real live-only bug).
local Class = require 'class'
local vecmath = require 'vecmath'
-- 'collision' (not just 'drone') to guarantee Drone.STICK_CANDIDATES is
-- attached regardless of what else has been required so far -- see
-- drawDebugOverlay below.
local Drone = require 'collision'
local clamp, vLen, vSub = vecmath.clamp, vecmath.vLen, vecmath.vSub

local OSD = Class('OSD')

local PITCH_LADDER_DEGS = {-40, -20, 20, 40}
local THRUST_BREAKDOWN_SCALE = 30
local THRUST_BREAKDOWN_ROWS = {
    {'THR', 'thrustAccel', 0xFF40E0FF},
    {'GRAV', 'gravity', 0xFFE05050},
    {'DRAG', 'dragUp', 0xFFFFA040},
    {'GND', 'ground', 0xFF50E070},
    {'CEIL', 'ceiling', 0xFF50E070},
    {'WIND', 'windZ', 0xFFC060FF},
}
local VARIO_SCALE = 25.0 -- m/s at the very top/bottom of the bar

function OSD:init(cfg)
    self.cfg = cfg
    self.font = nil
    self.telemetry = {
        armed = false, grounded = false, connected = false,
        flightMode = 'ACRO', throttle3d = false,
        vel = {x = 0, y = 0, z = 0},
        thrust = 0, thrustAccel = 0, gravity = 0, dragUp = 0, ground = 0, ceiling = 0, windZ = 0, accelZ = 0,
        profileName = '', profileMass = 0, profileMaxThrust = 0,
        flightElapsed = 0,
        recording = false, replaying = false, replayCount = 0, replayCapacity = 0,
        recordedSec = 0,
        -- Raw normalized stick position for the stick-position boxes --
        -- see docs/replay.md for why these go through telemetry too (a
        -- replay must show the recorded sticks, not whatever the live
        -- controller happens to be doing right now).
        stickRoll = 0, stickPitch = 0, stickYaw = 0, stickThrottle = 0,
    }
end

function OSD:createFont()
    self.font = renderCreateFont('Arial', 9, 5)
end

-- drone: drone.Drone. receiver: net.Receiver. recorder: replay.Recorder.
function OSD:syncLive(drone, receiver, recorder)
    local t = self.telemetry
    t.armed, t.grounded, t.connected = drone.armed, drone.grounded, receiver.connected
    t.flightMode, t.throttle3d = self.cfg.flight_mode, self.cfg.throttle_3d
    t.vel.x, t.vel.y, t.vel.z = drone.vel.x, drone.vel.y, drone.vel.z
    t.thrust = drone.thrust
    local dbg = drone.lastPhysicsDebug
    t.thrustAccel = dbg.thrust
    t.gravity = dbg.gravity
    t.dragUp = dbg.dragUp
    t.ground = dbg.ground
    t.ceiling = dbg.ceiling
    t.windZ = dbg.windZ
    t.accelZ = dbg.accelZ
    t.profileName = self.cfg.profile.name
    t.profileMass = self.cfg.profile.mass
    t.profileMaxThrust = self.cfg.profile.max_thrust
    t.flightElapsed = os.clock() - drone.flightStartClock
    t.recording = recorder.recording
    t.replaying = false
    t.replayCount = recorder.count
    t.replayCapacity = recorder.capacity
    t.recordedSec = recorder:bufferedSeconds()
    -- Drone HP, 1.0 at full pool down to 0.0 at sp.lua's crash-out
    -- threshold (350). nil = damage isn't a thing right now (SAMP or
    -- invulnerable) and the OSD hides its HP element.
    if not isSampAvailable() and self.cfg.sp_bullet_vulnerable
        and drone.obj and doesVehicleExist(drone.obj) then
        t.hp = vecmath.clamp((getCarHealth(drone.obj) - 350)
            / math.max(1, self.cfg.sp_drone_health - 350), 0, 1)
    else
        t.hp = nil
    end
    local calib, axesRaw = self.cfg.calib, receiver.axesRaw
    t.stickRoll = vecmath.axisBi(calib, axesRaw, self.cfg.axis_roll)
    t.stickPitch = vecmath.axisBi(calib, axesRaw, self.cfg.axis_pitch)
    t.stickYaw = vecmath.axisBi(calib, axesRaw, self.cfg.axis_yaw)
    t.stickThrottle = vecmath.axisUni(calib, axesRaw, self.cfg.axis_throttle)
end

-- Cosmetic only -- roll/pitch here are extracted from the body basis purely
-- for display, no bearing on the physics (which stays basis-vector-based to
-- avoid gimbal lock).
local function attitudeDeg(drone)
    local pitch = math.asin(clamp(drone.fwd.z, -1, 1))
    local roll = math.atan2(drone.right.z, drone.up.z)
    return math.deg(pitch), math.deg(roll)
end

local function headingDeg(drone)
    local h = math.deg(math.atan2(-drone.fwd.x, drone.fwd.y)) -- same convention as heading elsewhere (fwdX=-sin(h))
    if h < 0 then h = h + 360 end
    return h
end

local function drawDashedLine(x1, y1, x2, y2, width, color, dashPx)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return end
    local nx, ny = dx / len, dy / len
    local pos, draw = 0, true
    while pos < len do
        local segLen = math.min(dashPx, len - pos)
        if draw then
            renderDrawLine(x1 + nx * pos, y1 + ny * pos, x1 + nx * (pos + segLen), y1 + ny * (pos + segLen), width, color)
        end
        pos = pos + segLen
        draw = not draw
    end
end

local function drawStickBox(cx, cy, size, xVal, yVal, color)
    renderDrawBoxWithBorder(cx - size / 2, cy - size / 2, size, size, 0x22FFFFFF, 1.5, 0xFFFFFFFF)
    local dotX = cx + clamp(xVal, -1, 1) * (size / 2 - 4)
    local dotY = cy - clamp(yVal, -1, 1) * (size / 2 - 4) -- screen y is inverted, flip so "up" reads as up
    renderDrawBox(dotX - 3, dotY - 3, 6, 6, color)
end

-- value/scale -> a bipolar mini bar (grows left or right from a center zero
-- marker). Used by the thrust breakdown panel -- reads telemetry, so it's
-- correct in replay too.
local function drawMiniBar(x, y, w, h, value, scale, color)
    renderDrawBox(x, y, w, h, 0x33FFFFFF)
    local center = x + w / 2
    local frac = clamp(value / scale, -1, 1)
    local barW = math.abs(frac) * (w / 2)
    renderDrawBox(frac >= 0 and center or (center - barW), y, barW, h, color)
    renderDrawLine(center, y, center, y + h, 1, 0xFFFFFFFF)
end

function OSD:drawThrustBreakdown(x, y)
    for i, row in ipairs(THRUST_BREAKDOWN_ROWS) do
        local label, field, color = row[1], row[2], row[3]
        local v = self.telemetry[field]
        local ry = y + (i - 1) * 15
        renderFontDrawText(self.font, label, x, ry, 0xFFFFFFFF)
        drawMiniBar(x + 38, ry + 2, 64, 8, v, THRUST_BREAKDOWN_SCALE, color)
        renderFontDrawText(self.font, string.format('%.1f', v), x + 106, ry, 0xFFAAAAAA)
    end
    renderFontDrawText(self.font, string.format('= %.1f', self.telemetry.accelZ), x + 38,
        y + #THRUST_BREAKDOWN_ROWS * 15 + 2, 0xFFFFD040)
end

-- Real-FPV-OSD-style vario: a vertical scale with a marker sliding up/down
-- from center by vertical speed, plus the signed number.
function OSD:drawVario(x, y, height)
    renderDrawBox(x, y, 6, height, 0x33FFFFFF)
    local center = y + height / 2
    renderDrawLine(x - 4, center, x + 12, center, 1.5, 0xFFFFFFFF)
    local vz = clamp(self.telemetry.vel.z, -VARIO_SCALE, VARIO_SCALE)
    local markerY = center - (vz / VARIO_SCALE) * (height / 2)
    local color = vz >= 0 and 0xFF50E070 or 0xFFE05050
    renderDrawBox(x - 6, markerY - 3, 20, 6, color)
    renderFontDrawText(self.font, string.format('%+.1f', self.telemetry.vel.z), x - 34, markerY - 16, color)
end

-- drone: for decoyPed/pos (ALT/DIST readouts) and attitude/heading. All
-- other values, including stick position, come from self.telemetry.
function OSD:draw(drone)
    if not self.font then return end
    local t = self.telemetry
    local resX, resY = getScreenResolution()
    local cx, cy = resX / 2, resY / 2
    local pitchDeg, rollDeg = attitudeDeg(drone)
    local rollRad = math.rad(rollDeg)
    local cosR, sinR = math.cos(rollRad), math.sin(rollRad)
    local pxPerDeg = 4.0

    local function rungOffset(rungPitchDeg) return (pitchDeg - rungPitchDeg) * pxPerDeg end

    local halfLen = 140
    local dx, dy = cosR * halfLen, sinR * halfLen
    local mainOffset = rungOffset(0)
    renderDrawLine(cx - dx, cy + mainOffset - dy, cx + dx, cy + mainOffset + dy, 2.0, 0xFF40E0FF)

    local rungHalfLen = 70
    local rdx, rdy = cosR * rungHalfLen, sinR * rungHalfLen
    for _, rungDeg in ipairs(PITCH_LADDER_DEGS) do
        local off = rungOffset(rungDeg)
        if math.abs(off) < resY then -- skip rungs scrolled far off-screen
            drawDashedLine(cx - rdx, cy + off - rdy, cx + rdx, cy + off + rdy, 1.5, 0xAA40E0FF, 10)
        end
    end

    -- Fixed aircraft reference at true screen center, doesn't rotate/move.
    renderDrawLine(cx - 14, cy, cx - 4, cy, 2.0, 0xFFFFD040)
    renderDrawLine(cx + 4, cy, cx + 14, cy, 2.0, 0xFFFFD040)
    renderDrawBox(cx - 1, cy - 1, 2, 2, 0xFFFFD040)

    -- Compass strip along the top, current heading centered.
    local heading = headingDeg(drone)
    local compassSpan, compassPxPerDeg = 60, 3
    local topY = 40
    renderDrawLine(cx - compassSpan * compassPxPerDeg, topY, cx + compassSpan * compassPxPerDeg, topY, 1.5, 0xFFFFFFFF)
    for deg = -compassSpan, compassSpan, 15 do
        local worldDeg = (heading + deg) % 360
        local x = cx + deg * compassPxPerDeg
        local nearestCardinal = math.floor(worldDeg / 90 + 0.5) % 4
        local isCardinal = math.abs(worldDeg - nearestCardinal * 90) < 1.0 or math.abs(worldDeg - 360) < 1.0
        renderDrawLine(x, topY, x, topY - (isCardinal and 10 or 5), 1.5, 0xFFFFFFFF)
        if isCardinal then
            local label = ({[0] = 'N', [1] = 'E', [2] = 'S', [3] = 'W'})[nearestCardinal]
            renderFontDrawText(self.font, label, x - 3, topY - 24, 0xFFFFD040)
        end
    end
    renderDrawLine(cx, topY + 2, cx, topY + 12, 2.0, 0xFFFFD040)
    renderFontDrawText(self.font, string.format('%03d', math.floor(heading)), cx - 12, topY + 14, 0xFFFFFFFF)

    -- Telemetry text -- sourced from `telemetry` (not drone.*/connected
    -- directly), see docs/replay.md "osdTelemetry".
    local speed = vLen(t.vel)
    local altitude, dist = 0, 0
    if drone.decoyPed and doesCharExist(drone.decoyPed) then
        local px, py, pz = getCharCoordinates(drone.decoyPed)
        altitude = drone.pos.z - pz
        dist = vLen(vSub(drone.pos, {x = px, y = py, z = pz}))
    end
    renderFontDrawText(self.font, string.format('SPD %.0f', speed), cx - 220, resY - 68, 0xFFFFFFFF)
    renderFontDrawText(self.font, string.format('ALT %.0f', altitude), cx - 220, resY - 54, 0xFFFFFFFF)
    renderFontDrawText(self.font, string.format('DIST %.0f', dist), cx + 150, resY - 54, 0xFFFFFFFF)

    renderFontDrawText(self.font, t.grounded and 'LANDED' or (t.armed and 'ARMED' or 'DISARMED'),
        cx - 220, resY - 40, t.grounded and 0xFFFFD040 or (t.armed and 0xFF40E050 or 0xFFE04040))
    local modeText = 'MODE: ' .. t.flightMode .. (t.throttle3d and '+3D' or '')
    renderFontDrawText(self.font, modeText, cx - 220, resY - 26, 0xFFFFFFFF)
    renderFontDrawText(self.font, t.connected and 'SIGNAL OK' or 'NO SIGNAL', cx + 150, resY - 40,
        t.connected and 0xFF40E050 or 0xFFE04040)

    self:drawThrustBreakdown(20, cy - 60)
    self:drawVario(resX - 40, cy - 90, 180)

    -- Profile + flight timer + REC/REPLAY indicator, top-right.
    local elapsed = math.max(0, t.flightElapsed)
    local timeStr = string.format('%d:%02d', math.floor(elapsed / 60), math.floor(elapsed) % 60)
    renderFontDrawText(self.font, t.profileName:upper(), resX - 150, 20, 0xFFFFD040)
    renderFontDrawText(self.font, timeStr, resX - 150, 34, 0xFFFFFFFF)
    if t.replaying then
        renderFontDrawText(self.font, 'REPLAY', resX - 150, 48, 0xFF40C0FF)
    elseif t.recording then
        local blink = math.floor(os.clock() * 2) % 2 == 0 -- ~1Hz blink, like a real camera's REC dot
        renderFontDrawText(self.font, (blink and 'REC ' or '   ') .. t.replayCount .. '/' .. t.replayCapacity,
            resX - 150, 48, 0xFFE05050)
    end

    -- Stick position boxes, bottom center: left = yaw/throttle, right =
    -- roll/pitch. Shows the raw normalized stick position (not the
    -- flight-inverted control values), like a real TX/goggle OSD -- read
    -- from telemetry, not the live receiver, so a replay shows the
    -- recorded sticks instead of whatever the controller is doing right now.
    local boxSize, gap = 56, 12
    local stickY = resY - 90
    drawStickBox(cx - gap / 2 - boxSize / 2, stickY, boxSize, t.stickYaw, t.stickThrottle * 2 - 1, 0xFF40E0FF)
    drawStickBox(cx + gap / 2 + boxSize / 2, stickY, boxSize, t.stickRoll, t.stickPitch, 0xFF40E0FF)
end

local function grayColor(alpha, shade) return bit.lshift(alpha, 24) + shade * 0x010101 end

-- Distance-only static/noise, separate from the real UDP failsafe. Distance
-- is measured from the decoy ped (where the pilot is actually still
-- standing), not PLAYER_PED (that handle is the drone itself while flying).
function OSD:drawSignalInterference(drone)
    if not (drone.decoyPed and doesCharExist(drone.decoyPed)) then return end
    local cfg = self.cfg
    local px, py, pz = getCharCoordinates(drone.decoyPed)
    local dist = vLen(vSub(drone.pos, {x = px, y = py, z = pz}))
    if dist <= cfg.signal_clear_range then return end

    local resX, resY = getScreenResolution()
    local t = clamp((dist - cfg.signal_clear_range) / (cfg.signal_dead_range - cfg.signal_clear_range), 0, 1)

    renderDrawBox(0, 0, resX, resY, grayColor(math.floor(180 * t), 0))

    -- Bar count grows continuously with distance (t^2 so it's gentle near
    -- signal_clear_range, dense near signal_dead_range). Capped at 600 only
    -- for frame-time sanity, not as a visual ceiling.
    local count = math.floor(math.min(t * t * 600, 600))
    for _ = 1, count do
        local fullWidth = math.random() < 0.5
        local w = fullWidth and resX or math.random(80, 400)
        local h = math.random(2, 10)
        local x = fullWidth and 0 or math.random(0, resX)
        local y = math.random(0, resY)
        renderDrawBox(x, y, w, h, grayColor(math.floor(math.random(60, 255) * t), math.random(0, 255)))
    end

    -- Near total loss: occasional full-screen flicker, like the feed
    -- momentarily cutting out.
    if t > 0.6 and math.random() < (t - 0.6) then
        renderDrawBox(0, 0, resX, resY, grayColor(math.random(80, 220), math.random(0, 40)))
    end
end

-- Pre-OSD diagnostic overlay: connection/throttle/vehicle state (spawn
-- otherwise fails completely silently) plus the live physics-debug numbers
-- that found the two "won't fall" bugs, see docs/physics.md.
-- HP readout for the classic style, bottom-right: green -> yellow -> red.
function OSD:drawHpIndicator()
    if not self.font then return end
    local hp = self.telemetry.hp
    if not hp or self.telemetry.replaying then return end
    local rx, ry = getScreenResolution()
    local r = (hp < 0.5) and 255 or math.floor((1 - hp) * 2 * 255)
    local g = (hp > 0.5) and 255 or math.floor(hp * 2 * 255)
    local color = 0xFF000000 + r * 0x10000 + g * 0x100 + 0x30
    renderFontDrawText(self.font, string.format('HP %d%%', math.floor(hp * 100 + 0.5)),
        rx - 90, ry - 60, color)
end

-- Same camcorder REC corner the modern OSD has, for the classic style.
function OSD:drawRecIndicator()
    if not self.font then return end
    local t = self.telemetry
    if not t.recording or t.replaying then return end
    local rx = getScreenResolution()
    if math.floor(os.clock() * 2) % 2 == 0 then
        renderFontDrawText(self.font, 'REC', rx - 180, 22, 0xFFFF4030)
    end
    local sec = t.recordedSec or 0
    renderFontDrawText(self.font, string.format('%d:%02d', math.floor(sec / 60), math.floor(sec % 60)),
        rx - 146, 22, 0xFFFFFFFF)
end

function OSD:drawDebugOverlay(drone, cfg, receiver, recorder)
    if not self.font then return end
    if not cfg.debug_overlay then
        -- Spawn-reject and save-status lines stay visible even with debug
        -- off -- they answer "why did nothing happen", not "how does it fly".
        local rx, ry = getScreenResolution()
        if drone.lastSpawnReject and (os.clock() - drone.lastSpawnReject.clock) < 5.0 then
            renderFontDrawText(self.font, 'spawn rejected: ' .. drone.lastSpawnReject.reason,
                rx - 420, ry - 160, 0xFFFF6060)
        end
        if recorder.lastSave and (os.clock() - recorder.lastSave.clock) < 5.0 then
            renderFontDrawText(self.font,
                (recorder.lastSave.ok and 'replay saved: ' or 'replay save failed: ') .. recorder.lastSave.msg,
                rx - 420, ry - 146, recorder.lastSave.ok and 0xFF60FF60 or 0xFFFF6060)
        end
        return
    end
    local resX, resY = getScreenResolution()
    local x, y = resX - 560, resY - 160
    renderFontDrawText(self.font, string.format(
        'DRONE connected=%s throttle=%.0f%% armThresh=%.0f%% inVehicle=%s spawned=%s grounded=%s',
        tostring(receiver.connected), vecmath.axisUni(cfg.calib, receiver.axesRaw, cfg.axis_throttle) * 100, cfg.arm_throttle_max * 100,
        tostring(isCharInAnyCar(PLAYER_PED)), tostring(drone.spawned), tostring(drone.grounded)), x, y, 0xFFFFFFFF)
    if drone.lastSpawnReject and (os.clock() - drone.lastSpawnReject.clock) < 5.0 then
        renderFontDrawText(self.font, 'spawn rejected: ' .. drone.lastSpawnReject.reason, x, y + 14, 0xFFFF6060)
    end
    if recorder.lastSave and (os.clock() - recorder.lastSave.clock) < 5.0 then
        renderFontDrawText(self.font, (recorder.lastSave.ok and 'replay saved: ' or 'replay save failed: ') .. recorder.lastSave.msg,
            x, y + (drone.lastSpawnReject and 28 or 14), recorder.lastSave.ok and 0xFF60FF60 or 0xFFFF6060)
    end
    if drone.spawned then
        renderFontDrawText(self.font, '[F] stick-fix candidate ' .. drone.stickCandidateIndex .. '/' .. #Drone.STICK_CANDIDATES ..
            ': ' .. Drone.STICK_CANDIDATES[drone.stickCandidateIndex].name, x, y + 28, 0xFFFFFF60)
        renderFontDrawText(self.font, '[- / =] model_scale (collision only) = ' .. string.format('%.1f', cfg.profile.model_scale), x, y + 42, 0xFFFFFF60)
        renderFontDrawText(self.font, '[up / down] cam_tilt_deg = ' .. string.format('%.0f', cfg.cam_tilt_deg), x, y + 56, 0xFFFFFF60)
        local dbg = drone.lastPhysicsDebug
        renderFontDrawText(self.font, string.format(
            'thrust=%.2f gravity=%.2f dragUp=%.2f ground=%.2f ceiling=%.2f windZ=%.2f => accelZ=%.2f',
            dbg.thrust, dbg.gravity, dbg.dragUp, dbg.ground, dbg.ceiling, dbg.windZ, dbg.accelZ),
            x, y + 74, 0xFF60FFC0)
        renderFontDrawText(self.font, string.format('velZ=%.2f posZ=%.1f lastCollision=%s (x%d/s)',
            dbg.velZ, dbg.posZ, drone.lastCollisionKind, drone.collisionHitsPerSec),
            x, y + 88, 0xFF60FFC0)
        renderFontDrawText(self.font, string.format('replay: %d/%d frames buffered', recorder.count, recorder.capacity),
            x, y + 102, 0xFF60FFC0)
    end
end

return OSD
