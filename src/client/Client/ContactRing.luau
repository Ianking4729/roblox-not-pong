-- ContactRing (client, cosmetic and NON-authoritative): a hollow ring round the player's incoming ball that shows when
-- a flick would register (2026-11-17; replaced the accuracy bar). Config.Feedback.ContactRing.
--   * A faint full-circle track and a brighter ARC drawn clockwise from 12 o'clock; the arc grows (and the ring tightens
--     toward the ball) as the ball approaches the player's contact area, completes when contact becomes possible and turns
--     green, stays complete and green for the whole valid window, then quickly fades without unwinding.
--   * ELIGIBILITY (completion and green) = the SAME rule the server applies to a flick: the contact moment now +
--     Flick.ContactDelay classified against the incoming ball's contact window (normal reach, or the outer emergency ring)
--     from where the player stands (ShotInput.classify ~= "miss"). The client's window uses the server's snapshot of
--     the opponent's hit and the player's real root, exactly like the server (ShotController). Never the cosmetic paddle.
--   * PROGRESS = predicted approach: the time until a flick becomes valid, over Config...LeadTime (independent of camera
--     zoom and screen distance). With no window (the ball is not on a reachable path) it follows the ball's distance to
--     the contact area but is capped below completion and is never green. Display progress only ever increases for a ball.
--   * The ring is centred on the RENDERED ball every frame (BallView.onFrame); its radius never goes below the ball's
--     projected radius + a gap, so it cannot cover the ball. Only for the local player's incoming return (never a serve,
--     never the bot's ball); cleared on a swing's verdict, point reset, respawn and when the ball is no longer incoming.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ShotInput = require(Shared:WaitForChild("ShotInput"))

local BallView = require(script.Parent:WaitForChild("BallView"))
local PlatformZone = require(script.Parent:WaitForChild("PlatformZone"))

local ContactRing = {}

local R, S = Config.Feedback.ContactRing, Config.ShotControl
local Fl = Config.Flick

