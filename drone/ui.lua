-- Settings menu: macOS + DJI inside the game. Glass window, DJI status
-- bar on top, macOS dock with magnification at the bottom, animated
-- widgets, EN/UA i18n, first-run wizard, replay player overlay. Design
-- decisions live in theme.lua; row specs in sections.lua; strings in
-- i18n.lua; icon tiles in resources/icons/ (generate.py).
local Class = require 'class'
local imgui = require 'mimgui'
local theme = require 'theme'
local i18n = require 'i18n'
local icons = require 'icons'
local sections = require 'sections'
local Recorder = require 'replay.recorder'
local updateCheck = require 'update_check'
local new = imgui.new
local t = i18n.t

-- spec row -> label in the active language
local function rl(row) return (i18n.lang == 'ua' and row.ua) or row.en end
local function rhint(row)
    if i18n.lang == 'ua' then return row.hint_ua end
    return row.hint_en
end

local UI = Class('UI')

UI.SECTIONS = {
    {key = 'fly',        titleKey = 'sec_fly'},
    {key = 'controller', titleKey = 'sec_controller'},
    {key = 'camera',     titleKey = 'sec_camera'},
    {key = 'world',      titleKey = 'sec_world'},
    {key = 'audio',      titleKey = 'sec_audio'},
    {key = 'osd',        titleKey = 'sec_osd'},
    {key = 'replay',     titleKey = 'sec_replay'},
    {key = 'advanced',   titleKey = 'sec_advanced'},
}

UI.PROFILE_ORDER = {'default', 'whoop', 'racer', 'heavy'}

function UI:init(configObj, drone, receiver, recorder, player)
    self.configObj = configObj
    self.cfg = configObj.data
    self.drone = drone
    self.receiver = receiver
    self.recorder = recorder
    self.player = player

    self.show = new.bool(false)
    self.activeSection = 'fly'
    self.sectionAlpha = 1.0     -- content fade-in on section switch
    self.dockScale = {}         -- section key -> animated scale
    for _, s in ipairs(UI.SECTIONS) do self.dockScale[s.key] = 1.0 end
    self.toggleAnim = {}        -- toggle id -> animated 0..1 knob position
    self.searchBuf = new.char[64]('')
    self.lastFrameClock = os.clock()
    self.cfgDirty = false
    self.floatBufs, self.intBufs, self.textBufs = {}, {}, {}
    self.keyListen = nil       -- config field waiting for a keyboard key
    self.btnListen = nil       -- config field waiting for a controller button
    self.btnListenSnap = 0
    self.calibrating = false
    self.calibTrack = nil      -- per-axis {min, max} while sweeping
    self.replayFiles = nil     -- cached Recorder.listFiles()
    self.pendingPlayback = nil

    i18n.set(self.cfg.ui_lang or 'en')
    theme.setAccent(self.cfg.ui_accent or 'pink')

    self:buildWindow()
end

function UI:toggle() self.show[0] = not self.show[0] end
function UI:markDirty() self.cfgDirty = true end

-- ============================ widgets ============================

-- macOS-style delayed tooltip for the last item. Own hover timer -- imgui's
-- internal HoveredIdTimer isn't in mimgui's cdefs.
function UI:hint(text)
    if imgui.IsItemHovered() then
        if self.hintText ~= text then
            self.hintText, self.hintStart = text, os.clock()
        end
        if os.clock() - self.hintStart > 0.4 then
            imgui.BeginTooltip()
            imgui.PushTextWrapPos(320)
            imgui.TextUnformatted(text)
            imgui.PopTextWrapPos()
            imgui.EndTooltip()
        end
        self.hintHeldThisFrame = true
    end
end

-- iOS toggle switch, animated. Returns true when clicked (caller flips the
-- config value; the animation follows the value, not the click).
function UI:toggleSwitch(id, value)
    local w, h = 44, 24
    local pos = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(w, h))
    local target = value and 1.0 or 0.0
    local a = theme.approach(self.toggleAnim[id] or target, target, self.dt, 16)
    self.toggleAnim[id] = a
    local dl = imgui.GetWindowDrawList()
    local off = theme.u32(imgui.ImVec4(1, 1, 1, 0.16))
    local on = theme.accentU32(0.95)
    local track = a < 0.5 and off or on
    dl:AddRectFilled(pos, imgui.ImVec2(pos.x + w, pos.y + h), track, h / 2)
    local kx = pos.x + h / 2 + a * (w - h)
    dl:AddCircleFilled(imgui.ImVec2(kx, pos.y + h / 2), h / 2 - 3,
        theme.u32(imgui.ImVec4(1, 1, 1, 0.97)), 24)
    return clicked
end

-- Toggle row: switch first, label right next to it -- right-aligned
-- switches drift too far from their labels to scan comfortably.
function UI:toggleRow(label, tbl, field, hintText)
    if self:toggleSwitch('##tg_' .. field, tbl[field]) then
        tbl[field] = not tbl[field]
        self:markDirty()
    end
    if hintText then self:hint(hintText) end
    imgui.SameLine()
    imgui.AlignTextToFramePadding()
    imgui.TextUnformatted(label)
    if hintText then self:hint(hintText) end
end

-- Segmented control (one active pill из списку). Returns new index or nil.
function UI:segmented(id, items, activeIdx, hints)
    local changed = nil
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(4, 4))
    for i, label in ipairs(items) do
        if i > 1 then imgui.SameLine() end
        local active = (i == activeIdx)
        if active then
            imgui.PushStyleColor(imgui.Col.Button, theme.accent(0.85))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, theme.accent(0.95))
            imgui.PushStyleColor(imgui.Col.ButtonActive, theme.accent(1.0))
        end
        if imgui.Button(label .. '##' .. id .. i, imgui.ImVec2(0, 30)) then
            changed = i
        end
        if active then imgui.PopStyleColor(3) end
        if hints and hints[i] then self:hint(hints[i]) end
    end
    imgui.PopStyleVar()
    return changed
end

-- Small round button with a DrawList-drawn glyph: 'dup' (two sheets),
-- 'ren' (pencil), 'del' (cross). Returns true on click.
function UI:iconRoundBtn(id, kind, danger, bw)
    bw = bw or 24
    if danger then
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.85, 0.25, 0.22, 0.55))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.95, 0.28, 0.24, 0.85))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(1.0, 0.3, 0.26, 1))
    end
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 999)
    local clicked = imgui.Button('##irb_' .. id, imgui.ImVec2(bw, bw))
    imgui.PopStyleVar()
    if danger then imgui.PopStyleColor(3) end

    local mn, mx = imgui.GetItemRectMin(), imgui.GetItemRectMax()
    local cx, cy = (mn.x + mx.x) / 2, (mn.y + mx.y) / 2
    local dl = imgui.GetWindowDrawList()
    local col = theme.u32(imgui.ImVec4(1, 1, 1, 0.92))
    if kind == 'dup' then
        dl:AddRect(imgui.ImVec2(cx - 5.5, cy - 2), imgui.ImVec2(cx + 1.5, cy + 5.5),
            col, 1.5, 15, 1.4)
        dl:AddRect(imgui.ImVec2(cx - 1.5, cy - 5.5), imgui.ImVec2(cx + 5.5, cy + 2),
            col, 1.5, 15, 1.4)
    elseif kind == 'ren' then
        dl:AddLine(imgui.ImVec2(cx - 5, cy + 5), imgui.ImVec2(cx + 3.5, cy - 3.5), col, 1.8)
        dl:AddLine(imgui.ImVec2(cx + 2.2, cy - 5), imgui.ImVec2(cx + 5, cy - 2.2), col, 1.8)
    elseif kind == 'del' then
        dl:AddLine(imgui.ImVec2(cx - 4, cy - 4), imgui.ImVec2(cx + 4, cy + 4), col, 1.8)
        dl:AddLine(imgui.ImVec2(cx - 4, cy + 4), imgui.ImVec2(cx + 4, cy - 4), col, 1.8)
    elseif kind == 'share' then
        -- up arrow (export) + down arrow (import), side by side
        dl:AddLine(imgui.ImVec2(cx - 3, cy - 5), imgui.ImVec2(cx - 3, cy + 5), col, 1.6)
        dl:AddLine(imgui.ImVec2(cx - 5.5, cy - 2), imgui.ImVec2(cx - 3, cy - 5.5), col, 1.6)
        dl:AddLine(imgui.ImVec2(cx - 0.5, cy - 2), imgui.ImVec2(cx - 3, cy - 5.5), col, 1.6)
        dl:AddLine(imgui.ImVec2(cx + 3, cy - 5), imgui.ImVec2(cx + 3, cy + 5), col, 1.6)
        dl:AddLine(imgui.ImVec2(cx + 0.5, cy + 2), imgui.ImVec2(cx + 3, cy + 5.5), col, 1.6)
        dl:AddLine(imgui.ImVec2(cx + 5.5, cy + 2), imgui.ImVec2(cx + 3, cy + 5.5), col, 1.6)
    end
    return clicked
