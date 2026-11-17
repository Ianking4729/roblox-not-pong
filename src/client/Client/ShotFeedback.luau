-- ShotFeedback (client, cosmetic and NON-authoritative): what the player sees around a CLICK-AND-FLICK shot
-- (rewritten 2026-11-17; the charge meter, the drag dial and the "release now" arrow of hold-to-charge are gone).
--   * Aim marker          while preparing / committed: a ring on the opponent's half where the BASE aim points (from
--                         the cursor; locked at the click) and a post whose height shows the drive (short) .. arc (tall)
--                         profile. It is the base aim only: power and spin are not known before the flick, and spin will
--                         bend the real flight away from it.
--   * Flick dial          where you clicked (the cursor is held there while committed): "FLICK" while waiting; after the
--                         flick its arrow shows the flick's direction = the spin (up = topspin, down = backspin, sideways
--                         = curve) and its length the spin strength.
--   * Power / Curve       after the flick: the power the flick's speed gave and the spin strength (never during a hold:
--                         holding adds nothing).
--   * Contact ring        (Client/ContactRing) a hollow ring round the incoming ball whose arc completes and turns green
--                         while a flick right now would register (replaced the accuracy bar, 2026-11-17).
--   * Verdict text        after the flick, the SERVER's verdict (CLEAN / WEAK . EARLY / WEAK . LATE / EARLY / LATE / MISS / SAVE).
--   * Trajectory arrow    after the flick, until the verdict: the predicted flight from the ACTUAL inputs (the flick's
--                         power and spin, the locked aim and profile, the contact timing), computed with the same
--                         ShotLaunch + BallPhysics as the server (so prediction and launch agree).
--   * Impact              a burst when the server confirms a hit.
-- It reads the ShotController and listens to its events; it never changes them and never talks to the server.
-- Tunables: Config.Feedback.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))
local ShotLaunch = require(Shared:WaitForChild("ShotLaunch"))

local BallView = require(script.Parent:WaitForChild("BallView"))
local FrameDriver = require(script.Parent:WaitForChild("FrameDriver"))
local TrajectoryArrow = require(script.Parent:WaitForChild("TrajectoryArrow"))
local PowerMeter = require(script.Parent:WaitForChild("PowerMeter"))
local PlatformZone = require(script.Parent:WaitForChild("PlatformZone"))
local ContactRing = require(script.Parent:WaitForChild("ContactRing"))

local ShotFeedback = {}

local S, FB, Fl, P = Config.ShotControl, Config.Feedback, Config.Flick, Config.Prep
local DIAL, TIMING, METER, AIM = FB.SpinDial, FB.Timing, FB.PowerMeter, FB.AimMarker

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
	l.Position = position
	l.AnchorPoint = anchor
	l.Size = UDim2.fromOffset(200, size + 6)
	l.Font = Enum.Font.GothamBold
	l.TextSize = size
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.35
	l.Text = text
	l.Parent = parent
	return l
end

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

