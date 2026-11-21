-- ShotController (client): the player's shot input, CLICK-AND-FLICK (2026-11-17; replaces hold-to-charge, drag-to-spin
-- and release-to-strike). The ONE input path for rally shots, emergency saves and the serve strike.
--
--   PREPARE   (no button)    the cursor's absolute SCREEN position picks the stroke (left = backhand, right = forehand),
--                            the base aim across the opponent's half and the drive/arc profile (ShotInput.prep), and
--                            places the prepared paddle (StancePose arm layer). Never a target, never power.
--   COMMIT    (fresh press)  snapshots stroke, aim and profile; holds the mouse in place (MouseBehavior =
--                            LockCurrentPosition, so the cursor and the preparation cannot drift and screen edges do not
--                            matter) and starts a FRESH flick measurement (Shared/FlickGesture) from relative movement
--                            only. Holding never adds power. Movement (WASD, Shift) is never touched.
--   FLICK     (while held)   one coherent flick = the swing: its start time + Flick.ContactDelay is the contact moment,
--                            its speed the power, its direction the spin. Exactly one request per commitment.
--   RELEASE                  without a flick: cancelled, no hit. After a flick: nothing more happens; the next attempt
--                            needs a fresh press (a button still held after recovery never re-commits).
-- The client predicts the verdict immediately (same ShotInput window, timing and reach) for feedback and the arm's
-- contact; the server judges from its own simulation and replies (SwingResult). The client sends the flick's raw
-- measurements, never a power, a velocity or a contact point.
--
-- States: IDLE (preparing) -> COMMITTED -> SWUNG (request sent) -> CONTACT_RESOLVED -> RECOVERY -> IDLE; COMMITTED ->
-- IDLE on release without a flick, focus loss, input cancel, point reset, respawn or leaving the live rally.
-- SERVE: while your own toss is in the air (snapshot flag `sv`) a FRESH press (after the toss started) commits the serve:
-- the aim from the cursor's screen X (ServeRules.aimFromScreen), the stroke from the serving posture (Q); a flick
-- strikes (timing against the toss's contact phase). Rally slow motion is off (Config.ChargeFreeze).
-- EMERGENCY SAVE (Config.Emergency): a ball whose path never enters your normal reach but crosses the outer ring is
-- judged against the ring's window; the predicted attempt is reported in the "swing" event (kind = "emergency").
--
-- RALLY INPUT MODE (Config.ShotControl.RallyInput; exactly one is active):
--   "ClickLock"  everything above.
--   "MouseOnly"  (2026-11-17 prototype) rally shots need no button. While a ball is coming to you, every movement event
--                goes to Shared/MouseSwing, which separates moving the paddle (preparation, including fast stance
--                switches) from a deliberate flick. A candidate's ONSET freezes the live preparation (when its contact
--                would fall in the attempt zone, Config.MouseOnlyRally) and restores the preparation recorded just
--                BEFORE the flick's first movement (prepHistory), so the flick's own path never changes the stroke or the
--                aim. A recognised flick inside the attempt zone commits that snapshot and swings through the same
--                path as a click-and-flick (same request, same validation, same one-swing-per-ball). A sweep, a warp or
--                a flick outside the zone is ignored (preparation). Recovery returns to preparation by itself. The left
--                button is passed through during rallies; the SERVE still uses press + flick exactly as before.
-- Events (listeners): "stroke", "commit" (mouseOnly = true when made by a flick), "onset" / "onsetEnd" (a candidate's
-- reversible wind-up), "swing", "result", "cancel", "reset", "candidate" (an ignored mouse-only candidate: why).

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
local MouseSwing = require(Shared:WaitForChild("MouseSwing"))

local BallView = require(script.Parent:WaitForChild("BallView"))

local ShotController = {}