end

-- Rounded glass card wrapper: beginCard/endCard around arbitrary content.
function UI:beginCard(id, height)
    imgui.PushStyleColor(imgui.Col.ChildBg, theme.PANEL)
    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, theme.ROUND_CARD)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 8))
    return imgui.BeginChild(id, imgui.ImVec2(0, height or 0), true,
        imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
end

function UI:endCard()
    imgui.EndChild()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(1)
end

-- ============================ status bar ============================

-- Pretty display name for a profile: built-in presets get localized titles
-- (config keys stay lowercase on disk); user-created profiles show their
-- own name untouched.
function UI:profileTitle(key)
    for _, builtin in ipairs(UI.PROFILE_ORDER) do
        if key == builtin then return t('profile_' .. key .. '_title') end
    end
    local profile = self.cfg.profiles[key]
    return (profile and profile.name) or key
end

function UI:drawStatusBar()
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x

    -- macOS traffic-light close button
    local closeC = imgui.ImVec2(p.x + 12, p.y + 13)
    local closeHover = imgui.IsMouseHoveringRect(
        imgui.ImVec2(closeC.x - 9, closeC.y - 9), imgui.ImVec2(closeC.x + 9, closeC.y + 9))
    dl:AddCircleFilled(closeC, 7,
        theme.u32(imgui.ImVec4(1.0, closeHover and 0.28 or 0.37, 0.33, 1)), 20)
    if closeHover then
        local x = theme.u32(imgui.ImVec4(0.35, 0.05, 0.05, 1))
        dl:AddLine(imgui.ImVec2(closeC.x - 3, closeC.y - 3), imgui.ImVec2(closeC.x + 3, closeC.y + 3), x, 1.6)
        dl:AddLine(imgui.ImVec2(closeC.x - 3, closeC.y + 3), imgui.ImVec2(closeC.x + 3, closeC.y - 3), x, 1.6)
        if imgui.IsMouseClicked(0) then self.show[0] = false end
    end

    -- center: mode + profile
    local center = string.format('%s  ·  %s', self.cfg.flight_mode
        .. (self.cfg.throttle_3d and ' 3D' or ''), self:profileTitle(self.cfg.active_profile))
    local tw = imgui.CalcTextSize(center).x
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + (w - tw) / 2, p.y + 3))
    imgui.TextUnformatted(center)

    -- right cluster, laid out right-to-left from the actual edge so
    -- nothing spills past the window frame
    local conn = self.receiver.connected
    local dev = self.receiver.effectiveDeviceId
        and self.receiver.devices[self.receiver.effectiveDeviceId]
    local rightText = conn and (dev and dev.name or 'OK') or t('st_no_controller')
    local rtw = imgui.CalcTextSize(rightText).x
    local expW = imgui.CalcTextSize(t('expert_mode')).x
    local switchW, langW, gap = 44, 40, 10
    local x = p.x + w - switchW

    imgui.SetCursorScreenPos(imgui.ImVec2(x, p.y + 1))
    if self:toggleSwitch('##expert', self.cfg.ui_expert) then
        self.cfg.ui_expert = not self.cfg.ui_expert
        self:markDirty()
    end
    x = x - gap - expW
    imgui.SetCursorScreenPos(imgui.ImVec2(x, p.y + 3))
    imgui.TextUnformatted(t('expert_mode'))
    x = x - gap - langW
    imgui.SetCursorScreenPos(imgui.ImVec2(x, p.y))
    if imgui.Button(t('lang_toggle') .. '##lang', imgui.ImVec2(langW, 26)) then
        local nextLang = (i18n.lang == 'en') and 'ua' or 'en'
        i18n.set(nextLang)
        self.cfg.ui_lang = nextLang
        self:markDirty()
    end
    x = x - gap - rtw
    imgui.SetCursorScreenPos(imgui.ImVec2(x, p.y + 3))
    imgui.TextUnformatted(rightText)
    dl:AddCircleFilled(imgui.ImVec2(x - 12, p.y + 13), 5,
        theme.u32(conn and theme.OK or theme.DANGER), 16)

    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + 32))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 2))
end

-- Slim dismissible banner, only rendered once update_check.lua's async
-- download has actually found a newer commit on main. The URL sits in a
-- read-only InputText (not a live hyperlink -- MoonLoader has no
-- open-url native) so it's copyable with Ctrl+C the same way profile
-- sharing already works.
function UI:drawUpdateBanner()
    if not updateCheck.updateAvailable or self.updateBannerDismissed then return end
    local ua = i18n.lang == 'ua'
    imgui.PushStyleColor(imgui.Col.ChildBg, theme.accent(0.16))
    if self:beginCard('##updateBanner', 40) then
        imgui.AlignTextToFramePadding()
        imgui.TextUnformatted(ua
            and string.format('Доступне оновлення (%s -> %s):', updateCheck.localVersion, updateCheck.remoteVersion)
            or string.format('Update available (%s -> %s):', updateCheck.localVersion, updateCheck.remoteVersion))
        imgui.SameLine()
        if not self.updateUrlBuf then
            self.updateUrlBuf = new.char[128](updateCheck.REPO_URL)
        end
        imgui.PushItemWidth(320)
        imgui.InputText('##updateUrl', self.updateUrlBuf, 128, imgui.InputTextFlags.ReadOnly)
        imgui.PopItemWidth()
        imgui.SameLine(imgui.GetWindowWidth() - 34)
        if imgui.Button('X##dismissUpdate', imgui.ImVec2(24, 24)) then
            self.updateBannerDismissed = true
        end
    end
    self:endCard()
    imgui.PopStyleColor()
    imgui.Dummy(imgui.ImVec2(0, 4))
end

-- ============================ dock ============================

local DOCK_H = 84
local ICON_BASE = 48
local ICON_MAG = 0.42   -- max extra scale under the cursor
local MAG_RANGE = 110   -- px of cursor influence

