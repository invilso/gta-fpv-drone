-- Flight model (ACRO/LEVEL/HORIZON + 3D-throttle) and the per-frame matrix
-- write that drives the vehicle. Fully scripted kinematics, not GTA vehicle
-- physics -- needed for flips/inverted flight. Orientation is kept as an
-- orthonormal basis (not Euler integration) to avoid gimbal lock during
-- flips. See docs/physics.md and docs/orientation.md for the tuning/bug
-- history behind this file.
local ffi = require 'ffi'
local Drone = require 'drone'
local vecmath = require 'vecmath'
local replayFormat = require 'replay.format'
local vAdd, vSub, vScale, vDot, vCross, vLen, vNorm, vRotate, clamp, samePtr =
    vecmath.vAdd, vecmath.vSub, vecmath.vScale, vecmath.vDot, vecmath.vCross,
    vecmath.vLen, vecmath.vNorm, vecmath.vRotate, vecmath.clamp, vecmath.samePtr

-- CEntity/CReference require each other (opaque forward decl is enough for
-- CReference's `CEntity **ppEntity` field). Their own loop-guard only kicks
-- in when entered through SAMemory.require(), not a bare require() call.
local SAMemory = require 'SAMemory'
SAMemory.require('CEntity')

Drone.FLIGHT_MODES = replayFormat.FLIGHT_MODES -- cycle order, see flight_mode_cycle_vk/_btn in the entry-point

-- World-vertical push from a nearby surface below (ground effect) or above
-- (ceiling effect). See docs/physics.md -- the car=true fallback ray starts
-- at drone.pos, i.e. at/inside the drone's own vehicle model, so self-hits
-- must be filtered exactly like checkCollision does.
function Drone:surfaceProximityAccel(radius, strength, dirZ)
    if radius <= 0 or strength <= 0 then return 0 end
    if not (self.obj and doesVehicleExist(self.obj)) then return 0 end
    local selfPtr = getCarPointer(self.obj)
    local tx, ty, tz = self.pos.x, self.pos.y, self.pos.z + dirZ * radius
    local hit, colPoint = processLineOfSight(self.pos.x, self.pos.y, self.pos.z, tx, ty, tz,
        true, false, false, false, false, false, false, false)
    if not hit then
        hit, colPoint = processLineOfSight(self.pos.x, self.pos.y, self.pos.z, tx, ty, tz,
            false, true, false, false, false, false, false, false)
        if hit and samePtr(colPoint.entity, selfPtr) then hit = false end
    end
    if not hit then return 0 end
    local dist = math.abs(colPoint.pos[3] - self.pos.z)
    local t = 1 - clamp(dist / radius, 0, 1)
    return strength * t * t
end

function Drone:windAccel()
    local cfg = self.cfg
    if not cfg.wind_enabled then return {x = 0, y = 0, z = 0} end
    local h = math.rad(cfg.wind_dir_deg)
    local dirX, dirY = -math.sin(h), math.cos(h)
    local t = os.clock()
    local turb = vecmath.turbulence1D
    return {
        x = dirX * cfg.wind_strength + turb(t, 0.0) * cfg.wind_turbulence,
        y = dirY * cfg.wind_strength + turb(t, 7.3) * cfg.wind_turbulence,
        z = turb(t, 15.1) * cfg.wind_turbulence * 0.3, -- vertical gusts weaker than horizontal
    }
end

-- receiver: net.Receiver, for stick axes + connected/failsafe state.
function Drone:updatePhysics(dt, receiver)
    local cfg = self.cfg
    local prof = cfg.profile
    local axesRaw, calib = receiver.axesRaw, cfg.calib

    local roll  = vecmath.applyExpoDeadzone(vecmath.axisBi(calib, axesRaw, cfg.axis_roll), prof.expo, prof.deadzone)
    local pitch = vecmath.applyExpoDeadzone(vecmath.axisBi(calib, axesRaw, cfg.axis_pitch), prof.expo, prof.deadzone)
    if cfg.axis_pitch_invert then pitch = -pitch end
    local yaw   = vecmath.applyExpoDeadzone(vecmath.axisBi(calib, axesRaw, cfg.axis_yaw), prof.expo, prof.deadzone)
    if cfg.axis_yaw_invert then yaw = -yaw end

    -- 3D throttle: bidirectional (-1..1) around stick center -- negative
    -- thrust pushes along -up, letting the drone hold altitude
    -- upside-down. See docs/physics.md.
    local throttleTarget = 0.0
    if receiver.connected then
        throttleTarget = cfg.throttle_3d and vecmath.axisBi(calib, axesRaw, cfg.axis_throttle)
            or vecmath.axisUni(calib, axesRaw, cfg.axis_throttle)
    end

    if not receiver.connected then
        -- failsafe: cut throttle, let it fall -- no auto-hover/auto-land
        roll, pitch, yaw = 0, 0, 0
    end

    local rateMax = math.rad(prof.rate_max_deg)
    local pTarget, qTarget -- about fwd (roll), about right (pitch) -- rad/s, set per flight_mode below
    local rTarget = yaw * rateMax -- yaw is always rate-based, no mode self-levels heading

    if cfg.flight_mode == 'ACRO' then
        pTarget = roll * rateMax
        qTarget = pitch * rateMax
    else
        -- LEVEL/HORIZON: stick commands a target bank/pitch ANGLE, not a
        -- rate -- see docs/physics.md.
        local rollAngle = math.atan2(self.right.z, self.up.z)
        local pitchAngle = math.asin(clamp(self.fwd.z, -1, 1))
        local levelMaxRad = math.rad(cfg.level_max_angle_deg)
        local acroP, acroQ = roll * rateMax, pitch * rateMax
        local levelP = clamp((roll * levelMaxRad - rollAngle) * cfg.level_gain, -rateMax, rateMax)
        local levelQ = clamp((pitch * levelMaxRad - pitchAngle) * cfg.level_gain, -rateMax, rateMax)
        if cfg.flight_mode == 'LEVEL' then
            pTarget, qTarget = levelP, levelQ
        else -- HORIZON: blend acro in as each stick approaches full deflection
            local blendP = clamp((math.abs(roll) - cfg.horizon_blend_start) / math.max(1 - cfg.horizon_blend_start, 1e-4), 0, 1)
            local blendQ = clamp((math.abs(pitch) - cfg.horizon_blend_start) / math.max(1 - cfg.horizon_blend_start, 1e-4), 0, 1)
            pTarget = levelP + (acroP - levelP) * blendP
            qTarget = levelQ + (acroQ - levelQ) * blendQ
        end
    end

    -- Body-frame angular rates ease toward the target with time constant
    -- angular_tau, so releasing the stick decays rotation instead of
    -- stopping it dead.
    local angK = 1 - math.exp(-dt / math.max(prof.angular_tau, 1e-4))
    self.angRate.p = self.angRate.p + (pTarget - self.angRate.p) * angK
    self.angRate.q = self.angRate.q + (qTarget - self.angRate.q) * angK
    self.angRate.r = self.angRate.r + (rTarget - self.angRate.r) * angK

    local omega = vAdd(vAdd(vScale(self.fwd, self.angRate.p), vScale(self.right, self.angRate.q)), vScale(self.up, self.angRate.r))
    local angle = vLen(omega) * dt
    if angle > 1e-6 then
        local axis = vNorm(omega)
        self.fwd = vRotate(self.fwd, axis, angle)
        self.right = vRotate(self.right, axis, angle)
        self.up = vRotate(self.up, axis, angle)
    end
    -- Re-orthonormalize each frame to stop small numerical drift accumulating.
    self.right = vNorm(vCross(self.up, self.fwd))
    self.up = vNorm(vCross(self.fwd, self.right))

    -- Thrust lag: motors spool toward the commanded throttle instead of
    -- responding instantly, time constant motor_tau.
    local thrustK = 1 - math.exp(-dt / math.max(prof.motor_tau, 1e-4))
    self.thrust = self.thrust + (throttleTarget - self.thrust) * thrustK

    local thrustAccel = self.thrust * (prof.max_thrust / prof.mass)
    local accel = vScale(self.up, thrustAccel)
    accel.z = accel.z - prof.gravity

    -- Anisotropic drag: decompose velocity into the drone's own body frame,
    -- apply per-axis linear+quadratic coefficients, recompose into world
    -- space. See docs/physics.md "drag tuning".
    local vFwd, vRight, vUp = vDot(self.vel, self.fwd), vDot(self.vel, self.right), vDot(self.vel, self.up)
    local function dragAccel(v, lin, quad) return -(lin * v + quad * v * math.abs(v)) end
    local dFwd = dragAccel(vFwd, prof.drag_linear.fwd, prof.drag_quadratic.fwd)
    local dRight = dragAccel(vRight, prof.drag_linear.right, prof.drag_quadratic.right)
    local dUp = dragAccel(vUp, prof.drag_linear.up, prof.drag_quadratic.up)
    accel = vAdd(accel, vAdd(vAdd(vScale(self.fwd, dFwd), vScale(self.right, dRight)), vScale(self.up, dUp)))

    local groundA = self:surfaceProximityAccel(prof.ground_effect_radius, prof.ground_effect_strength, -1)
    local ceilingA = self:surfaceProximityAccel(prof.ceiling_effect_radius, prof.ceiling_effect_strength, 1)
    accel.z = accel.z + groundA + ceilingA

    local windA = self:windAccel()
    accel = vAdd(accel, windA)

    -- Debug: see the actual per-frame numbers instead of guessing why
    -- something isn't falling/reacting -- see docs/physics.md.
    local dbg = self.lastPhysicsDebug
    dbg.thrust = thrustAccel
    dbg.gravity = -prof.gravity
    dbg.dragUp = dUp
    dbg.ground = groundA
    dbg.ceiling = ceilingA
    dbg.windZ = windA.z
    dbg.accelZ = accel.z
    dbg.velZ = self.vel.z
    dbg.posZ = self.pos.z

    self.vel = vAdd(self.vel, accel, dt)
    self.pos = vAdd(self.pos, self.vel, dt)
end

-- Write right/up/at straight into the vehicle's world matrix -- see
-- docs/orientation.md for why (no axis-order/sign ambiguity, unlike
-- setObjectRotation) and for RCRAIDER's own local-axis convention. Camera
-- tilt is baked into the *rendered* fwd/up pair here, leaving the real
-- fwd/right/up untouched so physics/collision/OSD attitude are unaffected.
function Drone:applyTransform()
    if not (self.obj and doesVehicleExist(self.obj)) then return end

    local ptr = getCarPointer(self.obj)
    local ent = ffi.cast('CEntity*', ptr) -- CVehicle : CPhysical : CEntity, base layout lines up
    local mat = ent.Placeable.Matrix

    local rFwd, rUp = self.fwd, self.up
    if self.cfg.cam_tilt_deg ~= 0 then
        local tiltRad = -math.rad(self.cfg.cam_tilt_deg) -- negated: positive cam_tilt_deg tilts the view down
        rFwd = vRotate(self.fwd, self.right, tiltRad)
        rUp = vRotate(self.up, self.right, tiltRad)
    end

    mat.pos.x, mat.pos.y, mat.pos.z = self.pos.x, self.pos.y, self.pos.z
    mat.right.x, mat.right.y, mat.right.z = -self.right.x, -self.right.y, -self.right.z
    mat.up.x, mat.up.y, mat.up.z = rFwd.x, rFwd.y, rFwd.z
    mat.at.x, mat.at.y, mat.at.z = -rUp.x, -rUp.y, -rUp.z
end

return Drone
