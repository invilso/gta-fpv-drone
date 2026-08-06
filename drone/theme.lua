-- Visual language of the modern menu: accent presets, the glass look, and
-- animation easing. Every color decision lives here so sections/widgets
-- never hardcode style.
local imgui = require 'mimgui'

local M = {}

-- Accent presets (no free color picker by design). Order = display order
-- in the appearance settings.
M.ACCENTS = {
    {key = 'pink',   r = 0.96, g = 0.36, b = 0.66},
    {key = 'orange', r = 1.00, g = 0.45, b = 0.10},
    {key = 'cyan',   r = 0.25, g = 0.72, b = 1.00},
    {key = 'lime',   r = 0.55, g = 0.90, b = 0.35},
    {key = 'violet', r = 0.64, g = 0.48, b = 1.00},
    {key = 'white',  r = 0.95, g = 0.95, b = 0.97},
}

M.accentKey = 'pink'

local function findAccent(key)
    for _, a in ipairs(M.ACCENTS) do
        if a.key == key then return a end
    end
    return M.ACCENTS[1]
end

function M.setAccent(key) M.accentKey = key end

function M.accent(alpha)
    local a = findAccent(M.accentKey)
    return imgui.ImVec4(a.r, a.g, a.b, alpha or 1.0)
end

function M.accentU32(alpha)
    return imgui.ColorConvertFloat4ToU32(M.accent(alpha))
end

-- Base glass palette (dark, game slightly showing through).
M.BG        = imgui.ImVec4(0.055, 0.06, 0.085, 0.86)
M.PANEL     = imgui.ImVec4(1, 1, 1, 0.055)  -- cards / dock plate
M.PANEL_HI  = imgui.ImVec4(1, 1, 1, 0.10)   -- hovered card
M.BORDER    = imgui.ImVec4(1, 1, 1, 0.09)
M.TEXT      = imgui.ImVec4(0.94, 0.95, 0.97, 1)
M.TEXT_DIM  = imgui.ImVec4(0.62, 0.64, 0.70, 1)
M.DANGER    = imgui.ImVec4(1.00, 0.35, 0.30, 1)
M.OK        = imgui.ImVec4(0.35, 0.85, 0.45, 1)

function M.u32(v4, alphaMul)
    if alphaMul then v4 = imgui.ImVec4(v4.x, v4.y, v4.z, v4.w * alphaMul) end
    return imgui.ColorConvertFloat4ToU32(v4)
end

M.ROUND_WINDOW = 18.0
M.ROUND_CARD = 12.0
M.ROUND_WIDGET = 10.0

-- Frame-rate-independent exponential approach: cur -> target, `speed`/sec.
function M.approach(cur, target, dt, speed)
    return cur + (target - cur) * (1 - math.exp(-(speed or 12) * dt))
end

function M.lerp(a, b, t) return a + (b - a) * t end

function M.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-- Push the glass window style; every Begin() of the modern UI goes through
-- this pair so the whole thing restyles from one place.
function M.pushWindow()
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, M.ROUND_WINDOW)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(18, 16))
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, M.ROUND_WIDGET)
    imgui.PushStyleVarFloat(imgui.StyleVar.GrabRounding, M.ROUND_WIDGET)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(10, 7))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(10, 9))
    imgui.PushStyleColor(imgui.Col.WindowBg, M.BG)
    imgui.PushStyleColor(imgui.Col.Border, M.BORDER)
    imgui.PushStyleColor(imgui.Col.Text, M.TEXT)
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(1, 1, 1, 0.07))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(1, 1, 1, 0.11))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(1, 1, 1, 0.14))
    imgui.PushStyleColor(imgui.Col.SliderGrab, M.accent(0.95))
    imgui.PushStyleColor(imgui.Col.SliderGrabActive, M.accent(1.0))
    imgui.PushStyleColor(imgui.Col.CheckMark, M.accent(1.0))
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.08))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, M.accent(0.30))
    imgui.PushStyleColor(imgui.Col.ButtonActive, M.accent(0.45))
    imgui.PushStyleColor(imgui.Col.Header, M.accent(0.25))
    imgui.PushStyleColor(imgui.Col.HeaderHovered, M.accent(0.35))
    imgui.PushStyleColor(imgui.Col.HeaderActive, M.accent(0.45))
    imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(0.08, 0.085, 0.11, 0.97))
    imgui.PushStyleColor(imgui.Col.ScrollbarBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ScrollbarGrab, imgui.ImVec4(1, 1, 1, 0.14))
end

function M.popWindow()
    imgui.PopStyleColor(18)
    imgui.PopStyleVar(7)
end

return M