local S, F, E, MO = Config.ShotControl, Config.Flick, Config.Emergency, Config.MouseOnlyRally
local MOUSE_ONLY = S.RallyInput == "MouseOnly"
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
		-- preparation (follows the cursor while IDLE; locked from the press)
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
		-- verdicts
		window = nil :: ShotInput.Window?, -- contact window for the current ball (SERVER time), normal reach
		outerWindow = nil :: ShotInput.Window?, -- ... the emergency ring's window (only when the normal one is nil)
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
		onsetFired = false, -- the committed flick's onset was announced (the arm's wind-up)
		-- mouse-only rally (RallyInput = "MouseOnly")
		rallyInput = if MOUSE_ONLY then "MouseOnly" else "ClickLock",
		armed = false, -- a ball is coming to you and the classifier is listening
		inZone = false, -- (diagnostics) a flick right now would have its contact inside the attempt zone
		candidate = nil :: any, -- the frozen preparation snapshot while a candidate flick is measured
		nearWindow = nil :: ShotInput.Window?, -- the ball's closest approach (NearReach) when no reach window exists
		lastIgnored = nil :: any, -- { why, at } the last ignored candidate (dev indicator / telemetry)
		mouse = nil :: any, -- the MouseSwing classifier (mouse-only)
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
		self.stroke, self.strokeLocked = stroke, locked
		if changed then
			self.window, self.outerWindow = nil, nil -- the other stroke reaches from the other anchor
			fire("stroke", { stroke = stroke, locked = locked })
		end
	end

	-- While preparing: follow the cursor (the serving posture decides the stroke during your serve).
	-- (mouse-only) every live preparation is also kept for PrepHistory seconds, so a flick can use the one from just
	-- before its first movement (prepAt), never the cursor's position after the flick moved it.
	local prepHistory: { any } = {}
	local function updatePrep()
		if self.locked then
			return
		end
		local fx, fy = cursorFraction()
		local stroke, aim, profile, u, v = ShotInput.prep(fx, fy, self.stroke)
		if self.serveStrokeOverride then
			stroke = self.serveStrokeOverride
		end
		self.aim, self.profile, self.prepU, self.prepV = aim, profile, u, v
		self.serveAim = ServeRules.aimFromScreen(fx)
		setStroke(stroke, false)
		if MOUSE_ONLY then
			local now = os.clock()
			table.insert(prepHistory, { t = now, stroke = stroke, aim = aim, profile = profile, u = u, v = v, fx = fx, fy = fy })
			while #prepHistory > 2 and prepHistory[1].t < now - MO.PrepHistory do
				table.remove(prepHistory, 1)
			end
		end
	end
	-- The preparation recorded before os.clock() time `t` (the flick's first movement event was handled at t).
	local function prepAt(t: number): any
		for i = #prepHistory, 1, -1 do
			if prepHistory[i].t < t then
				return prepHistory[i]
			end
		end
		return prepHistory[1] or { stroke = self.stroke, aim = self.aim, profile = self.profile, u = self.prepU, v = self.prepV }
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
	local function reachNow(): (Vector3?, number)
		local r = rootPart()
		if not r then
			return nil, S.PaddleReach
		end
		return ShotInput.reachFor(r.CFrame, S, self.stroke)
	end
	function self.anchor(): Vector3?
		return (reachNow())
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

	-- (mouse-only; defined with the classifier below) drop a candidate in progress: unfreeze the preparation, end the wind-up
	local dropCandidate: (why: string) -> () = function(_why: string) end

	local function reset(why: string?)
		holdMouse(false)
		dropCandidate(why or "reset")
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
		end
		self.state = STATE.IDLE
		self.locked = false
		self.serving = false
		clearFlick()
		if why then
			self.lastReason = why
		end
		if was ~= STATE.IDLE then
			fire("reset", { why = why })
		end
		updatePrep() -- back to preparing: the cursor picks the next stroke
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
		if MOUSE_ONLY and not serve then
			return false -- mouse-only rallies: no button commitment (the click passes through); serves are unchanged
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

	-- ---------- prediction (the client's view of the verdict, for instant feedback and the arm) ----------
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
		if not self.serving and not incomingNow() then
			-- no ball on its way to you (not yet, or already past): a miss, never queued for a later ball (nothing to send)
			local why = if BallView.getInfo().hits == self.swungHits then "already swung at this ball" else "no ball to hit"
			self.state = STATE.CONTACT_RESOLVED
			self.lastResult, self.lastReason, self.lastKind = "miss", why, "normal"
			self.resolvedAt = os.clock()
			holdMouse(false)
			fire("swing", { stroke = self.stroke, kind = "normal", quality = "miss", contactT = contactT, power = self.power, serve = false, flick = flick, hold = flick.startT - self.commitAt, noBall = true })
			fire("result", { result = "miss", reason = why })
			return
		end
		self.predicted = predictSwing(contactT)
		if self.serving then
			serveSwingAt = os.clock()
		end
		self.seq += 1
		self.sentAt = os.clock()
		self.swungHits = if self.serving then -100 else BallView.getInfo().hits
		self.state = STATE.SWUNG
		self.lastResult, self.lastReason = "...", ""
		holdMouse(false) -- the flick is over; the cursor is free again (the button may still be held)
		local pr = self.predicted
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
			-- (telemetry) the gesture and the timing it was judged on
			flick = flick,
			hold = flick.startT - self.commitAt,
			reason = pr.reason,
			offset = pr.offset,
			window = if pr.kind == "emergency" then self.outerWindow else self.window,
			recognizedT = os.clock(),
		})
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
	end

	local function resolve(result: string, reason: string, msg: any?)
		self.lastResult, self.lastReason = result, reason
		self.resolvedAt = os.clock()
		self.state = STATE.CONTACT_RESOLVED
		fire("result", { result = result, reason = reason, offset = self.lastOffset, kind = self.lastKind, msg = msg })
	end

	resultRemote.OnClientEvent:Connect(function(msg)
		if typeof(msg) ~= "table" or msg.seq ~= self.seq or self.state ~= STATE.SWUNG then
			return
		end
		self.lastOffset = msg.offset
		self.lastKind = if msg.kind == "emergency" then "emergency" else "normal"
		resolve(msg.result, msg.reason or "", msg)
	end)

	-- ---------- button ----------
	local function onButton(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self.buttonDown = true
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
	-- COMMITTED; preparation movement before the press never reaches the detector (it starts fresh at the press).
	-- MOUSE-ONLY: the same samples go to the MouseSwing classifier while armed (defined below, with the zone logic).
	local lastFrameT = os.clock()
	local lastMousePos: Vector2? = nil
	local onMouseOnlyMove: (now: number, tPrev: number, dx: number, dy: number) -> () = function() end
	local function onMovement(now: number, tPrev: number, dx: number, dy: number)
		if self.state == STATE.COMMITTED and self.gesture then
			-- click-to-lock rally, or the serve (both modes)
			self.flickEvents += 1
			local g = self.gesture :: FlickGesture.Detector
			local flick = g:add(now, tPrev, dx, dy)
			if flick then
				swing(flick)
			elseif g.state == "segment" and not self.onsetFired and not self.serving then
				self.onsetFired = true
				fire("onset", { stroke = self.stroke }) -- (the arm's reversible wind-up)
			end
		elseif MOUSE_ONLY then
			onMouseOnlyMove(now, tPrev, dx, dy)
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
		if self.mouse then
			self.mouse:reset()
		end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		if self.state == STATE.COMMITTED then
			reset("window lost focus")
			fire("cancel", { why = "window lost focus" })
		end
		dropCandidate("window lost focus")
		if self.mouse then
			self.mouse:reset()
		end
		lastMousePos = nil -- (the first movement after focus returns is a jump, not movement)
		holdMouse(false)
	end)
	UserInputService.WindowFocused:Connect(function()
		lastMousePos = nil
	end)

	-- ---------- per frame ----------
	-- Contact windows for the current ball, in SERVER time, computed EXACTLY like the server's: from the snapshot taken at
	-- the opponent's hit (`incSnap`, the same state as the server's incomingState) with the anchor where the player stands
	-- NOW (the server judges with the root reported in the swing). A ball whose path misses the normal reach gets the
	-- emergency ring's window instead.
	local incSnap: any = nil
	local lastIncomingHits = -1
	local function computeWindows(info: any, incoming: boolean, st: string)
		local snap = BallView.getSnapshot()
		local a, reach = reachNow()
		self.nearWindow = nil
		if serveToss() and snap and a then
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
		elseif incoming and snap and a and info.mode == "free" and (st == STATE.IDLE or st == STATE.COMMITTED) then
			local src, bounced = snap, snap.b >= 1
			if incSnap and incSnap.t <= snap.t then
				src, bounced = incSnap, (incSnap.b or 0) >= 1
			end
			local w = ShotInput.contactWindow(src.state, a, reach, bounced)
			if w then
				self.window = ShotInput.shiftWindow(w, src.t) -- (absolute server times; keeps an earlier in-reach pass)
				self.outerWindow = nil
			else
				self.window = nil
				-- (the save ring keeps the falling-ball rule, exactly like the server's judge)
				local ow = if E.Enabled then ShotInput.contactWindow(src.state, a, ShotInput.emergencyReach(S), bounced, nil, true) else nil
				self.outerWindow = ShotInput.shiftWindow(ow, src.t)
				if MOUSE_ONLY and not ow then
					-- (mouse-only attempt zone only: when the ball passes near enough for an out-of-reach attempt to count)
					self.nearWindow = ShotInput.shiftWindow(ShotInput.contactWindow(src.state, a, MO.NearReach, bounced), src.t)
				end
			end
		end
	end

	-- ---------- MOUSE-ONLY rally (RallyInput = "MouseOnly") ----------
	-- The attempt zone: a flick whose contact moment (server time) falls in it can be a swing; outside, it is preparation.
	local function zoneContains(contactT: number): boolean
		local w = self.window or self.outerWindow or self.nearWindow
		if not w then
			return false
		end
		local first = (w.earlier or w).ideal
		return contactT >= first - MO.AttemptLead and contactT <= w.ideal + MO.AttemptTrail
	end
	local function applySnapshot(snap: any)
		self.locked = true
		self.aim, self.profile, self.prepU, self.prepV = snap.aim, snap.profile, snap.u, snap.v
		setStroke(snap.stroke, true)
		computeWindows(BallView.getInfo(), incomingNow(), self.state) -- (the snapshot's stroke reaches from its own anchor)
	end
	dropCandidate = function(why: string)
		if not self.candidate then
			return
		end
		self.candidate = nil
		if self.state == STATE.IDLE then
			self.locked = false
			updatePrep() -- back to the live cursor (e.g. the end of a fast stance switch)
		end
		fire("onsetEnd", { why = why })
	end
	local function ignore(why: string, flick: any?)
		self.lastIgnored = { why = why, at = os.clock(), flick = flick }
		fire("candidate", { outcome = why, flick = flick })
	end
	-- A recognised flick inside the zone: commit the preparation from just before it and swing (the click-and-flick path).
	local function mouseSwing(flick: FlickGesture.Flick)
		local snap = if self.candidate then self.candidate.snap else prepAt(flick.onsetEventT)
		self.candidate = nil -- (the wind-up turns into the swing: no onsetEnd)
		self.serving = false
		self.commitAt = flick.startT
		self.commitServer = toServer(flick.startT)
		clearFlick()
		self.state = STATE.COMMITTED
		applySnapshot(snap)
		fire("commit", {
			stroke = self.stroke,
			aim = self.aim,
			profile = self.profile,
			serve = false,
			fx = snap.fx,
			fy = snap.fy,
			incoming = true,
			mouseOnly = true,
		})
		swing(flick)
	end
	local function handleMouse(ev: any)
		if not ev then
			return
		end
		if ev.kind == "onset" then
			if zoneContains(toServer(ev.startT) + F.ContactDelay) then
				local snap = prepAt(ev.onsetEventT)
				self.candidate = { snap = snap, startT = ev.startT }
				applySnapshot(snap)
				fire("onset", { stroke = snap.stroke })
			else
				self.mouse:reject()
				ignore("outside the swing zone")
			end
		elseif ev.kind == "flick" then
			local fl = ev.flick :: FlickGesture.Flick
			if zoneContains(toServer(fl.startT) + F.ContactDelay) then
				mouseSwing(fl)
			else
				dropCandidate("outside the swing zone")
				ignore("outside the swing zone", fl)
			end
		elseif ev.kind == "discard" then
			dropCandidate(ev.reason)
			ignore(if ev.reason == "sweep" then "reposition (sweep)" else ev.reason, ev.flick)
		end
	end
	onMouseOnlyMove = function(now: number, tPrev: number, dx: number, dy: number)
		if self.armed and self.mouse and self.state == STATE.IDLE then
			handleMouse(self.mouse:add(now, tPrev, dx, dy))
		end
	end
	if MOUSE_ONLY then
		self.mouse = MouseSwing.new()
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

		-- MOUSE-ONLY: listen while a ball is coming to you and you are preparing (never during your serve, a swing or
		-- recovery); a fresh classifier for every ball, so nothing held carries into the next one
		if MOUSE_ONLY then
			local armedNow = self.state == STATE.IDLE and incoming and info.mode == "free" and not info.serve and not self.serving
			if armedNow ~= self.armed then
				if not armedNow then
					dropCandidate("not armed")
				end
				self.mouse:reset()
				self.armed = armedNow
			end
			if armedNow then
				handleMouse(self.mouse:update(now))
				self.inZone = zoneContains(workspace:GetServerTimeNow() + F.ContactDelay)
			else
				self.inZone = false
			end
		end
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
		local a = self.anchor()
		local top, side = self.topspin, self.sidespin
		local smash = ShotInput.smashEligible(pr.contact, self.power)
		local opts: ShotLaunch.Options = {
			stroke = self.stroke,
			timing = if pr.offset then ShotInput.timingValue(pr.offset) else nil,
			stretch = if a then Vector2.new(pr.contact.X - a.X, pr.contact.Z - a.Z).Magnitude / S.PaddleReach else 0,
			smash = smash,
			aim = self.aim,
			profile = self.profile,
		}
		if pr.quality == "weak" and not smash then
			top, side = top * S.WeakSpinFactor, side * S.WeakSpinFactor
			opts.speedFactor = S.WeakSpeedFactor
		end
		return ShotLaunch.compute(pr.contact, self.power, top, side, opts)
	end

	if S.ShowDiagnostics then
		-- Development-only bridge for Studio test scripts (a separate Lua context):
		-- Invoke("get") -> snapshot; "press" / "release" / "cancel" simulate the left button; "move", Vector2 feeds one
		-- relative movement sample (ref px; optional 3rd arg = seconds since the previous frame); "pointer", Vector2
		-- overrides the cursor (screen fractions; nil = the real mouse); "blur" = focus loss.
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
				-- one relative movement sample (ref px) through the same path as a real mouse event (both modes)
				local now = os.clock()
				onMovement(now, now - (if typeof(arg2) == "number" then arg2 else 1 / 60), arg.X, arg.Y)
			elseif cmd == "drag" and typeof(arg) == "Vector2" then
				-- TESTS: a FREE cursor movement: moves the cursor override by `arg` ref px (so the preparation follows it, as
				-- with a real mouse) and feeds the same movement sample. Starts from the current override (or the centre).
				local camera = workspace.CurrentCamera
				local size = camera and camera.ViewportSize or Vector2.new(1920, 1080)
				local k = refScale() or 1
				local p = self.pointerOverride or Vector2.new(0.5, 0.5)
				local nx = math.clamp(p.X + arg.X / k / size.X, 0, 1)
				local ny = math.clamp(p.Y + arg.Y / k / size.Y, 0, 1)
				local real = Vector2.new((nx - p.X) * size.X * k, (ny - p.Y) * size.Y * k) -- (clamped at the screen edge)
				self.pointerOverride = Vector2.new(nx, ny)
				local now = os.clock()
				if real.Magnitude > 0 then
					onMovement(now, now - (if typeof(arg2) == "number" then arg2 else 1 / 60), real.X, real.Y)
				end
				if not self.locked then
					updatePrep()
				end
			elseif cmd == "pointer" then
				self.pointerOverride = if typeof(arg) == "Vector2" then arg else nil
				updatePrep()
			elseif cmd == "blur" then
				if self.state == STATE.COMMITTED then
					reset("window lost focus")
					fire("cancel", { why = "window lost focus" })
				end
				dropCandidate("window lost focus")
				if self.mouse then
					self.mouse:reset()
				end
				lastMousePos = nil
				holdMouse(false)
			elseif cmd == "probe" then
				-- TESTS ONLY: where the incoming ball's legal path passes closest to the current anchor (any distance), so a
				-- test script can stand the character there. Returns { position, t (server time), anchor } or nil.
				local snap = incSnap or BallView.getSnapshot()
				local a = self.anchor()
				if not snap or not a or not incomingNow() then
					return nil
				end
				local w = ShotInput.contactWindow(snap.state, a, if typeof(arg) == "number" then arg else 80, (snap.b or 0) >= 1)
				local st = snap.state
				return w and {
					position = w.idealPosition,
					t = snap.t + w.ideal,
					anchor = a,
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
				-- mouse-only
				rallyInput = self.rallyInput,
				armed = self.armed,
				inZone = self.inZone,
				zoneWindow = if self.window then "normal" elseif self.outerWindow then "emergency" elseif self.nearWindow then "near" else "none",
				zoneFrom = (function()
					local zw = self.window or self.outerWindow or self.nearWindow
					return zw and ((zw.earlier or zw).ideal - MO.AttemptLead - now) or nil
				end)(),
				zoneTo = (function()
					local zw = self.window or self.outerWindow or self.nearWindow
					return zw and (zw.ideal + MO.AttemptTrail - now) or nil
				end)(),
				candidate = self.candidate ~= nil,
				classifier = self.mouse and self.mouse.state or nil,
				classifierStats = self.mouse and table.clone(self.mouse.stats) or nil,
				lastIgnored = self.lastIgnored and self.lastIgnored.why or nil,
				lastIgnoredAt = self.lastIgnored and self.lastIgnored.at or nil,
				pointer = self.pointerOverride,
				seq = self.seq,
				commitAim = self.aim,
			}
		end
		bridge.Parent = player -- (not PlayerGui: a respawn clears PlayerGui)
	end
	updatePrep()
	return self
end

return ShotController
