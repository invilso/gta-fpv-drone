-- Modern OSD: fullscreen imgui overlay in three styles -- 'skyline'
-- (clean thin white HD), 'recon' (mono green, analog-camera vibe) and
-- 'circuit' (race-sim look: center grid, crosshair, boxed corner
-- readouts). Reads the same osd.telemetry the classic OSD uses (see
-- docs/replay.md for why), plus the drone pose (synced by both live
-- flight and replay playback).
local Class = require 'class'
local imgui = require 'mimgui'
local vecmath = require 'vecmath'

local OSD2 = Class('OSD2')

function OSD2:init(cfg, osd, drone, player)
    self.cfg = cfg
    self.osd = osd
    self.drone = drone
    self.player = player

    local frame = imgui.OnFrame(function()
        return self.cfg.osd_style ~= 'classic'
            and (self.drone.spawned or self.player:isActive())
            and not isPauseMenuActive()
    end, function()
        self:draw()
    end)
    -- HUD, not a window: without this, mimgui shows the mouse cursor for
    -- the whole flight and the game stops seeing keyboard input (the +/-
    -- and arrow hotkeys die).
    frame.HideCursor = true
end

local function colU32(r, g, b, a)
    return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a))
end

function OSD2:palette()
    if self.cfg.osd_style == 'recon' then
        return {
            main = colU32(0.35, 1.0, 0.45, 0.95),
            dim = colU32(0.35, 1.0, 0.45, 0.55),
            warn = colU32(1.0, 0.85, 0.2, 1),
            danger = colU32(1.0, 0.3, 0.2, 1),
            thick = 2.0,
        }
    end
    return {
        main = colU32(1, 1, 1, 0.92),
        dim = colU32(1, 1, 1, 0.55),
        warn = colU32(1.0, 0.85, 0.2, 1),
        danger = colU32(1.0, 0.35, 0.3, 1),
        thick = 1.5,
    }
end

function OSD2:draw()
    local io = imgui.GetIO()
    local dw, dh = io.DisplaySize.x, io.DisplaySize.y
    imgui.SetNextWindowPos(imgui.ImVec2(0, 0), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(dw, dh), imgui.Cond.Always)
    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoBackground
        + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoBringToFrontOnFocus
    if imgui.Begin('##fpv_osd2', nil, flags) then
        local dl = imgui.GetWindowDrawList()
        local pal = self:palette()
        local t = self.osd.telemetry
        local d = self.drone
        local cx, cy = dw / 2, dh / 2

        if self.cfg.osd_style == 'circuit' then
            self:drawCircuit(dl, pal, t, d, dw, dh, cx, cy)
        else
            local roll = math.atan2(d.right.z, d.up.z)
            local pitch = -math.asin(vecmath.clamp(d.fwd.z, -1, 1))
            self:horizon(dl, pal, cx, cy, roll, pitch, dh)
            self:tapes(dl, pal, t, d, dw, dh, cx, cy)
            self:headingTape(dl, pal, d, cx, dh)
            self:homeAndTimer(dl, pal, t, d, cx, dh)
            self:sticks(dl, pal, t, dw, dh)
            self:banners(dl, pal, t, d, cx, cy)
            self:hpQuad(dl, t, dw - 74, dh * 0.86, 44)
        end
        self:recIndicator(dl, pal, t, dw)
    end
    imgui.End()
end

-- Artificial horizon + pitch ladder, rotated with roll around center.
function OSD2:horizon(dl, pal, cx, cy, roll, pitch, dh)
    local pxPerRad = dh * 0.5 -- pitch-to-pixels scale
    local ca, sa = math.cos(-roll), math.sin(-roll)
    local function rot(x, y) -- local ladder coords -> screen
        return imgui.ImVec2(cx + x * ca - y * sa, cy + x * sa + y * ca)
    end
    -- center reticle (fixed)
    dl:AddLine(imgui.ImVec2(cx - 34, cy), imgui.ImVec2(cx - 12, cy), pal.main, pal.thick)
    dl:AddLine(imgui.ImVec2(cx + 12, cy), imgui.ImVec2(cx + 34, cy), pal.main, pal.thick)
    dl:AddCircleFilled(imgui.ImVec2(cx, cy), 2.5, pal.main, 12)
    -- ladder: horizon + every 10 deg within +-30
    for deg = -30, 30, 10 do
        local y = (pitch - math.rad(deg)) * pxPerRad
        if math.abs(y) < dh * 0.35 then
            local half = (deg == 0) and 150 or 60
            local gap = (deg == 0) and 40 or 24
            dl:AddLine(rot(-half, y), rot(-gap, y), deg == 0 and pal.main or pal.dim, pal.thick)
            dl:AddLine(rot(gap, y), rot(half, y), deg == 0 and pal.main or pal.dim, pal.thick)
            if deg ~= 0 then
                dl:AddText(rot(half + 8, y - 7), pal.dim, tostring(deg))
            end
        end
    end
