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

-- Subscription model: the daemon owns the one well-known port (cfg.port);
-- this receiver binds an EPHEMERAL port (the OS picks a free one, so any
-- number of game instances can run at once -- SAMP + singleplayer etc.)
-- and keeps itself subscribed by sending this magic to the daemon every
-- SUBSCRIBE_INTERVAL_SEC. The daemon streams packets back to every
-- subscriber it heard from recently. See docs/controller-bridge.md.
Receiver.SUBSCRIBE_MAGIC = 'TXSUB'
Receiver.SUBSCRIBE_INTERVAL_SEC = 1.0

-- Button-bind values at/above this encode an AXIS-switch, not a real
-- button bit: RC transmitters (EdgeTX) map physical switches to channels
-- 5-8, which arrive as axes -- the joystick button mask never moves.
-- Encoding: AXIS_BTN_BASE + (axis-1)*2 + dir, dir 0 = "pressed" when the
-- axis goes high (>1536), 1 = when it goes low (<512).
Receiver.AXIS_BTN_BASE = 100

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
    self.lastSubClock = -1000 -- last time the TXSUB keepalive went out
end

function Receiver:open()
    if self.udp then self.udp:close(); self.udp = nil end
    if not socketlib then return false, 'luasocket missing' end
    self.udp = socketlib.udp()
    local ok, err = self.udp:setsockname('127.0.0.1', 0) -- ephemeral -- the daemon replies to whatever port the OS picked
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

    -- Keepalive doubles as the initial subscription -- the daemon prunes
    -- subscribers it hasn't heard from in a few seconds, so there's no
    -- separate connect/disconnect handshake to get wrong.
    local now = os.clock()
    if now - self.lastSubClock >= Receiver.SUBSCRIBE_INTERVAL_SEC then
        self.lastSubClock = now
        self.udp:sendto(Receiver.SUBSCRIBE_MAGIC, '127.0.0.1', self.cfg.port)
    end

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
        self.prevAxesRaw = self.axesRaw -- for axis-switch edge detection, see btnJustPressed
        self.axesRaw = pkt.axes
        self.failsafeFlag = (bit.band(pkt.flags, protocol.FLAG_FAILSAFE) ~= 0)
        self.lastRxClock = os.clock()
        self.prevButtonsRaw = self.buttonsRaw
        self.buttonsRaw = pkt.buttons
    end

    self.connected = (not self.failsafeFlag) and ((os.clock() - self.lastRxClock) * 1000 < self.cfg.failsafe_ms)
    if not self.connected then self.lastSeq = nil end
end

-- Rising-edge check for a controller binding -- true only on the poll
-- where it fires, same "just pressed" semantics as isKeyJustPressed.
-- Handles both real button bits and axis-switch encodings (see
-- AXIS_BTN_BASE above): for an axis-switch, "pressed" = the axis crossing
-- into its bound extreme zone.
function Receiver:btnJustPressed(bitIdx)
    if bitIdx < 0 then return false end
    if bitIdx >= Receiver.AXIS_BTN_BASE then
        local code = bitIdx - Receiver.AXIS_BTN_BASE
        local axis = math.floor(code / 2) + 1
        local cur = self.axesRaw[axis]
        local prev = self.prevAxesRaw and self.prevAxesRaw[axis]
        if not cur or not prev then return false end
        if code % 2 == 0 then
            return cur > 1536 and prev <= 1536
        end
        return cur < 512 and prev >= 512
    end
    local mask = bit.lshift(1, bitIdx)
    return bit.band(self.buttonsRaw, mask) ~= 0 and bit.band(self.prevButtonsRaw, mask) == 0
end

function Receiver:close()
    if self.udp then self.udp:close(); self.udp = nil end
end

return Receiver