function UI:drawDock()
    local dl = imgui.GetWindowDrawList()
    local avail = imgui.GetContentRegionAvail()
    local p = imgui.GetCursorScreenPos()
    local n = #UI.SECTIONS
    local spacing = 14
    local plateW = n * (ICON_BASE + spacing) + spacing + 8
    local plateX = p.x + (avail.x - plateW) / 2
    local plateY = p.y + DOCK_H - ICON_BASE - 22
    local baselineY = p.y + DOCK_H - 16 -- icons sit on this line

    -- glass plate
    dl:AddRectFilled(imgui.ImVec2(plateX, plateY - 10),
        imgui.ImVec2(plateX + plateW, p.y + DOCK_H),
        theme.u32(imgui.ImVec4(1, 1, 1, 0.07)), 20)
    dl:AddRect(imgui.ImVec2(plateX, plateY - 10),
        imgui.ImVec2(plateX + plateW, p.y + DOCK_H),
        theme.u32(theme.BORDER), 20)

    local mouse = imgui.GetIO().MousePos
    local mouseInDock = mouse.y > plateY - 30 and mouse.y < p.y + DOCK_H + 10
        and mouse.x > plateX - 40 and mouse.x < plateX + plateW + 40

    -- Pass 1: magnification targets from FIXED slot centers (stable under
    -- the cursor), then animate scales. Pass 2 lays icons out by their
    -- actual scaled widths so magnified neighbors push apart instead of
    -- overlapping, macOS-style.
    local slotCenters, scales = {}, {}
    local totalW = 0
    for i, s in ipairs(UI.SECTIONS) do
        slotCenters[i] = plateX + spacing + 4 + (i - 1) * (ICON_BASE + spacing) + ICON_BASE / 2
        local target = 1.0
        if mouseInDock then
            local d = math.abs(mouse.x - slotCenters[i])
            if d < MAG_RANGE then
                local k = math.cos(d / MAG_RANGE * math.pi / 2)
                target = 1.0 + ICON_MAG * k * k
            end
        end
        local scale = theme.approach(self.dockScale[s.key], target, self.dt, 18)
        self.dockScale[s.key] = scale
        scales[i] = scale
        totalW = totalW + ICON_BASE * scale + spacing
    end
    totalW = totalW - spacing

    local hoveredKey, hoveredCenterX = nil, nil
    local x = plateX + plateW / 2 - totalW / 2
    for i, s in ipairs(UI.SECTIONS) do
        local scale = scales[i]
        local sz = ICON_BASE * scale
        local cx = x + sz / 2
        local x1 = cx - sz / 2
        local y1 = baselineY - sz
        local x2, y2 = cx + sz / 2, baselineY
        local tex = icons.get(self.cfg.ui_icon_style or 'color', s.key)
        if tex then
            dl:AddImageRounded(tex, imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2),
                imgui.ImVec2(0, 0), imgui.ImVec2(1, 1),
                theme.u32(imgui.ImVec4(1, 1, 1, 1)), sz * 0.24)
        else
            dl:AddRectFilled(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2),
                theme.u32(imgui.ImVec4(1, 1, 1, 0.15)), sz * 0.24)
        end
        -- active dot under the current section, macOS-style
        if self.activeSection == s.key then
            dl:AddCircleFilled(imgui.ImVec2(cx, baselineY + 7), 2.5,
                theme.u32(imgui.ImVec4(1, 1, 1, 0.85)), 12)
        end

        if mouseInDock and mouse.x >= x1 - 4 and mouse.x <= x2 + 4
            and mouse.y >= y1 - 6 and mouse.y <= y2 + 8 then
            hoveredKey, hoveredCenterX = s.key, cx
            if imgui.IsMouseClicked(0) and self.activeSection ~= s.key then
                self.activeSection = s.key
                self.sectionAlpha = 0.0
            end
        end
        x = x + sz + spacing
    end

    -- floating label above the hovered icon
    if hoveredKey then
        local label
        for _, s in ipairs(UI.SECTIONS) do
            if s.key == hoveredKey then label = t(s.titleKey) end
        end
        local tw = imgui.CalcTextSize(label)
        local lx = hoveredCenterX - tw.x / 2
        local ly = plateY - 34
        dl:AddRectFilled(imgui.ImVec2(lx - 10, ly - 5),
            imgui.ImVec2(lx + tw.x + 10, ly + tw.y + 5),
            theme.u32(imgui.ImVec4(0.08, 0.085, 0.11, 0.96)), 8)
        dl:AddText(imgui.ImVec2(lx, ly), theme.u32(theme.TEXT), label)
    end

    imgui.Dummy(imgui.ImVec2(0, DOCK_H))
end

-- ============================ sections ============================

function UI:isBuiltinProfile(key)
    for _, b in ipairs(UI.PROFILE_ORDER) do if key == b then return true end end
    return false
end

function UI:customProfileKeys()
    local keys = {}
    for key in pairs(self.cfg.profiles) do
        if not self:isBuiltinProfile(key) then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
end

local function copyProfile(src)
    local dst = {}
    for k, v in pairs(src) do
        if type(v) == 'table' then
            local tt = {}
            for k2, v2 in pairs(v) do tt[k2] = v2 end
            dst[k] = tt
        else
            dst[k] = v
        end
    end
    return dst
end

function UI:duplicateProfile(key)
    local base, n = 'custom', 1
    while self.cfg.profiles[base .. '_' .. n] do n = n + 1 end
    local newKey = base .. '_' .. n
    local prof = copyProfile(self.cfg.profiles[key])
    prof.name = self:profileTitle(key) .. ' ' .. n
    self.cfg.profiles[newKey] = prof
    self:markDirty()
end

function UI:deleteProfile(key)
    if self:isBuiltinProfile(key) then return end
    self.cfg.profiles[key] = nil
    if self.cfg.active_profile == key then
        self.cfg.active_profile = 'default'
        self.cfg.profile = self.cfg.profiles.default
    end
    self:markDirty()
end

