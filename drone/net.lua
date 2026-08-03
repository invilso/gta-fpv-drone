-- UDP receiver for the controller wire protocol (v2, multi-device). See
-- protocol.lua for the packet format and docs/controller-bridge.md for the
-- device-selection design; this class owns the live socket state that used
-- to be module-locals (axesRaw/lastSeq/connected/buttonsRaw).
local Class = require 'class'
local protocol = require 'protocol'

local ok_socket, socketlib = pcall(require, 'luasocket.socket')
if not ok_socket then socketlib = _G.socket end

local Receiver = Class('Receiver')

-- A device not heard from for this long is dropped from the live picker
-- list and can no longer be auto-selected -- see docs/controller-bridge.md.
local DEVICE_STALE_SEC = 3.0

function Receiver:init(cfg)
    self.cfg = cfg
    self.udp = nil
    self.axesRaw = {1024, 1024, 1024, 1024, 1024, 1024, 1024, 1024}
    self.lastSeq = nil
    self.lastRxClock = -1000
    self.failsafeFlag = false
    self.connected = false
    -- Rising-edge detection for controller button bits: prevButtonsRaw is
    -- the snapshot from the previous packet, so a switch only "just
    -- pressed" on the packet where the bit actually flips 0->1.
    self.buttonsRaw = 0
    self.prevButtonsRaw = 0
    -- Every device seen recently: [deviceId] = {name=, lastSeen=}, used by
    -- ui.lua's Controller picker and by :effectiveSelection() below.
    self.devices = {}
    self.effectiveDeviceId = nil -- device currently driving axesRaw/buttonsRaw (auto or manually pinned)
end

function Receiver:open()
    if self.udp then self.udp:close(); self.udp = nil end
    if not socketlib then return false, 'luasocket missing' end
    self.udp = socketlib.udp()
    local ok, err = self.udp:setsockname('127.0.0.1', self.cfg.port)
    if not ok then
        self.udp:close()
        self.udp = nil
        return false, tostring(err)
    end
    self.udp:settimeout(0)
    return true
end

-- cfg.selected_device_id (-1 = auto): if set and still live, use it;
-- otherwise fall back to the lowest-id live device. Implements "one device
-- connected -> use it automatically; two connected and nothing chosen ->
-- use the first, but let the menu override" from docs/controller-bridge.md.
function Receiver:effectiveSelection()
    local want = self.cfg.selected_device_id
    if want and want >= 0 and self.devices[want] then
        return want
    end
    local best = nil
    for id in pairs(self.devices) do
        if best == nil or id < best then best = id end
    end
    return best
end

function Receiver:poll()
    if not self.udp then return end
    local latestByDevice = {} -- deviceId -> most recent packet this poll(), see below
    for _ = 1, 64 do
        local data = self.udp:receive()
        if not data then break end
        local pkt = protocol.parsePacket(data)
        if pkt then
            local dev = self.devices[pkt.deviceId]
            if not dev then dev = {}; self.devices[pkt.deviceId] = dev end
            dev.name = pkt.name
            dev.lastSeen = os.clock()
            latestByDevice[pkt.deviceId] = pkt
        end
    end

    local now = os.clock()
    for id, dev in pairs(self.devices) do
        if now - dev.lastSeen > DEVICE_STALE_SEC then self.devices[id] = nil end
    end

    local effective = self:effectiveSelection()
    if effective ~= self.effectiveDeviceId then
        self.effectiveDeviceId = effective
        self.lastSeq = nil -- switched device (auto or manual) -- restart sequence tracking
    end

    local pkt = effective and latestByDevice[effective]
    if pkt and protocol.seqNewer(pkt.seq, self.lastSeq) then
        self.lastSeq = pkt.seq
        self.axesRaw = pkt.axes
        self.failsafeFlag = (bit.band(pkt.flags, protocol.FLAG_FAILSAFE) ~= 0)
        self.lastRxClock = os.clock()
        self.prevButtonsRaw = self.buttonsRaw
        self.buttonsRaw = pkt.buttons
    end

    self.connected = (not self.failsafeFlag) and ((os.clock() - self.lastRxClock) * 1000 < self.cfg.failsafe_ms)
    if not self.connected then self.lastSeq = nil end
end

-- Rising-edge check for a single controller button bit -- true only on the
-- poll where it went from 0 to 1, same "just pressed" semantics as
-- isKeyJustPressed for the keyboard side of these same switches.
function Receiver:btnJustPressed(bitIdx)
    if bitIdx < 0 then return false end
    local mask = bit.lshift(1, bitIdx)
    return bit.band(self.buttonsRaw, mask) ~= 0 and bit.band(self.prevButtonsRaw, mask) == 0
end

function Receiver:close()
    if self.udp then self.udp:close(); self.udp = nil end
end

return Receiver
