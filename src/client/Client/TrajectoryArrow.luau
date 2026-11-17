-- TrajectoryArrow (client, cosmetic): the glowing 3D arrow that previews where the charged shot will GO, the
-- forward-looking counterpart of the ball trail (which shows where the ball HAS BEEN).
--
-- It only DRAWS a path it is given; the path itself is simulated by ShotFeedback with the shared ShotLaunch/BallPhysics
-- (same code as the server), so it rises, bends with sidespin, dips/floats with top/backspin and ends at the first
-- predicted contact. Rendering, all pooled and created once:
--   * a chain of Segments world-space Beams (bright core + wide translucent halo) between attachments that are moved
--     along the path every frame (the path is resampled to equal arc-length steps, so the beams stay evenly spaced),
--   * a tapered Beam arrowhead whose tip sits exactly on the predicted end point,
--   * a flat ring on the table at the predicted landing, and a "NET" / "OUT" label when the shot is predicted to fail
--     (the whole arrow then turns BadColor).
-- The drawn points ease toward each new prediction (Smoothing), so power/spin changes animate instead of jumping.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local TrajectoryArrow = {}

local A = Config.Feedback.Arrow

local function noPhysics(p: BasePart)
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Transparency = 1
end

-- Resample a polyline to `count` points at equal arc-length spacing, ending `trimEnd` studs before its end.
local function resample(src: { Vector3 }, count: number, trimEnd: number, out: { Vector3 })
	table.clear(out)
	local n = #src
	if n < 2 then
		for _ = 1, count do
			table.insert(out, src[1] or Vector3.zero)
		end
		return
	end
	local total = 0
	for i = 2, n do
		total += (src[i] - src[i - 1]).Magnitude
	end
	local usable = math.max(total - trimEnd, total * 0.5)
	local seg, segStart = 2, 0
	local segLen = (src[2] - src[1]).Magnitude
	for k = 0, count - 1 do
		local d = usable * k / (count - 1)
		while d > segStart + segLen and seg < n do
			segStart += segLen
			seg += 1
			segLen = (src[seg] - src[seg - 1]).Magnitude
		end
		local f = if segLen > 1e-6 then math.clamp((d - segStart) / segLen, 0, 1) else 0
		table.insert(out, src[seg - 1]:Lerp(src[seg], f))
	end
end