end

-- Speed (left) and altitude (right) vertical tapes + vario.
function OSD2:tapes(dl, pal, t, d, dw, dh, cx, cy)
    local speed = vecmath.vLen(t.vel)
    local alt = d.pos.z
    local tapeH = dh * 0.36
    local function tape(x, value, step, label)
        local y0, y1 = cy - tapeH / 2, cy + tapeH / 2
        dl:AddLine(imgui.ImVec2(x, y0), imgui.ImVec2(x, y1), pal.dim, pal.thick)
        local pxPerUnit = tapeH / (step * 6)
        local base = math.floor(value / step) * step
        for i = -4, 4 do
            local v = base + i * step
            local y = cy - (v - value) * pxPerUnit
            if y > y0 and y < y1 and v >= 0 then
                dl:AddLine(imgui.ImVec2(x - 6, y), imgui.ImVec2(x + 6, y), pal.dim, pal.thick)
                dl:AddText(imgui.ImVec2(x + 10, y - 7), pal.dim, string.format('%d', v))
            end
        end
        -- current value box
        dl:AddRectFilled(imgui.ImVec2(x - 58, cy - 12), imgui.ImVec2(x - 8, cy + 12),
            colU32(0, 0, 0, 0.45), 4)
        dl:AddText(imgui.ImVec2(x - 52, cy - 8), pal.main, string.format('%.0f', value))
        dl:AddText(imgui.ImVec2(x - 58, cy + 16), pal.dim, label)
    end
    tape(dw * 0.22, speed, 5, 'SPD')
    tape(dw * 0.78, alt, 10, 'ALT')
    -- vario next to altitude tape
    dl:AddText(imgui.ImVec2(dw * 0.78 - 58, cy + 34), pal.dim,
        string.format('%+.1f m/s', t.vel.z))
end

function OSD2:headingTape(dl, pal, d, cx, dh)
    local heading = math.deg(math.atan2(-d.fwd.x, d.fwd.y)) % 360
    local y = dh * 0.08
    local names = {[0] = 'N', [45] = 'NE', [90] = 'E', [135] = 'SE',
        [180] = 'S', [225] = 'SW', [270] = 'W', [315] = 'NW'}
    local pxPerDeg = 3
    for off = -40, 40, 5 do
        local hdg = (math.floor(heading / 5) * 5 + off) % 360
        local x = cx + (hdg - heading + 540) % 360 - 180
        x = cx + ((math.floor(heading / 5) * 5 + off) - heading) * pxPerDeg
        local major = hdg % 45 == 0
        dl:AddLine(imgui.ImVec2(x, y), imgui.ImVec2(x, y + (major and 10 or 5)),
            major and pal.main or pal.dim, pal.thick)
        if names[hdg] and major then
            dl:AddText(imgui.ImVec2(x - 8, y + 13), pal.main, names[hdg])
        end
    end
    dl:AddText(imgui.ImVec2(cx - 14, y - 20), pal.main, string.format('%03d', math.floor(heading)))
end

function OSD2:homeAndTimer(dl, pal, t, d, cx, dh)
    local y = dh - dh * 0.09
    -- flight timer
    local el = t.flightElapsed or 0
    dl:AddText(imgui.ImVec2(cx - 30, y), pal.main,
        string.format('%d:%02d', math.floor(el / 60), math.floor(el % 60)))
    -- home arrow + distance (pilot = decoy ped, absent during pure replay)
    if d.decoyPed and doesCharExist(d.decoyPed) then
        local hx, hy, hz = getCharCoordinates(d.decoyPed)
        local dx, dy = hx - d.pos.x, hy - d.pos.y
        local dist = math.sqrt(dx * dx + dy * dy + (hz - d.pos.z) ^ 2)
        -- bearing to home relative to drone heading
        local heading = math.atan2(-d.fwd.x, d.fwd.y)
        local bearing = math.atan2(-dx, dy) - heading
        local ax, ay = cx + 60, y + 8
        local r = 10
        local tip = imgui.ImVec2(ax + math.sin(bearing) * r, ay - math.cos(bearing) * r)
        local l = imgui.ImVec2(ax + math.sin(bearing + 2.6) * r, ay - math.cos(bearing + 2.6) * r)
        local rr = imgui.ImVec2(ax + math.sin(bearing - 2.6) * r, ay - math.cos(bearing - 2.6) * r)
        dl:AddTriangleFilled(tip, l, rr, pal.main)
        dl:AddText(imgui.ImVec2(ax + 16, y), pal.main, string.format('%.0fm', dist))
    end
    -- mode + profile, left of timer
    dl:AddText(imgui.ImVec2(cx - 170, y), pal.dim,
        (t.flightMode or '') .. (t.throttle3d and ' 3D' or '') .. '  ' .. (t.profileName or ''))
