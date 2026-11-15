-- BallTrail (client, cosmetic): a lightweight ribbon that follows the RENDERED ball.
--
-- It is drawn from the ball's real position every frame (BallView calls us after moving the visual), so every bend in
-- the ribbon is the real, physics-driven curve; nothing is smoothed, extrapolated or faked. Speed and spin only change
-- how the ribbon LOOKS (brightness, opacity, width, a subtle tint by dominant spin axis), never its path.
--
-- Cosmetic isolation: the style is plain data (Config.Feedback.Trail, overridable per ball skin with setStyle) and the
-- trail lives on its own invisible follower part, not on the ball, so swapping the ball's look or the trail's look
-- never touches gameplay. One Trail instance and two attachments exist for the whole session (no per-frame objects).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BallPhysics = require(Shared:WaitForChild("BallPhysics"))

local BallTrail = {}

local STYLE_UPDATE_EVERY = 3 -- frames between colour/width refreshes (the path itself updates every frame)
local TELEPORT_DISTANCE = 6 -- a one-frame jump this large is a reset (ball placed at a serve point), not flight

function BallTrail.start(overrides: { [string]: any }?)
	local style = table.clone(Config.Feedback.Trail)
	for k, v in overrides or {} do
		style[k] = v
	end

	local follower = Instance.new("Part")
	follower.Name = "NotPongBallTrail"
	follower.Size = Vector3.new(0.1, 0.1, 0.1)
	follower.Transparency = 1
	follower.Anchored, follower.CanCollide, follower.CanQuery, follower.CanTouch, follower.CastShadow = true, false, false, false, false
	local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
	a0.Parent, a1.Parent = follower, follower

	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.FaceCamera = true
	trail.LightEmission = 0.55
	trail.LightInfluence = 0
	trail.MinLength = 0.05
	trail.Enabled = false
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.15) })
	trail.Parent = follower
	follower.Parent = workspace.CurrentCamera

	local self = {}
	local lastPos: Vector3? = nil
	local frame = 0
	local active = false

	local function applyStyle(speed: number, spin: Vector3, velocity: Vector3)
		local speedN = math.clamp(speed / style.FullSpeed, 0, 1)
		local spinN = math.clamp(spin.Magnitude / style.SpinFullAt, 0, 1)

		-- Base colour by speed, tinted toward the dominant spin axis (relative to the direction of travel).
		local color = style.SlowColor:Lerp(style.FastColor, speedN)
		local flat = Vector3.new(velocity.X, 0, velocity.Z)
		if spinN > 0.05 and flat.Magnitude > 1e-3 then
			local top = spin:Dot(Vector3.yAxis:Cross(flat.Unit)) -- + topspin, - backspin (ShotSolver convention)
			local side = math.abs(spin.Y)
			local tint, amount
			if math.abs(top) >= side then
				tint = if top >= 0 then style.TopspinColor else style.BackspinColor
				amount = math.abs(top)
			else
				tint, amount = style.SidespinColor, side
			end
			color = color:Lerp(tint, math.clamp(amount / style.SpinFullAt, 0, 1) * style.TintStrength)
		end
		trail.Color = ColorSequence.new(color, color:Lerp(style.SlowColor, 0.5))

		local startT = style.MaxTransparency + (style.MinTransparency - style.MaxTransparency) * speedN
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, startT), NumberSequenceKeypoint.new(1, 1) })
		trail.Lifetime = style.Lifetime

		local width = style.Width * (0.7 + 0.3 * speedN) * (1 + (style.WidthScaleSpinned - 1) * spinN)
		a0.Position = Vector3.new(0, width / 2, 0)
		a1.Position = Vector3.new(0, -width / 2, 0)
	end

	-- Called by BallView after the visual ball moved this frame.
	function self.onFrame(state: BallPhysics.State, _visual: BasePart)
		local shouldShow = style.Enabled and not state.resting
		if shouldShow ~= active then
			active = shouldShow
			trail.Enabled = shouldShow
			if not shouldShow then
				trail:Clear() -- rally over / ball placed: no leftover streak
			end
		end
		if not shouldShow then
			lastPos = nil
			return
		end
		local pos = state.position
		if lastPos and (pos - lastPos).Magnitude > TELEPORT_DISTANCE then
			trail:Clear()
		end
		lastPos = pos
		follower.CFrame = CFrame.new(pos)
		frame += 1
		if frame % STYLE_UPDATE_EVERY == 0 then
			applyStyle(state.velocity.Magnitude, state.spin, state.velocity)
		end
	end

	-- Swap the look (a ball skin / cosmetic trail) without touching gameplay.
	function self.setStyle(newStyle: { [string]: any })
		for k, v in newStyle do
			style[k] = v
		end
	end

	function self.destroy()
		follower:Destroy()
	end

	return self
end

return BallTrail