function UI:drawFly()
    imgui.TextUnformatted(t('fly_profiles'))
    imgui.Dummy(imgui.ImVec2(0, 2))

    local cardW = (imgui.GetContentRegionAvail().x - 3 * 10) / 4
    for i, key in ipairs(UI.PROFILE_ORDER) do
        if i > 1 then imgui.SameLine() end
        self:drawProfileCard(key, cardW)
    end

    -- custom profiles: same card style, own horizontally-scrollable row
    local customs = self:customProfileKeys()
    if #customs > 0 then
        imgui.Dummy(imgui.ImVec2(0, 6))
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
        if imgui.BeginChild('##customProfiles', imgui.ImVec2(0, 184), false,
            imgui.WindowFlags.HorizontalScrollbar) then
            for i, key in ipairs(customs) do
                if i > 1 then imgui.SameLine() end
                self:drawProfileCard(key, math.max(cardW, 190))
            end
        end
        imgui.EndChild()
        imgui.PopStyleColor()
    end

    -- share popup: the profile as editable JSON text -- copy it out to
    -- share (export), or paste someone else's and Apply (import; custom
    -- profiles only -- built-ins are the reference set)
    if self.shareKey then
        imgui.OpenPopup('##shareProfile')
        theme.pushWindow()
        if imgui.BeginPopup('##shareProfile') then
            local ffi = require 'ffi'
            local ua = i18n.lang == 'ua'
            if not self.shareBuf then
                self.shareBuf = new.char[4096](encodeJson(self.cfg.profiles[self.shareKey]) or '')
                self.shareError = nil
            end
            imgui.TextUnformatted(ua and ('Профіль: ' .. self:profileTitle(self.shareKey))
                or ('Profile: ' .. self:profileTitle(self.shareKey)))
            imgui.PushStyleColor(imgui.Col.Text, theme.TEXT_DIM)
            imgui.TextUnformatted(ua and 'Ctrl+A, Ctrl+C -- скопіювати. Ctrl+V -- вставити чужий.'
                or 'Ctrl+A, Ctrl+C to copy. Ctrl+V to paste a shared one.')
            imgui.PopStyleColor()
            imgui.InputTextMultiline('##shareText', self.shareBuf, 4096,
                imgui.ImVec2(440, 220), 0)
            if self.shareError then
                imgui.PushStyleColor(imgui.Col.Text, theme.DANGER)
                imgui.TextUnformatted(self.shareError)
                imgui.PopStyleColor()
            end
            if imgui.Button(ua and 'Застосувати' or 'Apply', imgui.ImVec2(110, 26)) then
                local ok, parsed = pcall(decodeJson, ffi.string(self.shareBuf))
                if ok and type(parsed) == 'table' and type(parsed.mass) == 'number' then
                    local prof = self.cfg.profiles[self.shareKey]
                    for k, v in pairs(parsed) do prof[k] = v end
                    self:markDirty()
                    self.shareKey, self.shareBuf, self.shareError = nil, nil, nil
                    imgui.CloseCurrentPopup()
                else
                    self.shareError = ua and 'Це не схоже на профіль (битий JSON або немає mass).'
                        or 'Does not look like a profile (broken JSON or no mass field).'
                end
            end
            imgui.SameLine()
            if imgui.Button(ua and 'Закрити' or 'Close', imgui.ImVec2(110, 26)) then
                self.shareKey, self.shareBuf, self.shareError = nil, nil, nil
                imgui.CloseCurrentPopup()
            end
            imgui.EndPopup()
        else
            self.shareKey, self.shareBuf, self.shareError = nil, nil, nil
        end
        theme.popWindow()
    end

    -- rename popup (opened from a card's R button)
    if self.renameKey then
        imgui.OpenPopup('##renameProfile')
        theme.pushWindow()
        if imgui.BeginPopup('##renameProfile') then
            local ffi = require 'ffi'
            if not self.renameBuf then
                self.renameBuf = new.char[48](self.cfg.profiles[self.renameKey].name or '')
            end
            imgui.PushItemWidth(200)
            imgui.InputText('##renName', self.renameBuf, 48)
            imgui.PopItemWidth()
            if imgui.Button(i18n.lang == 'ua' and 'Зберегти' or 'Save', imgui.ImVec2(96, 26)) then
                local newName = ffi.string(self.renameBuf)
                if #newName > 0 then
                    self.cfg.profiles[self.renameKey].name = newName
                    self:markDirty()
                end
                self.renameKey, self.renameBuf = nil, nil
                imgui.CloseCurrentPopup()
            end
            imgui.SameLine()
            if imgui.Button(i18n.lang == 'ua' and 'Скасувати' or 'Cancel', imgui.ImVec2(96, 26)) then
                self.renameKey, self.renameBuf = nil, nil
                imgui.CloseCurrentPopup()
            end
            imgui.EndPopup()
        else
            self.renameKey, self.renameBuf = nil, nil
        end
        theme.popWindow()
    end

    imgui.Dummy(imgui.ImVec2(0, 10))
    imgui.TextUnformatted(t('fly_mode'))
    local modes = {'ACRO', 'LEVEL', 'HORIZON'}
    local cur = 1
    for i, m in ipairs(modes) do if m == self.cfg.flight_mode then cur = i end end
    local ua = i18n.lang == 'ua'
    local sel = self:segmented('flymode', modes, cur, {
        ua and 'Повний ручний контроль обертання, без самовирівнювання. Як літають справжні FPV.'
            or 'Full manual rate control, no self-leveling. How real FPV quads fly.',
        ua and 'Стік = кут нахилу, відпустив — дрон вирівнюється сам. Найпростіший.'
            or 'Stick = tilt angle; release and the drone levels itself. Easiest.',
        ua and 'Гібрид: по центру стіка — LEVEL, на краях — повні фліпи як ACRO.'
            or 'Hybrid: LEVEL near stick center, full ACRO flips at the edges.',
    })
    if sel then
        self.cfg.flight_mode = modes[sel]
        self:markDirty()
    end

    imgui.Dummy(imgui.ImVec2(0, 6))
    self:toggleRow(t('fly_3d'), self.cfg, 'throttle_3d', t('fly_3d_hint'))

    -- Custom profiles exist to be tuned -- their physics editor shows
    -- regardless of the global Expert toggle.
    if self.cfg.ui_expert or not self:isBuiltinProfile(self.cfg.active_profile) then
        self:drawProfileEditor()
    end
end

UI.PROFILE_FIELDS = {
    {f = 'mass', mn = 0.05, mx = 5, fmt = '%.2f', en = 'Mass (kg)', ua = 'Маса (кг)'},
    {f = 'max_thrust', mn = 1, mx = 60, fmt = '%.1f', en = 'Max thrust', ua = 'Макс. тяга'},
    {f = 'gravity', mn = 1, mx = 30, fmt = '%.1f', en = 'Gravity', ua = 'Гравітація'},
    {f = 'motor_tau', mn = 0.01, mx = 0.5, fmt = '%.2f', en = 'Motor lag', ua = 'Інерція моторів'},
    {f = 'angular_tau', mn = 0.01, mx = 0.5, fmt = '%.2f', en = 'Rotation lag', ua = 'Інерція обертання'},
    {f = 'rate_max_deg', mn = 100, mx = 1000, fmt = '%.0f', en = 'Max rate (deg/s)', ua = 'Макс. оберти (град/с)'},
    {f = 'expo', mn = 0, mx = 1, fmt = '%.2f', en = 'Stick expo', ua = 'Експо стіків'},
    {f = 'deadzone', mn = 0, mx = 0.2, fmt = '%.3f', en = 'Deadzone', ua = 'Мертва зона'},
    {f = 'model_scale', mn = 0.01, mx = 2, fmt = '%.2f', en = 'Model scale', ua = 'Масштаб моделі'},
    {f = 'ground_effect_strength', mn = 0, mx = 20, fmt = '%.1f', en = 'Ground effect', ua = 'Екранний ефект'},
    {f = 'ground_effect_radius', mn = 0, mx = 5, fmt = '%.1f', en = 'Ground effect radius', ua = 'Радіус екранного ефекту'},
    {f = 'ceiling_effect_strength', mn = 0, mx = 20, fmt = '%.1f', en = 'Ceiling effect', ua = 'Стельовий ефект'},
    {f = 'ceiling_effect_radius', mn = 0, mx = 5, fmt = '%.1f', en = 'Ceiling effect radius', ua = 'Радіус стельового ефекту'},
}

-- Expert-only: live physics sliders for the ACTIVE profile.
function UI:drawProfileEditor()
    local prof = self.cfg.profile
    imgui.Dummy(imgui.ImVec2(0, 10))
    imgui.PushStyleColor(imgui.Col.Text, theme.accent(0.9))
    imgui.TextUnformatted((i18n.lang == 'ua' and 'Фізика профілю: ' or 'Profile physics: ')
        .. self:profileTitle(self.cfg.active_profile))
    imgui.PopStyleColor()
    imgui.Separator()
    for _, row in ipairs(UI.PROFILE_FIELDS) do
        local b = self.floatBufs['pf_' .. row.f]
        if not b then b = new.float(); self.floatBufs['pf_' .. row.f] = b end
        b[0] = prof[row.f] or 0
        imgui.PushItemWidth(220)
        if imgui.SliderFloat(rl(row) .. '##pf' .. row.f, b, row.mn, row.mx, row.fmt) then
            prof[row.f] = b[0]; self:markDirty()
        end
        imgui.PopItemWidth()
    end
    -- drag vectors, linear + quadratic x fwd/right/up
    for _, kind in ipairs({'drag_linear', 'drag_quadratic'}) do
        imgui.TextUnformatted(kind == 'drag_linear'
            and (i18n.lang == 'ua' and 'Лінійний опір' or 'Linear drag')
            or (i18n.lang == 'ua' and 'Квадратичний опір' or 'Quadratic drag'))
        for _, axis in ipairs({'fwd', 'right', 'up'}) do
            local id = 'pf_' .. kind .. axis
            local b = self.floatBufs[id]
            if not b then b = new.float(); self.floatBufs[id] = b end
            b[0] = prof[kind][axis] or 0
            imgui.PushItemWidth(150)
            if imgui.SliderFloat(axis .. '##' .. id, b, 0,
                kind == 'drag_linear' and 2 or 0.2, '%.3f') then
                prof[kind][axis] = b[0]; self:markDirty()
            end
            imgui.PopItemWidth()
            if axis ~= 'up' then imgui.SameLine() end
        end
    end
end

function UI:drawProfileCard(key, w)
    local profile = self.cfg.profiles[key]
    if not profile then return end
    local active = (self.cfg.active_profile == key)
    local builtin = self:isBuiltinProfile(key)

    imgui.BeginGroup()
    local p = imgui.GetCursorScreenPos()
    local h = 168
    local dl = imgui.GetWindowDrawList()
    local hovered = imgui.IsMouseHoveringRect(p, imgui.ImVec2(p.x + w, p.y + h))
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h),
        theme.u32(hovered and theme.PANEL_HI or theme.PANEL), theme.ROUND_CARD)
    if active then
        dl:AddRect(p, imgui.ImVec2(p.x + w, p.y + h), theme.accentU32(0.9),
            theme.ROUND_CARD, 15, 2) -- 15 = all corners rounded (ImDrawCornerFlags_All)
    end

    local iconSz = 56
    -- custom profiles all share the gear-badge quad icon
    local tex = icons.get('profiles', 'profile_' .. key)
        or icons.get('profiles', 'profile_custom')
    local ix = p.x + (w - iconSz) / 2
    if tex then
        dl:AddImageRounded(tex, imgui.ImVec2(ix, p.y + 12),
            imgui.ImVec2(ix + iconSz, p.y + 12 + iconSz),
            imgui.ImVec2(0, 0), imgui.ImVec2(1, 1),
            theme.u32(imgui.ImVec4(1, 1, 1, 1)), iconSz * 0.24)
    end

    local name = self:profileTitle(key)
    local tw = imgui.CalcTextSize(name).x
    dl:AddText(imgui.ImVec2(p.x + (w - tw) / 2, p.y + 76), theme.u32(theme.TEXT), name)

    -- description, wrapped by hand into the card width
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 10, p.y + 96))
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + w - 20)
    imgui.PushStyleColor(imgui.Col.Text, theme.TEXT_DIM)
    imgui.TextUnformatted(builtin and t('profile_' .. key .. '_desc') or t('profile_custom_desc'))
    imgui.PopStyleColor()
    imgui.PopTextWrapPos()

    -- bottom row: Select (or Active) + round icon buttons to its right --
    -- duplicate always; rename/delete only for custom profiles
    local ua = i18n.lang == 'ua'
    local bw, gap = 24, 6
    local groupW = builtin and bw or (4 * bw + 3 * gap)
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 10, p.y + h - 32))
    if active then
        imgui.PushStyleColor(imgui.Col.Text, theme.accent(1))
        imgui.TextUnformatted(t('profile_active'))
        imgui.PopStyleColor()
    else
        if imgui.Button(t('profile_select') .. '##prof_' .. key,
            imgui.ImVec2(w - 20 - groupW - 8, 24)) then
            self.cfg.active_profile = key
            self.cfg.profile = profile
            self:markDirty()
        end
    end
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + w - 10 - groupW, p.y + h - 32))
    if self:iconRoundBtn('dup_' .. key, 'dup', false, bw) then
        self:duplicateProfile(key)
    end
    self:hint(ua and 'Дублювати профіль' or 'Duplicate profile')
    if not builtin then
        imgui.SameLine(0, gap)
        if self:iconRoundBtn('share_' .. key, 'share', false, bw) then
            self.shareKey, self.shareBuf = key, nil
        end
        self:hint(ua and 'Імпорт/експорт: скопіюй текст або встав чужий і застосуй'
            or 'Import/export: copy the text, or paste someone\'s and apply')
        imgui.SameLine(0, gap)
        if self:iconRoundBtn('ren_' .. key, 'ren', false, bw) then
            self.renameKey, self.renameBuf = key, nil
        end
        self:hint(ua and 'Перейменувати' or 'Rename')
        imgui.SameLine(0, gap)
        if self:iconRoundBtn('delp_' .. key, 'del', true, bw) then
            self:deleteProfile(key)
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h))
            imgui.Dummy(imgui.ImVec2(w, 0))
            imgui.EndGroup()
            return
        end
        self:hint(ua and 'Видалити профіль' or 'Delete profile')
    end

    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h))
    imgui.Dummy(imgui.ImVec2(w, 0))
    imgui.EndGroup()
