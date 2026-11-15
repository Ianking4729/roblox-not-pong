-- ShotController (client): the player's shot input, HOLD LEFT-CLICK TO CHARGE + DRAG TO CURVE -> RELEASE TO STRIKE.
--   * Power comes ONLY from how long the button is held (ShotLaunch.powerFromHold); mouse movement never adds power.
--   * Spin comes ONLY from the mouse movement accumulated while holding (relative deltas, not the cursor position):
--     right/left = sidespin, up = topspin, down = backspin; dragging back reduces or reverses it.
--   * The cursor never selects a landing point; where the ball goes emerges from power + spin + the real physics.
-- Immediate feedback only. The server (RallyService) judges every swing from its own ball simulation and measures the
-- charge itself from the press/release times; this module sends REQUESTS ("charge started", "released: drag, time").
--
-- States:
--   IDLE              not holding (charging is possible whenever a rally is live and we have not swung at this ball)
--   CHARGING          left button held: power grows with hold time, drag shapes the spin, the arrow previews the shot
--   SWING_RELEASED    button released at an incoming ball: request sent, waiting for the server's verdict
--   CONTACT_RESOLVED  verdict known (clean / weak / miss / rejected)
--   RECOVERY          short pause; then IDLE (no second swing at the same ball)
-- Resets to IDLE (charge and spin cleared) on: point reset (ball held), character respawn, input cancelled.
--
-- CHARGE SLOW MOTION (Config.ChargeFreeze, solo only; decided by the SERVER): pressing near contact slows the rally.
-- This client predicts the configured scale on the press frame; the server snapshot confirms mode "slow" or denies it.
-- Power continues charging in real time, while release timing follows the slowed ball simulation.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ShotInput = require(Shared:WaitForChild("ShotInput"))
local ShotLaunch = require(Shared:WaitForChild("ShotLaunch"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))

local BallView = require(script.Parent:WaitForChild("BallView"))

local ShotController = {}

