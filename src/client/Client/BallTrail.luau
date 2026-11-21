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
	trail.LightEmission = style.LightEmission or 0.55
	trail.LightInfluence = 0
	trail.MinLength = 0.05
	trail.Enabled = false
	-- (Pass 15) TAPER. A Trail's WidthScale / Transparency keys run from 0 = the NEWEST point (at the ball) to 1 = the oldest
	-- (Transparency key 0 is the opaque head). So the width is widest at key 0 and narrows smoothly to the tail:
	-- style.Taper (position, fraction) then `tail` at 1. Every layer uses it, so no companion recreates a wide-behind shape.
	local function taperWidth(tail: number): NumberSequence
		local kp = {}
		for _, k in style.Taper or { { 0, 1 } } do
			table.insert(kp, NumberSequenceKeypoint.new(k[1], k[2]))
		end
		table.insert(kp, NumberSequenceKeypoint.new(1, tail))
		return NumberSequence.new(kp)
	end
	trail.WidthScale = taperWidth(style.TailWidth or 0.15)
	if style.Texture then
		-- (2026-11-20) the main ribbon is textured with a comet body cut from the user's Trails sheet (comet_body.png)
		trail.Texture = style.Texture
		trail.TextureMode = Enum.TextureMode.Stretch
	end
	trail.Parent = follower
	follower.Parent = workspace.CurrentCamera

	-- COMET LAYERS (2026-11-20, style.Comet.Layers): extra textured Trails on the SAME follower (created once, no per-frame
	-- objects), cut from the user's SyphoDev Trails sheets by tools/trail_textures.py (assets/vfx/comet_*.png): a white-hot
	-- core, fine strands, sparkle dust and smoky wisps. Each fades in from its own rally stage (FromPercent -> FullPercent),
	-- is tinted with the stage colour (Whiten mixes white in, like the reference's white-hot heads), and yields to the orange
	-- vulnerable-ball line. (Roblox Trails draw the texture's TOP row at the ball, its height along the length.)
	local NSK = NumberSequenceKeypoint.new
	local layers = {}
	local CM = style.Comet
	if CM and CM.Enabled then
		for _, L in CM.Layers do
			local l0, l1 = Instance.new("Attachment"), Instance.new("Attachment")
			l0.Position, l1.Position = Vector3.new(0, L.Width / 2, 0), Vector3.new(0, -L.Width / 2, 0)
			l0.Parent, l1.Parent = follower, follower
			local t = Instance.new("Trail")
			t.Name = "NotPongComet" .. L.Name
			t.Attachment0, t.Attachment1 = l0, l1
			t.Texture = L.Texture
			t.TextureMode = Enum.TextureMode.Stretch
			t.FaceCamera = true
			t.LightEmission = L.LightEmission or 0.7
			t.LightInfluence = 0
			t.Lifetime = L.Lifetime
			t.MinLength = 0.05
			t.WidthScale = taperWidth(L.TailWidth or 0.6)
			t.Transparency = NumberSequence.new(1)
			t.Enabled = false
			t.Parent = follower
			table.insert(layers, { cfg = L, trail = t, a0 = l0, a1 = l1, on = false, opacity = 0 })
		end
	end
	local cometAllowed = false -- (set each frame from BallView's info: a struck ball in free flight)
	local function layersOff()
		for _, l in layers do
			l.on, l.opacity = false, 0
			l.trail.Enabled = false
			l.trail:Clear()
		end
	end
	-- RALLY COLOURS (Pass 15, style.RallyColors): the colour stage follows the RETURN COUNT (BallView info.hits - 1: the
	-- server's referee counts each accepted legal paddle hit once; the serve is hit 1; it restarts at every serve), in steps
	-- of RC.ReturnInterval. colorStage switches hard (no blend: yellow -> red would pass through the orange cue colour);
	-- stageLevel is the same value eased, used only for the layers' fade-in and the glow.
	local RC = style.RallyColors
	local colorStage = 0
	local stageLevel = 0
	local WHITE = Color3.new(1, 1, 1)
	local function stageFor(returns: number): number
		if not RC or not RC.Enabled then
			return 0
		end
		return math.clamp(math.floor(returns / math.max(RC.ReturnInterval or 10, 1)), 0, #RC.Colors - 1)
	end
	local function stageColor(stage: number): Color3
		return if RC and RC.Colors then RC.Colors[stage + 1] or WHITE else WHITE
	end

	-- ATTACKABLE HIGH BALL (Config.Feedback.HighBallTrail, 2026-11-18): a thin orange wavy line on its own follower (the
	-- wave is a smooth offset across the direction of travel) + a wider faint companion on the true ball path. Blended in
	-- while the server's classification (BallView info.highBall) is active, the normal trail blended out, and back.
	local HB = Config.Feedback.HighBallTrail
	local BallView = require(script.Parent:WaitForChild("BallView"))
	local function hbTrail(name: string, width: number, lifetime: number): (BasePart, Trail)
		local f = Instance.new("Part")
		f.Name = name
		f.Size = Vector3.new(0.1, 0.1, 0.1)
		f.Transparency = 1
		f.Anchored, f.CanCollide, f.CanQuery, f.CanTouch, f.CastShadow = true, false, false, false, false
		local b0, b1 = Instance.new("Attachment"), Instance.new("Attachment")
		b0.Position, b1.Position = Vector3.new(0, width / 2, 0), Vector3.new(0, -width / 2, 0)
		b0.Parent, b1.Parent = f, f
		local t = Instance.new("Trail")
		t.Attachment0, t.Attachment1 = b0, b1
		t.FaceCamera = true
		t.LightEmission = 0.6
		t.LightInfluence = 0
		t.MinLength = 0.03
		t.Lifetime = lifetime
		t.Color = ColorSequence.new(HB.Color)
		t.Enabled = false
		t.Parent = f
		f.Parent = workspace.CurrentCamera
		return f, t
	end
	local hbCoreF, hbCore = hbTrail("NotPongHighBallTrail", HB.Width, HB.Lifetime)
	local hbHaloF, hbHalo = hbTrail("NotPongHighBallHalo", HB.HaloWidth, HB.Lifetime * 0.8)
	hbHalo.LightEmission = 0.3
	local hbWeight = 0
	local hbOn = false
	local hbDist = 0
	local hbPhases = { 0, 0, 0, 0 }
	local hbKey: any = nil
	local hbLastHits = -1
	local hbFastUntil = -math.huge
	local lastClock = os.clock()
	local function setHb(weight: number)
		local core = 1 - (1 - HB.CoreTransparency) * weight
		local halo = 1 - (1 - HB.HaloTransparency) * weight
		hbCore.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, core), NumberSequenceKeypoint.new(1, 1) })
		hbHalo.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, halo), NumberSequenceKeypoint.new(1, 1) })
	end
	local function hbClear()
		hbWeight, hbOn = 0, false
		hbCore.Enabled, hbHalo.Enabled = false, false
		hbCore:Clear()
		hbHalo:Clear()
	end

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
		-- stage colour (return count): stage 0 keeps the white speed colour; a later stage replaces it outright
		local stageK = math.clamp(stageLevel, 0, 1)
		local sc = stageColor(colorStage)
		if colorStage > 0 then
			color = sc
			trail.Color = ColorSequence.new(sc, sc)
		else
			trail.Color = ColorSequence.new(color, color:Lerp(style.SlowColor, 0.5))
		end
		local le = style.LightEmission or 0.55
		trail.LightEmission = le + ((style.ColorLightEmission or le) - le) * stageK
		-- comet layers: each from its own stage, stronger toward purple and with speed, yielding to orange
		for _, l in layers do
			local L = l.cfg
			local k = math.clamp((stageLevel - L.FromStage) / math.max(L.FullStage - L.FromStage, 1e-3), 0, 1)
			local opacity = if stageLevel >= L.FromStage - 0.01 then L.MinOpacity + (L.MaxOpacity - L.MinOpacity) * k else 0
			local slow = L.SlowFactor or 0.6
			opacity *= (1 - hbWeight) * (slow + (1 - slow) * speedN) * (if cometAllowed then 1 else 0)
			local on = opacity > 0.01
			if on then
				-- (additive glow washes a coloured stage out over the orange table: less emission as the colour takes over)
				l.trail.LightEmission = L.LightEmission + ((L.ColorLightEmission or L.LightEmission) - L.LightEmission) * stageK
				local whiten = L.Whiten or 0
				l.trail.Color = ColorSequence.new(sc:Lerp(WHITE, whiten), sc:Lerp(WHITE, whiten * 0.4))
				local hc = math.clamp(L.HeadClear or 0, 0, 0.5)
				local kp = {}
				if hc > 0 then
					table.insert(kp, NSK(0, 1))
				end
				table.insert(kp, NSK(hc, 1 - opacity))
				table.insert(kp, NSK(0.75, 1 - opacity * 0.7))
				table.insert(kp, NSK(1, 1))
				l.trail.Transparency = NumberSequence.new(kp)
				local w = L.Width * (0.8 + 0.2 * speedN)
				l.a0.Position, l.a1.Position = Vector3.new(0, w / 2, 0), Vector3.new(0, -w / 2, 0)
			end
			l.opacity = opacity
			if l.on ~= on then
				l.on = on
				l.trail.Enabled = on
				if not on then
					l.trail:Clear()
				end
			end
		end

		local startT = style.MaxTransparency + (style.MinTransparency - style.MaxTransparency) * speedN
		startT += (1 - startT) * 0.9 * hbWeight -- (the orange high-ball line takes over from the normal trail)
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
				stageLevel, colorStage = 0, 0
				layersOff()
			end
		end
		local nowClock = os.clock()
		local dt = math.clamp(nowClock - lastClock, 0, 0.1)
		lastClock = nowClock
		if not shouldShow then
			lastPos = nil
			if hbOn or hbWeight > 0 then
				hbClear() -- reset / held ball: no orange left behind
			end
			return
		end
		local pos = state.position
		local teleport = lastPos ~= nil and (pos - lastPos :: Vector3).Magnitude > TELEPORT_DISTANCE
		if teleport then
			trail:Clear()
			hbClear()
			for _, l in layers do
				l.trail:Clear()
			end
		end
		local step = if lastPos and not teleport then (pos - lastPos :: Vector3).Magnitude else 0
		lastPos = pos
		follower.CFrame = CFrame.new(pos)

		-- attackable high ball: the server's window for THIS hit, until the opportunity ends
		local info = BallView.getInfo()
		-- the colour stage from the RETURN COUNT of the ball in flight (hits - 1: the serve is hit 1). A toss / held ball is 0.
		do
			-- (style.PreviewReturns: review renders only, never set by the game: forces a return count on a separate trail instance)
			local returns = if style.PreviewReturns then style.PreviewReturns
				elseif info.mode == "free" and not info.serve then math.max((info.hits or 1) - 1, 0)
				else 0
			-- the comet layers belong to a STRUCK ball (a serve or a return), never to a toss rising / falling
			cometAllowed = style.PreviewReturns ~= nil or (info.mode == "free" and not info.serve and (info.hits or 0) >= 1)
			local target = stageFor(returns)
			colorStage = target
			if target < stageLevel - 0.5 then
				stageLevel = target -- (a new point: back to white at once)
			else
				stageLevel += (target - stageLevel) * (1 - math.exp(-dt / math.max(RC and RC.BlendTime or 0.3, 1e-3)))
			end
		end
		local hb = info.highBall
		local want = false
		if HB.Enabled and hb and info.mode == "free" then
			local now = workspace:GetServerTimeNow()
			want = now <= hb.z and (HB.LeadIn <= 0 or now >= hb.a - HB.LeadIn)
			if hbKey ~= hb.a then -- (each snapshot sends a new table: key on the window itself)
				hbKey = hb.a
				hbDist = 0
				if hbOn then
					hbCore:Clear() -- (Pass 12) a new orange shot never carries the previous one's segments
					hbHalo:Clear()
				end
				-- phases from the window itself (deterministic per ball, different between balls; never per frame)
				local seed = math.floor((hb.a * 1000) % 100000)
				local rng = Random.new(seed)
				for k = 1, 4 do
					hbPhases[k] = rng:NextNumber(0, 2 * math.pi)
				end
			end
		end
		-- a new hit ends the opportunity at once (the receiver played it): fade almost immediately, not at the slow rate
		local newHit = info.hits ~= hbLastHits
		hbLastHits = info.hits
		if newHit and not want then
			hbFastUntil = nowClock + (HB.FadeOutOnHit or 0.08)
			if hbOn then
				hbClear() -- (Pass 12) contact: the next (normal) shot never keeps the lob's orange segments
			end
		end
		local fadeOut = if nowClock < hbFastUntil then (HB.FadeOutOnHit or 0.08) else HB.FadeOut
		local rate = if want then 1 / math.max(HB.FadeIn, 1e-3) else 1 / math.max(fadeOut, 1e-3)
		hbWeight = math.clamp(hbWeight + (if want then 1 else -1) * rate * dt, 0, 1)
		if hbWeight > 0.001 then
			if not hbOn then
				hbOn = true
				hbCore:Clear()
				hbHalo:Clear()
				hbCore.Enabled, hbHalo.Enabled = true, true
			end
			hbDist += step
			local v = state.velocity
			local camera = workspace.CurrentCamera
			local look = camera and camera.CFrame.LookVector or Vector3.zAxis
			local perp = if v.Magnitude > 1e-3 then v.Unit:Cross(look) else Vector3.yAxis
			perp = if perp.Magnitude > 1e-3 then perp.Unit else Vector3.yAxis
			local L = HB.WaveLengths
			local s = hbDist
			local wave = 0.5 * math.sin(2 * math.pi * s / L[1] + hbPhases[1])
				+ 0.3 * math.sin(2 * math.pi * s / L[2] + hbPhases[2])
				+ 0.2 * math.sin(2 * math.pi * s / L[3] + hbPhases[3])
			local envelope = 0.7 + 0.3 * math.sin(2 * math.pi * s / HB.EnvelopeLength + hbPhases[4])
			hbCoreF.CFrame = CFrame.new(pos + perp * (wave * envelope * HB.Amplitude * hbWeight))
			hbHaloF.CFrame = CFrame.new(pos)
			setHb(hbWeight)
		elseif hbOn then
			hbClear()
		end

		frame += 1
		if frame % STYLE_UPDATE_EVERY == 0 then
			applyStyle(state.velocity.Magnitude, state.spin, state.velocity)
		end
	end
	-- (tests) the high-ball layer's current blend weight
	function self.highBallWeight(): number
		return hbWeight
	end
	if Config.ShotControl.ShowDiagnostics then
		local lp = game:GetService("Players").LocalPlayer
		if lp then
			local bridge = Instance.new("BindableFunction")
			bridge.Name = "NotPongTrailDebug"
			bridge.OnInvoke = function()
				return { highBallWeight = hbWeight, highBallOn = hbOn, coreEnabled = hbCore.Enabled, distance = hbDist, info = BallView.getInfo().highBall, stage = colorStage, level = stageLevel, color = trail.Color.Keypoints[1].Value, layers = (function()
					local o = {}
					for _, l in layers do
						o[l.cfg.Name] = math.floor(l.opacity * 100 + 0.5) / 100
					end
					return o
				end)(), streakOn = (function()
					for _, l in layers do
						if l.on then
							return true
						end
					end
					return false
				end)(), trailTransparency = trail.Transparency.Keypoints[1].Value, followerChildren = #follower:GetChildren() }
			end
			bridge.Parent = lp
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