end

-- ==================== search ====================

UI.SECTION_SPECS = {
    controller = 'controller', camera = 'camera', world = 'world',
    audio = 'audio', replay = 'replay', advanced = 'advanced',
}

-- Returns true when search results were drawn (section content skipped).
function UI:drawSearch()
    local ffi = require 'ffi'
    imgui.PushItemWidth(260)
    imgui.InputTextWithHint('##search', t('search_hint'), self.searchBuf, 64)
    imgui.PopItemWidth()
    local q = ffi.string(self.searchBuf):lower()
    if #q < 2 then return false end
    imgui.Dummy(imgui.ImVec2(0, 4))
    for secKey in pairs(UI.SECTION_SPECS) do
        for _, row in ipairs(sections[secKey]) do
            if row.f and rl(row):lower():find(q, 1, true) then
                if imgui.Selectable(rl(row) .. '   ->   ' .. t('sec_' .. secKey)
                    .. '##sr_' .. row.f) then
                    self.activeSection = secKey
                    self.sectionAlpha = 0
                    imgui.StrCopy(self.searchBuf, '')
                end
            end
        end
    end
    return true
end

-- ==================== spec-driven rows (sections.lua) ====================

function UI:drawRows(spec)
    for _, row in ipairs(spec) do
        local hidden = row.expert and not self.cfg.ui_expert
        if not hidden then
            if row.group then
                imgui.Dummy(imgui.ImVec2(0, 6))
                imgui.PushStyleColor(imgui.Col.Text, theme.accent(0.9))
                imgui.TextUnformatted(rl(row))
                imgui.PopStyleColor()
                imgui.Separator()
            else
                self:drawRow(row)
            end
        end
    end
end

function UI:drawRow(row)
    local cfg, label = self.cfg, rl(row)
    local id = '##r_' .. row.f
    if row.type == 'toggle' then
        self:toggleRow(label, cfg, row.f, rhint(row))
        return
    end
    if row.type == 'slider' then
        local b = self.floatBufs[row.f]
        if not b then b = new.float(); self.floatBufs[row.f] = b end
        b[0] = cfg[row.f] or 0
        imgui.PushItemWidth(220)
        if imgui.SliderFloat(label .. id, b, row.mn, row.mx, row.fmt or '%.2f') then
            cfg[row.f] = b[0]; self:markDirty()
        end
        imgui.PopItemWidth()
    elseif row.type == 'int' then
        local b = self.intBufs[row.f]
        if not b then b = new.int(); self.intBufs[row.f] = b end
        b[0] = cfg[row.f] or 0
        imgui.PushItemWidth(160)
        if imgui.InputInt(label .. id, b) then cfg[row.f] = b[0]; self:markDirty() end
        imgui.PopItemWidth()
        if row.axis then
            -- live preview of the assigned axis, so the mapping is
            -- instantly verifiable: wiggle the stick, watch the bar
            local idx = cfg[row.f]
            local raw = (idx and idx >= 1 and idx <= 8) and self.receiver.axesRaw[idx] or 1024
            imgui.SameLine()
            local dl = imgui.GetWindowDrawList()
            local p = imgui.GetCursorScreenPos()
            local w, h = 90, 14
            local y = p.y + 3
            dl:AddRectFilled(imgui.ImVec2(p.x, y), imgui.ImVec2(p.x + w, y + h),
                theme.u32(imgui.ImVec4(1, 1, 1, 0.08)), h / 2)
            dl:AddLine(imgui.ImVec2(p.x + w / 2, y + 2), imgui.ImVec2(p.x + w / 2, y + h - 2),
                theme.u32(imgui.ImVec4(1, 1, 1, 0.25)), 1)
            dl:AddCircleFilled(imgui.ImVec2(p.x + 5 + (w - 10) * raw / 2047, y + h / 2),
                5, theme.accentU32(1), 12)
            imgui.Dummy(imgui.ImVec2(w, h + 4))
        end
    elseif row.type == 'text' then
        local b = self.textBufs[row.f]
        if not b then b = new.char[32](tostring(cfg[row.f] or '')); self.textBufs[row.f] = b end
        imgui.PushItemWidth(160)
        if imgui.InputText(label .. id, b, 32) then
            local ffi = require 'ffi'
            cfg[row.f] = ffi.string(b); self:markDirty()
        end
        imgui.PopItemWidth()
    elseif row.type == 'combo' then
        local cur = (cfg[row.f] or 0) + 1
        local curItem = row.items[cur]
        local preview = curItem and rl(curItem) or tostring(cfg[row.f])
        imgui.PushItemWidth(220)
        if imgui.BeginCombo(label .. id, preview) then
            for i, item in ipairs(row.items) do
                if imgui.Selectable(rl(item) .. id .. i, i == cur) then
                    cfg[row.f] = i - 1; self:markDirty()
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()
    elseif row.type == 'key' then
        local text = (self.keyListen == row.f) and '...'
            or string.format('0x%02X', cfg[row.f] or 0)
        if imgui.Button(text .. id, imgui.ImVec2(70, 0)) then
            self.keyListen = (self.keyListen ~= row.f) and row.f or nil
        end
        imgui.SameLine(); imgui.TextUnformatted(label)
    elseif row.type == 'btn' then
        local v = cfg[row.f] or -1
        local text
        if self.btnListen == row.f then
            text = '...'
        elseif v >= 100 then -- axis-switch encoding, see net.lua AXIS_BTN_BASE
            local code = v - 100
            text = string.format('A%d%s', math.floor(code / 2) + 1,
                code % 2 == 0 and '+' or '-')
        elseif v >= 0 then
            text = 'B' .. v
        else
            text = '--'
        end
        if imgui.Button(text .. id, imgui.ImVec2(70, 0)) then
            if self.btnListen ~= row.f then
                self.btnListen = row.f
                self.btnListenSnap = self.receiver.buttonsRaw
                self.btnListenAxesSnap = {}
                for i = 1, 8 do self.btnListenAxesSnap[i] = self.receiver.axesRaw[i] end
            else
                cfg[row.f] = -1; self.btnListen = nil; self:markDirty() -- second click clears
            end
        end
        imgui.SameLine(); imgui.TextUnformatted(label)
    end
    local h = rhint(row)
    if h then self:hint(h) end
end

-- ==================== controller: picker + calibration ====================

