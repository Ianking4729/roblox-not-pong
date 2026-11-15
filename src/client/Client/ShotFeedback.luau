-- ShotFeedback (client, cosmetic and NON-authoritative): everything the player sees while charging and making a shot.
--   * Trajectory arrow    (Client/TrajectoryArrow) a glowing 3D arrow through the air: the PREDICTED flight of the shot
--                         you are charging, from the predicted paddle contact to the first predicted landing. It runs the
--                         same ShotLaunch + BallPhysics as the server with your current power (hold time) and spin (drag),
--                         so it grows with the charge, bends with sidespin and dips/floats with top/backspin. Red with
--                         NET / OUT when the shot is predicted to fail; more transparent while a release now would be WEAK.
--   * Power / Curve meter (Client/PowerMeter) power fills with hold time only; curve = spin strength.
--   * Spin dial           where you pressed: arrow = direction and strength of the actual (capped) spin.
--   * Contact timing bar  predicted clean / weak release window and a moving "now" needle; after release it shows the
--                         SERVER's verdict (CLEAN / WEAK . EARLY / WEAK . LATE / EARLY / LATE / MISS).
--   * Swing + impact      a procedural paddle swing the moment you release; an impact burst when the server confirms a hit.
--   * Charge slow motion  while the rally is slowed: a draining timer, a subtle desaturating tint, and the arrow drawn
--                         from the predicted contact point.
-- It reads the ShotController (state, power, drag, spin, window) and listens to its events; it never changes them and
-- never feeds anything back to the server. Nothing here follows the cursor as a target. Tunables: Config.Feedback.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ShotInput = require(Shared:WaitForChild("ShotInput"))
local ShotLaunch = require(Shared:WaitForChild("ShotLaunch"))
local StancePose = require(Shared:WaitForChild("StancePose"))

local BallView = require(script.Parent:WaitForChild("BallView"))
local FrameDriver = require(script.Parent:WaitForChild("FrameDriver"))
local TrajectoryArrow = require(script.Parent:WaitForChild("TrajectoryArrow"))
local PowerMeter = require(script.Parent:WaitForChild("PowerMeter"))

local ShotFeedback = {}

local S, FB = Config.ShotControl, Config.Feedback
local ARROW, DIAL, TIMING, METER = FB.Arrow, FB.SpinDial, FB.Timing, FB.PowerMeter

-- ---------- small UI helpers ----------

