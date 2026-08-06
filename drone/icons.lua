-- Icon textures for the modern menu. PNG tiles generated offline by
-- resources/icons/generate.py (macOS-style gradient squircles); loaded
-- lazily because mimgui's renderer only exists after its OnInitialize.
-- get() returns nil until the renderer is up -- callers draw a fallback
-- (plain rounded rect) for those first frames.
local imgui = require 'mimgui'

local M = {}

local DIR = getWorkingDirectory() .. '\\drone\\resources\\icons\\'
local cache = {} -- relative path -> texture (false = load failed, don't retry)

-- style: 'color' | 'mono' | 'profiles'
function M.get(style, name)
    local rel = style .. '\\' .. name .. '.png'
    local tex = cache[rel]
    if tex ~= nil then return tex or nil end
    if not imgui.IsInitialized() then return nil end
    local path = DIR .. rel
    if not doesFileExist(path) then
        print('icon missing: ' .. path)
        cache[rel] = false
        return nil
    end
    tex = imgui.CreateTextureFromFile(path)
    if not tex then
        print('icon failed to load: ' .. path)
        cache[rel] = false
        return nil
    end
    cache[rel] = tex
    return tex
end

return M
