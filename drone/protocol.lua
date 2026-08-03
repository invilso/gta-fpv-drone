-- Controller wire format (v2) -- one packet per connected device, sent by
-- moonloader/drone/bridge/controllerd.py to the drone's own UDP port.
-- Deliberately NOT shared with moonloader/tx12.lua: that script stays on
-- the old single-device v1 format (28 bytes, no deviceId/name) on its own
-- port, untouched -- see docs/controller-bridge.md for why two formats
-- exist. MoonLoader scripts also run in isolated Lua states, so even if the
-- formats matched there'd be no clean way to share a live socket/parsed
-- packet between the two scripts without extra IPC plumbing.
local ffi = require 'ffi'

local M = {}

M.PROTOCOL_VERSION = 2
M.PACKET_SIZE = 45
M.FLAG_FAILSAFE = 0x01
M.NAME_LEN = 16

ffi.cdef[[
#pragma pack(push, 1)
typedef struct {
    char     magic[2];
    uint8_t  version;
    uint8_t  flags;
    uint32_t seq;
    uint16_t axes[8];
    uint32_t buttons;
    uint8_t  deviceId;
    char     name[16];
} controller_packet_t;
#pragma pack(pop)
]]

local ffiPacketOk = (ffi.sizeof('controller_packet_t') == M.PACKET_SIZE)
local pktBuf = ffiPacketOk and ffi.new('controller_packet_t') or nil

function M.parsePacket(data)
    if #data ~= M.PACKET_SIZE then return nil end
    if ffiPacketOk then
        ffi.copy(pktBuf, data, M.PACKET_SIZE)
        if pktBuf.magic[0] ~= 84 or pktBuf.magic[1] ~= 88 then return nil end -- "TX"
        if pktBuf.version ~= M.PROTOCOL_VERSION then return nil end
        local axes = {}
        for i = 0, 7 do axes[i + 1] = pktBuf.axes[i] end
        return {
            seq = tonumber(pktBuf.seq), flags = pktBuf.flags, axes = axes, buttons = tonumber(pktBuf.buttons),
            deviceId = pktBuf.deviceId, name = ffi.string(pktBuf.name, M.NAME_LEN):match('^[^%z]*'),
        }
    else
        local b = {data:byte(1, M.PACKET_SIZE)}
        if b[1] ~= 84 or b[2] ~= 88 or b[3] ~= M.PROTOCOL_VERSION then return nil end
        local function u16(o) return b[o] + b[o + 1] * 256 end
        local function u32(o) return b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216 end
        local axes = {}
        for i = 0, 7 do axes[i + 1] = u16(9 + i * 2) end
        local nameChars = {}
        for i = 1, M.NAME_LEN do
            local c = b[29 + i]
            if c == 0 then break end
            nameChars[#nameChars + 1] = string.char(c)
        end
        return {seq = u32(5), flags = b[4], axes = axes, buttons = u32(25), deviceId = b[29], name = table.concat(nameChars)}
    end
end

function M.seqNewer(newSeq, oldSeq)
    if oldSeq == nil then return true end
    local diff = (newSeq - oldSeq) % 4294967296
    return diff > 0 and diff < 2147483648
end

return M
