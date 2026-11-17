-- CameraController: third-person camera behind the local player, aimed at the table. The ONE owner of the camera while
-- the player is on the platform (it writes CFrame and Focus together every frame). Visual only; it reads Config, the
-- local character, the arena's match attributes and BallView's flags, and never touches gameplay state.
--
-- Placement (world axes, because the table is axis-aligned and the player always faces -Z):
--   Let t = how many studs further behind the end line the player is than the reference stand-back distance.
--   RALLY: position = (table X + (target X offset) * CameraXFollow + ShoulderOffset, floor + Height + HeightPerBackStud * t,
--                      target Z + DistanceBehind + DistancePerBackStud * t), pulled back along the line of sight by
--                      DistanceMultiplier;
--          aim point = (table X + (target X offset) * LateralFollow, table surface + LookAtHeightOffset,
--                       table centre Z - LookAheadStuds + AimPerBackStud * t)
--   SERVE (Config.Camera.Serve, the player's own serve): the same horizontal distance behind the player, lowered to about
--          head height and aimed more horizontally at the table centre; blended with the rally framing by a serve weight.
--
-- Follow (2026-11-16 pass 3, balanced and fluid): the TARGET is the HumanoidRootPart position (stable physics, never the
-- animated head / feet) plus a bounded, eased look-ahead; X and Z each follow it through a critically damped spring
-- (frame-rate independent, no overshoot on reversals). Lateral following, depth and the serve/rally blend are separate,
-- so a pitch change never drags the sideways follow and vice versa.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GameStates = require(Shared:WaitForChild("GameStates"))
local PlatformZone = require(script.Parent:WaitForChild("PlatformZone"))
local BallView = require(script.Parent:WaitForChild("BallView"))

local BIND_NAME = "NotPongCamera"

local CameraController = {}
CameraController.__index = CameraController

function CameraController.new(player: Player)
	return setmetatable({
		player = player,
		position = nil :: Vector3?,
		lookAt = nil :: Vector3?,
		side = 1, -- +1 home half, -1 bot half (see compute)
		active = true, -- false while the player is off the platform (the default Roblox camera is in charge)
		returning = false, -- easing back in from the default camera
		leaving = nil :: number?, -- os.clock() when the hand-off to the default camera started
		-- follow state (springs)
		fx = nil :: number?, -- followed target X
		fz = nil :: number?, -- followed target Z
		vx = 0, -- spring velocities
		vz = 0,
		leadX = 0, -- eased look-ahead (studs)
		leadZ = 0,
		-- serve framing
		serveRamp = 0, -- linear 0..1 progress toward the serve framing (eased with smootherstep when used)
		serveTarget = 0,
		serveOffsetNow = nil :: number?, -- followed serve-framing sideways offset (court-relative studs)
		serveOffsetSpeed = 0,
	}, CameraController)
end

-- Critically damped spring toward `target` (Game Programming Gems 4, "Critically Damped Ease-In/Ease-Out Smoothing"):
-- frame-rate independent, never overshoots a fixed target. Returns the new value and velocity.
local function smoothDamp(current: number, target: number, velocity: number, smoothTime: number, dt: number): (number, number)
	local st = math.max(smoothTime, 1e-4)
	local omega = 2 / st
	local x = omega * dt
	local decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = current - target
	local temp = (velocity + omega * change) * dt
	local newVelocity = (velocity - omega * temp) * decay
	local value = target + (change + temp) * decay
	if (target - current > 0) == (value > target) then -- (cannot pass the target)
		value = target
		newVelocity = 0
	end
	return value, newVelocity
end

local function smootherstep(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * u * (u * (u * 6 - 15) + 10)
end

-- The serve framing's sideways offset for a court position (Config.Camera.Serve): court-relative X (+ = the player's
-- right, whichever end they stand at), shaped smoothly through the centre. Pure; used by tests too.
function CameraController.serveOffset(rootX: number, side: number?): number
	local SV = Config.Camera.Serve
	local sg = side or 1
	local courtX = (rootX - Config.Layout.TableSurfaceCenter.X) * sg
	local u = math.clamp(courtX / math.max(SV.CenterBlend or 1, 1e-3), -1, 1)
	return (SV.LateralOffset or 0) * u * (3 - u * u) / 2
end

-- Where the camera wants to be and look, given the (already followed) target position. Pure; used by tests too.
-- `side` is +1 when the player is on the home (+Z) half and -1 on the bot's half: the whole framing is mirrored along Z
-- so the camera is always behind the player looking at the table. `serveWeight` 0..1 blends in the serve framing;
-- `serveOffset` (court-relative studs, + = the player's right) is its sideways offset (default: from the position).
function CameraController.compute(rootPosition: Vector3, side: number?, serveWeight: number?, serveOffset: number?): (Vector3, Vector3)
	local C, L = Config.Camera, Config.Layout
	local sg = side or 1
	local centre = L.TableSurfaceCenter
	-- Distance from the table centre along the player's own axis, but never less than "just behind the end line":
	-- alongside the table the framing stays at the closest standing position, so the whole table remains in view.
	local rz = math.max(sg * (rootPosition.Z - centre.Z), Config.Table.Length / 2 + Config.PlayArea.FrontGap)
	local t = (rz - Config.Table.Length / 2) - Config.Avatar.StandBack -- studs further back than the reference spot
	local dx = rootPosition.X - centre.X
	local desiredPosition = Vector3.new(
		centre.X + dx * C.CameraXFollow + sg * (C.ShoulderOffset or 0),
		L.FloorY + C.Height + C.HeightPerBackStud * t,
		centre.Z + sg * (rz + C.DistanceBehind + C.DistancePerBackStud * t)
	)
	local desiredLookAt = Vector3.new(
		centre.X + dx * C.LateralFollow,
		L.SurfaceY + C.LookAtHeightOffset,
		centre.Z + sg * (-C.LookAheadStuds + C.AimPerBackStud * t)
	)
	-- Pull back along the line of sight: same angle and composition, wider view.
	desiredPosition = desiredLookAt + (desiredPosition - desiredLookAt) * (C.DistanceMultiplier or 1)
	local w = math.clamp(serveWeight or 0, 0, 1)
	if w > 0 and C.Serve then
		local SV = C.Serve
		-- serve framing: the same horizontal distance behind the player (follow distance kept), lowered to about head
		-- height, aimed more horizontally at the table centre
		local horiz = Vector3.new(0, 0, desiredPosition.Z - rootPosition.Z)
		local offset = serveOffset or CameraController.serveOffset(rootPosition.X, sg)
		local servePos = Vector3.new(
			centre.X + dx * C.CameraXFollow + sg * offset,
			L.FloorY + SV.Height,
			rootPosition.Z + horiz.Z
		)
		local serveLook = Vector3.new(centre.X + dx * C.LateralFollow, L.SurfaceY + SV.LookHeight, centre.Z - sg * (SV.LookAheadStuds or 0))
		desiredPosition = desiredPosition:Lerp(servePos, w)
		desiredLookAt = desiredLookAt:Lerp(serveLook, w)
	end
	return desiredPosition, desiredLookAt
end

-- The default follow camera's pose for the hand-off: behind the avatar along the current view direction, looking at
-- the head from OffPlatformDistance away (pitched OffPlatformPitch degrees down).
local function followPose(look: Vector3, character: Model): (Vector3?, Vector3?)
	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return nil, nil
	end
	local C = Config.Camera
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local pitch = math.rad(C.OffPlatformPitch or 20)
	local dir = flat * math.cos(pitch) - Vector3.yAxis * math.sin(pitch)
	local focus = head.Position
	return focus - dir * (C.OffPlatformDistance or 25), focus
end

-- The serve framing the match calls for right now (1 = serve view, 0 = rally view, nil = keep the current one):
--   our serve being prepared / tossed (ReadyToServe or Serving, not yet struck)  -> 1
--   our serve struck (the referee counted the hit)                                -> 0 (blend up with the outgoing ball)
--   a missed swing / dropped toss                                                 -> 1 until the point resolves
--   PointScored (fault, let pending, point)                                       -> keep (the next state decides)
--   bot serving, rally, waiting, match over                                       -> 0
function CameraController:_serveTarget(): number?
	local arena = workspace:FindFirstChild(Config.Names.Arena)
	if not arena then
		return 0
	end
	local Attr, S = GameStates.Attributes, GameStates.State
	local st = arena:GetAttribute(Attr.State)
	local mine = arena:GetAttribute(Attr.Server) == GameStates.Side.Player
		and arena:GetAttribute(Config.Names.SeatedPlayerAttribute) == self.player.UserId
	if st == S.ReadyToServe then
		return if mine then 1 else 0
	elseif st == S.Serving then
		if not mine then
			return 0
		end
		local info = BallView.getInfo()
		if info.mode ~= "hand" and (info.hits or 0) >= 1 then
			return 0 -- struck: the serve is on its way
		end
		return 1
	elseif st == S.PointScored then
		return nil
	end
	return 0
end

function CameraController:_update(dt: number)
	if self.leaving then
		-- Hand-off: glide from the table framing to the default camera's follow pose, then give it control at exactly
		-- that pose (same direction, same zoom distance), so the default camera continues without a jump.
		local camera = workspace.CurrentCamera
		local character = self.player.Character
		local pos, at
		if camera and character then
			pos, at = followPose(self.leaveLook or camera.CFrame.LookVector, character)
		end
		local C = Config.Camera
		local u = math.clamp((os.clock() - self.leaving) / math.max(C.HandoffTime or 0.4, 1e-3), 0, 1)
		if pos and at and self.position and self.lookAt then
			local k = 1 - (1 - u) ^ 3
			local p, a = self.position:Lerp(pos, k), self.lookAt:Lerp(at, k)
			camera.CFrame = CFrame.lookAt(p, a)
			camera.Focus = CFrame.new(a)
		end
		if u >= 1 or not pos then
			self.leaving = nil
			self:_handToDefault()
		end
		return
	end
	if not self.active then
		return
	end
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	dt = math.clamp(dt, 0, 0.1)

	local C = Config.Camera
	local rootPos = root.Position
	-- Look-ahead: velocity * LeadTime, clamped, eased (never a jump on start / stop / reversal); none during a dive.
	local velocity = root.AssemblyLinearVelocity
	local divePhase = (character :: Model):GetAttribute(Config.Names.DiveStateAttribute)
	local wantX, wantZ = 0, 0
	if divePhase ~= "lunge" and divePhase ~= "recover" then
		local maxLead = C.MaxLead or 3
		wantX = math.clamp(velocity.X * (C.LeadTime or 0.1), -maxLead, maxLead)
		wantZ = math.clamp(velocity.Z * (C.LeadTime or 0.1), -maxLead, maxLead)
	end
	local leadAlpha = 1 - math.exp(-(C.LeadRate or 6) * dt)
	self.leadX += (wantX - self.leadX) * leadAlpha
	self.leadZ += (wantZ - self.leadZ) * leadAlpha
	local targetX, targetZ = rootPos.X + self.leadX, rootPos.Z + self.leadZ
	if not self.fx or not self.fz then
		self.fx, self.fz, self.vx, self.vz = targetX, targetZ, 0, 0
	end
	self.fx, self.vx = smoothDamp(self.fx :: number, targetX, self.vx, C.LateralSmoothTime or 0.14, dt)
	self.fz, self.vz = smoothDamp(self.fz :: number, targetZ, self.vz, C.DepthSmoothTime or 0.14, dt)

	local dz = rootPos.Z - Config.Layout.TableSurfaceCenter.Z
	if (self.side == 1 and dz < -6) or (self.side == -1 and dz > 6) then
		self.side = -self.side -- hysteresis: only flip once clearly past the net plane
	end

	-- Serve framing weight: a linear ramp toward the target at 1/EnterTime or 1/ExitTime per second, eased with
	-- smootherstep where it is used (no snap at either end, no change of FOV).
	local target = self:_serveTarget()
	if target ~= nil then
		self.serveTarget = target
	end
	local SV = C.Serve
	if SV then
		local rate = if self.serveTarget > self.serveRamp then 1 / math.max(SV.EnterTime, 1e-3) else 1 / math.max(SV.ExitTime, 1e-3)
		local step = rate * dt
		self.serveRamp = if self.serveTarget > self.serveRamp
			then math.min(self.serveRamp + step, self.serveTarget)
			else math.max(self.serveRamp - step, self.serveTarget)
	end
	local serveWeight = smootherstep(self.serveRamp)
	-- the serve framing's sideways offset from the court position (followed X), through its own damped spring
	local wantOffset = CameraController.serveOffset(self.fx :: number, self.side)
	if self.serveOffsetNow == nil then
		self.serveOffsetNow, self.serveOffsetSpeed = wantOffset, 0
	end
	self.serveOffsetNow, self.serveOffsetSpeed = smoothDamp(self.serveOffsetNow, wantOffset, self.serveOffsetSpeed, (SV and SV.OffsetSmoothTime) or 0.3, dt)

	local desiredPosition, desiredLookAt = CameraController.compute(
		Vector3.new(self.fx :: number, rootPos.Y, self.fz :: number),
		self.side,
		serveWeight,
		self.serveOffsetNow
	)
	if not self.position or not self.lookAt then
		self.position, self.lookAt = desiredPosition, desiredLookAt
	else
		if self.returning and (self.position - desiredPosition).Magnitude < 0.5 then
			self.returning = false
		end
		local rate = if self.returning then (C.ReturnSmoothing or 4) else (C.OutputSmoothing or 30)
		local alpha = 1 - math.exp(-rate * dt)
		self.position = self.position:Lerp(desiredPosition, alpha)
		self.lookAt = self.lookAt:Lerp(desiredLookAt, alpha)
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = C.FieldOfView
	camera.CFrame = CFrame.lookAt(self.position :: Vector3, self.lookAt :: Vector3)
	camera.Focus = CFrame.new(self.lookAt :: Vector3)
end

-- Off the platform: hand the camera to Roblox's default follow camera (normal zoom/orbit controls), via a short glide.
function CameraController:_release()
	self.active = false
	self.returning = false
	if self.position and self.lookAt and workspace.CurrentCamera then
		self.leaving = os.clock()
		self.leaveLook = workspace.CurrentCamera.CFrame.LookVector -- the glide keeps this view direction
	else
		self:_handToDefault()
	end
end

function CameraController:_handToDefault()
	local camera = workspace.CurrentCamera
	local humanoid = self.player.Character and self.player.Character:FindFirstChildOfClass("Humanoid")
	if not camera or self.active then
		return
	end
	-- The default camera keeps the view DIRECTION of the camera's CFrame but uses its own zoom distance; pin the zoom to
	-- the hand-off distance for a moment so it starts exactly where the glide ended (then normal zoom limits return).
	local player = self.player
	local dist = (camera.Focus.Position - camera.CFrame.Position).Magnitude
	if humanoid and humanoid.Parent then
		local head = humanoid.Parent:FindFirstChild("Head") :: BasePart?
		if head then
			dist = (head.Position - camera.CFrame.Position).Magnitude
		end
	end
	local prevMin = player.CameraMinZoomDistance
	player.CameraMinZoomDistance = math.clamp(dist, prevMin, player.CameraMaxZoomDistance)
	camera.CameraType = Enum.CameraType.Custom
	if humanoid then
		camera.CameraSubject = humanoid
	end
	task.delay(0.15, function()
		player.CameraMinZoomDistance = prevMin
	end)
end

-- Back on the platform: take over again starting from the current (default-camera) view, then ease into the table
-- framing at ReturnSmoothing, so there is no snap.
function CameraController:_resume()
	self.leaving = nil
	local camera = workspace.CurrentCamera
	if camera then
		local cf = camera.CFrame
		local focus = camera.Focus.Position
		local dist = (focus - cf.Position).Magnitude
		self.position = cf.Position
		self.lookAt = cf.Position + cf.LookVector * math.max(dist, 10)
	end
	self.fx, self.fz = nil, nil -- the follow springs restart from the player (the output easing covers the gap)
	self.serveOffsetNow = nil
	self.returning = true
	self.active = true
end

function CameraController:start()
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_update(dt)
	end)
	PlatformZone.onChanged(function(on)
		if on then
			self:_resume()
		else
			self:_release()
		end
	end)
	self.player.CharacterAdded:Connect(function()
		-- a fresh character takes its spawn's state at once; start the table camera without easing from far away
		self.position, self.lookAt, self.returning = nil, nil, false
		self.fx, self.fz, self.leadX, self.leadZ = nil, nil, 0, 0
		self.serveOffsetNow = nil
		local target = self:_serveTarget()
		self.serveTarget = target or 0
		self.serveRamp = self.serveTarget
	end)
end

function CameraController:stop()
	RunService:UnbindFromRenderStep(BIND_NAME)
end

return CameraController