function ContactRing.new(screen: ScreenGui, controller: any)
	local N = R.Segments

	local root = Instance.new("Frame")
	root.Name = "ContactRing"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(0, 0)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = screen

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromScale(0, 0)
	track.BackgroundTransparency = 1
	track.Parent = root
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0.5, 0)
	trackCorner.Parent = track
	local trackStroke = Instance.new("UIStroke")
	trackStroke.Thickness = R.TrackThickness
	trackStroke.Color = R.TrackColor
	trackStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	trackStroke.Parent = track

	-- the arc: N short bars laid along the circle (pooled, only repositioned); bar i covers the angle i/N of a turn
	-- clockwise from 12 o'clock, so any fraction of a turn is drawn exactly
	local bars: { Frame } = {}
	for i = 1, N do
		local f = Instance.new("Frame")
		f.Name = "Seg" .. i
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = R.ArcColor
		f.Visible = false
		f.Parent = root
		bars[i] = f
	end

	local self = {}
	local hitsKey = -1 -- the incoming ball (hit counter) the ring is tracking
	local display = 0 -- displayed progress 0..1 (never decreases for one ball)
	local phase = "off" -- "off" | "live" | "fading"
	local fade = 0 -- 1 = fully visible .. 0 = gone (while fading)
	local wasGreen = false
	local lastRadius = -1
	local lastShown = -1
	local dbg = { visible = false, progress = 0, eligible = false, green = false, radius = 0, ballPx = 0, phase = "off", windowKind = "none", toValid = 0 }

	local function clear()
		phase, display, fade, wasGreen = "off", 0, 0, false
		root.Visible = false
		hitsKey = -1
		dbg.visible = false
	end
	local function startFade()
		if phase == "live" then
			phase, fade = "fading", 1
		end
	end

	controller.on(function(event: string, data: any)
		if event == "swing" then
			startFade() -- the opportunity was used (a return or the serve strike): leave the ring as it is and fade (never unwind)
		elseif event == "result" then
			startFade()
		elseif event == "reset" and data and (data.why == "point reset" or data.why == "respawned") then
			clear()
		end
	end)

	local function place(radius: number, progress: number, color: Color3, alpha: number)
		local thick = R.Thickness
		local size = radius * 2
		root.Size = UDim2.fromOffset(size, size)
		track.Size = UDim2.fromOffset(size, size)
		trackStroke.Transparency = 1 - (1 - R.TrackTransparency) * alpha
		local shown = math.floor(progress * N + 0.5)
		local seg = math.max(2 * math.pi * radius / N * 1.35, thick)
		for i = 1, N do
			local f = bars[i]
			if i <= shown then
				local th = (i - 0.5) / N * 2 * math.pi
				f.Position = UDim2.fromOffset(radius + radius * math.sin(th), radius - radius * math.cos(th))
				f.Size = UDim2.fromOffset(seg, thick)
				f.Rotation = math.deg(th)
				f.BackgroundColor3 = color
				f.BackgroundTransparency = 1 - alpha * (1 - R.ArcTransparency)
				f.Visible = true
			else
				f.Visible = false
			end
		end
		lastRadius, lastShown = radius, shown
	end

	-- Called every frame after the rendered ball moved.
	function self.onFrame(dt: number, state: any, visual: BasePart)
		local info = BallView.getInfo()
		local camera = workspace.CurrentCamera
		local serverNow = workspace:GetServerTimeNow()
		local incoming = BallView.getState() ~= nil
			and info.mode == "free"
			and info.incoming
			and not info.serve
			and not controller.serving
			and PlatformZone.isOn()
			and info.hits ~= controller.swungHits
			and (controller.state == "IDLE" or controller.state == "COMMITTED")
		-- SERVE TOSS (Pass 12): your own toss in the air, not yet struck. The ring uses the toss's real contact phase
		-- (ServeRules.phase from the server's toss snapshot and your stroke's reach, the same rule the server judges the
		-- serve flick with: legal when the flick STARTS inside [enter, exit]). No rally bounce rules, no slow motion.
		local sw = controller.window
		local serveMode = BallView.getState() ~= nil
			and info.mode == "free"
			and info.serve == true
			and controller.swungHits ~= -100
			and PlatformZone.isOn()
			and (controller.state == "IDLE" or controller.state == "COMMITTED")
		local key = if serveMode then -7 else info.hits
		incoming = incoming or serveMode

		-- a different incoming ball (or a new toss): start over
		if incoming and (key ~= hitsKey or phase == "off") then
			if phase ~= "off" then
				clear()
			end
			hitsKey = key
			phase, display, fade, wasGreen = "live", 0, 1, false
		end
		if phase == "live" and not incoming then
			startFade()
		end
		if phase == "off" or not camera then
			root.Visible = false
			dbg.visible = false
			return
		end

		-- the rendered ball on the screen
		local pos = visual.Position
		local vp, onScreen = camera:WorldToViewportPoint(pos)
		if not onScreen or vp.Z <= 0 then
			root.Visible = false
			dbg.visible = false
			return
		end
		local viewport = camera.ViewportSize
		local dist = (camera.CFrame.Position - pos).Magnitude
		local ballPx = Config.Ball.Radius * viewport.Y / (2 * math.max(dist, 0.1) * math.tan(math.rad(camera.FieldOfView) / 2))

		local eligible, target = false, display
		local kind = "none"
		local toValid = 0
		if phase == "live" and serveMode then
			kind = "serve"
			if sw and sw.cleanStart then
				-- release (flick start) times in server time: legal for a flick starting in [enter, exit]
				eligible = serverNow >= sw.enter and serverNow <= sw.exit
				toValid = sw.enter - serverNow
				if eligible then
					target = 1
				elseif serverNow > sw.exit then
					startFade() -- the toss dropped past the contact phase
				else
					target = math.min(1 - math.clamp(toValid / R.LeadTime, 0, 1), R.BeforeValidMax)
				end
			end
		elseif phase == "live" then
			local w = controller.window
			local win = w or controller.outerWindow
			if win and not win.cleanStart then
				kind = if w then "normal" else "emergency"
				local contactT = serverNow + Fl.ContactDelay
				local quality = ShotInput.classify(contactT, win)
				eligible = quality ~= "miss"
				-- the flick moments that would register: contact in [lo, hi] (the clean window plus the weak margins)
				-- (a high bounce can be in reach on the way up AND on the way down: approach the pass still to come)
				local half = S.ContactWindowDuration / 2
				local pw = win
				if win.earlier and contactT <= ShotInput.windowEnd(win.earlier) then
					pw = win.earlier
				end
				local lo = math.max(pw.enter, pw.ideal - half - S.EarlyReleaseTolerance) - Fl.ContactDelay
				local hi = math.min(pw.exit, pw.ideal + half + S.LateReleaseTolerance) - Fl.ContactDelay
				if pw ~= win then
					hi = math.min(win.exit, win.ideal + half + S.LateReleaseTolerance) - Fl.ContactDelay -- (fade only after the last pass)
				end
				toValid = lo - serverNow
				if eligible then
					target = 1
				elseif serverNow > hi then
					startFade() -- the opportunity passed
				else
					target = 1 - math.clamp(toValid / R.LeadTime, 0, 1)
					target = math.min(target, R.BeforeValidMax) -- never complete until eligible
				end
			else
				-- no reachable window (yet / any more): approach by distance to the contact area, never complete, never green
				-- (studs outside the normal reach, in either contact model)
				local r = controller.reach and controller.reach(false)
				local outside: number? = nil
				if typeof(r) == "table" then
					outside = (ShotInput.zoneRadius(r, pos) - 1) * math.min(r.side, r.front)
				elseif typeof(r) == "Vector3" then
					outside = Vector2.new(pos.X - r.X, pos.Z - r.Z).Magnitude - S.PaddleReach
				end
				if outside then
					target = math.clamp(1 - outside / R.ApproachStuds, 0, R.UnreachableMax)
				end
			end
		end

		if phase == "live" then
			if eligible then
				display = 1 -- no smoothing on the green signal
				wasGreen = true
			else
				display = math.max(display, display + (target - display) * (1 - math.exp(-R.Smoothing * dt)))
			end
		elseif phase == "fading" then
			fade -= dt / R.FadeTime
			if fade <= 0 then
				clear()
				return
			end
		end

		local green = (phase == "live" and eligible) or (phase == "fading" and wasGreen)
		local alpha = if phase == "fading" then fade else 1
		local far = R.FarRadius
		local near = ballPx + R.NearGap + R.Thickness / 2
		local radius = math.max(far + (near - far) * display, near)
		place(radius, display, if green then R.GreenColor else R.ArcColor, alpha) -- (72 pooled bars: cheap)
		root.Position = UDim2.fromOffset(vp.X - radius, vp.Y - radius)
		-- (root's anchor is the centre of its box; bars are positioned from the box's top-left, so offset by the radius)
		root.AnchorPoint = Vector2.zero
		root.Visible = true
		track.Position = UDim2.fromOffset(radius, radius)

		dbg.visible, dbg.progress, dbg.eligible, dbg.green = true, display, eligible, green
		dbg.radius, dbg.ballPx, dbg.phase, dbg.windowKind, dbg.toValid = radius, ballPx, phase, kind, toValid
	end

	local lastFrame = os.clock()
	BallView.onFrame(function(state, visual)
		local now = os.clock()
		local dt = math.clamp(now - lastFrame, 0, 0.1)
		lastFrame = now
		self.onFrame(dt, state, visual)
	end)
	function self.debug()
		return dbg
	end
	return self
end

return ContactRing