function UI:drawController()
    local cfg, receiver = self.cfg, self.receiver
    imgui.PushStyleColor(imgui.Col.Text, theme.accent(0.9))
    imgui.TextUnformatted(t('sec_controller'))
    imgui.PopStyleColor()
    imgui.Separator()
    local ids = {}
    for id in pairs(receiver.devices) do ids[#ids + 1] = id end
    table.sort(ids)
    if imgui.ListBoxHeaderVec2('##devices', imgui.ImVec2(320, 76)) then
        if imgui.Selectable('Auto', cfg.selected_device_id == -1) then
            cfg.selected_device_id = -1; self:markDirty()
        end
        for _, id in ipairs(ids) do
            local dev = receiver.devices[id]
            if imgui.Selectable(string.format('[%d] %s', id, dev.name),
                cfg.selected_device_id == id) then
                cfg.selected_device_id = id; self:markDirty()
            end
        end
        imgui.ListBoxFooter()
    end

    self:drawRows(sections.controller)

    imgui.Dummy(imgui.ImVec2(0, 6))
    imgui.PushStyleColor(imgui.Col.Text, theme.accent(0.9))
    imgui.TextUnformatted(i18n.lang == 'ua' and 'Калібрування' or 'Calibration')
    imgui.PopStyleColor()
    imgui.Separator()
    self:drawCalibrationBlock()
end

-- Shared by the Controller section and the wizard's calibration step.
function UI:drawCalibrationBlock()
    local cfg, receiver = self.cfg, self.receiver
    if not self.calibrating then
        if imgui.Button(i18n.lang == 'ua' and 'Почати калібрування' or 'Start calibration',
            imgui.ImVec2(220, 30)) then
            self.calibrating = true
            self.calibTrack = {}
            for i = 1, 8 do
                local raw = receiver.axesRaw[i]
                self.calibTrack[i] = {min = raw, max = raw}
            end
        end
    else
        imgui.TextUnformatted(i18n.lang == 'ua'
            and 'Поганяй всі стіки по повному ходу, потім заверши по центрах.'
            or 'Sweep every stick to its limits, then finish with sticks centered.')
        local dl = imgui.GetWindowDrawList()
        for i = 1, 8 do
            local tr = self.calibTrack[i]
            local raw = receiver.axesRaw[i]
            tr.min, tr.max = math.min(tr.min, raw), math.max(tr.max, raw)
            local p = imgui.GetCursorScreenPos()
            local w = 260
            dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + 12),
                theme.u32(imgui.ImVec4(1, 1, 1, 0.08)), 6)
            dl:AddRectFilled(imgui.ImVec2(p.x + w * tr.min / 2047, p.y),
                imgui.ImVec2(p.x + w * tr.max / 2047, p.y + 12), theme.accentU32(0.35), 6)
            dl:AddCircleFilled(imgui.ImVec2(p.x + w * raw / 2047, p.y + 6), 5,
                theme.accentU32(1), 12)
            imgui.Dummy(imgui.ImVec2(w, 16))
        end
        if imgui.Button(i18n.lang == 'ua' and 'Завершити (стіки по центру)'
            or 'Finish (sticks centered)', imgui.ImVec2(260, 30)) then
            for i = 1, 8 do
                local tr = self.calibTrack[i]
                if tr.max - tr.min > 64 then -- only axes that actually moved
                    cfg.calib[i] = {min = tr.min, center = receiver.axesRaw[i], max = tr.max}
                end
            end
            self.calibrating = false
            self:markDirty()
        end
    end
end

-- ==================== osd section: style + appearance ====================

UI.OSD_STYLES = {'classic', 'skyline', 'recon', 'circuit'}

function UI:drawOsdSection()
    imgui.PushStyleColor(imgui.Col.Text, theme.accent(0.9))
    imgui.TextUnformatted('OSD')
    imgui.PopStyleColor()
    imgui.Separator()
    local cur = 1
    for i, s in ipairs(UI.OSD_STYLES) do if s == self.cfg.osd_style then cur = i end end
    local ua = i18n.lang == 'ua'
    local sel = self:segmented('osdstyle', {'Classic', 'Skyline', 'Recon', 'Circuit'}, cur, {
        ua and 'Класичний текстовий OSD.' or 'The classic text OSD.',
        ua and 'Сучасний білий HD: горизонт, стрічки, компас.' or 'Modern white HD: horizon, tapes, compass.',
        ua and 'Той самий, але моно-зелений, як аналогова камера.' or 'Same, mono green like an analog cam.',
        ua and 'Сім-рейсінговий: сітка, приціл, боксові показники, таймер з мілісекундами.'
            or 'Race-sim look: grid, crosshair, boxed readouts, millisecond timer.',
    })
    if sel then self.cfg.osd_style = UI.OSD_STYLES[sel]; self:markDirty() end

    imgui.Dummy(imgui.ImVec2(0, 10))
    imgui.PushStyleColor(imgui.Col.Text, theme.accent(0.9))
    imgui.TextUnformatted(i18n.lang == 'ua' and 'Вигляд меню' or 'Menu appearance')
    imgui.PopStyleColor()
    imgui.Separator()
    -- accent preset dots
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local x = p.x
    for _, a in ipairs(theme.ACCENTS) do
        local c = imgui.ImVec2(x + 14, p.y + 14)
        dl:AddCircleFilled(c, 12, theme.u32(imgui.ImVec4(a.r, a.g, a.b, 1)), 24)
        if theme.accentKey == a.key then
            dl:AddCircle(c, 15, theme.u32(imgui.ImVec4(1, 1, 1, 0.9)), 24, 2)
        end
        if imgui.IsMouseHoveringRect(imgui.ImVec2(c.x - 14, c.y - 14),
            imgui.ImVec2(c.x + 14, c.y + 14)) and imgui.IsMouseClicked(0) then
            theme.setAccent(a.key)
            self.cfg.ui_accent = a.key
            self:markDirty()
        end
        x = x + 36
    end
    imgui.Dummy(imgui.ImVec2(0, 34))
    self:toggleRow(ua and 'Debug-рядки (справа знизу)' or 'Debug lines (bottom right)',
        self.cfg, 'debug_overlay',
        ua and 'Технічна телеметрія фізики/колізій для розробки й тюнінгу.'
            or 'Physics/collision dev telemetry for debugging and tuning.')
    imgui.Dummy(imgui.ImVec2(0, 4))
    if imgui.Button(i18n.lang == 'ua' and 'Запустити майстер налаштування'
        or 'Run setup wizard', imgui.ImVec2(260, 28)) then
        self:startWizard()
    end
    imgui.Dummy(imgui.ImVec2(0, 4))
    local iconIdx = (self.cfg.ui_icon_style == 'mono') and 2 or 1
    local isel = self:segmented('iconstyle',
        {i18n.lang == 'ua' and 'Кольорові іконки' or 'Color icons',
         i18n.lang == 'ua' and 'Монохромні' or 'Mono glass'}, iconIdx)
    if isel then
        self.cfg.ui_icon_style = (isel == 2) and 'mono' or 'color'
        self:markDirty()
    end
end

-- ==================== replay section ====================

