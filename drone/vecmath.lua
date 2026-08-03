-- Vector math, normalization helpers, and the uint/int pointer-compare fix
-- (see docs/physics.md, docs/collision.md).
local M = {}

function M.clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

-- See docs/physics.md ("the two drone won't fall bugs").
function M.samePtr(a, b) return bit.tobit(a) == bit.tobit(b) end

function M.vAdd(a, b, s) return {x = a.x + b.x * (s or 1), y = a.y + b.y * (s or 1), z = a.z + b.z * (s or 1)} end
function M.vSub(a, b) return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z} end
function M.vScale(a, s) return {x = a.x * s, y = a.y * s, z = a.z * s} end
function M.vDot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function M.vCross(a, b)
    return {x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x}
end
function M.vLen(a) return math.sqrt(M.vDot(a, a)) end
function M.vNorm(a)
    local l = M.vLen(a)
    if l < 1e-9 then return {x = 0, y = 0, z = 0} end
    return {x = a.x / l, y = a.y / l, z = a.z / l}
end

-- Rotate v around unit axis by angle (radians), Rodrigues' formula.
function M.vRotate(v, axis, angle)
    local c, s = math.cos(angle), math.sin(angle)
    local cross = M.vCross(axis, v)
    local dot = M.vDot(axis, v)
    return {
        x = v.x * c + cross.x * s + axis.x * dot * (1 - c),
        y = v.y * c + cross.y * s + axis.y * dot * (1 - c),
        z = v.z * c + cross.z * s + axis.z * dot * (1 - c),
    }
end

function M.axisBi(calib, axesRaw, i)
    local c = calib[i]
    local raw = axesRaw[i]
    local v
    if raw >= c.center then
        v = (raw - c.center) / math.max(1, c.max - c.center)
    else
        v = (raw - c.center) / math.max(1, c.center - c.min)
    end
    return M.clamp(v, -1, 1)
end

function M.axisUni(calib, axesRaw, i)
    local c = calib[i]
    return M.clamp((axesRaw[i] - c.min) / math.max(1, c.max - c.min), 0, 1)
end

function M.applyExpoDeadzone(v, expo, dz)
    local s = (v < 0) and -1 or 1
    local a = math.abs(v)
    if a < dz then return 0 end
    a = (a - dz) / (1 - dz)
    a = expo * a * a * a + (1 - expo) * a
    return s * M.clamp(a, 0, 1)
end

-- Pseudo-Perlin turbulence: sum of a few sine waves at incommensurate
-- frequencies/phases, amplitudes summing to 1. Not true Perlin noise, just
-- smooth bounded pseudo-randomness -- good enough for wind gusts.
function M.turbulence1D(t, seed)
    return 0.6 * math.sin(t * 0.9 + seed) + 0.3 * math.sin(t * 2.3 + seed * 1.7) + 0.1 * math.sin(t * 5.1 + seed * 3.1)
end

return M