-- Verdict text from the SERVER's reply: brief and distinct per cause (2026-11-17). Detailed numbers stay in the dev
-- telemetry ([Tel] lines), never on the HUD.
--   contact made:  SAVE! / CLEAN / WEAK . EARLY / WEAK . LATE, or CONTACT . OUT / CONTACT . NET when the shot (as the
--                  server predicts it from the same physics) will not land on the opponent's half
--   miss:          TOO EARLY / TOO LATE / OUT OF REACH (the server's reason); NO FLICK comes from the controller
--                  (a commitment that ended without a recognised flick), see below
local function describe(result: string, reason: string, offset: number?, kind: string?, land: string?): (string?, Color3)
	local r = string.lower(reason or "")
	if (result == "clean" or result == "weak") and (land == "out" or land == "own") then
		return "CONTACT  \u{2022}  OUT", TIMING.WeakColor
	elseif (result == "clean" or result == "weak") and land == "net" then
		return "CONTACT  \u{2022}  NET", TIMING.WeakColor
	elseif (result == "clean" or result == "weak") and kind == "emergency" then
		return "SAVE!", TIMING.SaveColor
	elseif result == "clean" then
		return "CLEAN", TIMING.CleanColor
	elseif result == "weak" then
		local early = r == "early" or (offset ~= nil and offset < 0)
		return if early then "WEAK  \u{2022}  EARLY" else "WEAK  \u{2022}  LATE", TIMING.WeakColor
	elseif result == "miss" then
		if string.find(r, "late") then
			return "TOO LATE", TIMING.MissColor
		elseif string.find(r, "early") then
			return "TOO EARLY", TIMING.MissColor
		elseif string.find(r, "reach") then
			return "OUT OF REACH", TIMING.MissColor
		end
		return "MISS", TIMING.MissColor -- (no ball coming / already swung at this ball)
	end
	return nil, TIMING.MissColor -- "rejected": nothing to celebrate or blame
end

local function marker(name: string, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Transparency = 1
	p.Parent = parent
	return p
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

	-- Flick dial (where you clicked)
	local dial = frame(screen, "FlickDial", UDim2.fromOffset(DIAL.RadiusPixels * 2, DIAL.RadiusPixels * 2))
	dial.Visible = false
	local dialRing = frame(dial, "Ring", UDim2.fromScale(1, 1))
	corner(dialRing)
	local dialRingStroke = stroke(dialRing, 2, DIAL.IdleColor, 0.55)
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
	local dialText = label(dial, "Prompt", "FLICK", 14, UDim2.new(0.5, 0, 1, 10), Vector2.new(0.5, 0))
	local R = DIAL.RadiusPixels
	local hints = {
		label(dial, "Top", "TOP", 11, UDim2.new(0.5, 0, 0, -9), Vector2.new(0.5, 1)),
		label(dial, "Back", "BACK", 11, UDim2.new(0.5, 0, 1, 26), Vector2.new(0.5, 0)),
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

	-- Verdict text (CLEAN / WEAK / EARLY / LATE / MISS / SAVE!), shown briefly after a swing. (The old accuracy bar was
	-- replaced by the contact ring, Client/ContactRing, on 2026-11-17.)
	local resultLabel = label(screen, "Result", "", 24, UDim2.new(0.5, 0, 1, -TIMING.Offset), Vector2.new(0.5, 1))
	resultLabel.Size = UDim2.fromOffset(TIMING.Width, 30)
	resultLabel.TextTransparency = 1
	resultLabel.TextStrokeTransparency = 1
	local ring = ContactRing.new(screen, controller)
	-- TEMPORARY developer indicator (Config.ShotControl.ShowInputDebug): the rally input mode, what the input is doing
	-- now (PREPARING / SWING ONSET / SWING RECOGNIZED / RECOVERING) and the last ignored candidate or miss reason.
	local devLabel: TextLabel? = nil
	local devNote, devNoteUntil = "", -math.huge
	if S.ShowInputDebug then
		local l = label(screen, "InputModeDebug", "", 13, UDim2.new(0, 12, 1, -150), Vector2.new(0, 1))
		l.Size = UDim2.fromOffset(360, 40)
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextYAlignment = Enum.TextYAlignment.Bottom
		l.Font = Enum.Font.Code
		l.TextTransparency = 0.15
		devLabel = l
	end
	local function note(text: string)
		devNote, devNoteUntil = text, os.clock() + 1.5
	end
	-- ---------- arrow + meter + aim marker ----------
	local arrow = TrajectoryArrow.new(playerGui)
	local meter = PowerMeter.new(screen)
	local markers = Instance.new("Folder")
	markers.Name = "NotPongAimMarker"
	markers.Parent = workspace.CurrentCamera
	local aimRing = marker("AimRing", markers)
	aimRing.Shape = Enum.PartType.Cylinder
	aimRing.Size = Vector3.new(0.08, AIM.RingRadius * 2, AIM.RingRadius * 2)
	local aimPost = marker("AimPost", markers)

	-- ---------- state ----------
	local path: { Vector3 } = {}
	local prediction: { kind: string, contact: Vector3, launch: any }? = nil
	local meterUntil = -math.huge
	local resultUntil = -math.huge
	local dialUntil = -math.huge
			local dialAt = Vector2.zero
	local lastSwing: any = nil

	local function showVerdict(text: string, color: Color3)
		resultLabel.Text = text
		resultLabel.TextColor3 = color
		resultLabel.TextTransparency = 0
		resultLabel.TextStrokeTransparency = 0.35
		resultUntil = os.clock() + TIMING.ResultShowTime
	end

	local committedLive = false -- the current commitment was made in a live rally (not your serve)
	controller.on(function(event: string, data: any)
		if event == "commit" then
			dialAt = game:GetService("UserInputService"):GetMouseLocation()
			resultLabel.TextTransparency = 1
			resultLabel.TextStrokeTransparency = 1
			committedLive = not data.serve and data.incoming == true -- (also set per frame once a ball comes during the hold)
		elseif event == "cancel" or event == "reset" then
			if controller.state == STATE.IDLE then
				arrow.hide()
				prediction = nil
			end
			-- NO FLICK: a commitment against a live ball ended without a recognised flick (released, or the point ended
			-- while holding). Only "cancel" (fired after the reset) carries the cause; deliberate cancels stay silent.
			if event == "cancel" and committedLive then
				committedLive = false
				local why = data and data.why
				if why == "released without a flick" or why == "point reset" then
					showVerdict("NO FLICK", TIMING.MissColor)
				end
			end
		elseif event == "candidate" then
			note("IGNORED: " .. tostring(data and data.outcome))
		elseif event == "swing" then
			committedLive = false
			if not data.serve then
				note(("flick power %d%%"):format(math.floor((data.power or 0) * 100 + 0.5)))
			end
			lastSwing = data
			meterUntil = os.clock() + METER.ShowAfterRelease
			dialUntil = os.clock() + METER.ShowAfterRelease
			resultLabel.TextTransparency = 1
			resultLabel.TextStrokeTransparency = 1
			prediction = nil
			arrow.hide()
			-- the predicted flight from the actual inputs (the same shared launch as the server's)
			if not data.serve and data.quality ~= "miss" and data.contact then
				local ok, launch = pcall(controller.predictLaunch)
				if ok and launch then
					local res = ShotLaunch.predictPath(data.contact, launch.velocity, launch.spin, path, 2)
					prediction = { kind = res.kind, contact = data.contact, launch = launch }
					arrow.set(path, res.kind, false)
					arrow.setSmash(launch.how and string.find(launch.how, "smash") ~= nil or false)
					arrow.setWeak(data.quality == "weak")
				end
			end
		elseif event == "result" then
			local text, color = describe(data.result, data.reason, data.offset, data.kind, data.msg and data.msg.land)
			if not text and data.result == "rejected" and lastSwing and not lastSwing.serve and lastSwing.quality == "miss" then
				-- the server could not judge (the point had already ended when the flick arrived, typically a very late
				-- flick): show the client's own timing verdict for that flick (TOO LATE / TOO EARLY / OUT OF REACH)
				text, color = describe("miss", lastSwing.reason, nil, nil, nil)
			end
			if text then
				showVerdict(text, color)
				if data.result == "miss" or data.result == "rejected" then
					note("MISS: " .. text .. "  (" .. tostring(data.reason) .. ")")
				else
					note(text)
				end
			end
			if impactFx and (data.result == "clean" or data.result == "weak") then
				local msg = data.msg
				local at = (msg and typeof(msg.contact) == "Vector3" and msg.contact) or (BallView.getState() and BallView.getState().position)
				if at then
					impactFx.play(at, data.result)
				end
			end
			-- the real ball takes over now (its trail shows the actual flight)
			task.delay(0.15, function()
				if controller.state ~= STATE.SWUNG then
					arrow.hide()
				end
			end)
		end
	end)

	-- ---------- per-frame update ----------
	FrameDriver.bind("NotPongShotFeedback", Enum.RenderPriority.Last.Value - 10, function(dt)
		local state = controller.state
		local committed = state == STATE.COMMITTED
		local swung = state == STATE.SWUNG or state == STATE.CONTACT_RESOLVED or state == STATE.RECOVERY
		local nowClock = os.clock()
		local serverNow = workspace:GetServerTimeNow()
		local info = BallView.getInfo()
		local live = BallView.getState() ~= nil and info.mode == "free"
		local w = controller.window
		local ow = controller.outerWindow
		local emergencyNow = w == nil and ow ~= nil
		if committed and not controller.serving and live and info.incoming and not info.serve then
			committedLive = true -- (a ball came to you while you held the commitment: NO FLICK applies if it ends unflicked)
		end

		-- Aim marker: the base aim on the opponent's half while preparing / committed in a live rally (not your serve:
		-- the serve has its own aim line).
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local showAim = live and not info.serve and not controller.serving and PlatformZone.isOn() and root ~= nil and (state == STATE.IDLE or committed)
		if showAim then
			local depth = math.clamp((S.MinShotDepth + S.MaxShotDepth) / 2 + P.DriveDepthBonus + (P.ArcDepthBonus - P.DriveDepthBonus) * controller.profile, 0.2, 0.92)
			local spot = TableWorld.pointOnHalf("Bot", depth, ShotLaunch.aimLateral(controller.aim, "Player"))
			local y = Config.Layout.SurfaceY + 0.06
			local color = if committed then AIM.LockedColor else AIM.Color
			aimRing.CFrame = CFrame.new(spot.X, y, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
			aimRing.Color = color
			aimRing.Transparency = if committed then 0.2 else 0.45
			local h = AIM.PostMin + (AIM.PostMax - AIM.PostMin) * controller.profile
			aimPost.Size = Vector3.new(0.18, h, 0.18)
			aimPost.CFrame = CFrame.new(spot.X, y + h / 2, spot.Z)
			aimPost.Color = color
			aimPost.Transparency = if committed then 0.3 else 0.55
		else
			aimRing.Transparency, aimPost.Transparency = 1, 1
		end

		-- Arrow: shown from the flick until the verdict (set by the "swing" event); step its easing.
		if prediction and swung then
			arrow.step(dt)
		elseif not swung then
			if prediction then
				prediction = nil
			end
			arrow.hide()
		end

		-- Power / curve: after the flick only.
		local curve = math.sqrt(controller.topspin ^ 2 + controller.sidespin ^ 2) / math.max(S.MaxSpin, 1e-3)
		if nowClock < meterUntil and lastSwing then
			meter.set(true, controller.power, curve)
		else
			meter.set(false, 0, 0)
		end

		-- Flick dial
		local showDial = committed or nowClock < dialUntil
		dial.Visible = showDial
		if showDial then
			dial.Position = UDim2.fromOffset(dialAt.X, dialAt.Y)
			local flicked = controller.flick ~= nil
			dialText.Text = if flicked then ("%d%%"):format(math.floor(controller.power * 100 + 0.5)) else "FLICK"
			local n = if flicked then clamp01(curve) else 0
			if not flicked or n < 0.02 then
				dialArrow.Visible, dialHead.Visible = false, false
				dialDot.BackgroundColor3 = DIAL.IdleColor
				dialRingStroke.Color = if committed then DIAL.HighColor else DIAL.IdleColor
				dialRingStroke.Transparency = if committed then 0.25 else 0.6
				dialRingStroke.Thickness = 2
				dialDot.Size = UDim2.fromOffset(10, 10)
			else
				local color = DIAL.LowColor:Lerp(DIAL.HighColor, n)
				local len = R * n
				-- screen direction of the flick = the spin: x = -sidespin, y = -topspin (screen y grows downward)
				local ang = math.atan2(-controller.topspin, -controller.sidespin)
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

		if devLabel then
			local mode = if controller.rallyInput == "MouseOnly" then "MOUSE-ONLY" else "CLICK-TO-LOCK"
			local now
			if state == STATE.IDLE then
				if controller.candidate then
					now = "SWING ONSET..."
				elseif controller.armed then
					now = if controller.inZone then "PREPARING  (swing zone)" else "PREPARING  (ball coming)"
				else
					now = "PREPARING"
				end
			elseif committed then
				now = if controller.serving then "SERVE: FLICK" else "LOCKED: FLICK"
			elseif state == STATE.SWUNG then
				now = "SWING RECOGNIZED"
			else
				now = "RECOVERING"
			end
			devLabel.Text = ("[dev] rally input %s\n%s%s"):format(mode, now, if nowClock < devNoteUntil then "   |   " .. devNote else "")
		end

		if nowClock >= resultUntil and resultLabel.TextTransparency < 1 then
			resultLabel.TextTransparency = 1
			resultLabel.TextStrokeTransparency = 1
		end
	end)

	if S.ShowDiagnostics then
		-- Development-only bridge for Studio test scripts: what the arrow, the meter and the aim marker currently show.
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongArrowDebug"
		bridge.OnInvoke = function()
			local shown = arrow.getShown()
			local pts = table.clone(path)
			return {
				visible = arrow.isVisible(),
				kind = prediction and prediction.kind,
				contact = prediction and prediction.contact,
				velocity = prediction and prediction.launch and prediction.launch.velocity,
				spin = prediction and prediction.launch and prediction.launch.spin,
				solve = prediction and prediction.launch and prediction.launch.how,
				path = pts,
				shownTip = shown[#shown],
				shownCount = #shown,
				meterVisible = meter.panel.Visible,
				meterPower = meter.powerFill.Size.X.Scale,
				meterCurve = meter.curveFill.Size.X.Scale,
				aimVisible = aimRing.Transparency < 1,
				aimPosition = aimRing.Position,
				aimPostHeight = aimPost.Size.Y,
				dialVisible = dial.Visible,
				dialText = dialText.Text,
				ringVisible = ring.debug().visible,
				ring = ring.debug(),
				resultText = resultLabel.Text,
			}
		end
		bridge.Parent = player
	end
end

return ShotFeedback