function TrajectoryArrow.new(playerGui: Instance)
	local N = math.max(4, A.Segments)

	local holder = Instance.new("Part")
	holder.Name = "NotPongTrajectoryArrow"
	holder.Size = Vector3.new(0.1, 0.1, 0.1)
	holder.CFrame = CFrame.identity -- attachments' Position == world position
	noPhysics(holder)

	local attachments: { Attachment } = {}
	for i = 1, N + 2 do -- N+1 path points + the arrow tip
		local a = Instance.new("Attachment")
		a.Name = "P" .. i
		a.Parent = holder
		attachments[i] = a
	end

	local function beam(name: string, a0: Attachment, a1: Attachment, emission: number): Beam
		local b = Instance.new("Beam")
		b.Name = name
		b.Attachment0, b.Attachment1 = a0, a1
		b.FaceCamera = true
		b.Segments = 1
		b.LightEmission = emission
		b.LightInfluence = 0
		b.Texture = ""
		b.Enabled = false
		b.Parent = holder
		return b
	end
	local cores: { Beam } = {}
	local glows: { Beam } = {}
	for i = 1, N do
		glows[i] = beam("Glow" .. i, attachments[i], attachments[i + 1], 0)
		cores[i] = beam("Core" .. i, attachments[i], attachments[i + 1], 1)
		cores[i].ZOffset = 1
	end
	local headGlow = beam("HeadGlow", attachments[N + 1], attachments[N + 2], 0)
	local head = beam("Head", attachments[N + 1], attachments[N + 2], 1)
	head.ZOffset = 1
	holder.Parent = workspace.CurrentCamera

	-- Landing ring (flat on the table) and failure label.
	local ringPart = Instance.new("Part")
	ringPart.Name = "NotPongArrowLanding"
	ringPart.Size = Vector3.new(A.EndRingRadius * 2, 0.05, A.EndRingRadius * 2)
	noPhysics(ringPart)
	ringPart.Parent = workspace.CurrentCamera
	local ringGui = Instance.new("SurfaceGui")
	ringGui.Name = "NotPongArrowLandingGui"
	ringGui.Face = Enum.NormalId.Top
	ringGui.CanvasSize = Vector2.new(128, 128)
	ringGui.LightInfluence = 0
	ringGui.ResetOnSpawn = false
	ringGui.Adornee = ringPart
	ringGui.Enabled = false
	ringGui.Parent = playerGui
	local ring = Instance.new("Frame")
	ring.Size = UDim2.fromScale(0.86, 0.86)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 0.6
	ring.Parent = ringGui
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(0.5, 0)
	ringCorner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Thickness = 12
	ringStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ringStroke.Parent = ring

	local labelPart = Instance.new("Part")
	labelPart.Name = "NotPongArrowLabel"
	labelPart.Size = Vector3.new(0.1, 0.1, 0.1)
	noPhysics(labelPart)
	labelPart.Parent = workspace.CurrentCamera
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NotPongArrowLabelGui"
	billboard.Size = UDim2.fromOffset(90, 30)
	billboard.StudsOffset = Vector3.new(0, 1.6, 0)
	billboard.AlwaysOnTop = true
	billboard.ResetOnSpawn = false
	billboard.Adornee = labelPart
	billboard.Enabled = false
	billboard.Parent = playerGui
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBlack
	text.TextScaled = true
	text.TextColor3 = A.BadColor
	text.TextStrokeTransparency = 0.3
	text.Parent = billboard

	-- ---------- state ----------
	local goal: { Vector3 } = {} -- N+1 resampled path points + tip (target of the easing)
	local shown: { Vector3 } = {}
	local scratch: { Vector3 } = {}
	local visible = false
	local snap = true
	local kind = "ok"
	local weak = false
	local smash = false -- a smash is lined up: gold arrow + "SMASH" label (red NET / OUT still wins)
	local SMASH_COLOR = Config.ShotControl.SmashColor

	local self = {}

	function self.setSmash(v: boolean)
		smash = v
	end

	-- points: the simulated path (contact ... first contact). resultKind: "ok" | "net" | "own" | "out".
	function self.set(points: { Vector3 }, resultKind: string, isWeak: boolean)
		if #points < 2 then
			self.hide()
			return
		end
		local tip = points[#points]
		resample(points, N + 1, A.HeadLength, scratch)
		table.clear(goal)
		for i, p in scratch do
			goal[i] = p
		end
		goal[N + 2] = tip
		if resultKind ~= kind then
			snap = true -- a changed verdict (ok / risky / net / out) is drawn at once, never eased in from the old path
		end
		kind, weak = resultKind, isWeak
		if not visible then
			snap = true
		end
		visible = true
	end

	function self.setWeak(v: boolean)
		weak = v
	end

	function self.hide()
		if not visible then
			return
		end
		visible = false
		for i = 1, N do
			cores[i].Enabled, glows[i].Enabled = false, false
		end
		head.Enabled, headGlow.Enabled = false, false
		ringGui.Enabled = false
		billboard.Enabled = false
	end

	function self.isVisible(): boolean
		return visible
	end

	-- Drawn end point (for tests / other layers).
	function self.getShown(): { Vector3 }
		return shown
	end

	function self.step(dt: number)
		if not visible or #goal < N + 2 then
			return
		end
		local f = if snap then 1 else 1 - math.exp(-A.Smoothing * dt)
		snap = false
		for i = 1, N + 2 do
			local g = goal[i]
			shown[i] = if shown[i] then (shown[i] :: Vector3):Lerp(g, f) else g
			attachments[i].Position = shown[i]
		end

		local risky = kind == "risky" -- lands now, but a moment later would not / right on an edge (ShotFeedback)
		local bad = kind ~= "ok" and not risky
		local riskyColor = A.RiskyColor or A.BadColor
		local color = if bad then A.BadColor elseif risky then riskyColor elseif smash then SMASH_COLOR else A.Color
		local glowColor = if bad then A.BadColor elseif risky then riskyColor elseif smash then SMASH_COLOR else A.GlowColor
		local extra = if weak then A.WeakTransparency else 0
		local core = ColorSequence.new(color)
		local glow = ColorSequence.new(glowColor)
		for i = 1, N do
			-- fade in over the first StartFade of the path (keeps the paddle and the ball readable)
			local t0, t1 = (i - 1) / N, i / N
			local fade0 = 1 - math.clamp(t0 / math.max(A.StartFade, 1e-3), 0, 1)
			local fade1 = 1 - math.clamp(t1 / math.max(A.StartFade, 1e-3), 0, 1)
			local function tr(base: number, fade: number): number
				return math.clamp(base + extra + (1 - base) * fade * 0.9, 0, 1)
			end
			local c, g = cores[i], glows[i]
			c.Color, g.Color = core, glow
			c.Transparency = NumberSequence.new(tr(A.CoreTransparency, fade0), tr(A.CoreTransparency, fade1))
			g.Transparency = NumberSequence.new(tr(A.GlowTransparency, fade0), tr(A.GlowTransparency, fade1))
			c.Width0, c.Width1 = A.Width, A.Width
			g.Width0, g.Width1 = A.GlowWidth, A.GlowWidth
			c.Enabled, g.Enabled = true, true
		end
		head.Color, headGlow.Color = core, glow
		head.Transparency = NumberSequence.new(math.clamp(A.CoreTransparency + extra, 0, 1))
		headGlow.Transparency = NumberSequence.new(math.clamp(A.GlowTransparency + extra, 0, 1))
		head.Width0, head.Width1 = A.HeadWidth, 0
		headGlow.Width0, headGlow.Width1 = A.HeadWidth * 1.7, 0
		head.Enabled, headGlow.Enabled = true, true

		local tip = shown[N + 2]
		local onTable = kind == "ok" or kind == "own" or risky
		ringGui.Enabled = onTable
		if onTable then
			ringPart.CFrame = CFrame.new(tip.X, tip.Y - Config.Ball.Radius + 0.06, tip.Z)
			ringStroke.Color = color
			ring.BackgroundColor3 = glowColor
			ringStroke.Transparency = 0.1 + extra
		end
		billboard.Enabled = bad or smash or risky
		if bad or smash or risky then
			labelPart.CFrame = CFrame.new(tip)
			local what = if risky then "RISKY" elseif not bad then "" elseif kind == "net" then "NET" elseif kind == "own" then "OWN SIDE" else "OUT"
			text.Text = if smash and (bad or risky) then "SMASH " .. what elseif smash then "SMASH" else what
			text.TextColor3 = if bad then A.BadColor elseif risky then riskyColor else SMASH_COLOR
		end
	end

	return self
end

return TrajectoryArrow
