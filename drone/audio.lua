-- Motor sound: pre-baked looped sample + live BASS pitch/volume, not live
-- Lua synthesis. See docs/audio.md for why, and for the bass.dll/device
-- sharing notes.
local Class = require 'class'
local vecmath = require 'vecmath'

local MotorAudio = Class('MotorAudio')

local MOTOR_WAV_PATH = getWorkingDirectory() .. '\\drone\\resources\\drone_motor.wav'

function MotorAudio:init(cfg)
    self.cfg = cfg
    self.ok = false  -- true once BASS_Init + the sample both loaded successfully
    self.bass = nil  -- the ffi.load'd module table (require 'bass''s return value)
    self.stream = 0  -- HSTREAM handle
end

function MotorAudio:load()
    if not self.cfg.audio_enabled then return end
    local ok_bass, bassLib = pcall(require, 'bass')
    if not ok_bass or not bassLib then
        print('motor audio disabled: lib/bass.lua failed to load: ' .. tostring(bassLib))
        return
    end
    if not doesFileExist(MOTOR_WAV_PATH) then -- shipped in the repo, offline-generated, see docs/audio.md
        print('motor audio disabled: missing ' .. MOTOR_WAV_PATH)
        return
    end

    -- BASS's output device is process-wide -- see docs/audio.md. BASS_ERROR_ALREADY
    -- means some other script already initialized it, which is fine.
    local initOk = bassLib.BASS_Init(-1, 44100, 0, nil, nil)
    if initOk == 0 then
        local err = bassLib.BASS_ErrorGetCode()
        if err ~= BASS_ERROR_ALREADY then
            print('motor audio disabled: BASS_Init failed, error code ' .. tostring(err))
            return
        end
    end

    local stream = bassLib.BASS_StreamCreateFile(false, MOTOR_WAV_PATH, 0, 0, BASS_SAMPLE_LOOP)
    if stream == 0 then
        print('motor audio disabled: BASS_StreamCreateFile failed, error code '
            .. tostring(bassLib.BASS_ErrorGetCode()) .. ', path ' .. MOTOR_WAV_PATH)
        return
    end

    self.bass = bassLib
    self.stream = stream
    self.ok = true
    print('motor audio ready')
end

function MotorAudio:start()
    if not self.ok then return end
    self.bass.BASS_ChannelSetAttribute(self.stream, BASS_ATTRIB_VOL, 0)
    self.bass.BASS_ChannelPlay(self.stream, true) -- restart=true: always starts clean from the top
end

function MotorAudio:stop()
    if not self.ok then return end
    self.bass.BASS_ChannelStop(self.stream)
end

-- throttle01: 0..1 even in 3D-throttle mode (magnitude, not signed --
-- pitch/volume don't care about thrust direction, just how hard the motors
-- spin). Called every tick while spawned, both live flight and replay.
function MotorAudio:update(throttle01, distance)
    if not self.ok then return end
    local cfg = self.cfg
    local pitch = cfg.audio_pitch_min + vecmath.clamp(throttle01, 0, 1) * (cfg.audio_pitch_max - cfg.audio_pitch_min)
    local distAtten = 1 - vecmath.clamp(distance / math.max(cfg.audio_max_range, 1), 0, 1)
    local vol = cfg.audio_vol_max * (0.35 + 0.65 * vecmath.clamp(throttle01, 0, 1)) * distAtten
    self.bass.BASS_ChannelSetAttribute(self.stream, BASS_ATTRIB_FREQ, 44100 * pitch)
    self.bass.BASS_ChannelSetAttribute(self.stream, BASS_ATTRIB_VOL, vol)
end

function MotorAudio:shutdown()
    if self.ok then self.bass.BASS_StreamFree(self.stream) end -- not BASS_Free() -- see docs/audio.md
end

return MotorAudio
