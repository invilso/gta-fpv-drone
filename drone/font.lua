-- Custom menu font (Inter), auto-downloaded once to
-- moonloader/drone/resources/Inter.ttf and swapped in via
-- mimgui.OnInitialize -- the library's own supported hook for a
-- script-specific font, firing once right after mimgui loads its own
-- default into this script's own isolated ImGui context (each
-- mimgui-using script gets its own via renderer:SwitchContext(), not one
-- shared atlas). License: SIL OFL 1.1, see resources/Inter-OFL.txt.
local imgui = require 'mimgui'
local dlstatus = require 'moonloader'.download_status

local M = {}

local RESOURCES_DIR = getWorkingDirectory() .. '\\drone\\resources'
local INTER_FONT_PATH = RESOURCES_DIR .. '\\Inter.ttf'
-- The variable-font (default/Regular instance) from Google Fonts' own repo
-- mirror -- stb_truetype (mimgui's rasterizer) reads the base glyph outlines
-- fine and ignores the variable axes it doesn't understand; no single-file
-- static-instance build was available at a stable URL.
local INTER_FONT_URL = 'https://raw.githubusercontent.com/google/fonts/main/ofl/inter/Inter%5Bopsz%2Cwght%5D.ttf'

-- rendererReady mirrors whether mimgui's own OnInitialize has fired yet for
-- this script (i.e. whether it's safe to touch imgui.GetIO()/Fonts at all --
-- that requires the D3D9 context mimgui creates lazily on first render).
-- fontApplied guards against redoing the swap twice. Together these let
-- applyInterFont() be called from two different, unordered triggers (the
-- menu being opened for the first time, and the download finishing) and
-- still only do real work once, whichever happens second.
local rendererReady = false
local fontApplied = false

local function applyInterFont()
    if fontApplied or not rendererReady then return end
    if not doesFileExist(INTER_FONT_PATH) then return end
    imgui.GetIO().Fonts:Clear()
    -- Same Cyrillic-glyph-ranges pattern mimgui's own default-font setup
    -- uses -- this script's own labels are English, but keeping Cyrillic
    -- coverage costs nothing and matches the library's own default.
    local builder = imgui.ImFontGlyphRangesBuilder()
    builder:AddRanges(imgui.GetIO().Fonts:GetGlyphRangesCyrillic())
    local glyphRanges = imgui.ImVector_ImWchar()
    builder:BuildRanges(glyphRanges)
    imgui.GetIO().Fonts:AddFontFromFileTTF(INTER_FONT_PATH, 15, nil, glyphRanges[0].Data)
    imgui.InvalidateFontsTexture() -- safe even after the menu's already been shown -- rebuilds next frame
    fontApplied = true
end

-- Fire-and-forget: only downloads once (skipped if the file's already
-- there). If the menu got opened (and applyInterFont already ran once with
-- the file still missing) before this finishes, calling it again here
-- catches the swap up live instead of waiting for the next script reload.
function M.ensure()
    if doesFileExist(INTER_FONT_PATH) then return end
    if not doesDirectoryExist(RESOURCES_DIR) then createDirectory(RESOURCES_DIR) end
    downloadUrlToFile(INTER_FONT_URL, INTER_FONT_PATH, function(_, status)
        if status ~= dlstatus.STATUSEX_ENDDOWNLOAD and status ~= dlstatus.STATUS_ENDDOWNLOADDATA then return end
        applyInterFont()
    end)
end

imgui.OnInitialize(function()
    rendererReady = true
    applyInterFont() -- covers the common case: file already existed from an earlier run
end)

return M
