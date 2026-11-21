-- ServeGuide (client, cosmetic; Config.Serve.Guide; Pass 12, reworked Pass 13 2026-11-19): the player's serve landing
-- feedback. Drawn from the moment the ball rests in your hand on your serve until the paddle meets the toss.
--   PROVISIONAL (serve preparation and the toss, before the flick): a REPRESENTATIVE serve (Guide.Representative: power
--     0.5, no spin, a clean contact at the toss's typical contact point, your current aim) solved with the same shared
--     ShotLaunch.serve the server uses. Drawn fainter (it is a typical serve, not your final one): dashed path, hollow
--     ring at its receiver-side landing and the downward arrow filling tail -> tip. Re-solved only when the aim or your
--     position changes (throttled); the ring / arrow ease to the new spot and the fill never restarts for a move.
--   FINAL (from the flick until contact): the predicted serve from the real inputs (power / spin / aim / quality), full
--     strength. The guide hides at contact (the user's choice: the prediction is not drawn over the struck ball).
-- Dashes: laid FLAT ON THE TABLE along the predicted flight's ground track (only over the table), DashWidthScale x the
-- BallVisual's measured diameter wide, evenly spaced along the track's arc length (they do not crawl), stopping short of
-- the ring. Everything is pooled.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BallPhysics = require(Shared:WaitForChild("BallPhysics"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))

local ServeGuide = {}

local G = Config.Serve.Guide

local function noPhysics(p: BasePart)
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
end

-- Simulate a struck serve from `state` until its receiver-side bounce (the first table contact on the Bot's half), the
-- net / floor, or `horizon` seconds. Returns the landing (nil if none); `out` receives the path points.
function ServeGuide.simulate(state: BallPhysics.State, out: { Vector3 }, stride: number?, horizon: number?): (Vector3?, string)
	local cfg, world = TableWorld.physics, TableWorld.world
	local s = BallPhysics.copyState(state)
	s.resting = false
	local events: { BallPhysics.Event } = {}
	table.clear(out)
	table.insert(out, s.position)
	local n = math.floor((horizon or 2.5) / cfg.fixedStep)
	local every = stride or 2
	for i = 1, n do
		local before = #events
		BallPhysics.tick(s, cfg, world, events)
		for k = before + 1, #events do
			local e = events[k]
			if e.kind == "table" then
				table.insert(out, e.position)
				if e.surface == "Bot" then
					return e.position, "ok"
				end
			elseif e.kind == "net" or e.kind == "floor" then
				table.insert(out, e.position)
				return nil, e.kind
			end
		end
		if i % every == 0 then
			table.insert(out, s.position)
		end
		if s.resting then
			break
		end
	end
	return nil, "none"
end

function ServeGuide.new(playerGui: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "NotPongServeGuide"
	folder.Parent = workspace.CurrentCamera

	-- the dash width follows the ball actually on screen (measured), unless Config overrides it
	local function ballDiameter(): number
		local arena = workspace:FindFirstChild(Config.Names.Arena)
		local tpl = arena and arena:FindFirstChild("BallTemplate")
		local ballPart = tpl and tpl:FindFirstChild("Ball")
		local vis = ballPart and ballPart:FindFirstChild("BallVisual")
		if vis and vis:IsA("BasePart") then
			return math.max(vis.Size.X, vis.Size.Y, vis.Size.Z)
		end
		return Config.Ball.Radius * 2
	end
	local dashWidth = G.DashWidth or (ballDiameter() * (G.DashWidthScale or 1))

	local dashes: { BasePart } = {}
	for i = 1, G.MaxDashes do
		local d = Instance.new("Part")
		d.Name = "Dash" .. i
		noPhysics(d)
		d.Material = Enum.Material.SmoothPlastic
		d.Color = G.Color
		d.Transparency = 1
		d.Size = Vector3.new(dashWidth, G.DashThickness, G.DashLength)
		d.Parent = folder
		dashes[i] = d
	end

	-- hollow ring on the table
	local ringPart = Instance.new("Part")
	ringPart.Name = "LandingRing"
	noPhysics(ringPart)
	ringPart.Transparency = 1
	ringPart.Size = Vector3.new(G.RingRadius * 2, 0.05, G.RingRadius * 2)
	ringPart.Parent = folder
	local ringGui = Instance.new("SurfaceGui")
	ringGui.Name = "NotPongServeRingGui"
	ringGui.Face = Enum.NormalId.Top
	ringGui.CanvasSize = Vector2.new(128, 128)
	ringGui.LightInfluence = 0
	ringGui.AlwaysOnTop = G.MarkerOnTop ~= false -- (measured: from the serve camera the landing sits behind your own body)
	ringGui.ResetOnSpawn = false
	ringGui.Adornee = ringPart
	ringGui.Enabled = false
	ringGui.Parent = playerGui
	local ring = Instance.new("Frame")
	ring.Size = UDim2.fromOffset(128 - G.RingThickness * 2, 128 - G.RingThickness * 2)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.Parent = ringGui
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(0.5, 0)
	ringCorner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Thickness = G.RingThickness
	ringStroke.Color = G.Color
	ringStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ringStroke.Parent = ring

	-- the downward arrow: a camera-facing billboard whose bottom-centre (the tip) is the ring's centre
	local arrowAnchor = Instance.new("Part")
	arrowAnchor.Name = "ArrowAnchor"
	noPhysics(arrowAnchor)
	arrowAnchor.Transparency = 1
	arrowAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
	arrowAnchor.Parent = folder
	local board = Instance.new("BillboardGui")
	board.Name = "NotPongServeArrow"
	-- studs + a pixel floor: from the low serve camera (~33 studs behind, ~7 above the table) a studs-only arrow was 23 px
	board.Size = UDim2.new(G.ArrowWidth, G.ArrowMinWidthPx or 0, G.ArrowHeight, G.ArrowMinHeightPx or 0)
	board.SizeOffset = Vector2.new(0, 0.5) -- (the box sits above the anchor: its bottom edge = the tip = the ring's centre)
	board.LightInfluence = 0
	board.AlwaysOnTop = G.MarkerOnTop ~= false
	board.ResetOnSpawn = false
	board.Adornee = arrowAnchor
	board.Enabled = false
	board.Parent = playerGui
	-- the arrow shape, unrotated frames only (so the fill can clip it): a shaft and a head of stacked rows
	local HEAD_FROM, ROWS, SHAFT_W = 0.5, 18, 0.3
	local function arrowShape(parent: Instance): { Frame }
		local parts = {}
		local shaft = Instance.new("Frame")
		shaft.BorderSizePixel = 0
		shaft.AnchorPoint = Vector2.new(0.5, 0)
		shaft.Position = UDim2.fromScale(0.5, 0)
		shaft.Size = UDim2.fromScale(SHAFT_W, HEAD_FROM + 0.01)
		shaft.Parent = parent
		table.insert(parts, shaft)
		local rowH = (1 - HEAD_FROM) / ROWS
		for i = 1, ROWS do
			local r = Instance.new("Frame")
			r.BorderSizePixel = 0
			r.AnchorPoint = Vector2.new(0.5, 0)
			r.Position = UDim2.fromScale(0.5, HEAD_FROM + (i - 1) * rowH)
			r.Size = UDim2.fromScale(math.max(1 - (i - 0.5) / ROWS, 0.04), rowH * 1.05)
			r.Parent = parent
			table.insert(parts, r)
		end
		return parts
	end
	local trackParts = arrowShape(board)
	local clip = Instance.new("Frame")
	clip.Name = "Fill"
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.Size = UDim2.fromScale(1, 0)
	clip.Parent = board
	local fillHolder = Instance.new("Frame")
	fillHolder.BackgroundTransparency = 1
	fillHolder.Size = UDim2.fromScale(1, 1)
	fillHolder.Parent = clip
	local fillParts = arrowShape(fillHolder)
	for _, f in trackParts do
		f.BackgroundColor3 = G.Color
	end
	for _, f in fillParts do
		f.BackgroundColor3 = G.Color
	end

	-- ---------- state ----------
	local mode = "off" -- "off" | "provisional" | "final"
	local path: { Vector3 } = {}
	local cum: { number } = {}
	local landing: Vector3? = nil -- the drawn (eased) ring centre
	local goalLanding: Vector3? = nil
	local fillStart = os.clock() -- the fill cycle's clock (never restarted by a moving target)
	local alpha = 0
	local fading = false
	local fadeTime = G.FadeTime
	local dbg = { mode = "off", dashes = 0, landing = nil :: Vector3?, fill = 0, fillStarts = 0, alpha = 0, dashWidth = dashWidth, solves = 0 }

	local function rebuildLengths()
		table.clear(cum)
		local total = 0
		cum[1] = 0
		for i = 2, #path do
			total += (path[i] - path[i - 1]).Magnitude
			cum[i] = total
		end
	end
	local function pointAt(s: number): Vector3
		local n = #path
		if n == 0 then
			return Vector3.zero
		end
		if s <= 0 then
			return path[1]
		end
		if s >= cum[n] then
			return path[n]
		end
		local lo, hi = 1, n
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if cum[mid] <= s then
				lo = mid
			else
				hi = mid
			end
		end
		local seg = cum[hi] - cum[lo]
		local f = if seg > 1e-6 then (s - cum[lo]) / seg else 0
		return path[lo]:Lerp(path[hi], f)
	end

	local self = {}

	-- Show a predicted serve (`state` = the ball just struck). which = "provisional" | "final".
	function self.show(state: BallPhysics.State, which: string): boolean
		local pts = {}
		local land = ServeGuide.simulate(state, pts, 2)
		if not land then
			return false
		end
		dbg.solves += 1
		-- (Pass 13, user: "should lay flat on the table") the dashes follow the predicted flight's GROUND TRACK on the table
		-- surface, only where it is over the table
		local y = Config.Layout.SurfaceY + (G.FlatLift or 0.04)
		local c, hw, hl = TableWorld.center, TableWorld.halfWidth, TableWorld.halfLength
		local flat = {}
		for _, p in pts do
			if math.abs(p.X - c.X) <= hw and math.abs(p.Z - c.Z) <= hl then
				table.insert(flat, Vector3.new(p.X, y, p.Z))
			end
		end
		if #flat < 2 then
			flat = { Vector3.new(land.X, y, land.Z), Vector3.new(land.X, y, land.Z + 0.1) }
		end
		path = flat
		rebuildLengths()
		goalLanding = land
		if mode == "off" or not landing or fading then
			landing = land
			fillStart = os.clock() -- a fresh appearance starts the fill; later moves only ease the ring / arrow
			dbg.fillStarts += 1
		elseif (land - landing).Magnitude > (G.SnapDistance or 6) then
			landing = land -- (a big jump: snap rather than slide across the table; the fill continues)
		end
		mode, fading, alpha = which, false, 1
		return true
	end

	function self.mode(): string
		return mode
	end

	-- Fade out (contact, fault, reset, mode change). immediate = hide now; fast = the short contact fade.
	function self.hide(immediate: boolean?, fast: boolean?)
		if mode == "off" then
			return
		end
		if immediate then
			mode, alpha, fading = "off", 0, false
			for _, d in dashes do
				d.Transparency = 1
			end
			ringGui.Enabled, board.Enabled = false, false
			return
		end
		if not fading then
			fading = true
			fadeTime = if fast then (G.ContactFadeTime or 0.12) else G.FadeTime
		end
	end

	function self.step(dt: number)
		if mode == "off" then
			dbg.mode, dbg.dashes, dbg.alpha = "off", 0, 0
			return
		end
		if fading then
			alpha -= dt / math.max(fadeTime, 1e-3)
			if alpha <= 0 then
				self.hide(true)
				return
			end
		end
		if goalLanding and landing then
			landing = landing:Lerp(goalLanding, 1 - math.exp(-G.Smoothing * dt))
		end
		local final = mode == "final"
		-- dashes (flat ribbons facing the camera, ball-wide)
		local total = (cum[#cum] or 0) - (G.EndTrim or 0)
		local period = G.DashLength + G.DashGap
		local baseT = if final then G.DashTransparency else G.ProvisionalTransparency
		local transparency = 1 - (1 - baseT) * alpha
		local used = 0
		local k = 0
		while used < #dashes do
			local s0 = k * period
			if s0 >= total then
				break
			end
			local s1 = math.min(s0 + G.DashLength, total)
			k += 1
			if s1 - s0 > 0.15 then
				local a, b = pointAt(s0), pointAt(s1)
				local along = b - a
				local len = along.Magnitude
				if len > 0.05 then
					used += 1
					local d = dashes[used]
					local mid = (a + b) / 2
					d.Size = Vector3.new(dashWidth, G.DashThickness, len)
					d.CFrame = CFrame.lookAt(mid, b, Vector3.yAxis) -- flat on the table
					d.Transparency = transparency
				end
			end
		end
		for i = used + 1, #dashes do
			if dashes[i].Transparency < 1 then
				dashes[i].Transparency = 1
			end
		end
		-- ring
		if landing then
			ringPart.CFrame = CFrame.new(landing.X, Config.Layout.SurfaceY + 0.04, landing.Z)
			ringStroke.Transparency = 1 - (1 - (if final then G.RingTransparency else G.ProvisionalRingTransparency)) * alpha
			ringGui.Enabled = true
		end
		-- arrow: fills tail -> tip, holds, repeats (its clock runs on; a moving target never restarts it)
		local fill = 0
		if landing then
			arrowAnchor.CFrame = CFrame.new(landing.X, Config.Layout.SurfaceY + 0.02, landing.Z)
			local cycle = G.FillTime + G.HoldTime
			local t = (os.clock() - fillStart) % cycle
			fill = math.clamp(t / G.FillTime, 0, 1)
			local strength = if final then 1 else (G.ProvisionalArrowStrength or 0.75)
			local trackT = 1 - (1 - G.ArrowTrackTransparency) * alpha
			for _, f in trackParts do
				f.BackgroundTransparency = trackT
			end
			for _, f in fillParts do
				f.BackgroundTransparency = 1 - alpha * strength
			end
			clip.Visible = fill > 0.001
			clip.Size = UDim2.fromScale(1, fill)
			fillHolder.Size = UDim2.fromScale(1, 1 / math.max(fill, 0.001))
			board.Enabled = true
		end
		dbg.mode, dbg.dashes, dbg.landing, dbg.fill, dbg.alpha = mode, used, landing, fill, alpha
	end

	function self.debug()
		return dbg
	end
	return self
end

return ServeGuide