local function corner(parent: Instance, scale: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale or 0.5, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, thickness: number, color: Color3, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function frame(parent: Instance, name: string, size: UDim2, position: UDim2?, anchor: Vector2?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = position or UDim2.fromScale(0.5, 0.5)
	f.AnchorPoint = anchor or Vector2.new(0.5, 0.5)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function label(parent: Instance, name: string, text: string, size: number, position: UDim2, anchor: Vector2): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Text = text
	l.Font = Enum.Font.GothamBold
	l.TextSize = size
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeColor3 = Color3.new(0, 0, 0)
	l.TextStrokeTransparency = 0.45
	l.Position = position
	l.AnchorPoint = anchor
	l.Size = UDim2.fromOffset(200, size + 4)
	l.Parent = parent
	return l
end

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

-- Verdict text from the SERVER's reply.
local function describe(result: string, reason: string, offset: number?): (string?, Color3)
	local r = string.lower(reason or "")
	if result == "clean" then
		return "CLEAN", TIMING.CleanColor
	elseif result == "weak" then
		local early = r == "early" or (offset ~= nil and offset < 0)
		return if early then "WEAK  \u{2022}  EARLY" else "WEAK  \u{2022}  LATE", TIMING.WeakColor
	elseif result == "miss" then
		if string.find(r, "late") or string.find(r, "held past") then
			return "LATE", TIMING.MissColor
		elseif string.find(r, "early") then
			return "EARLY", TIMING.MissColor
		end
		return "MISS", TIMING.MissColor
	end
	return nil, TIMING.MissColor -- "rejected": nothing to celebrate or blame
end

function ShotFeedback.start(player: Player, controller: any, extras: { impact: any? }?)
	local playerGui = player:WaitForChild("PlayerGui")
	local impactFx = extras and extras.impact
	local STATE = require(script.Parent:WaitForChild("ShotController")).STATE

	-- ---------- screen UI ----------
	local screen = Instance.new("ScreenGui")
	screen.Name = "NotPongFeedback"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 5
	screen.Parent = playerGui

	-- Spin dial
	local dial = frame(screen, "SpinDial", UDim2.fromOffset(DIAL.RadiusPixels * 2, DIAL.RadiusPixels * 2))
	dial.Visible = false
	local dialRing = frame(dial, "Ring", UDim2.fromScale(1, 1))
	corner(dialRing)
	local dialRingStroke = stroke(dialRing, 2, DIAL.IdleColor, 0.55)
	local dialShadow = frame(dial, "Shadow", UDim2.fromScale(1.06, 1.06))
	corner(dialShadow)
	stroke(dialShadow, 1, Color3.new(0, 0, 0), 0.6)
	local dialDot = frame(dial, "Dot", UDim2.fromOffset(10, 10))
	corner(dialDot)
	dialDot.BackgroundTransparency = 0
	dialDot.BackgroundColor3 = DIAL.IdleColor
	local dialArrow = frame(dial, "Arrow", UDim2.fromOffset(0, 5), nil, Vector2.new(0, 0.5))
	dialArrow.BackgroundTransparency = 0
	corner(dialArrow)
	local dialHead = frame(dial, "Head", UDim2.fromOffset(13, 13))
	dialHead.BackgroundTransparency = 0
	dialHead.Rotation = 45
	local R = DIAL.RadiusPixels
	local hints = {
		label(dial, "Top", "TOP", 11, UDim2.new(0.5, 0, 0, -9), Vector2.new(0.5, 1)),
		label(dial, "Back", "BACK", 11, UDim2.new(0.5, 0, 1, 9), Vector2.new(0.5, 0)),
		label(dial, "Left", "L", 11, UDim2.new(0, -8, 0.5, 0), Vector2.new(1, 0.5)),
		label(dial, "Right", "R", 11, UDim2.new(1, 8, 0.5, 0), Vector2.new(0, 0.5)),
	}
	for _, h in hints do
		h.Size = UDim2.fromOffset(48, 14)
		h.TextTransparency = 0.45
		h.TextStrokeTransparency = 0.7
	end
	hints[3].TextXAlignment = Enum.TextXAlignment.Right
	hints[4].TextXAlignment = Enum.TextXAlignment.Left

	-- Timing bar
	local barW = TIMING.Width
	local bar = frame(screen, "Timing", UDim2.fromOffset(barW, 50), UDim2.new(0.5, 0, 1, -TIMING.Offset), Vector2.new(0.5, 1))
	bar.Visible = false
	local resultLabel = label(bar, "Result", "", 22, UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0))
	resultLabel.Size = UDim2.new(1, 0, 0, 26)
	resultLabel.TextTransparency = 1
	resultLabel.TextStrokeTransparency = 1
	local track = frame(bar, "Track", UDim2.new(1, 0, 0, 10), UDim2.new(0.5, 0, 0, 36), Vector2.new(0.5, 0.5))
	track.BackgroundTransparency = 0.35
	track.BackgroundColor3 = Color3.fromRGB(18, 18, 28)
	corner(track, 0.5)
	local function zone(name: string, color: Color3): Frame
		local z = frame(track, name, UDim2.fromScale(0, 1), UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5))
		z.BackgroundTransparency = 0.25
		z.BackgroundColor3 = color
		return z
	end
	local weakEarly = zone("WeakEarly", TIMING.WeakColor)
	local weakLate = zone("WeakLate", TIMING.WeakColor)
	local cleanZone = zone("Clean", TIMING.CleanColor)
	cleanZone.BackgroundTransparency = 0.05
	local needle = frame(bar, "Needle", UDim2.fromOffset(3, 22), UDim2.new(0, 0, 0, 36), Vector2.new(0.5, 0.5))
	needle.BackgroundTransparency = 0
	needle.BackgroundColor3 = Color3.new(1, 1, 1)
	corner(needle, 0.5)
	local releaseTick = frame(bar, "Release", UDim2.fromOffset(4, 22), UDim2.new(0, 0, 0, 36), Vector2.new(0.5, 0.5))
	releaseTick.BackgroundTransparency = 0
	releaseTick.BackgroundColor3 = Color3.fromRGB(170, 170, 180)
	releaseTick.Visible = false
	corner(releaseTick, 0.5)

	-- ---------- arrow + meter ----------
	local arrow = TrajectoryArrow.new(playerGui)
	local meter = PowerMeter.new(screen)

	-- ---------- charge slow motion: timer + tint ----------
	local CF = Config.ChargeFreeze
	-- (stacked right above the Power / Curve panel, same width, so the three read as one group)
	local freezeBar = frame(screen, "SlowMotionTimer", UDim2.fromOffset(METER.Width + 96, 40), UDim2.new(1, -24, 1, -184), Vector2.new(1, 1))
	freezeBar.Visible = false
	local freezeLabel = label(freezeBar, "Label", "SLOW MO", 18, UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0))
	freezeLabel.Size = UDim2.new(1, 0, 0, 20)
	freezeLabel.TextColor3 = CF.TimerColor
	local freezeTrack = frame(freezeBar, "Track", UDim2.new(1, 0, 0, 8), UDim2.new(0.5, 0, 0, 30), Vector2.new(0.5, 0.5))
	freezeTrack.BackgroundTransparency = 0.35
	freezeTrack.BackgroundColor3 = Color3.fromRGB(18, 18, 28)
	corner(freezeTrack, 0.5)
	local freezeFill = frame(freezeTrack, "Fill", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5))
	freezeFill.BackgroundTransparency = 0.05
	freezeFill.BackgroundColor3 = CF.TimerColor
	corner(freezeFill, 0.5)
	local tint = Instance.new("ColorCorrectionEffect")
	tint.Name = "NotPongSlowMotionTint"
	tint.Enabled = true
	tint.Saturation = 0
	tint.TintColor = Color3.new(1, 1, 1)
	tint.Parent = Lighting -- (client-side instance: only this player sees it)
	local tintTween: Tween? = nil
	local function setTint(on: boolean)
		if tintTween then
			tintTween:Cancel()
		end
		local goal = if on
			then { Saturation = CF.TintSaturation, TintColor = CF.TintColor }
			else { Saturation = 0, TintColor = Color3.new(1, 1, 1) }
		tintTween = TweenService:Create(tint, TweenInfo.new(CF.TintFadeTime, Enum.EasingStyle.Quad), goal)
		;(tintTween :: Tween):Play()
	end

	-- ---------- state ----------
	local path: { Vector3 } = {}
	local prediction: { kind: string, contact: Vector3 }? = nil
	local predictKey = ""
	local nextPredictAt = -math.huge
	local meterUntil = -math.huge
	local resultUntil = -math.huge
	local frozenWindow: ShotInput.Window? = nil -- the window at release, kept to draw the verdict
	local releasedAt: number? = nil -- server time of release (client estimate)
	local lastPredictCost = 0
	local lastPredTop, lastPredSide = 0, 0 -- the spin the arrow's last prediction used

	-- ---------- swing + impact (events from the controller) ----------
	local function estimateQuality(): string
		if controller.freeze then
			return controller.freeze.q -- server's quality estimate when slow motion began
		elseif controller.freezePredicted then
			return "clean"
		end
		local w = controller.window
		if not w then
			return "miss"
		end
		local off = workspace:GetServerTimeNow() - w.ideal
		local half = S.ContactWindowDuration / 2
		if workspace:GetServerTimeNow() < w.enter or workspace:GetServerTimeNow() > w.exit then
			return "miss"
		elseif math.abs(off) <= half then
			return "clean"
		elseif (off < 0 and -off <= half + S.EarlyReleaseTolerance) or (off > 0 and off <= half + S.LateReleaseTolerance) then
			return "weak"
		end
		return "miss"
	end

	controller.on(function(event: string, data: any)
		if event == "slowMotion" then
			setTint(data.active)
		elseif event == "cancel" or event == "reset" then
			arrow.hide()
		elseif event == "release" then
			arrow.hide() -- the real ball takes over (its trail shows the actual flight)
			meterUntil = os.clock() + METER.ShowAfterRelease
			frozenWindow = controller.window
			releasedAt = workspace:GetServerTimeNow()
			releaseTick.BackgroundColor3 = Color3.fromRGB(170, 170, 180)
			resultLabel.TextTransparency = 1
			resultLabel.TextStrokeTransparency = 1
			-- Instant, local swing: strength from the client's estimate (visual only; the server decides the hit).
			local q = data.quality or estimateQuality()
			local strength = if q == "clean" then Config.Swing.CleanStrength elseif q == "weak" then Config.Swing.WeakStrength else Config.Swing.MissStrength
			local character = player.Character
			if character then
				-- The server judges the release moment on its slowed simulation timeline.
				local delay = math.max((data.strikeDelay or 0) - Config.Swing.Duration * 0.4, 0)
				if delay > 0 then
					task.delay(delay, StancePose.playSwing, character, strength)
				else
					StancePose.playSwing(character, strength)
				end
			end
		elseif event == "result" then
			local text, color = describe(data.result, data.reason, data.offset)
			if text then
				resultLabel.Text = text
				resultLabel.TextColor3 = color
				resultLabel.TextTransparency = 0
				resultLabel.TextStrokeTransparency = 0.35
				releaseTick.BackgroundColor3 = color
				resultUntil = os.clock() + TIMING.ResultShowTime
			end
			if impactFx and (data.result == "clean" or data.result == "weak") then
				local ball = BallView.getState()
				if ball then
					impactFx.play(ball.position, data.result)
				end
			end
		end
	end)

	-- ---------- prediction ----------
	-- The shot you would play if you released at the window's ideal moment: same ShotLaunch + BallPhysics as the server.
	local function predict(contact: Vector3, power: number, top: number, side: number)
		local launch = ShotLaunch.compute(contact, power, top, side)
		local result = ShotLaunch.predictPath(contact, launch.velocity, launch.spin, path, 2)
		return { kind = result.kind, contact = contact }
	end

	-- ---------- TEMPORARY input debug overlay (Config.ShotControl.ShowInputDebug) ----------
	-- Traces the whole pipeline from the button to the arrow, refreshed ~8 times a second (no per-frame text spam).
	local debugLabel: TextLabel? = nil
	local nextDebugAt = 0
	--[[
	if S.ShowInputDebug then
		local l = Instance.new("TextLabel")
		l.Name = "InputDebug"
		l.BackgroundColor3 = Color3.new(0, 0, 0)
		l.BackgroundTransparency = 0.45
		l.TextColor3 = Color3.fromRGB(190, 255, 200)
		l.Font = Enum.Font.Code
		l.TextSize = 14
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextYAlignment = Enum.TextYAlignment.Top
		l.AnchorPoint = Vector2.new(0, 0)
		l.Position = UDim2.fromOffset(10, 190)
		l.Size = UDim2.fromOffset(330, 150)
		l.Text = ""
		l.Parent = screen
		debugLabel = l
	end
	]]
	local function updateInputDebug(now: number)
		local l = debugLabel
		if not l or now < nextDebugAt then
			return
		end
		nextDebugAt = now + 0.12
		local m = controller.lastMove
		local d = controller.dragOverride or controller.drag
		l.Text = ("INPUT DEBUG (temporary)\nbutton held : %s\nstate        : %s\nmouse events : %d total, %d this charge\nlast move    : (%+.0f, %+.0f) via %s\ndrag (accum) : (%+.0f, %+.0f)\nspin         : top %+.0f  side %+.0f\nmeter        : power %.2f  curve %.2f\narrow spin   : top %+.0f  side %+.0f"):format(
			tostring(controller.buttonDown), tostring(controller.state), controller.moveEvents, controller.chargeMoveEvents,
			m.X, m.Y, tostring(controller.moveSource), d.X, d.Y, controller.topspin, controller.sidespin,
			meter.powerFill.Size.X.Scale, meter.curveFill.Size.X.Scale, lastPredTop, lastPredSide)
	end

	-- ---------- per-frame update ----------
	FrameDriver.bind("NotPongShotFeedback", Enum.RenderPriority.Last.Value - 10, function(dt)
		local state = controller.state
		local charging = state == STATE.CHARGING
		local released = state == STATE.SWING_RELEASED or state == STATE.CONTACT_RESOLVED or state == STATE.RECOVERY
		local nowClock = os.clock()
		local serverNow = workspace:GetServerTimeNow()
		local w: ShotInput.Window? = controller.window
		local aiming = state == STATE.IDLE and w ~= nil -- a ball is coming and we could start charging
		local freeze = controller.freeze
		local frozenNow = charging and (freeze ~= nil or controller.freezePredicted)

		-- Trajectory arrow: while charging at a reachable incoming ball. During confirmed slow motion it starts from the
		-- server's predicted contact point; otherwise it starts from our contact window.
		local power = controller.power()
		local top, side = controller.topspin, controller.sidespin
		local contactAt: Vector3? = nil
		if charging and freeze then
			contactAt = freeze.at
		elseif charging and w and (frozenNow or serverNow <= (w :: ShotInput.Window).exit) then
			contactAt = (w :: ShotInput.Window).idealPosition
		end
		if contactAt then
			local c = contactAt :: Vector3
			local key = ("%d|%d,%d|%.2f,%.2f,%.2f"):format(
				math.floor(power * 200 + 0.5),
				math.floor(top / 2 + 0.5),
				math.floor(side / 2 + 0.5),
				c.X,
				c.Y,
				c.Z
			)
			if key ~= predictKey and nowClock >= nextPredictAt then
				predictKey = key
				local t0 = os.clock()
				prediction = predict(c, power, top, side)
				lastPredTop, lastPredSide = top, side
				-- Adaptive budget: a slow prediction pushes the next one back in proportion (never eats the frame rate).
				lastPredictCost = os.clock() - t0
				nextPredictAt = nowClock + math.max(ARROW.RecomputeInterval, lastPredictCost * 6)
				arrow.set(path, (prediction :: any).kind, false)
			end
			arrow.setWeak(estimateQuality() == "weak")
			arrow.step(dt)
		else
			if prediction then
				prediction = nil
				predictKey = ""
			end
			arrow.hide()
		end

		-- Power / curve meter: while charging, and briefly after the release (held at the released power).
		local curve = math.sqrt(top * top + side * side) / S.MaxSpin
		if charging then
			meter.set(true, power, curve)
		elseif nowClock < meterUntil then
			meter.set(true, controller.releasedPower, curve)
		else
			meter.set(false, 0, 0)
		end

		updateInputDebug(nowClock)

		-- Spin dial
		dial.Visible = charging
		if charging then
			local ds: Vector2 = controller.dragStart
			dial.Position = UDim2.fromOffset(ds.X, ds.Y)
			local n = clamp01(curve)
			if n < 0.02 then
				dialArrow.Visible, dialHead.Visible = false, false
				dialDot.BackgroundColor3 = DIAL.IdleColor
				dialRingStroke.Color = DIAL.IdleColor
				dialRingStroke.Transparency = 0.6
				dialRingStroke.Thickness = 2
				dialDot.Size = UDim2.fromOffset(10, 10)
			else
			local color = DIAL.LowColor:Lerp(DIAL.HighColor, n)
				local len = R * n
				local ang = math.atan2(-top, -side) -- screen direction of the drag: x = -side, y = -top (y grows downward)
				dialArrow.Visible, dialHead.Visible = true, true
				dialArrow.Rotation = math.deg(ang)
				dialArrow.Size = UDim2.fromOffset(len, 3 + 3 * n)
				dialArrow.BackgroundColor3 = color
				dialHead.BackgroundColor3 = color
				dialHead.Position = UDim2.new(0.5, math.cos(ang) * len, 0.5, math.sin(ang) * len)
				dialDot.BackgroundColor3 = color
				dialDot.Size = UDim2.fromOffset(8, 8)
				dialRingStroke.Color = color
				dialRingStroke.Transparency = 0.5 - 0.35 * n
				dialRingStroke.Thickness = 2 + 2 * n
			end
		end

		-- Slow-motion timer (replaces the timing bar while the player is charging near contact)
		freezeBar.Visible = frozenNow
		if frozenNow then
			local left = if freeze then math.clamp((freeze.ends - serverNow) / CF.MaxDuration, 0, 1) else 1
			freezeFill.Size = UDim2.fromScale(left, 1)
			local color = if left < 0.3 then CF.TimerLowColor else CF.TimerColor
			freezeFill.BackgroundColor3 = color
			freezeLabel.TextColor3 = color
			freezeLabel.Text = if left < 0.3 then "RELEASE!" else "SLOW MO"
		end

		-- Contact timing bar
		local showBar = false
		if not released and nowClock >= resultUntil then
			frozenWindow = nil
		end
		local win = if frozenWindow and (released or nowClock < resultUntil) then frozenWindow else w
		if win and (aiming or charging or released) then
			showBar = true
		end
		if nowClock < resultUntil and win then
			showBar = true
		end
		if frozenNow then
			showBar = false -- the slow-motion countdown replaces the contact timing bar
		end
		bar.Visible = showBar
		if showBar and win then
			local span = TIMING.SecondsBefore + TIMING.SecondsAfter
			local function x(t: number): number
				return clamp01((t - win.ideal + TIMING.SecondsBefore) / span)
			end
			local half = S.ContactWindowDuration / 2
			local cs, ce = math.max(win.ideal - half, win.enter), math.min(win.ideal + half, win.exit)
			local es = math.max(win.ideal - half - S.EarlyReleaseTolerance, win.enter)
			local le = math.min(win.ideal + half + S.LateReleaseTolerance, win.exit)
			local function place(z: Frame, a: number, b: number)
				local xa, xb = x(a), x(b)
				z.Position = UDim2.fromScale(xa, 0.5)
				z.Size = UDim2.fromScale(math.max(xb - xa, 0), 1)
				z.Visible = b > a
			end
			place(weakEarly, es, cs)
			place(cleanZone, cs, ce)
			place(weakLate, ce, le)
			local nowX = x(serverNow)
			needle.Position = UDim2.new(nowX, 0, 0, 36)
			needle.Visible = not released or nowClock < resultUntil
			needle.BackgroundTransparency = if serverNow < win.ideal - TIMING.SecondsBefore then 0.7 else 0
			if releasedAt then
				releaseTick.Visible = released or nowClock < resultUntil
				releaseTick.Position = UDim2.new(x(releasedAt), 0, 0, 36)
			end
		end
		if nowClock >= resultUntil and resultLabel.TextTransparency < 1 then
			resultLabel.TextTransparency = 1
			resultLabel.TextStrokeTransparency = 1
		end
		if not released and not (nowClock < resultUntil) then
			releaseTick.Visible = false
			releasedAt = nil
		end
	end)

	if S.ShowDiagnostics then
		-- Development-only bridge for Studio test scripts: what the arrow and the meter currently show.
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongArrowDebug"
		bridge.OnInvoke = function()
			local shown = arrow.getShown()
			local pts = table.clone(path)
			return {
				visible = arrow.isVisible(),
				kind = prediction and prediction.kind,
				contact = prediction and prediction.contact,
				path = pts, -- the latest simulated path (contact ... first contact)
				shownTip = shown[#shown],
				shownCount = #shown,
				predictCost = lastPredictCost,
				meterVisible = meter.panel.Visible,
				meterPower = meter.powerFill.Size.X.Scale,
				meterCurve = meter.curveFill.Size.X.Scale,
			}
		end
		bridge.Parent = player
	end
end

return ShotFeedback