end

function OSD2:sticks(dl, pal, t, dw, dh)
    local box = 64
    local y0 = dh - dh * 0.09 - box - 10
    local function stick(x0, sx, sy)
        dl:AddRect(imgui.ImVec2(x0, y0), imgui.ImVec2(x0 + box, y0 + box), pal.dim, 6, 15, pal.thick)
        local px = x0 + box / 2 + vecmath.clamp(sx, -1, 1) * (box / 2 - 5)
        local py = y0 + box / 2 + vecmath.clamp(sy, -1, 1) * (box / 2 - 5)
        dl:AddCircleFilled(imgui.ImVec2(px, py), 4, pal.main, 12)
    end
    -- left: yaw + throttle (throttle 0..1 -> bottom..top), right: roll+pitch
    stick(dw * 0.5 - box - 14, t.stickYaw, 1 - 2 * (t.stickThrottle or 0))
    stick(dw * 0.5 + 14, t.stickRoll, t.stickPitch)
end

-- Mini quad silhouette tinted by HP (green -> yellow -> red) + percent.
-- Hidden when damage isn't in play (t.hp nil) or during replay.
function OSD2:hpQuad(dl, t, x, y, size)
    local hp = t.hp
    if not hp or t.replaying then return end
    local r = (hp < 0.5) and 1.0 or (1 - hp) * 2
    local g = (hp > 0.5) and 1.0 or hp * 2
    local col = colU32(r, g, 0.18, 0.95)
    local s = size / 2
    local cx, cy = x + s, y + s
    local rotor = s * 0.38
    local off = s * 0.55
    for _, o in ipairs({{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) do
        local mx, my = cx + o[1] * off, cy + o[2] * off
        dl:AddLine(imgui.ImVec2(cx, cy), imgui.ImVec2(mx, my), col, 2)
        dl:AddCircle(imgui.ImVec2(mx, my), rotor, col, 16, 2)
    end
    dl:AddCircleFilled(imgui.ImVec2(cx, cy), s * 0.22, col, 12)
    dl:AddText(imgui.ImVec2(x + size + 6, cy - 7), col,
        string.format('%d%%', math.floor(hp * 100 + 0.5)))
end

-- 'Circuit' style: race-sim analog look -- graph-paper grid across the
-- middle, crosshair reticle, boxed corner readouts, status lines.
function OSD2:drawCircuit(dl, pal, t, d, dw, dh, cx, cy)
    local grid = colU32(1, 1, 1, 0.10)
    local gridB = colU32(1, 1, 1, 0.25)
    local gx0, gx1 = dw * 0.18, dw * 0.82
    local gy0, gy1 = dh * 0.16, dh * 0.84
    local step = dh * 0.085
    local x = cx
    while x <= gx1 do
        dl:AddLine(imgui.ImVec2(x, gy0), imgui.ImVec2(x, gy1), x == cx and gridB or grid, 1)
        if x ~= cx then
            dl:AddLine(imgui.ImVec2(2 * cx - x, gy0), imgui.ImVec2(2 * cx - x, gy1), grid, 1)
        end
        x = x + step
    end
    local y = cy
    while y <= gy1 do
        dl:AddLine(imgui.ImVec2(gx0, y), imgui.ImVec2(gx1, y), y == cy and gridB or grid, 1)
        if y ~= cy then
            dl:AddLine(imgui.ImVec2(gx0, 2 * cy - y), imgui.ImVec2(gx1, 2 * cy - y), grid, 1)
        end
        y = y + step
    end
    dl:AddCircle(imgui.ImVec2(cx, cy), 10, pal.main, 24, 1.5)
    dl:AddCircleFilled(imgui.ImVec2(cx, cy), 2, pal.main, 8)
    for _, ox in ipairs({-step * 1.5, step * 1.5}) do
        local mx, my = cx + ox, cy + step * 2
        dl:AddLine(imgui.ImVec2(mx - 6, my), imgui.ImVec2(mx + 6, my), gridB, 1.5)
        dl:AddLine(imgui.ImVec2(mx, my - 6), imgui.ImVec2(mx, my + 6), gridB, 1.5)
    end

    -- top-left: flight mode chip
    local mode = (t.flightMode or '') .. (t.throttle3d and ' 3D' or '')
    dl:AddRectFilled(imgui.ImVec2(24, 20), imgui.ImVec2(40 + 8 * #mode, 44),
        colU32(0, 0, 0, 0.5), 4)
    dl:AddText(imgui.ImVec2(33, 25), pal.main, mode)

    -- top-center: flight timer with milliseconds, race-clock style
    local el = t.flightElapsed or 0
    dl:AddText(imgui.ImVec2(cx - 42, 22), pal.main,
        string.format('%02d:%02d.%03d', math.floor(el / 60), math.floor(el % 60),
            math.floor((el % 1) * 1000)))

    -- top-right: boxed ALT and SPD readouts
    local bx = dw - 132
    dl:AddRectFilled(imgui.ImVec2(bx, 20), imgui.ImVec2(dw - 24, 46), colU32(0, 0, 0, 0.5), 4)
    dl:AddText(imgui.ImVec2(bx + 8, 25), pal.dim, 'ALT')
    dl:AddText(imgui.ImVec2(bx + 54, 25), pal.main, string.format('%.0f', d.pos.z))
    dl:AddRectFilled(imgui.ImVec2(bx, 52), imgui.ImVec2(dw - 24, 78), colU32(0, 0, 0, 0.5), 4)
    dl:AddText(imgui.ImVec2(bx + 8, 57), pal.dim, 'SPD')
    dl:AddText(imgui.ImVec2(bx + 54, 57), pal.main,
        string.format('%.0f', vecmath.vLen(t.vel) * 3.6))

    -- bottom-left: status lines, sim-style plain text
    local msgs = {}
    if d.exploding then
        msgs[#msgs + 1] = 'CRASHED'
    elseif t.replaying then
        msgs[#msgs + 1] = 'REPLAY'
    else
        if not t.connected then msgs[#msgs + 1] = 'FAILSAFE -- no controller signal' end
        if not t.armed then
            msgs[#msgs + 1] = 'Drone disarmed. Throttle to idle, then the ARM key/switch to arm.'
        end
        if t.grounded then msgs[#msgs + 1] = 'Landed. Raise throttle to lift off.' end
    end
    for i, m in ipairs(msgs) do
        dl:AddText(imgui.ImVec2(24, dh - 70 - (#msgs - i) * 18), pal.warn, m)
    end

    self:sticks(dl, pal, t, dw, dh)
    self:hpQuad(dl, t, dw - 110, dh - 130, 64)
end

-- Camcorder-style REC in the top-right corner while the flight recorder
-- is capturing: blinking red dot + buffered/capacity counter.
function OSD2:recIndicator(dl, pal, t, dw)
    if not t.recording or t.replaying then return end
    local x, y = dw - 190, 22
    if math.floor(os.clock() * 2) % 2 == 0 then
        dl:AddCircleFilled(imgui.ImVec2(x, y + 8), 6, colU32(1.0, 0.22, 0.16, 1), 16)
    end
    local sec = t.recordedSec or 0
    dl:AddText(imgui.ImVec2(x + 14, y), colU32(1.0, 0.3, 0.24, 1), 'REC')
    dl:AddText(imgui.ImVec2(x + 48, y), pal.main,
        string.format('%d:%02d', math.floor(sec / 60), math.floor(sec % 60)))
end

function OSD2:banners(dl, pal, t, d, cx, cy)
    local msg, col = nil, pal.danger
    if d.exploding then msg = 'CRASHED'
    elseif not t.connected and not t.replaying then msg = 'FAILSAFE'
    elseif not t.armed and not t.replaying then msg = 'DISARMED'
    elseif t.grounded then msg, col = 'LANDED', pal.warn
    elseif t.replaying then msg, col = 'REPLAY', pal.warn end
    if msg then
        local y = cy - cy * 0.35
        dl:AddRectFilled(imgui.ImVec2(cx - 80, y - 6), imgui.ImVec2(cx + 80, y + 22),
            colU32(0, 0, 0, 0.5), 6)
        dl:AddText(imgui.ImVec2(cx - #msg * 4.2, y), col, msg)
    end
end

return OSD2
