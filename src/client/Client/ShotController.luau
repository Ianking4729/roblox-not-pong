-- ShotController (client): the player's shot input, CLICK-AND-FLICK with Q stroke selection (2026-11-18). The ONE input
-- path for rally shots, emergency saves and the serve strike. (The 2026-11-17 button-free prototype was superseded and
-- removed; a copy lives in tools/legacy/ShotController_mouseonly_2026-11-17.luau.)
--
--   SELECT    (Q)            toggles the rally stroke Forehand <-> Backhand (Config.ShotControl.StrokeSelect = "Q"). The
--                            cursor never selects it. While committed / swinging, Q QUEUES the next stroke (applied when
--                            the stroke's recovery ends); the current commitment never changes. Q during your own serve
--                            (ball in hand / toss up) belongs to the serving posture (ServeInput, higher priority).
--   PREPARE   (no button)    the cursor's absolute SCREEN position sets the base aim across the opponent's half (either
--                            stroke reaches either side), the drive/arc profile (higher = arc) and the prepared paddle
--                            (StancePose arm layer). Never a target, never power; movement before the press never
--                            reaches the flick detector.
--   COMMIT    (fresh press)  snapshots stroke, aim and profile; holds the cursor in place (MouseBehavior =
--                            LockCurrentPosition: preparation cannot drift, screen edges do not matter) and starts a FRESH
--                            flick measurement (Shared/FlickGesture) from relative movement only. Holding never adds
--                            power. Movement (WASD, Shift) is never touched; the character is never moved or rotated.
--   FLICK     (while held)   ONSET (1-2 frames after the hand starts): "onset" event with the predicted contact, the arm
--                            starts the stroke so the paddle meets the ball at the contact moment (StrokeAtOnset).
--                            FINALISED after a short bounded measurement (Flick.MeasureTime): speed = power, direction =
--                            spin; the request is sent; with PredictBallResponse the ball's new flight is shown locally at
--                            the contact moment (BallView.predictHit) until the server's snapshot confirms or corrects it.
--                            Exactly one request per commitment.
--   RELEASE                  without a flick: cancelled, no hit. After a flick: nothing more happens; the next attempt
--                            needs a fresh press (a button still held after recovery never re-commits).
-- The client predicts the verdict immediately (same ShotInput window, timing and reach) for feedback, the arm and the
-- local ball response; the server judges from its own simulation and replies (SwingResult). The client sends the flick's
-- raw measurements, never a power, a velocity or a contact point.
--
-- States: IDLE (preparing) -> COMMITTED -> SWUNG (request sent) -> CONTACT_RESOLVED -> RECOVERY -> IDLE; COMMITTED ->
-- IDLE on release without a flick, focus loss, UI text focus, input cancel, point reset, respawn or leaving the rally.
-- SERVE: while your own toss is in the air (snapshot flag `sv`) a FRESH press (after the toss started) commits the serve:
-- the aim from the cursor's screen X (ServeRules.aimFromScreen), the stroke from the serving posture; a flick strikes
-- (timing against the toss's contact phase, from the Anchor rule: serves are unchanged).
-- REACH (Config.ShotControl.ContactModel): "Body" = one symmetric torso-centred zone for both strokes (Config.ContactZone,
-- ShotInput.bodyZone); "Anchor" = the previous per-stroke circle. EMERGENCY SAVE: a ball whose path never enters the
-- normal zone but crosses the emergency zone is judged against that zone's window (kind = "emergency").
-- Events (listeners): "stroke", "strokeSelect", "commit", "onset", "onsetEnd", "swing", "result", "cancel", "reset",
-- "serveAim".

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ShotInput = require(Shared:WaitForChild("ShotInput"))
local ShotLaunch = require(Shared:WaitForChild("ShotLaunch"))
local BallPhysics = require(Shared:WaitForChild("BallPhysics"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))
local ServeRules = require(Shared:WaitForChild("ServeRules"))
local FlickGesture = require(Shared:WaitForChild("FlickGesture"))

local BallView = require(script.Parent:WaitForChild("BallView"))

local ShotController = {}

local S, F, E = Config.ShotControl, Config.Flick, Config.Emergency
local STATE = table.freeze({
	IDLE = "IDLE",
	COMMITTED = "COMMITTED",
	SWUNG = "SWUNG",
	CONTACT_RESOLVED = "CONTACT_RESOLVED",
	RECOVERY = "RECOVERY",
})
ShotController.STATE = STATE

function ShotController.start(player: Player)
	if not S.Enabled then
		return
	end
	local remotes = ReplicatedStorage:WaitForChild(Config.Names.Remotes)
	local swingRemote = remotes:WaitForChild("SwingRequest") :: RemoteEvent
	local resultRemote = remotes:WaitForChild("SwingResult") :: RemoteEvent

	local self = {
		state = STATE.IDLE,
		-- stroke: `selectedStroke` is what Q chose; `stroke` is the active one (= selected while preparing, locked from
		-- the press until the stroke's recovery ends; a Q press meanwhile only changes selectedStroke = the queue)
		selectedStroke = "Forehand",
		stroke = "Forehand", -- "Forehand" | "Backhand"
		strokeLocked = false,
		aim = 0, -- -1 .. 1
		profile = 0.5, -- 0 low drive .. 1 high arc
		prepU = 0, -- paddle preparation across the screen (-1..1)
		prepV = 0.5, -- paddle preparation height (0 low .. 1 high)
		locked = false, -- aim / profile / prep locked (committed or swinging)
		commitAt = 0, -- os.clock() of the press
		commitServer = 0, -- server time of the press
		-- flick
		gesture = nil :: FlickGesture.Detector?,
		flick = nil :: FlickGesture.Flick?, -- the recognised flick (power / spin below)
		power = 0,
		topspin = 0,
		sidespin = 0,
		flickEvents = 0, -- relative movement events since the press (diagnostics)
		onsetFired = false, -- the committed flick's onset was announced (the arm's stroke start)
		trace = nil :: any, -- (diagnostics) timestamps of the last flick: first movement, onset, finalised, contact
		traceSamples = nil :: any, -- (display only) relative movement samples of the current / last commitment
		-- verdicts
		window = nil :: ShotInput.Window?, -- contact window for the current ball (SERVER time), normal reach
		outerWindow = nil :: ShotInput.Window?, -- ... the emergency zone's window (only when the normal one is nil)
		swungHits = -1, -- server hit counter of the ball we already swung at (-100 = the current toss)
		seq = 0,
		sentAt = 0,
		resolvedAt = 0,
		lastResult = "-",
		lastReason = "",
		lastOffset = nil :: number?,
		lastKind = "normal",
		predicted = nil :: any, -- the client's own prediction of the last swing (see predictSwing)
		serving = false, -- the current commitment is at your own toss
		serveAim = 0,
		serveStrokeOverride = nil :: string?, -- the serving posture's stroke while it is your serve
		buttonDown = false,
		pointerOverride = nil :: Vector2?, -- development tests only: replaces the cursor (screen fractions)
		lastArmSolve = nil :: any, -- (diagnostics) the arm layer's last contact solve: error, time, clearance
		lastGesture = nil :: any, -- (telemetry) the last commitment that ended without a recognised flick
		rallyInput = "ClickLock",
		contactModel = S.ContactModel or "Anchor",
	}

	local listeners: { (string, any) -> () } = {}
	local function fire(name: string, data: any?)
		for _, fn in listeners do
			task.spawn(fn, name, data)
		end
	end
	self.on = function(fn: (string, any) -> ())
		table.insert(listeners, fn)
	end

	-- ---------- cursor (absolute) ----------
	-- Screen fractions of the cursor: GetMouseLocation and ViewportSize both span the whole window (including the top
	-- bar's inset area), so the fraction is consistent; recomputed every frame (a resized window just works).
	local function cursorFraction(): (number, number)
		if self.pointerOverride then
			return self.pointerOverride.X, self.pointerOverride.Y
		end
		local camera = workspace.CurrentCamera
		local size = camera and camera.ViewportSize or Vector2.zero
		if size.X < 2 or size.Y < 2 then
			return 0.5, 0.5
		end
		local m = UserInputService:GetMouseLocation()
		return m.X / size.X, m.Y / size.Y
	end

	local function setStroke(stroke: string, locked: boolean)
		local changed = stroke ~= self.stroke or locked ~= self.strokeLocked
		local strokeChanged = stroke ~= self.stroke
		self.stroke, self.strokeLocked = stroke, locked
		if changed then
			if strokeChanged and self.contactModel ~= "Body" then
				self.window, self.outerWindow = nil, nil -- (Anchor model) the other stroke reaches from the other anchor
			end
			fire("stroke", { stroke = stroke, locked = locked })
		end
	end

	-- While preparing: the cursor sets aim / profile / paddle preparation; the stroke is the Q selection (or, with
	-- StrokeSelect = "Cursor", the screen side); the serving posture decides the stroke during your serve.
	local function updatePrep()
		if self.locked then
			return
		end
		local fx, fy = cursorFraction()
		local stroke, aim, profile, u, v = ShotInput.prep(fx, fy, self.selectedStroke)
		if S.StrokeSelect == "Cursor" then
			self.selectedStroke = stroke
		end
		if self.serveStrokeOverride then
			stroke = self.serveStrokeOverride
		end
		self.aim, self.profile, self.prepU, self.prepV = aim, profile, u, v
		self.serveAim = ServeRules.aimFromScreen(fx)
		setStroke(stroke, false)
	end
	function self.setServeStroke(stroke: string?)
		self.serveStrokeOverride = stroke
		if not self.locked then
			updatePrep()
		end
	end
	function self.pointerAim(): number
		local fx = cursorFraction()
		return ServeRules.aimFromScreen(fx)
	end
	-- Does the paddle arm belong to the click-and-flick arm layer right now (StancePose)? Not while the ball rests in your
	-- hand or your toss is up (the serve clips own the arm), nor for the serve strike's follow-through.
	local serveSwingAt = -math.huge
	function self.armEnabled(): boolean
		local info = BallView.getInfo()
		if info.mode == "hand" or info.serve or self.serving then
			return false
		end
		return os.clock() - serveSwingAt > Config.Serve.Posture.FollowThroughHold + 0.1
	end

	-- ---------- Q: rally stroke selection ----------
	-- Bound just BELOW ServeInput's Q (which sinks Q only when it switches the serving posture), so one press is never
	-- both. Ignored while your own serve is in progress (ball in hand / toss up: the posture owns the stroke then).
	local function toggleStroke(): boolean
		if S.StrokeSelect ~= "Q" then
			return false
		end
		local info = BallView.getInfo()
		if info.mode == "hand" or info.serve or self.serving then
			return false
		end
		self.selectedStroke = if self.selectedStroke == "Backhand" then "Forehand" else "Backhand"
		if not self.locked then
			updatePrep() -- shown at once (the arm blends to the new prepared pose)
		end
		fire("strokeSelect", { selected = self.selectedStroke, queued = self.locked })
		return true
	end
	ContextActionService:BindActionAtPriority("NotPongRallyStroke", function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Pass
		end
		return if toggleStroke() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value - 1, Enum.KeyCode.Q)

	-- ---------- mouse hold ----------
	local mouseHeld = false
	local function holdMouse(on: boolean)
		if on == mouseHeld then
			return
		end
		mouseHeld = on
		pcall(function()
			UserInputService.MouseBehavior = if on then Enum.MouseBehavior.LockCurrentPosition else Enum.MouseBehavior.Default
		end)
	end

	-- ---------- helpers ----------
	local function rootPart(): BasePart?
		local character = player.Character
		return character and character:FindFirstChild("HumanoidRootPart") :: BasePart? or nil
	end
	local function rootClaim(): Vector3?
		local r = rootPart()
		return r and r.Position or nil
	end
	-- The rally reach right now (either contact model): what ShotInput.contactWindow takes (zone or anchor, radius).
	local function reachNow(emergency: boolean?): (any, number)
		local r = rootPart()
		if not r then
			return nil, S.PaddleReach
		end
		return ShotInput.reachZone(r.CFrame, S, self.stroke, emergency)
	end
	function self.reach(emergency: boolean?): any
		return (reachNow(emergency))
	end
	function self.anchor(): Vector3?
		return ShotInput.reachPoint((reachNow()))
	end
	-- The serve's reach point (serves keep the Anchor rule: ServeRules.phase).
	local function serveAnchor(): Vector3?
		local r = rootPart()
		return r and ShotInput.anchor(r.CFrame, S, self.stroke) or nil
	end
	local function incomingNow(): boolean
		local info = BallView.getInfo()
		return BallView.getState() ~= nil and info.mode == "free" and info.incoming and info.hits ~= self.swungHits
	end
	local function serveToss(): boolean
		local info = BallView.getInfo()
		return info.serve == true and self.swungHits ~= -100
	end
	local function toServer(clockT: number): number
		return workspace:GetServerTimeNow() - (os.clock() - clockT)
	end

	local function clearFlick()
		self.gesture, self.flick = nil, nil
		self.power, self.topspin, self.sidespin = 0, 0, 0
		self.flickEvents = 0
	end

	local function reset(why: string?)
		holdMouse(false)
		local was = self.state
		if was == STATE.COMMITTED then
			-- (telemetry: what the hand did during a commitment that ended WITHOUT a recognised flick)
			local g = self.gesture
			self.lastGesture = {
				why = why,
				hold = os.clock() - self.commitAt,
				stats = g and table.clone(g.stats) or nil,
				state = g and g.state or "none",
				serving = self.serving,
			}
			if self.onsetFired then
				fire("onsetEnd", { why = why }) -- a stroke started at the onset that never became a swing: retract it
			end
		end
		self.state = STATE.IDLE
		self.locked = false
		self.serving = false
		self.onsetFired = false
		clearFlick()
		if why then
			self.lastReason = why
		end
		if was ~= STATE.IDLE then
			fire("reset", { why = why })
		end
		updatePrep() -- back to preparing (a queued Q selection applies now)
	end

	-- ---------- commit ----------
	local function commit(): boolean
		if self.state ~= STATE.IDLE then
			return false
		end
		local info = BallView.getInfo()
		if BallView.getState() == nil or info.mode ~= "free" then
			return false -- no live rally / toss (between points, ball in hand): the click is not ours
		end
		local serve = info.serve == true
		if serve and self.swungHits == -100 then
			return false -- already swung at this toss
		end
		updatePrep() -- the cursor's position at the press
		self.serving = serve
		self.locked = true
		self.commitAt = os.clock()
		self.commitServer = workspace:GetServerTimeNow()
		clearFlick()
		self.gesture = FlickGesture.new()
		self.state = STATE.COMMITTED
		self.onsetFired = false
		self.trace = { commit = self.commitAt }
		self.traceSamples = {} -- (display only) this commitment's movement samples, Client/CursorTrace
		setStroke(self.stroke, true)
		holdMouse(true)
		if serve then
			fire("serveAim", { aim = self.serveAim, locked = true })
		end
		local fx, fy = cursorFraction()
		fire("commit", {
			stroke = self.stroke,
			aim = self.aim,
			profile = self.profile,
			serve = serve,
			fx = fx,
			fy = fy,
			incoming = incomingNow(), -- (telemetry) a ball was on its way to you at the press
		})
		return true
	end

	-- ---------- prediction (the client's view of the verdict, for instant feedback, the arm and the ball) ----------
	-- The ball at server time `t` from the latest snapshot (the same simulation the server judges with).
	local function ballAt(t: number): BallPhysics.State?
		local snap = BallView.getSnapshot()
		if not snap then
			return nil
		end
		local s = BallPhysics.copyState(snap.state)
		s.resting = false
		local steps = math.clamp(math.floor((t - snap.t) / TableWorld.physics.fixedStep + 0.5), 0, 1200)
		for _ = 1, steps do
			BallPhysics.tick(s, TableWorld.physics, TableWorld.world)
		end
		return s
	end

	local function predictSwing(contactT: number)
		local p: any = { contactT = contactT, kind = "normal", quality = "miss", reason = "ball never in reach", serve = self.serving }
		if self.serving then
			local w = self.window
			if w and w.cleanStart then
				local rel = contactT - Config.Serve.HitDelay
				p.quality = if rel < w.enter or rel > w.exit then "miss" elseif rel >= w.cleanStart and rel <= w.cleanEnd then "clean" else "weak"
				p.reason = p.quality
			end
		else
			local w = self.window
			local ow = self.outerWindow
			if w then
				p.quality, p.reason, p.offset = ShotInput.classify(contactT, w)
			elseif ow then
				p.kind = "emergency"
				p.quality, p.reason, p.offset = ShotInput.classify(contactT, ow)
				p.lunge = contactT >= ow.enter and contactT <= ow.exit
			end
		end
		local s = ballAt(contactT)
		p.contact = s and s.position or nil
		return p
	end

	-- ---------- swing (a recognised flick) ----------
	local function swing(flick: FlickGesture.Flick)
		if self.state ~= STATE.COMMITTED then
			return
		end
		self.flick = flick
		self.power, self.topspin, self.sidespin = ShotInput.flickShot(flick.speed, flick.dirX, flick.dirY)
		local startServer = toServer(flick.startT)
		local contactT = startServer + (if self.serving then Config.Serve.HitDelay else F.ContactDelay)
		local tr = self.trace
		if tr then
			tr.start, tr.onset, tr.final, tr.contactServer = flick.startT, flick.detectT, os.clock(), contactT
			tr.contactClock = flick.startT + (if self.serving then Config.Serve.HitDelay else F.ContactDelay)
		end
		if not self.serving and not incomingNow() then
			-- no ball on its way to you (not yet, or already past): a miss, never queued for a later ball (nothing to send)
			local why = if BallView.getInfo().hits == self.swungHits then "already swung at this ball" else "no ball to hit"
			self.state = STATE.CONTACT_RESOLVED
			self.lastResult, self.lastReason, self.lastKind = "miss", why, "normal"
			self.resolvedAt = os.clock()
			holdMouse(false)
			fire("swing", { stroke = self.stroke, kind = "normal", quality = "miss", contactT = contactT, power = self.power, serve = false, flick = flick, hold = flick.startT - self.commitAt, noBall = true, onsetStarted = self.onsetFired })
			fire("result", { result = "miss", reason = why })
			return
		end
		self.predicted = predictSwing(contactT)
		self.clientSmash = not self.serving and self.predicted.kind == "normal" and self.predicted.quality ~= "miss" and self.predicted.contact ~= nil
			and ShotInput.smashEligible(self.predicted.contact, self.power)
		self.serverSmash = nil
		if self.serving then
			serveSwingAt = os.clock()
		end
		self.seq += 1
		self.sentAt = os.clock()
		BallView.noteSwing()
		local hitsAtSwing = BallView.getInfo().hits
		self.swingHits = hitsAtSwing -- (rally pace: this return's number)
		self.swungHits = if self.serving then -100 else hitsAtSwing
		self.state = STATE.SWUNG
		self.lastResult, self.lastReason = "...", ""
		holdMouse(false) -- the flick is over; the cursor is free again (the button may still be held)
		local pr = self.predicted
		-- the request first (latency), then the local feedback
		swingRemote:FireServer({
			seq = self.seq,
			t = startServer,
			commitT = self.commitServer,
			stroke = self.stroke,
			aim = if self.serving then self.serveAim else self.aim,
			profile = self.profile,
			flick = { d = flick.distance, u = flick.duration, x = flick.dirX, y = flick.dirY },
			root = rootClaim(),
		})
		fire("swing", {
			seq = self.seq,
			stroke = self.stroke,
			kind = pr.kind,
			quality = pr.quality,
			lunge = pr.lunge,
			contactT = contactT,
			contact = pr.contact,
			power = self.power,
			topspin = self.topspin,
			sidespin = self.sidespin,
			aim = self.aim,
			profile = self.profile,
			serve = self.serving,
			onsetStarted = self.onsetFired, -- the arm already started this stroke at the onset
			-- the SAME rule the server applies to the hit (clean / weak contact, power, height, behind the end line): a real smash
			smash = pr.kind == "normal" and pr.quality ~= "miss" and pr.contact ~= nil and ShotInput.smashEligible(pr.contact, self.power),
			-- (telemetry) the gesture and the timing it was judged on
			flick = flick,
			hold = flick.startT - self.commitAt,
			reason = pr.reason,
			offset = pr.offset,
			window = if pr.kind == "emergency" then self.outerWindow else self.window,
			recognizedT = os.clock(),
		})
		-- the ball's new flight shown at the contact moment (local prediction of the server's launch)
		if S.PredictBallResponse and not self.serving and pr.quality ~= "miss" and pr.contact then
			local ok, launch = pcall(self.predictLaunch)
			if ok and launch then
				BallView.predictHit(contactT, pr.contact, launch.velocity, launch.spin, hitsAtSwing)
			end
		end
	end

	local function resolve(result: string, reason: string, msg: any?)
		self.lastResult, self.lastReason = result, reason
		self.resolvedAt = os.clock()
		self.state = STATE.CONTACT_RESOLVED
		if result ~= "clean" and result ~= "weak" then
			BallView.cancelPrediction() -- the server did not hit it: the ball keeps its real path
		end
		fire("result", { result = result, reason = reason, offset = self.lastOffset, kind = self.lastKind, msg = msg })
	end

	resultRemote.OnClientEvent:Connect(function(msg)
		if typeof(msg) ~= "table" or msg.seq ~= self.seq or self.state ~= STATE.SWUNG then
			return
		end
		self.lastOffset = msg.offset
		self.serverSmash = msg.smash
		self.serverContact = msg.contact
		self.lastKind = if msg.kind == "emergency" then "emergency" else "normal"
		if self.trace then
			self.trace.reply = os.clock()
			self.trace.serverContact = msg.contactT
		end
		resolve(msg.result, msg.reason or "", msg)
	end)

	-- ---------- button ----------
	local function onButton(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self.buttonDown = true
			if UserInputService:GetFocusedTextBox() then
				return Enum.ContextActionResult.Pass -- typing in a UI box: never a commitment
			end
			if commit() then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			self.buttonDown = false
			if self.state == STATE.COMMITTED then
				reset(if inputState == Enum.UserInputState.Cancel then "input cancelled" else "released without a flick")
				fire("cancel", { why = self.lastReason })
				return Enum.ContextActionResult.Sink
			end
		end
		return Enum.ContextActionResult.Pass
	end
	ContextActionService:BindActionAtPriority("NotPongShot", onButton, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseButton1)

	-- ---------- relative mouse movement -> flick ----------
	-- Each movement event becomes one timestamped sample: movement in REFERENCE pixels (Delta x ReferenceHeight /
	-- viewport height), covering the time since the previous rendered frame (input arrives in frame batches). Only while
	-- COMMITTED: preparation movement before the press never reaches the detector (it starts fresh at the press).
	local lastFrameT = os.clock()
	local lastMousePos: Vector2? = nil
	local TRACE = Config.Feedback.CursorTrace
	local function onMovement(now: number, tPrev: number, dx: number, dy: number)
		-- (display only: Client/CursorTrace draws these; they never feed back into the shot) the samples of this
		-- commitment, and a short tail after the flick was finalised
		local samples = self.traceSamples
		if samples and (self.state == STATE.COMMITTED or (self.flick and now - self.flick.endT <= (TRACE.TailTime or 0))) then
			table.insert(samples, { t = now, dx = dx, dy = dy, speed = math.sqrt(dx * dx + dy * dy) / math.max(now - tPrev, F.MinElapsed) })
			if #samples > 400 then
				table.remove(samples, 1)
			end
		end
		if self.state ~= STATE.COMMITTED or not self.gesture then
			return
		end
		self.flickEvents += 1
		local tr = self.trace
		if tr and not tr.firstMove and (dx * dx + dy * dy) >= F.JitterPixels * F.JitterPixels then
			tr.firstMove = now
		end
		local g = self.gesture :: FlickGesture.Detector
		local onsetBefore = g.state == "segment"
		local flick = g:add(now, tPrev, dx, dy)
		if not self.onsetFired and not self.serving and (flick or g.state == "segment") and not onsetBefore then
			-- ONSET: start the visible stroke now, timed to meet the ball at the contact moment (flick start + ContactDelay)
			self.onsetFired = true
			local startT = if flick then flick.startT else (g:onset())
			if startT then
				local contactT = toServer(startT) + F.ContactDelay
				local pr = predictSwing(contactT)
				if tr then
					tr.onsetFired = os.clock()
				end
				-- SMASH ATTEMPT (drives the visual hop only): the predicted contact meets the smash rule's geometry (power is not
				-- known yet: the flick's onset speed stands in for it) and the ball is genuinely in play at the paddle
				local SH = Config.ArmLayer.SmashHop
				local smashTry = SH ~= nil and SH.Enabled and pr.kind == "normal" and pr.contact ~= nil
					and pr.reason ~= "ball never in reach" and ShotInput.smashEligible(pr.contact, 1)
					and (g.stats.maxSpeed or 0) >= SH.OnsetSpeed
				fire("onset", { stroke = self.stroke, contactT = contactT, contact = pr.contact, aim = self.aim, kind = pr.kind, quality = pr.quality, smash = smashTry })
			end
		end
		if flick then
			swing(flick)
		end
	end
	local function refScale(): number?
		local camera = workspace.CurrentCamera
		local h = camera and camera.ViewportSize.Y or 0
		if h < 2 then
			return nil
		end
		return F.ReferenceHeight / h
	end
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local move = ShotInput.movementOf(Vector2.new(input.Delta.X, input.Delta.Y), pos, lastMousePos)
		lastMousePos = pos
		if move == Vector2.zero then
			return
		end
		local k = refScale()
		if not k then
			return
		end
		local now = os.clock()
		onMovement(now, math.min(lastFrameT, now), move.X * k, move.Y * k)
	end)
	RunService.RenderStepped:Connect(function()
		lastFrameT = os.clock()
	end)

	-- ---------- resets ----------
	player.CharacterAdded:Connect(function()
		reset("respawned")
	end)
	local function dropFocus(why: string)
		if self.state == STATE.COMMITTED then
			reset(why)
			fire("cancel", { why = why })
		end
		lastMousePos = nil -- (the first movement after focus returns is a jump, not movement)
		holdMouse(false)
	end
	UserInputService.WindowFocusReleased:Connect(function()
		dropFocus("window lost focus")
	end)
	UserInputService.WindowFocused:Connect(function()
		lastMousePos = nil
	end)
	UserInputService.TextBoxFocused:Connect(function()
		dropFocus("UI text focus")
	end)

	-- ---------- per frame ----------
	-- Contact windows for the current ball, in SERVER time, computed EXACTLY like the server's: from the snapshot taken at
	-- the opponent's hit (`incSnap`, the same state as the server's incomingState) with the reach where the player stands
	-- NOW (the server judges with the root reported in the swing). A ball whose path misses the normal reach gets the
	-- emergency zone's window instead.
	local incSnap: any = nil
	local lastIncomingHits = -1
	local smashCheckedHits = -2 -- (the ball whose smashability was sampled)
	local function computeWindows(info: any, incoming: boolean, st: string)
		local snap = BallView.getSnapshot()
		if serveToss() and snap then
			local a = serveAnchor()
			if not a then
				return
			end
			-- your toss's contact phase (server time; RELEASE times = contact - HitDelay, as ServeRules returns them)
			local w = ServeRules.phase(snap.state, a, S.PaddleReach)
			self.window = w and {
				enter = snap.t + w.enter,
				ideal = snap.t + w.ideal,
				exit = snap.t + w.exit,
				cleanStart = snap.t + w.cleanStart,
				cleanEnd = snap.t + w.cleanEnd,
				idealPosition = w.idealPosition,
			} :: any or nil
			self.outerWindow = nil
			return
		end
		local a, reach = reachNow(false)
		if incoming and snap and a and info.mode == "free" and (st == STATE.IDLE or st == STATE.COMMITTED) then
			local src, bounced = snap, snap.b >= 1
			if incSnap and incSnap.t <= snap.t then
				src, bounced = incSnap, (incSnap.b or 0) >= 1
			end
			local w = ShotInput.contactWindow(src.state, a, reach, bounced)
			if w then
				self.window = ShotInput.shiftWindow(w, src.t) -- (absolute server times; keeps an earlier in-reach pass)
				-- (animation only) can this ball be SMASHED somewhere in its window? Sampled once per ball: drives the smash
				-- windup while committed (StancePose)
				if smashCheckedHits ~= lastIncomingHits then
					smashCheckedHits = lastIncomingHits
					self.smashable = false
					local win = self.window :: any
					for k = 0, 6 do
						local st = ballAt(win.enter + (win.exit - win.enter) * k / 6)
						if st and ShotInput.smashEligible(st.position, 1) then
							self.smashable = true
							break
						end
					end
				end
				self.outerWindow = nil
			else
				self.window = nil
				-- (the emergency zone keeps the falling-ball rule, exactly like the server's judge)
				local oa, oreach = reachNow(true)
				local ow = if E.Enabled and oa then ShotInput.contactWindow(src.state, oa, oreach, bounced, nil, true) else nil
				self.outerWindow = ShotInput.shiftWindow(ow, src.t)
			end
		end
	end

	RunService.Heartbeat:Connect(function()
		local info = BallView.getInfo()
		local incoming = incomingNow()
		local now = os.clock()

		if info.mode == "held" or info.mode == "hand" then
			-- a new point: the hit counter starts again, so the previous point's incoming snapshot must be forgotten (it
			-- would otherwise be reused for the next serve with the same counter: a stale contact window)
			lastIncomingHits, incSnap = -1, nil
			if self.state ~= STATE.IDLE then
				reset("point reset")
				fire("cancel", { why = "point reset" })
			end
		end
		if not info.serve and self.swungHits == -100 then
			self.swungHits = -1 -- the serve is over (struck or dropped)
		end

		-- a committed shot whose ball went away (point over, toss resolved) is dropped
		if self.state == STATE.COMMITTED then
			if self.serving and not serveToss() then
				reset("the toss is over")
				fire("cancel", { why = "the toss is over" })
			elseif self.gesture then
				local flick = (self.gesture :: FlickGesture.Detector):update(now)
				if flick then
					swing(flick)
				elseif (self.gesture :: FlickGesture.Detector).state == "invalid" then
					if self.onsetFired then
						self.onsetFired = false
						fire("onsetEnd", { why = "invalid flick" })
					end
					self.gesture = FlickGesture.new() -- an invalid sample: start the measurement over (still committed)
				end
			end
		end

		if incoming and info.hits ~= lastIncomingHits then
			lastIncomingHits = info.hits
			self.window, self.outerWindow = nil, nil
			incSnap = BallView.getSnapshot()
		elseif not incoming and not serveToss() then
			self.window, self.outerWindow = nil, nil -- (also the moment your toss is struck or dropped)
		end

		updatePrep() -- (no-op while locked)

		local st = self.state
		if st == STATE.SWUNG then
			if now - self.sentAt > S.ResultTimeout then
				resolve("miss", "no reply from server")
			end
		elseif st == STATE.CONTACT_RESOLVED then
			self.state = STATE.RECOVERY
		elseif st == STATE.RECOVERY then
			if now - self.resolvedAt >= S.RecoveryTime then
				reset()
			end
		end

		computeWindows(info, incoming, self.state)
	end)

	-- (prediction helper for feedback: the launch the server would compute for the last swing, from the same inputs)
	function self.predictLaunch(): any
		local pr = self.predicted
		if not pr or not pr.contact or pr.quality == "miss" or pr.serve then
			return nil
		end
		if pr.kind == "emergency" then
			local top = math.clamp(self.topspin * E.SpinFactor, -E.MaxSpin, E.MaxSpin)
			local side = math.clamp(self.sidespin * E.SpinFactor, -E.MaxSpin, E.MaxSpin)
			return ShotLaunch.emergencyLob(pr.contact, self.aim, top, side, "Player")
		end
		local r = self.reach(false)
		local top, side = self.topspin, self.sidespin
		local smash = ShotInput.smashEligible(pr.contact, self.power)
		local opts: ShotLaunch.Options = {
			stroke = self.stroke,
			timing = if pr.offset then ShotInput.timingValue(pr.offset) else nil,
			stretch = if r then ShotInput.reachStretch(r, pr.contact) else 0,
			smash = smash,
			aim = self.aim,
			profile = self.profile,
		}
		if pr.quality == "weak" and not smash then
			top, side = top * S.WeakSpinFactor, side * S.WeakSpinFactor
			opts.speedFactor = S.WeakSpeedFactor
		end
		-- RALLY PACE: the same factor as the server (this return's number = the hit count at the swing)
		if not smash and self.swingHits then
			opts.speedFactor = (opts.speedFactor or 1) * ShotLaunch.rallyPaceFactor(self.swingHits, ShotLaunch.speedFor(self.power))
		end
		return ShotLaunch.compute(pr.contact, self.power, top, side, opts)
	end

	if S.ShowDiagnostics then
		-- Development-only bridge for Studio test scripts (a separate Lua context):
		-- Invoke("get") -> snapshot; "press" / "release" / "cancel" simulate the left button; "move", Vector2 feeds one
		-- relative movement sample (ref px; optional 3rd arg = seconds since the previous frame); "drag", Vector2 moves the
		-- cursor override by that many ref px AND feeds the sample (a free cursor); "pointer", Vector2 overrides the cursor
		-- (screen fractions; nil = the real mouse); "q" = the Q key (rally stroke selection); "blur" = focus loss;
		-- "probe" = where the incoming ball passes closest to the current reach point (tests stand the character there).
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongShotDebug"
		bridge.OnInvoke = function(cmd: string, arg: any, arg2: any)
			if cmd == "press" then
				onButton(nil, Enum.UserInputState.Begin)
			elseif cmd == "release" then
				onButton(nil, Enum.UserInputState.End)
			elseif cmd == "cancel" then
				onButton(nil, Enum.UserInputState.Cancel)
			elseif cmd == "move" and typeof(arg) == "Vector2" then
				local now = os.clock()
				onMovement(now, now - (if typeof(arg2) == "number" then arg2 else 1 / 60), arg.X, arg.Y)
			elseif cmd == "drag" and typeof(arg) == "Vector2" then
				local camera = workspace.CurrentCamera
				local size = camera and camera.ViewportSize or Vector2.new(1920, 1080)
				local k = refScale() or 1
				local p = self.pointerOverride or Vector2.new(0.5, 0.5)
				if not mouseHeld then -- (a held cursor does not move; the movement is still measured)
					local nx = math.clamp(p.X + arg.X / k / size.X, 0, 1)
					local ny = math.clamp(p.Y + arg.Y / k / size.Y, 0, 1)
					self.pointerOverride = Vector2.new(nx, ny)
				end
				local now = os.clock()
				onMovement(now, now - (if typeof(arg2) == "number" then arg2 else 1 / 60), arg.X, arg.Y)
				if not self.locked then
					updatePrep()
				end
			elseif cmd == "armCfg" then
				-- DEV / REVIEW: set a Config.ArmLayer.Strokes value in the GAME's config instance (e.g. FreezeAt)
				Config.ArmLayer.Strokes[arg] = arg2
				return Config.ArmLayer.Strokes[arg]
			elseif cmd == "hopCfg" then
				-- DEV / REVIEW: set a Config.ArmLayer.SmashHop value in the GAME's config instance (e.g. TimeScale, FreezeAt)
				Config.ArmLayer.SmashHop[arg] = arg2
				return Config.ArmLayer.SmashHop[arg]
			elseif cmd == "q" then
				return toggleStroke()
			elseif cmd == "pointer" then
				self.pointerOverride = if typeof(arg) == "Vector2" then arg else nil
				updatePrep()
			elseif cmd == "blur" then
				dropFocus("window lost focus")
			elseif cmd == "probe" then
				-- TESTS ONLY: where the incoming ball's legal path passes closest to the current reach point (any distance).
				local snap = incSnap or BallView.getSnapshot()
				local r = self.reach(false)
				if not snap or not r or not incomingNow() then
					return nil
				end
				local big: any
				if typeof(r) == "table" then
					big = table.clone(r)
					big.side, big.front, big.back = 80, 80, 80
				else
					big = r
				end
				local w = ShotInput.contactWindow(snap.state, big, if typeof(arg) == "number" then arg else 80, (snap.b or 0) >= 1)
				local st = snap.state
				return w and {
					position = w.idealPosition,
					t = snap.t + w.ideal,
					anchor = ShotInput.reachPoint(r),
					stroke = self.stroke,
					state = { p = st.position, v = st.velocity, w = st.spin },
					snapT = snap.t,
					bounced = (snap.b or 0) >= 1,
				} or nil
			end
			local w = self.window
			local ow = self.outerWindow
			local now = workspace:GetServerTimeNow()
			local g = self.gesture
			return {
				state = self.state,
				stroke = self.stroke,
				selectedStroke = self.selectedStroke,
				strokeLocked = self.strokeLocked,
				aim = self.aim,
				profile = self.profile,
				prepU = self.prepU,
				prepV = self.prepV,
				locked = self.locked,
				gesture = g and g.state or nil,
				flickEvents = self.flickEvents,
				power = self.power,
				topspin = self.topspin,
				sidespin = self.sidespin,
				flickSpeed = self.flick and self.flick.speed or nil,
				flickClosedBy = self.flick and self.flick.closedBy or nil,
				result = self.lastResult,
				reason = self.lastReason,
				kind = self.lastKind,
				offset = self.lastOffset,
				predicted = self.predicted and { kind = self.predicted.kind, quality = self.predicted.quality, reason = self.predicted.reason, lunge = self.predicted.lunge } or nil,
				toIdeal = w and (w.ideal - now) or nil,
				toEnter = w and (w.enter - now) or nil,
				toExit = w and (w.exit - now) or nil,
				outerToIdeal = ow and (ow.ideal - now) or nil,
				ballMode = BallView.getInfo().mode,
				serving = self.serving,
				serveAim = self.serveAim,
				serveStroke = self.serveStrokeOverride,
				serveFlag = BallView.getInfo().serve,
				swungHits = self.swungHits,
				hits = BallView.getInfo().hits,
				mouseHeld = mouseHeld,
				buttonDown = self.buttonDown,
				armSolve = self.lastArmSolve, -- (set by the StancePose arm layer at each swing)
				armEnabled = self.armEnabled(),
				onsetFired = self.onsetFired,
				clientSmash = self.clientSmash,
				smashable = self.smashable,
				lastCockAt = self.lastCockAt,
				serverSmash = self.serverSmash,
				clientContact = self.predicted and self.predicted.contact or nil,
				serverContact = self.serverContact,
				lastHop = self.lastHop and table.clone(self.lastHop) or nil, -- (set by the stance layer) the last smash hop
				trace = self.trace and table.clone(self.trace) or nil,
				contactModel = self.contactModel,
				seq = self.seq,
				pointer = self.pointerOverride,
				ballHit = BallView.hitDebug(),
			}
		end
		bridge.Parent = player -- (not PlayerGui: a respawn clears PlayerGui)
	end
	updatePrep()
	return self
end

return ShotController