function UI:drawReplaySection()
    self:drawRows(sections.replay)
    imgui.Dummy(imgui.ImVec2(0, 6))
    imgui.PushStyleColor(imgui.Col.Text, theme.accent(0.9))
    imgui.TextUnformatted(i18n.lang == 'ua' and 'Збережені польоти' or 'Saved flights')
    imgui.PopStyleColor()
    imgui.Separator()

    if self.recorder.count > 0 then
        imgui.TextUnformatted(string.format(
            i18n.lang == 'ua' and 'У буфері: %d кадрів' or 'Buffered: %d frames',
            self.recorder.count))
        imgui.SameLine()
        if imgui.Button(i18n.lang == 'ua' and 'Зберегти##save' or 'Save##save') then
            self.recorder:save()
            self.replayFiles = nil
        end
    end

    if not self.replayFiles then
        self.replayFiles = {}
        for _, name in ipairs(Recorder.listFiles() or {}) do
            self.replayFiles[#self.replayFiles + 1] =
                {name = name, info = Recorder.fileInfo(name)}
        end
    end
    if imgui.Button(i18n.lang == 'ua' and 'Оновити список' or 'Refresh list') then
        self.replayFiles = nil
        return
    end
    imgui.SameLine()
    local totalBytes = 0
    for _, e in ipairs(self.replayFiles) do
        totalBytes = totalBytes + (e.info and e.info.size or 0)
    end
    imgui.PushStyleColor(imgui.Col.Text, theme.TEXT_DIM)
    imgui.TextUnformatted(string.format(
        i18n.lang == 'ua' and '%d файлів · %.1f МБ' or '%d files · %.1f MB',
        #self.replayFiles, totalBytes / 1048576))
    imgui.PopStyleColor()

    for _, e in ipairs(self.replayFiles) do
        local name = e.name
        if self:beginCard('##rp_' .. name, 44) then
            imgui.AlignTextToFramePadding()
            imgui.TextUnformatted(name)
            if e.info then
                imgui.SameLine()
                imgui.PushStyleColor(imgui.Col.Text, theme.TEXT_DIM)
                local dur = e.info.durationSec
                imgui.TextUnformatted(string.format('  %d:%02d · %.1f %s',
                    math.floor(dur / 60), math.floor(dur % 60),
                    e.info.size / 1048576, i18n.lang == 'ua' and 'МБ' or 'MB'))
                imgui.PopStyleColor()
            end
            imgui.SameLine(imgui.GetWindowWidth() - 132)
            if imgui.Button((i18n.lang == 'ua' and 'Грати' or 'Play') .. '##' .. name,
                imgui.ImVec2(70, 24)) then
                self.pendingPlayback = name
                self.show[0] = false
            end
            imgui.SameLine()
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.85, 0.25, 0.22, 0.55))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.95, 0.28, 0.24, 0.85))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(1.0, 0.3, 0.26, 1))
            if imgui.Button('X##del_' .. name, imgui.ImVec2(26, 24)) then
                Recorder.deleteFile(name)
                self.replayFiles = nil
            end
            imgui.PopStyleColor(3)
            self:hint(i18n.lang == 'ua' and 'Видалити цей запис назавжди'
                or 'Delete this recording permanently')
            if not self.replayFiles then self:endCard(); return end
        end
        self:endCard()
    end
end

function UI:consumePendingPlayback()
    local name = self.pendingPlayback
    self.pendingPlayback = nil
    return name
end

-- ==================== first-run wizard ====================
-- Steps: 1 language, 2 controller check, 3 calibration, 4 deadzone
-- (graphical -- novices skip this and then report "drift" in ACRO),
-- 5 binds, 6 profile. cfg.ui_wizard_done gates auto-start.

UI.WIZARD_STEPS = 6

function UI:startWizard()
    self.wizardStep = 1
    self.calibrating = false
end

function UI:drawWizard()
    local cfg = self.cfg
    local ua = i18n.lang == 'ua'
    imgui.Dummy(imgui.ImVec2(0, 8))
    imgui.TextUnformatted(string.format('%s  %d / %d',
        ua and 'Налаштування' or 'Setup', self.wizardStep, UI.WIZARD_STEPS))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 8))

    local step = self.wizardStep
    if step == 1 then
        imgui.TextUnformatted(ua and 'Мова / Language:' or 'Language / Мова:')
        local sel = self:segmented('wizlang', {'English', 'Українська'},
            i18n.lang == 'ua' and 2 or 1)
        if sel then
            local lang = sel == 2 and 'ua' or 'en'
            i18n.set(lang); cfg.ui_lang = lang; self:markDirty()
        end
    elseif step == 2 then
        local conn = self.receiver.connected
        local dev = self.receiver.effectiveDeviceId
            and self.receiver.devices[self.receiver.effectiveDeviceId]
        if conn and dev then
            imgui.PushStyleColor(imgui.Col.Text, theme.OK)
            imgui.TextUnformatted((ua and 'Контролер знайдено: ' or 'Controller found: ') .. dev.name)
            imgui.PopStyleColor()
        else
            imgui.PushStyleColor(imgui.Col.Text, theme.DANGER)
            imgui.TextUnformatted(ua and 'Контролер не знайдено.' or 'No controller detected.')
            imgui.PopStyleColor()
            imgui.PushTextWrapPos(500)
            imgui.TextUnformatted(ua
                and 'Запусти controllerd (див. README) і підключи пульт/геймпад -- цей крок оновиться сам.'
                or 'Start controllerd (see README) and plug in a transmitter/gamepad -- this step updates by itself.')
            imgui.PopTextWrapPos()
        end
    elseif step == 3 then
        imgui.PushTextWrapPos(520)
        imgui.TextUnformatted(ua
            and 'Калібрування: без нього стіки читаються неправильно. Не пропускай.'
            or 'Calibration: without it stick ranges read wrong. Do not skip.')
        imgui.PopTextWrapPos()
        self:drawCalibrationBlock()
    elseif step == 4 then
        imgui.PushTextWrapPos(520)
        imgui.TextUnformatted(ua
            and 'Мертва зона: якщо дрон у ACRO повільно крутиться сам -- стіки не повертаються ідеально в нуль. Подивись на точки нижче: рух БЕЗ торкання стіків = дрейф. Збільшуй зону, поки точки не заспокояться всередині кола.'
            or 'Deadzone: if the drone slowly rotates by itself in ACRO, your sticks do not return exactly to zero. Watch the dots below: movement WITHOUT touching the sticks = drift. Raise the deadzone until the dots rest inside the circle.')
        imgui.PopTextWrapPos()
        self:drawDeadzoneBlock()
    elseif step == 5 then
        imgui.TextUnformatted(ua and 'Основні кнопки (можна змінити потім):'
            or 'Key bindings (changeable later):')
        for _, f in ipairs({'arm_toggle_vk', 'arm_toggle_btn', 'recall_vk', 'recall_btn',
            'flight_mode_cycle_vk', 'flight_mode_cycle_btn'}) do
            for _, row in ipairs(sections.controller) do
                if row.f == f then self:drawRow(row) end
            end
        end
    elseif step == 6 then
        imgui.TextUnformatted(t('fly_profiles'))
        local cardW = (imgui.GetContentRegionAvail().x - 3 * 10) / 4
        for i, key in ipairs(UI.PROFILE_ORDER) do
            if i > 1 then imgui.SameLine() end
            self:drawProfileCard(key, cardW)
        end
    end

    imgui.Dummy(imgui.ImVec2(0, 14))
    if step > 1 and imgui.Button(ua and 'Назад' or 'Back', imgui.ImVec2(90, 30)) then
        self.wizardStep = step - 1
    end
    if step > 1 then imgui.SameLine() end
    local last = step == UI.WIZARD_STEPS
    if imgui.Button((last and (ua and 'Готово' or 'Done') or (ua and 'Далі' or 'Next')),
        imgui.ImVec2(90, 30)) then
        if last then
            self.wizardStep = nil
            cfg.ui_wizard_done = true
            self:markDirty()
        else
            self.wizardStep = step + 1
        end
    end
    imgui.SameLine(imgui.GetWindowWidth() - 110)
    if imgui.Button(ua and 'Пропустити' or 'Skip all', imgui.ImVec2(90, 30)) then
        self.wizardStep = nil
        cfg.ui_wizard_done = true
        self:markDirty()
    end
end

-- Live stick crosshair boxes with the deadzone circle overlaid; the slider
-- writes the same deadzone into every profile (novice-friendly: one knob).
function UI:drawDeadzoneBlock()
    local vecmath = require 'vecmath'
    local cfg = self.cfg
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local box, gap = 120, 24
    local dz = cfg.profile.deadzone or 0.04
    local sticksXY = {
        {x = vecmath.axisBi(cfg.calib, self.receiver.axesRaw, cfg.axis_yaw),
         y = -vecmath.axisBi(cfg.calib, self.receiver.axesRaw, cfg.axis_throttle)},
        {x = vecmath.axisBi(cfg.calib, self.receiver.axesRaw, cfg.axis_roll),
         y = vecmath.axisBi(cfg.calib, self.receiver.axesRaw, cfg.axis_pitch)},
    }
    for i, st in ipairs(sticksXY) do
        local x0 = p.x + (i - 1) * (box + gap)
        dl:AddRectFilled(imgui.ImVec2(x0, p.y), imgui.ImVec2(x0 + box, p.y + box),
            theme.u32(imgui.ImVec4(1, 1, 1, 0.06)), 10)
        local cx, cy = x0 + box / 2, p.y + box / 2
        dl:AddCircle(imgui.ImVec2(cx, cy), dz * box / 2,
            theme.accentU32(0.8), 32, 1.5)
        local px = cx + theme.clamp(st.x, -1, 1) * (box / 2 - 6)
        local py = cy + theme.clamp(st.y, -1, 1) * (box / 2 - 6)
        local inside = (st.x * st.x + st.y * st.y) <= dz * dz
        dl:AddCircleFilled(imgui.ImVec2(px, py), 5,
            theme.u32(inside and theme.OK or theme.DANGER), 16)
    end
    imgui.Dummy(imgui.ImVec2(0, box + 10))
    local b = self.floatBufs['wiz_dz']
    if not b then b = new.float(); self.floatBufs['wiz_dz'] = b end
    b[0] = dz
    imgui.PushItemWidth(box * 2 + gap)
    if imgui.SliderFloat((i18n.lang == 'ua' and 'Мертва зона' or 'Deadzone') .. '##wizdz',
        b, 0.0, 0.2, '%.3f') then
        for _, prof in pairs(cfg.profiles) do prof.deadzone = b[0] end
        self:markDirty()
    end
    imgui.PopItemWidth()
