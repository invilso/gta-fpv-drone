-- Flight recorder binary format (FFI structs), shared by recorder.lua and
-- player.lua. See docs/replay.md for the format-versioning rationale --
-- each version bump is a breaking change, no migration path.
local ffi = require 'ffi'

local M = {}

M.MAX_ENTITIES = 48
M.MAGIC = 'DRPL'
M.VERSION = 3

ffi.cdef(string.format([[
#pragma pack(push, 1)
typedef struct {
    uint8_t  kind;      // 0=empty, 1=vehicle, 2=ped, 3=object
    uint16_t modelId;
    uint32_t entityId;  // live native handle at capture time -- see docs/replay.md "entity proxies" tradeoff
    float    x, y, z;
    float    heading;   // degrees, same convention as getCarHeading/getCharHeading
} replay_entity_t;

typedef struct {
    double   timestamp;        // os.clock() at capture -- paces playback by real time, not 1:1 ticks
    float    px, py, pz;       // drone position
    float    fwdx, fwdy, fwdz; // drone forward
    float    upx, upy, upz;    // drone up (right rederived on playback: normalize(cross(up,fwd)))
    float    velx, vely, velz; // drone velocity -- speed (OSD) and vertical speed (vario) both derive from this
    float    thrust;           // spooled 0..1 throttle
    // Physics accel breakdown, for the OSD's thrust-breakdown panel only.
    float    thrustAccel, gravity, dragUp, ground, ceiling, windZ, accelZ;
    // Raw normalized stick position (calibrated, pre-expo/deadzone) --
    // same values the live OSD's stick-position boxes show, see osd.lua.
    // stickThrottle is 0..1 (axisUni); the other three are -1..1 (axisBi).
    float    stickRoll, stickPitch, stickYaw, stickThrottle;
    uint8_t  flags;            // bit0=armed bit1=grounded bit2=exploding bit3=connected bit4-5=flight_mode(0..2) bit6=throttle_3d
    uint8_t  entityCount;      // how many of entities[] are populated this frame
    replay_entity_t entities[%d];
} replay_frame_t;

typedef struct {
    char     magic[4];   // "DRPL"
    uint16_t version;
    uint16_t frameSize;   // sizeof(replay_frame_t) at save time -- refuse mismatched old files
    uint16_t maxEntities;
    uint32_t frameCount;  // frames following, chronological (oldest-first)
    char     profileName[16]; // profile name at save time, for the OSD's profile readout
    float    profileMass;
    float    profileMaxThrust;
} replay_header_t;
#pragma pack(pop)
]], M.MAX_ENTITIES))

M.FLIGHT_MODES = {'ACRO', 'LEVEL', 'HORIZON'} -- cycle order; bits 4-5 of frame.flags index into this (+1)

return M
