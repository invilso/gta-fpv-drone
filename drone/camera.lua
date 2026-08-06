-- FPV camera. The native in-vehicle camera (activated via warpCharIntoCar
-- in drone.lua's :spawn()) is what actually banks correctly with the
-- drone's own matrix, so this module has almost nothing left to do every
-- tick -- see docs/orientation.md for why the alternatives don't work.
local ffi = require 'ffi'
local SAMemory = require 'SAMemory'
SAMemory.require('CCamera') -- for TheCamera.mCameraMatrix / aCams -- see docs/orientation.md

local M = {}

-- Disabling the camera's own geometry-avoidance -- reasonable regardless of
-- camera mode, so unconditional, called once per tick.
function M.update()
    local cam = ffi.cast('CCamera*', SAMemory.camera)
    cam.bMoveCamToAvoidGeom = false
end

-- cam_tilt_deg is applied in physics.lua's Drone:applyTransform (baked into
-- the render matrix, not written to CCam) -- see docs/orientation.md. The
-- old CCam.aCams[0].fTilt write attempt is gone; it never had any effect.

return M