local S = Config.ShotControl
local STATE = table.freeze({
	IDLE = "IDLE",
	CHARGING = "CHARGING",
	SWING_RELEASED = "SWING_RELEASED",
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
	local chargeRemote = remotes:WaitForChild("ChargeStart") :: RemoteEvent

	local CF = Config.ChargeFreeze
	local arena = workspace:WaitForChild(Config.Names.Arena)
	local self = {
		freeze = nil :: any, -- the server-confirmed slow-motion state { id, ends, strikeIn, at, q }
		freezePredicted = false, -- this client predicted slow motion on press, awaiting the server's verdict
		freezePressAt = 0, -- (the press the prediction belongs to)
		freezeHits = -1, -- hit counter of the ball we froze (one freeze per incoming ball)
		state = STATE.IDLE,
		pressAt = 0, -- server time (GetServerTimeNow) the button went down
		releasedPower = 0, -- power at the last release
		dragStart = Vector2.zero, -- screen position where the button went down (the spin dial sits there)
		drag = Vector2.zero, -- accumulated relative mouse movement while holding (pixels; y down)
		topspin = 0,
		sidespin = 0,
		window = nil :: ShotInput.Window?, -- contact window for the current ball, in SERVER time (GetServerTimeNow)
		windowFrozen = false,
		swungHits = -1, -- server hit counter of the ball we already swung at
		seq = 0,
		sentAt = 0,
		resolvedAt = 0,
		lastResult = "-",
		lastReason = "",
		lastOffset = nil :: number?,
		lastLanding = nil :: Vector3?,
		releaseTiming = nil :: number?, -- server time at release - window ideal (client estimate)
		dragOverride = nil :: Vector2?, -- development tests only: replaces the accumulated mouse drag
		pendingPress = false, -- the button went down when charging was not possible yet (recovery, between points)
		-- input diagnostics (read by the on-screen input overlay, Config.ShotControl.ShowInputDebug)
		lastMove = Vector2.zero, -- last movement event while charging (pixels)
		moveSource = "-", -- where it came from: "delta" | "position" | "none" | "invalid"
		moveEvents = 0, -- MouseMovement events seen (any state)
		chargeMoveEvents = 0, -- ... while charging (reset at each press)
		buttonDown = false, -- left button currently held
	}

	-- Power right now (0..1): from hold time only.
	function self.power(): number
		if self.state == STATE.CHARGING then
			return ShotLaunch.powerFromHold(workspace:GetServerTimeNow() - self.pressAt)
		end
		return 0
	end

	-- Visual layers (ShotFeedback, ImpactFx, swing animation) listen here; this controller never draws anything.
	-- Events: "charge" (button down), "release" {seq, power, timing}, "cancel" {why}, "result" {result, reason, offset},
	-- "reset" {why}.
	local listeners: { (string, any) -> () } = {}
	local function fire(name: string, data: any?)
		for _, fn in listeners do
			task.spawn(fn, name, data)
		end
	end
	self.on = function(fn: (string, any) -> ())
		table.insert(listeners, fn)
	end

	local function clearInput()
		self.topspin, self.sidespin, self.drag = 0, 0, Vector2.zero
	end

	-- Slow our local animation tracks immediately; the server applies the authoritative movement speed.
	local localLocked = false
	local slowTracks: { [AnimationTrack]: number } = {}
	local animationPlayed: RBXScriptConnection? = nil
	local function localSlowMotionEffects(on: boolean)
		if on == localLocked then
			return
		end
		localLocked = on
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		local function slowTrack(track: AnimationTrack)
			if slowTracks[track] == nil then
				slowTracks[track] = track.Speed
				track:AdjustSpeed(track.Speed * CF.TimeScale)
			end
		end
		if on then
			table.clear(slowTracks)
			if animator then
				for _, track in animator:GetPlayingAnimationTracks() do
					slowTrack(track)
				end
				animationPlayed = animator.AnimationPlayed:Connect(slowTrack)
			end
		else
			if animationPlayed then
				animationPlayed:Disconnect()
				animationPlayed = nil
			end
			for track, speed in slowTracks do
				if track.IsPlaying then
					track:AdjustSpeed(speed)
				end
			end
			table.clear(slowTracks)
		end
	end
	local function endLocalSlowMotion()
		local was = self.freeze ~= nil or self.freezePredicted
		self.freeze, self.freezePredicted = nil, false
		BallView.setLocalTimeScale(nil)
		localSlowMotionEffects(false)
		self.window, self.windowFrozen = nil, false -- the time-scale change invalidates the old timing
		if was then
			fire("slowMotion", { active = false })
		end
	end

	local function reset(why: string?)
		if self.state == STATE.CHARGING and (self.freeze or self.freezePredicted) then
			chargeRemote:FireServer({ cancel = true }) -- restore normal speed; the server keeps our swing available
			endLocalSlowMotion()
		end
		self.window, self.windowFrozen = nil, false
		clearInput()
		local was = self.state
		self.state = STATE.IDLE
		if why then
			self.lastReason = why
		end
		if was ~= STATE.IDLE then
			fire("reset", { why = why })
		end
	end

	local function incomingNow(): boolean
		local info = BallView.getInfo()
		return BallView.getState() ~= nil and (info.mode == "free" or info.mode == "slow") and info.incoming and info.hits ~= self.swungHits
	end

	local function anchor(): Vector3?
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		return root and ShotInput.anchor(root.CFrame, S) or nil
	end

	-- The server's slow-motion rule, evaluated on our own prediction of the same window (Config.ChargeFreeze.LeadTime).
	local function freezeLikely(serverNow: number): boolean
		local info = BallView.getInfo()
		local w = self.window
		return arena:GetAttribute("ChargeFreeze") == true
			and w ~= nil
			and info.hits ~= self.freezeHits
			and serverNow >= w.ideal - CF.LeadTime
			and serverNow <= ShotInput.windowEnd(w)
	end

	local function refreshSpin()
		local d = self.dragOverride or self.drag
		self.topspin, self.sidespin = ShotInput.dragToSpin(d.X, d.Y)
	end

	local function press(): boolean
		if self.state ~= STATE.IDLE then
			return false
		end
		local info = BallView.getInfo()
		if BallView.getState() == nil or (info.mode ~= "free" and info.mode ~= "slow") then
			return false -- no live rally (between points): the click is not ours
		end
		if info.incoming and info.hits == self.swungHits then
			return false -- already swung at this ball
		end
		self.pressAt = workspace:GetServerTimeNow()
		self.dragStart = UserInputService:GetMouseLocation()
		self.chargeMoveEvents, self.lastMove, self.moveSource = 0, Vector2.zero, "-"
		clearInput()
		refreshSpin()
		self.state = STATE.CHARGING
		chargeRemote:FireServer({ t = self.pressAt })
		if freezeLikely(self.pressAt) then
			-- Predict slow motion on this frame; the server confirms or denies within one round trip.
			self.freezePredicted, self.freezePressAt, self.freezeHits = true, self.pressAt, info.hits
			BallView.setLocalTimeScale(CF.TimeScale)
			localSlowMotionEffects(true)
			fire("slowMotion", { active = true, predicted = true })
		end
		fire("charge")
		return true
	end

	local function release(auto: boolean)
		if self.state ~= STATE.CHARGING then
			return
		end
		local serverNow = workspace:GetServerTimeNow()
		refreshSpin()
		self.releasedPower = ShotLaunch.powerFromHold(serverNow - self.pressAt)
		if not incomingNow() then
			-- Released before the opponent's return is on its way: nothing to hit, nothing is sent.
			reset("released with no ball to hit")
			fire("cancel", { why = "no ball to hit" })
			return
		end
		self.seq += 1
		self.sentAt = os.clock()
		self.releaseTiming = if self.window then serverNow - self.window.ideal else nil
		self.swungHits = BallView.getInfo().hits
		self.state = STATE.SWING_RELEASED
		self.lastResult, self.lastReason = "...", if auto then "auto-release" else ""
		local f = self.freeze
		local frozen = f ~= nil or self.freezePredicted
		fire("release", {
			seq = self.seq,
			auto = auto,
			timing = if frozen then 0 else self.releaseTiming,
			power = self.releasedPower,
			frozen = frozen,
			strikeDelay = nil, -- server rewinds and judges the actual release contact
			quality = if f then f.q else nil,
		})
		local d = self.dragOverride or self.drag
		swingRemote:FireServer({
			seq = self.seq,
			dx = d.X,
			dy = d.Y,
			t = serverNow,
			pressT = self.pressAt, -- informational: the server measures the hold from its own record of the press
			freeze = if f then f.id else nil,
		})
		-- The server's normal-speed snapshot confirms the end of slow motion.
	end

	local function resolve(result: string, reason: string)
		self.lastResult, self.lastReason = result, reason
		self.resolvedAt = os.clock()
		self.state = STATE.CONTACT_RESOLVED
		fire("result", { result = result, reason = reason, offset = self.lastOffset })
	end

	resultRemote.OnClientEvent:Connect(function(msg)
		if typeof(msg) == "table" and msg.freeze and msg.seq == -1 then
			-- the server ran the slow-motion window out before our release arrived
			if self.state == STATE.CHARGING then
				self.swungHits = BallView.getInfo().hits
				self.releasedPower = self.power()
				resolve("miss", msg.reason or "held too long")
			end
			return
		end
		if typeof(msg) ~= "table" or msg.seq ~= self.seq or self.state ~= STATE.SWING_RELEASED then
			return
		end
		self.lastOffset = msg.offset
		self.lastLanding = msg.landing
		resolve(msg.result, msg.reason or "")
	end)

	local function onButton(_, inputState: Enum.UserInputState)
		self.buttonDown = inputState == Enum.UserInputState.Begin
		if inputState == Enum.UserInputState.Begin then
			if press() then
				return Enum.ContextActionResult.Sink
			end
			-- Not possible yet (recovering from the last swing, or between points): if the button is still held when it
			-- becomes possible, charging starts then (power counts from that moment, not from the early press).
			self.pendingPress = true
			return Enum.ContextActionResult.Pass
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			self.pendingPress = false
			if self.state == STATE.CHARGING then
				if inputState == Enum.UserInputState.Cancel then
					reset("input cancelled")
					fire("cancel", { why = "input cancelled" })
				else
					release(false)
				end
				return Enum.ContextActionResult.Sink
			end
		end
		return Enum.ContextActionResult.Pass
	end
	ContextActionService:BindActionAtPriority(
		"NotPongShot",
		onButton,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.UserInputType.MouseButton1
	)

	-- Spin: accumulate RELATIVE mouse movement while holding (works with a free or a locked mouse, and while moving with
	-- WASD / Shift). Clamped just past full spin, so dragging back reduces the spin straight away.
	-- Movement comes from ShotInput.movementOf: input.Delta when it is non-zero, else the cursor-position change between
	-- events (an unlocked mouse can report Delta = 0 on every event). lastMousePos is tracked on EVERY movement event, so
	-- the first event after a press already has a previous position.
	local lastMousePos: Vector2? = nil
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local move, source = ShotInput.movementOf(Vector2.new(input.Delta.X, input.Delta.Y), pos, lastMousePos)
		lastMousePos = pos
		self.moveEvents += 1
		if self.state ~= STATE.CHARGING then
			return
		end
		self.lastMove, self.moveSource = move, source
		self.chargeMoveEvents += 1
		if move.X ~= 0 or move.Y ~= 0 then
			self.drag = ShotInput.clampDrag(self.drag + move)
			refreshSpin()
		end
	end)

	player.CharacterAdded:Connect(function()
		self.pendingPress = false
		reset("respawned")
		endLocalSlowMotion()
		localLocked = false
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		if self.state == STATE.CHARGING then
			reset("window lost focus")
			fire("cancel", { why = "window lost focus" })
		end
	end)

	-- Contact window for the current ball, in SERVER time. Predicted from the latest server snapshot (exact state at a
	-- known server time), the same input the server judges with, using the paddle anchor where the player stands now.
	-- Recomputed every frame while the player moves; frozen once the ball is inside reach.
	local function updateWindow(snap, bounced: boolean, now: number)
		if self.windowFrozen then
			return
		end
		local a = anchor()
		if not a then
			return
		end
		local w = ShotInput.contactWindow(snap.state, a, S.PaddleReach, bounced)
		if not w then
			self.window = nil -- not reachable from where the player stands right now (may still be moving)
			return
		end
		if w.enter <= 2 * TableWorld.physics.fixedStep and self.window then
			-- this snapshot was taken with the ball already in reach: keep the earlier full window
			self.windowFrozen = now >= self.window.enter
			return
		end
		self.window = { enter = snap.t + w.enter, ideal = snap.t + w.ideal, exit = snap.t + w.exit, idealPosition = w.idealPosition }
		self.windowFrozen = now >= self.window.enter
	end

	local lastIncomingHits = -1
	RunService.Heartbeat:Connect(function()
		local info = BallView.getInfo()
		local incoming = incomingNow()
		local now = os.clock()
		local serverNow = workspace:GetServerTimeNow()

		if info.mode == "held" and self.state ~= STATE.IDLE then
			reset("point reset")
			fire("cancel", { why = "point reset" })
		end

		-- A new incoming ball: forget the previous ball's window.
		if incoming and info.hits ~= lastIncomingHits then
			lastIncomingHits = info.hits
			self.window, self.windowFrozen = nil, false
		elseif not incoming and (self.state == STATE.IDLE or self.state == STATE.CHARGING) then
			self.window, self.windowFrozen = nil, false
		end

		if self.pendingPress and self.state == STATE.IDLE and press() then
			self.pendingPress = false
		end

		-- Charge slow motion: confirmation / denial / end, from the server's snapshots.
		local serverFreeze = if info.mode == "slow" then info.freeze else nil
		if serverFreeze then
			if self.state == STATE.CHARGING and (self.freeze == nil or self.freeze.id ~= serverFreeze.id) then
				local first = self.freeze == nil and not self.freezePredicted
				self.freeze, self.freezePredicted = serverFreeze, false
				self.freezeHits = info.hits
				BallView.setLocalTimeScale(nil) -- use the server's authoritative scale from now on
				localSlowMotionEffects(true)
				if first then
					fire("slowMotion", { active = true })
				end
			end
		elseif self.freeze then
			endLocalSlowMotion() -- normal speed resumes
		elseif self.freezePredicted and info.pressAck >= self.freezePressAt then
			endLocalSlowMotion() -- the server denied slow motion: continue at normal speed
		end

		local st = self.state
		if st == STATE.CHARGING then
			if self.dragOverride then
				refreshSpin()
			end
			local w = self.window
			local f = self.freeze
			if f and serverNow > f.ends then
				-- slow motion ran out: the shot is lost (the server applies the same rule)
				self.swungHits = info.hits
				self.releasedPower = self.power()
				resolve("miss", "held too long (slow motion ran out)")
			elseif not f and not self.freezePredicted and incoming and w and self.windowFrozen and serverNow >= ShotInput.windowEnd(w) then
				if S.AutoReleaseAtWindowEnd then
					release(true)
				else
					self.swungHits = info.hits -- the ball is gone for us
					self.releasedPower = self.power()
					resolve("miss", "held past the contact window")
				end
			end
		elseif st == STATE.SWING_RELEASED then
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

		local snap = BallView.getSnapshot()
		if incoming and snap and info.mode == "free" and not self.freezePredicted and (self.state == STATE.IDLE or self.state == STATE.CHARGING) then
			updateWindow(snap, snap.b >= 1, serverNow)
		end
	end)

	if S.ShowDiagnostics then
		-- Development-only bridge for Studio test scripts (they run in a separate Lua context):
		-- Invoke("get") -> snapshot of the controller; "press" / "release" simulate the left button;
		-- "drag", Vector2 overrides the accumulated drag (nil clears); "move", Vector2 feeds a relative mouse delta
		-- through the same accumulation as real mouse movement.
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongShotDebug"
		bridge.OnInvoke = function(cmd: string, arg: any)
			if cmd == "press" then
				onButton(nil, Enum.UserInputState.Begin)
			elseif cmd == "release" then
				onButton(nil, Enum.UserInputState.End)
			elseif cmd == "drag" then
				self.dragOverride = arg
				refreshSpin()
			elseif cmd == "move" and self.state == STATE.CHARGING then
				self.drag = ShotInput.clampDrag(self.drag + arg)
				refreshSpin()
			end
			local w = self.window
			local now = workspace:GetServerTimeNow()
			return {
				state = self.state,
				power = self.power(),
				releasedPower = self.releasedPower,
				hold = if self.state == STATE.CHARGING then now - self.pressAt else nil,
				drag = self.dragOverride or self.drag,
				topspin = self.topspin,
				sidespin = self.sidespin,
				result = self.lastResult,
				reason = self.lastReason,
				offset = self.lastOffset,
				landing = self.lastLanding,
				frozen = self.windowFrozen,
				idealPosition = w and w.idealPosition,
				toEnter = w and (w.enter - now),
				toIdeal = w and (w.ideal - now),
				toExit = w and (w.exit - now),
				toEnd = w and (ShotInput.windowEnd(w) - now),
				freeze = self.freeze,
				freezePredicted = self.freezePredicted,
				freezeLeft = self.freeze and (self.freeze.ends - now) or nil,
				ballMode = BallView.getInfo().mode,
			}
		end
		bridge.Parent = player -- (not PlayerGui: a respawn clears PlayerGui)
	end
	return self
end

return ShotController