end

-- ==================== replay player overlay (YouTube-style) ====================

local function fmtTime(s)
    s = math.max(0, s or 0)
    return string.format('%d:%05.2f', math.floor(s / 60), s % 60)
end

function UI:consumeStopRequest()
    local v = self.stopRequest
    self.stopRequest = nil
    return v
end

-- Fullscreen pass-through window with an auto-hiding bottom glass bar.
-- Shown instead of the menu while a replay is playing.
function UI:drawPlayerOverlay()
    local player = self.player
    local io = imgui.GetIO()
    local dw, dh = io.DisplaySize.x, io.DisplaySize.y

    -- auto-hide: reveal on mouse move / pause, fade after 2s idle
    local m = io.MousePos
    if not self.lastMouse or m.x ~= self.lastMouse.x or m.y ~= self.lastMouse.y then
        self.lastMouseMoveClock = os.clock()
    end
    self.lastMouse = {x = m.x, y = m.y}
    local wantBar = player.paused or (os.clock() - (self.lastMouseMoveClock or 0) < 2.0)
    self.playerBarAlpha = theme.approach(self.playerBarAlpha or 1, wantBar and 1 or 0, self.dt, 8)
    local a = self.playerBarAlpha
    if a < 0.02 then return end

    local barW, barH = dw * 0.6, 92
    local bx, by = (dw - barW) / 2, dh - barH - 28
    imgui.SetNextWindowPos(imgui.ImVec2(bx, by), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(barW, barH), imgui.Cond.Always)
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, a)
    theme.pushWindow()
    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar
    if imgui.Begin('##fpv_player', nil, flags) then
        -- scrub
        local b = self.floatBufs['scrub2']
        if not b then b = new.float(); self.floatBufs['scrub2'] = b end
        b[0] = player.playbackTime
        imgui.PushItemWidth(barW - 36)
        if imgui.SliderFloat('##scrub2s', b, 0, player.durationSec, '') then
            player:seek(b[0])
        end
        imgui.PopItemWidth()

        -- controls row
        if imgui.Button(player.paused and '  >  ' or ' || ', imgui.ImVec2(44, 26)) then
            player.paused = not player.paused
        end
        imgui.SameLine()
        if imgui.Button('|<##fs1', imgui.ImVec2(30, 26)) then
            player.paused = true; player:seek(player.playbackTime - 1 / 30)
        end
        imgui.SameLine()
        if imgui.Button('>|##fs2', imgui.ImVec2(30, 26)) then
            player.paused = true; player:seek(player.playbackTime + 1 / 30)
        end
        imgui.SameLine()
        imgui.TextUnformatted(fmtTime(player.playbackTime) .. ' / ' .. fmtTime(player.durationSec))
        imgui.SameLine()
        local speeds = {0.25, 0.5, 1.0, 2.0}
        local cur = 3
        for i, s in ipairs(speeds) do if math.abs(player.speed - s) < 0.01 then cur = i end end
        local sel = self:segmented('pspeed', {'.25x', '.5x', '1x', '2x'}, cur)
        if sel then player.speed = speeds[sel] end
        imgui.SameLine(barW - 80)
        if imgui.Button(i18n.lang == 'ua' and 'Стоп' or 'Stop', imgui.ImVec2(60, 26)) then
            self.stopRequest = true
        end
    end
    imgui.End()
    theme.popWindow()
    imgui.PopStyleVar()
end

-- ============================ window ============================

function UI:buildWindow()
    -- The player overlay is its own frame, NOT gated on the menu being
    -- open -- like a video player, it appears over the running replay by
    -- itself and auto-hides; the menu window yields entirely during
    -- playback.
    imgui.OnFrame(function() return self.player:isActive() end, function()
        local now = os.clock()
        self.dt = theme.clamp(now - self.lastFrameClock, 0, 0.05)
        self.lastFrameClock = now
        self:drawPlayerOverlay()
    end)

    imgui.OnFrame(function() return self.show[0] and not self.player:isActive() end, function()
        local now = os.clock()
        self.dt = theme.clamp(now - self.lastFrameClock, 0, 0.05)
        self.lastFrameClock = now
        self.sectionAlpha = theme.approach(self.sectionAlpha, 1.0, self.dt, 10)
        if not self.hintHeldThisFrame then self.hintText = nil end
        self.hintHeldThisFrame = false
        if not self.cfg.ui_wizard_done and not self.wizardStep then
            self:startWizard()
        end

        local io = imgui.GetIO()
        local dw, dh = io.DisplaySize.x, io.DisplaySize.y
        imgui.SetNextWindowPos(imgui.ImVec2(dw / 2, dh / 2), imgui.Cond.Always,
            imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(dw * 0.72, dh * 0.78), imgui.Cond.Always)

        theme.pushWindow()
        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
            + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar
            + imgui.WindowFlags.NoScrollWithMouse
        if imgui.Begin('##fpv_modern', self.show, flags) then
            self:drawStatusBar()
            self:drawUpdateBanner()

            -- content area between status bar and dock, own scroll
            local contentH = imgui.GetContentRegionAvail().y - DOCK_H - 6
            imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, self.sectionAlpha)
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
            if imgui.BeginChild('##content', imgui.ImVec2(0, contentH), false) then
                if self.wizardStep then self:drawWizard()
                elseif self:drawSearch() then -- search results replace content
                elseif self.activeSection == 'fly' then self:drawFly()
                elseif self.activeSection == 'controller' then self:drawController()
                elseif self.activeSection == 'camera' then self:drawRows(sections.camera)
                elseif self.activeSection == 'world' then self:drawRows(sections.world)
                elseif self.activeSection == 'audio' then self:drawRows(sections.audio)
                elseif self.activeSection == 'osd' then self:drawOsdSection()
                elseif self.activeSection == 'replay' then self:drawReplaySection()
                elseif self.activeSection == 'advanced' then self:drawRows(sections.advanced)
                end
            end
            imgui.EndChild()
            imgui.PopStyleColor()
            imgui.PopStyleVar()

            self:drawDock()
        end
        imgui.End()
        theme.popWindow()
    end)
end

-- Called once per main-loop tick: key/button bind capture (can't run inside
-- imgui callbacks -- isKeyJustPressed is a game-loop-side API) + autosave.
function UI:processInput()
    if self.keyListen then
        for vk = 3, 254 do
            if isKeyJustPressed(vk) then
                self.cfg[self.keyListen] = vk
                self.keyListen = nil
                self:markDirty()
                break
            end
        end
    end
    if self.btnListen then
        local nowBtns = self.receiver.buttonsRaw
        local rising = bit.band(nowBtns, bit.bnot(self.btnListenSnap))
        if rising ~= 0 then
            local idx = 0
            while bit.band(rising, bit.lshift(1, idx)) == 0 do idx = idx + 1 end
            self.cfg[self.btnListen] = idx
            self.btnListen = nil
            self:markDirty()
        else
            self.btnListenSnap = nowBtns
            -- RC switches usually arrive as AXES (EdgeTX maps them to
            -- channels 5-8), never as joystick buttons -- a big jump from
            -- the listen-start position binds as an axis-switch.
            for i = 1, 8 do
                local d = self.receiver.axesRaw[i] - (self.btnListenAxesSnap[i] or 1024)
                if math.abs(d) > 700 then
                    self.cfg[self.btnListen] = self.receiver.AXIS_BTN_BASE
                        + (i - 1) * 2 + (d > 0 and 0 or 1)
                    self.btnListen = nil
                    self:markDirty()
                    break
                end
            end
        end
    end
    if self.cfgDirty then
        self.configObj:save()
        self.cfgDirty = false
    end
end

return UI
