-- RallyService (server): owns the ONE authoritative ball and runs points end to end.
--   * simulates the ball with BallPhysics at a fixed 240 Hz inside Heartbeat (frame-rate independent),
--   * moves only the invisible gameplay part (BallTemplate.Ball); clients render the cosmetic BallVisual themselves
--     from snapshots (Client/BallView) using the same deterministic simulation,
--   * serving: player via the ServeRequest remote (validated here), bot automatically,
--   * per physics tick asks each Striker (bot, temporary player auto-return) whether it can legally hit,
--   * feeds contacts to RallyReferee and applies outcomes to the existing MatchState (score, serve rotation).
-- Clients only send requests: "serve now" (checked: seat, state, turn, distance, delay, rate limit), "I started
-- charging" (press time) and "I released a swing" (drag, release time). A swing is judged HERE from the ball's own
-- simulated history: press and release times are each clamped to MaxLatencyCompensation of when they arrived, so the
-- CHARGE (power) is measured by the server; the contact window comes from the ball's distance to the paddle anchor
-- (ShotInput); spin is clamped; one swing per incoming ball; and the launch is computed with the shared ShotLaunch
-- model and real physics. The client never claims a hit and never sends a power value or a target.
--
-- CHARGE SLOW MOTION (Config.ChargeFreeze; solo matches only): a press near contact slows the ball simulation,
-- player movement and bot movement/animations. Charge power remains measured in real time. Release is judged against
-- the slowed simulation timeline; no release within MaxDuration -> normal speed resumes and the swing is lost.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GameStates = require(Shared:WaitForChild("GameStates"))
local BallPhysics = require(Shared:WaitForChild("BallPhysics"))
local ShotSolver = require(Shared:WaitForChild("ShotSolver"))
local ShotInput = require(Shared:WaitForChild("ShotInput"))
local ShotLaunch = require(Shared:WaitForChild("ShotLaunch"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))

local Server = script.Parent
local ArenaBuilder = require(Server:WaitForChild("ArenaBuilder"))
local RallyReferee = require(Server:WaitForChild("RallyReferee"))
local Striker = require(Server:WaitForChild("Striker"))
local BotController = require(Server:WaitForChild("BotController"))
local MovementService = require(Server:WaitForChild("MovementService"))

local State, Attr = GameStates.State, GameStates.Attributes

local RallyService = {}

local function log(...)
	if Config.Debug.Verbose then
		print("[Rally]", ...)
	end
end

local function remotes()
	local folder = ReplicatedStorage:FindFirstChild(Config.Names.Remotes)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.Names.Remotes
		folder.Parent = ReplicatedStorage
	end
	local function remote(name: string): RemoteEvent
		local r = folder:FindFirstChild(name)
		if not r then
			r = Instance.new("RemoteEvent")
			r.Name = name
			r.Parent = folder
		end
		return r :: RemoteEvent
	end
	return remote("BallSnapshot"), remote("ServeRequest"), remote("SwingRequest"), remote("SwingResult"), remote("ChargeStart")
end

local function finite(n: any): boolean
	return typeof(n) == "number" and n == n and math.abs(n) < 1e10 -- (server time is ~1.8e9)
end

-- arena: ArenaBuilder.load() result. match: MatchState. avatars: AvatarService. bot: the bot Model (or nil).
function RallyService.start(arena, match, avatars, bot: Model?)
	local cfg, world = TableWorld.physics, TableWorld.world
	local snapshotRemote, serveRemote, swingRemote, swingResultRemote, chargeRemote = remotes()
	local SC = Config.ShotControl
	local rng = Random.new()
	local referee = RallyReferee.new()

	local ball = BallPhysics.newState(Config.Layout.ServeBall[match.server])
	ball.resting = true
	local phase = "held" -- held | toss | live | dead
	local serveSide = match.server
	local readyAt = os.clock()
	local lastHit = { Player = -math.huge, Bot = -math.huge }
	local lastActivity = os.clock()
	local lastSnapshot = 0
	local serial = 0 -- bumps whenever a point is reset; stale delayed callbacks check it
	local lastRequest: { [Player]: number } = {}
	-- Phase 3 swing judging
	local timeOffset = workspace:GetServerTimeNow() -- server time = ball.time + timeOffset
	local history: { BallPhysics.State } = {} -- recent per-tick ball states (for latency rewind)
	local incomingState: BallPhysics.State? = nil -- the ball right after the Bot's last hit / serve
	local swingUsed = false -- one swing per incoming ball
	local lastSwing: { [Player]: number } = {}
	local pressAt: { [Player]: number } = {} -- server time the player's current charge began (validated)
	local lastPressMsg: { [Player]: number } = {}
	local pressAck = 0 -- the client time of the last press this service processed (echoed in snapshots)
	-- Charge slow motion
	local CF = Config.ChargeFreeze
	local matchMode = if bot then "Solo" else "PvP"
	local slowMotionAllowed = CF.Enabled and CF.Modes[matchMode] == true
	arena.Folder:SetAttribute("ChargeFreeze", slowMotionAllowed) -- client predicts the slow-motion transition
	arena.Folder:SetAttribute("MatchMode", matchMode)
	local slowMotion: any = nil -- the active charge slow motion (see trySlowMotion)
	local slowMotionSerial = 0
	local slowMotionUsedHits = -1 -- referee.hits of the ball last slowed (one per incoming ball)
	local botTracks: { [AnimationTrack]: number } = {}
	local botAnimationPlayed: RBXScriptConnection? = nil

	local strikers = {
		Player = Striker.new("Player", Config.AutoReturn, function()
			local p = avatars.getSeatedPlayer()
			return p and p.Character or nil
		end),
		Bot = Striker.new("Bot", Config.BotPlay, function()
			return bot
		end),
	}
	local botBrain = if bot then BotController.new(bot, strikers.Bot) else nil

	-- Is the player the next to play the ball (Bot's return, or the Bot's serve)?
	local function incomingForPlayer(): boolean
		return (referee.phase == "rally" and referee.lastHitter == "Bot")
			or (referee.phase == "serveFlight" and referee.server == "Bot")
	end

	local function packet()
		local f = slowMotion
		return {
			p = ball.position,
			v = ball.velocity,
			w = ball.spin,
			t = workspace:GetServerTimeNow(),
			mode = if f then "slow" elseif ball.resting then "held" else "free",
			ts = if f then CF.TimeScale else 1,
			i = incomingForPlayer(), -- the ball is on its way to the player (aim now)
			b = referee.bounces.Player, -- bounces on the player's half since the last hit
			h = referee.hits, -- hit counter: identifies each incoming ball
			pa = pressAck, -- last press processed (a client that predicted slow motion learns the verdict from this)
			f = f and { -- the active charge slow motion
				id = f.id,
				ends = f.startServer + CF.MaxDuration, -- server time slow motion runs out
				strikeIn = f.strikeRel - (ball.time - f.incTime),
				at = f.contactPosition, -- where the paddle will meet the ball (the arrow starts here)
				q = f.quality,
			} or nil,
		}
	end
	local function snapshot()
		lastSnapshot = os.clock()
		snapshotRemote:FireAllClients(packet())
	end
	snapshotRemote.OnServerEvent:Connect(function(player) -- a client asks for the current state (join / reload)
		snapshotRemote:FireClient(player, packet())
	end)

	local function setEvent(text: string)
		arena.Folder:SetAttribute(Attr.LastEvent, text)
		log(text)
	end

	-- ===== charge slow-motion helpers =====
	local function rootOf(model: Model?): BasePart?
		return model and model:FindFirstChild("HumanoidRootPart") :: BasePart? or nil
	end
	local function slowBot(on: boolean)
		local root = rootOf(bot)
		local hum = bot and bot:FindFirstChildOfClass("Humanoid")
		if not bot or not root or not hum then
			return
		end
		hum.WalkSpeed = Config.Bot.WalkSpeed * (if on then CF.TimeScale else 1)
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if animator and CF.SlowBotAnimations then
			if on then
				table.clear(botTracks)
				local function slowTrack(track: AnimationTrack)
					if botTracks[track] == nil then
						botTracks[track] = track.Speed
						track:AdjustSpeed(track.Speed * CF.TimeScale)
					end
				end
				for _, track in animator:GetPlayingAnimationTracks() do
					slowTrack(track)
				end
				botAnimationPlayed = animator.AnimationPlayed:Connect(slowTrack)
			else
				if botAnimationPlayed then
					botAnimationPlayed:Disconnect()
					botAnimationPlayed = nil
				end
				for track, speed in botTracks do
					if track.IsPlaying then
						track:AdjustSpeed(speed)
					end
				end
				table.clear(botTracks)
			end
		end
	end
	-- Restore normal speed and compensate wall-clock timers for the time dilation.
	local function endSlowMotion(why: string)
		local f = slowMotion
		if not f then
			return
		end
		slowMotion = nil
		local elapsed = os.clock() - f.startedAt
		local gameTimeLost = elapsed * (1 - CF.TimeScale)
		lastActivity += gameTimeLost
		lastHit.Player += gameTimeLost
		lastHit.Bot += gameTimeLost
		slowBot(false)
		if f.player.Parent ~= nil then
			MovementService.setSlowMotion(f.player, 1)
		end
		timeOffset = workspace:GetServerTimeNow() - ball.time
		log(("charge slow motion ended (%s) after %.2fs"):format(why, elapsed))
	end
	-- Point reset / player gone: drop any active slow motion.
	local function clearSlowMotion()
		if slowMotion then
			endSlowMotion("reset")
		end
		slowMotionUsedHits = -1
	end

	-- Ball held at `side`'s serve point (a reset: the only time the ball is placed rather than simulated).
	local function hold(side: string)
		serial += 1
		phase = "held"
		serveSide = side
		ball = BallPhysics.newState(Config.Layout.ServeBall[side])
		ball.resting = true
		timeOffset = workspace:GetServerTimeNow() - ball.time
		table.clear(history)
		incomingState, swingUsed = nil, false
		table.clear(pressAt) -- a charge never carries over into the next point
		clearSlowMotion()
		ArenaBuilder.moveBall(arena, ball.position)
		readyAt = os.clock() + Config.Timing.ServeReadyDelay
		snapshot()
	end

	local function endPoint(outcome)
		phase = "dead"
		local mySerial = serial
		if botBrain then
			botBrain:goHome()
		end
		if outcome.let then
			setEvent("Let: serve touched the net. Replay the serve.")
			task.delay(Config.Timing.PointResetDelay, function()
				if serial == mySerial then
					match:replayServe()
				end
			end)
			return
		end
		match:awardPoint(outcome.winner, outcome.reason)
		setEvent(("%s wins the point: %s"):format(outcome.winner, outcome.reason))
		task.delay(Config.Timing.PointResetDelay, function()
			if serial == mySerial and match:getState() == State.PointScored then
				match:nextPoint()
			end
		end)
	end

	local function handle(outcome)
		if not outcome or phase == "dead" then
			return
		end
		if outcome.serveGood then
			match:enterRally()
		elseif outcome.winner or outcome.let then
			endPoint(outcome)
		end
	end

	local function strike(side: string, velocity: Vector3, spin: Vector3)
		local outcome = referee:onHit(side)
		ball.velocity, ball.spin, ball.resting = velocity, spin, false
		lastHit[side] = os.clock()
		lastActivity = os.clock()
		if side == "Bot" then
			incomingState, swingUsed = BallPhysics.copyState(ball), false
		end
		if outcome and outcome.hit then
			match:registerHit(side)
			phase = "live"
		end
		snapshot()
		handle(outcome)
		if botBrain and phase == "live" then
			if side == "Player" then
				botBrain:onOpponentHit(ball)
			else
				task.delay(0.4, function()
					if phase == "live" and referee:expecting() == "Player" then
						botBrain:goHome() -- recover toward the centre while the ball is away
					end
				end)
			end
		end
	end

	local function serveShot(side: string)
		local S = Config.Serve
		local receiver = RallyReferee.opponentOf(side)
		local start = ball.position
		local towardServerRight = if side == "Player" then 1 else -1
		local first, shot
		for attempt = 1, 4 do -- a random target occasionally has no legal trajectory: pick another
			local spread = if attempt == 4 then 0 else S.TargetSpreadX
			first = TableWorld.pointOnHalf(
				side,
				S.FirstBounceDepth,
				towardServerRight * S.RestSideOffset * 0.5 + rng:NextNumber(-spread, spread)
			)
			shot = ShotSolver.solveServe(cfg, world, start, first, {
				speed = S.Speed,
				minSpeed = S.MinSpeed,
				maxSpeed = S.MaxSpeed,
				topspin = S.Topspin,
				sidespin = S.Sidespin,
				server = side,
				receiver = receiver,
				secondDepth = S.SecondBounceDepth + (if attempt == 4 then 0 else rng:NextNumber(-2, 2)),
				netZ = TableWorld.netZ,
			})
			if shot.ok then
				break
			end
		end
		if not shot.ok then
			-- No valid serve found (should not happen with sane Config): play a simple drag-free guess so the ball still
			-- flies physically; the referee will judge it.
			warn("[Rally] serve solver found no valid serve; using a fallback")
			local d = first - start
			local t = Vector3.new(d.X, 0, d.Z).Magnitude / S.Speed
			return Vector3.new(d.X / t, (d.Y + 0.5 * cfg.gravity * t * t) / t, d.Z / t), Vector3.zero
		end
		return shot.velocity, shot.spin
	end

	-- ReadyToServe -> Serving: toss the ball straight up. Returns ok, reason.
	local function beginServe(side: string): (boolean, string?)
		if match:getState() ~= State.ReadyToServe then
			return false, "not ready to serve"
		end
		if match.server ~= side then
			return false, "not your serve"
		end
		if phase ~= "held" or os.clock() < readyAt then
			return false, "wait a moment"
		end
		local ok, err = match:startServe()
		if not ok then
			return false, err
		end
		referee:startServe(side)
		phase = "toss"
		ball.resting = false
		ball.velocity = Vector3.new(0, Config.Serve.TossSpeed, 0)
		ball.spin = Vector3.zero
		lastActivity = os.clock()
		snapshot()
		setEvent(side .. " serves")
		return true
	end

	serveRemote.OnServerEvent:Connect(function(player)
		local now = os.clock()
		if now - (lastRequest[player] or 0) < Config.Serve.RequestCooldown then
			return
		end
		lastRequest[player] = now
		if avatars.getSeatedPlayer() ~= player then
			return
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local holdAt = Config.Layout.ServeBall.Player
		if not root or Vector2.new(root.Position.X - holdAt.X, root.Position.Z - holdAt.Z).Magnitude > Config.Serve.PlayerReach then
			setEvent("Serve refused: walk back to your serving position")
			return
		end
		local ok, why = beginServe("Player")
		if not ok then
			log("serve request refused:", why)
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		lastRequest[p] = nil
	end)

	-- Per physics tick (240 Hz): serve strike, then paddle contacts.
	local historyLength = SC.MaxLatencyCompensation + 0.05
	local function onTick(s)
		if phase == "live" then
			table.insert(history, BallPhysics.copyState(s))
			while #history > 0 and s.time - history[1].time > historyLength do
				table.remove(history, 1)
			end
		end
		if phase == "toss" then
			local holdY = Config.Layout.ServeBall[serveSide].Y
			if s.velocity.Y < 0 and s.position.Y <= holdY then
				local v, w = serveShot(serveSide)
				strike(serveSide, v, w)
			end
		elseif phase == "live" then
			for _, side in { "Player", "Bot" } do
				if (side == "Bot" or (Config.AutoReturn.Enabled and not SC.Enabled)) and referee:canHit(side) then
					local striker = strikers[side]
					if os.clock() - lastHit[side] > Config.Rally.HitCooldown and striker:shouldStrike(s.position, s.velocity) then
						local shot = striker:shot(s.position, rng)
						if shot.velocity.Magnitude > 0 then
							strike(side, shot.velocity, shot.spin)
							break
						end
					end
				end
			end
		end
	end

	local events = {}
	-- Advance the authoritative ball by dt, feeding contacts to the referee and paddles per tick.
	local function advance(dt: number)
		table.clear(events)
		local processed = 0
		BallPhysics.step(ball, cfg, world, dt, events, function(s)
			-- contacts produced this tick
			while processed < #events do
				processed += 1
				local e = events[processed]
				if phase == "live" or phase == "toss" then
					if e.kind == "table" then
						handle(referee:onBounce(e.surface))
					elseif e.kind == "net" or e.kind == "netCord" then
						referee:onNet()
					elseif e.kind == "floor" or e.kind == "side" then
						handle(referee:onDead(e.kind))
					end
				end
			end
			onTick(s)
		end)
	end

	RunService.Heartbeat:Connect(function(dt)
		local timeScale = 1
		if slowMotion then
			local f = slowMotion
			local character = f.player.Character
			local hum = character and character:FindFirstChildOfClass("Humanoid")
			if phase ~= "live" or f.player.Parent == nil or not hum or hum.Health <= 0 or avatars.getSeatedPlayer() ~= f.player then
				pressAt[f.player] = nil
				endSlowMotion("player gone")
				snapshot()
			elseif os.clock() > f.startedAt + CF.MaxDuration + SC.MaxLatencyCompensation then
				swingUsed = true -- the shot is lost: no hit is ever awarded for running out the clock
				pressAt[f.player] = nil
				endSlowMotion("ran out")
				snapshot()
				setEvent("Swing missed: held too long (slow motion ran out)")
				swingResultRemote:FireClient(f.player, { seq = -1, freeze = f.id, result = "miss", reason = "held too long (slow motion ran out)" })
			elseif os.clock() - lastSnapshot > Config.Rally.SnapshotInterval then
				snapshot()
				timeScale = CF.TimeScale
			else
				timeScale = CF.TimeScale
			end
		end
		if ball.resting and phase == "held" then
			return
		end
		advance(dt * timeScale)
		timeOffset = workspace:GetServerTimeNow() - ball.time
		arena.Ball.Position = ball.position
		if #events > 0 or os.clock() - lastSnapshot > Config.Rally.SnapshotInterval then
			snapshot()
		end
		if (phase == "live" or phase == "toss") and os.clock() - lastActivity > Config.Timing.RallyTimeout then
			handle(referee:onTimeout())
		end
	end)

	-- ===== Phase 3: player swing requests =====
	-- The ball state at simulation time `t` from the recent history (or the live ball if t is now).
	local function stateAt(t: number): BallPhysics.State
		local found = nil
		for i = #history, 1, -1 do
			if history[i].time <= t + 1e-6 then
				found = history[i]
				break
			end
		end
		return BallPhysics.copyState(found or history[1] or ball)
	end

	-- "I started charging": remember WHEN (server time), trusting the client's clock only within
	-- MaxLatencyCompensation of the moment the message arrived. One small message per press; nothing per frame.
	-- Charge slow motion: may this press slow the rally? Decided ONLY here, from the server's own ball history and the
	-- character's replicated position. Returns nothing; starts slow motion when the press qualifies.
	local function trySlowMotion(player: Player, pressT: number)
		if not slowMotionAllowed or slowMotion then
			return
		end
		if phase ~= "live" or not incomingForPlayer() or not incomingState or swingUsed then
			return
		end
		if slowMotionUsedHits == referee.hits then
			return -- one slow-motion window per incoming ball
		end
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		local root = rootOf(character)
		if not root or not hum or hum.Health <= 0 then
			return
		end
		local anchor = ShotInput.anchor(root.CFrame, SC)
		if not anchor then
			return
		end
		-- The ball as the player saw it when pressing: rewound to the validated press time, unless it has bounced since
		-- (a contact the referee already counted is never undone).
		local cand = stateAt(pressT - timeOffset)
		if cand.bounces ~= ball.bounces or cand.time > ball.time then
			cand = BallPhysics.copyState(ball)
		end
		local inc = incomingState :: BallPhysics.State
		local window = ShotInput.contactWindow(inc, anchor, SC.PaddleReach, false)
		if not window then
			return -- not reachable from where the player stands: no slow motion (and no free hit)
		end
		local rel = cand.time - inc.time
		if rel < window.ideal - CF.LeadTime or rel > ShotInput.windowEnd(window) then
			return -- too early (charge in real time instead) or too late
		end
		local strikeRel, quality, why = window.ideal, "clean", "on time (slow motion)"
		local contactPosition = window.idealPosition
		if rel > window.ideal then
			-- pressed late in the window: the paddle meets the ball where it is now, with the quality of this moment
			strikeRel, contactPosition = rel, cand.position
			quality, why = ShotInput.classify(rel, window)
			if quality == "miss" then
				return
			end
			why ..= " (slow motion)"
		end
		slowMotionSerial += 1
		slowMotionUsedHits = referee.hits
		cand.accumulator = 0
		ball = cand
		while #history > 0 and history[#history].time > ball.time + 1e-6 do
			table.remove(history)
		end
		arena.Ball.Position = ball.position
		slowMotion = {
			id = slowMotionSerial,
			player = player,
			startedAt = os.clock(),
			startServer = workspace:GetServerTimeNow(),
			startSimTime = ball.time,
			incTime = inc.time,
			strikeRel = strikeRel,
			quality = quality,
			why = why,
			contactPosition = contactPosition,
		}
		MovementService.setSlowMotion(player, CF.TimeScale)
		slowBot(true)
		log(("charge slow motion %d: contact in %.3fs (%s)"):format(slowMotionSerial, strikeRel - rel, quality))
	end

	-- "I started charging": remember WHEN (server time), trusting the client's clock only within
	-- MaxLatencyCompensation of the moment the message arrived. One small message per press; nothing per frame.
	-- { cancel = true }: the client gave up the charge (focus lost, input cancelled): normal speed resumes and the
	-- player keeps the swing (slow motion stays used for this ball).
	chargeRemote.OnServerEvent:Connect(function(player, req)
		if not SC.Enabled or typeof(req) ~= "table" then
			return
		end
		if req.cancel == true then
			pressAt[player] = nil
			if slowMotion and slowMotion.player == player then
				endSlowMotion("cancelled")
				snapshot()
			end
			return
		end
		if not finite(req.t) then
			return
		end
		local now = os.clock()
		if now - (lastPressMsg[player] or -math.huge) < 0.05 then
			return -- spam
		end
		lastPressMsg[player] = now
		if avatars.getSeatedPlayer() ~= player then
			return
		end
		local serverNow = workspace:GetServerTimeNow()
		pressAt[player] = math.clamp(req.t, serverNow - SC.MaxLatencyCompensation, serverNow)
		pressAck = req.t
		trySlowMotion(player, pressAt[player])
		snapshot() -- always answer: slow or normal (a client that predicted slow motion corrects itself from this)
	end)

	swingRemote.OnServerEvent:Connect(function(player, req)
		if not SC.Enabled or typeof(req) ~= "table" or not finite(req.seq) then
			return
		end
		local function reply(result: string, reason: string, extra: { [string]: any }?)
			local msg = { seq = req.seq, result = result, reason = reason }
			for k, v in extra or {} do
				msg[k] = v
			end
			swingResultRemote:FireClient(player, msg)
		end
		local now = os.clock()
		if now - (lastSwing[player] or -math.huge) < SC.SwingCooldown then
			return reply("rejected", "too many swings")
		end
		lastSwing[player] = now
		if avatars.getSeatedPlayer() ~= player then
			return reply("rejected", "not seated")
		end
		local dx, dy, t = req.dx, req.dy, req.t
		if not (finite(dx) and finite(dy) and finite(t)) then
			return reply("rejected", "bad input")
		end

		-- A slow-motion release uses the same server-side contact window, mapped from real release time into the slowed
		-- simulation timeline. Charge power still uses real elapsed time.
		if slowMotion and slowMotion.player == player then
			local f = slowMotion
			if swingUsed then
				endSlowMotion("already swung")
				snapshot()
				return reply("rejected", "already swung at this ball")
			end
			local serverNow = workspace:GetServerTimeNow()
			local release = math.clamp(t, serverNow - SC.MaxLatencyCompensation, serverNow)
			local pressed = pressAt[player]
			pressAt[player] = nil
			local hold = if pressed then math.clamp(release - pressed, 0, CF.MaxDuration + SC.MaxLatencyCompensation) else 0
			local power = ShotLaunch.powerFromHold(hold)
			local simRelease = f.startSimTime + math.max(release - f.startServer, 0) * CF.TimeScale
			local inc = incomingState :: BallPhysics.State
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local anchor = root and ShotInput.anchor(root.CFrame, SC)
			if not anchor then
				endSlowMotion("no character")
				snapshot()
				return reply("rejected", "no character")
			end
			local window = ShotInput.contactWindow(inc, anchor, SC.PaddleReach, false)
			local rel = simRelease - inc.time
			local quality, why, offset = ShotInput.classify(rel, window)
			local info = {
				offset = offset,
				lag = serverNow - release,
				hold = hold,
				power = power,
				anchor = anchor,
				window = window and { enter = window.enter - rel, ideal = window.ideal - rel, exit = window.exit - rel } or nil,
			}
			swingUsed = true
			if quality == "miss" then
				endSlowMotion("missed")
				snapshot()
				setEvent("Swing missed: " .. why)
				return reply("miss", why, info)
			end

			local contact = stateAt(simRelease)
			local top, side = ShotInput.dragToSpin(dx, dy)
			local opts: ShotLaunch.Options = { hitter = "Player" }
			if quality == "weak" then
				top, side = top * SC.WeakSpinFactor, side * SC.WeakSpinFactor
				local e = SC.WeakAimError
				opts.speedFactor = SC.WeakSpeedFactor
				opts.aimOffset = Vector3.new(rng:NextNumber(-e, e), 0, rng:NextNumber(-e, e))
			end
			endSlowMotion("released")
			local catchUp = math.max(ball.time - contact.time, 0)
			contact.accumulator = 0
			ball = contact
			ball.resting = false
			local shot = ShotLaunch.compute(contact.position, power, top, side, opts)
			strike("Player", shot.velocity, shot.spin)
			while catchUp > 1e-6 and phase == "live" do
				local chunk = math.min(catchUp, cfg.fixedStep * cfg.maxStepsPerUpdate * 0.9)
				advance(chunk)
				catchUp -= chunk
			end
			arena.Ball.Position = ball.position
			snapshot()
			setEvent(("You hit (%s, %s, power %d%%): %s"):format(quality, why, math.floor(power * 100 + 0.5), shot.how))
			info.aim, info.topspin, info.sidespin, info.solve = shot.aim, top, side, shot.how
			info.contact, info.velocity, info.spin = contact.position, shot.velocity, shot.spin
			reply(quality, why, info)
			return
		end

		if phase ~= "live" or not incomingForPlayer() or not incomingState then
			return reply("rejected", "no ball to hit")
		end
		if swingUsed then
			return reply("rejected", "already swung at this ball")
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local anchor = root and ShotInput.anchor(root.CFrame, SC)
		if not anchor then
			return reply("rejected", "no character")
		end
		swingUsed = true

		-- When did the player release? Trust the client's clock only within MaxLatencyCompensation of now.
		local serverNow = workspace:GetServerTimeNow()
		local release = math.clamp(t, serverNow - SC.MaxLatencyCompensation, serverNow)
		-- Charge, measured by the server: release minus the validated press time (no press on record = no charge).
		local pressed = pressAt[player]
		pressAt[player] = nil
		local hold = if pressed then math.max(release - pressed, 0) else 0
		local power = ShotLaunch.powerFromHold(hold)
		local simRelease = release - timeOffset
		local inc = incomingState :: BallPhysics.State
		local window = ShotInput.contactWindow(inc, anchor, SC.PaddleReach, false)
		local quality, why, offset = ShotInput.classify(simRelease - inc.time, window)
		local rel = simRelease - inc.time
		local info = { -- (diagnostics: the server's view, shown by the client panel)
			offset = offset,
			lag = serverNow - release,
			hold = hold,
			power = power,
			anchor = anchor,
			window = window and { enter = window.enter - rel, ideal = window.ideal - rel, exit = window.exit - rel } or nil,
		}
		if quality == "miss" then
			setEvent("Swing missed: " .. why)
			return reply("miss", why, info)
		end

		-- Contact: where the ball actually was at the release moment.
		local contact = stateAt(simRelease)
		local top, side = ShotInput.dragToSpin(dx, dy) -- clamped to MaxSpin
		local launchOpts: ShotLaunch.Options = { hitter = "Player" }
		if quality == "weak" then
			top, side = top * SC.WeakSpinFactor, side * SC.WeakSpinFactor
			local e = SC.WeakAimError
			launchOpts.speedFactor = SC.WeakSpeedFactor
			launchOpts.aimOffset = Vector3.new(rng:NextNumber(-e, e), 0, rng:NextNumber(-e, e))
		end
		local shot = ShotLaunch.compute(contact.position, power, top, side, launchOpts)
		local how = shot.how

		-- Rewind to the contact moment, hit, then re-simulate up to now (the ball is never steered afterwards).
		local catchUp = math.max(ball.time - contact.time, 0)
		contact.accumulator = 0 -- catch-up below re-simulates exactly the elapsed ticks
		ball = contact
		ball.resting = false
		strike("Player", shot.velocity, shot.spin)
		while catchUp > 1e-6 and phase == "live" do
			local chunk = math.min(catchUp, cfg.fixedStep * cfg.maxStepsPerUpdate * 0.9)
			advance(chunk)
			catchUp -= chunk
		end
		arena.Ball.Position = ball.position
		snapshot()
		setEvent(("You hit (%s, %s, power %d%%): %s"):format(quality, why, math.floor(power * 100 + 0.5), how))
		info.aim, info.topspin, info.sidespin, info.solve = shot.aim, top, side, how
		info.contact, info.velocity, info.spin = contact.position, shot.velocity, shot.spin
		reply(quality, why, info)
	end)
	Players.PlayerRemoving:Connect(function(p)
		lastSwing[p] = nil
		pressAt[p] = nil
		lastPressMsg[p] = nil
	end)

	local function scheduleBotServe()
		local mySerial = serial
		task.delay(Config.Serve.BotDelay + Config.Timing.ServeReadyDelay, function()
			if serial == mySerial and match.server == "Bot" then
				beginServe("Bot")
			end
		end)
	end

	match.Changed:Connect(function(newState)
		if newState == State.ReadyToServe then
			hold(match.server)
			if botBrain then
				botBrain:goHome()
			end
			if match.server == "Bot" then
				scheduleBotServe()
			else
				setEvent("Your serve: press Space")
			end
		elseif newState == State.WaitingForPlayer then
			hold(match.server)
		end
	end)

	-- The match may already be ReadyToServe (event fired before we connected).
	hold(match.server)
	if match:getState() == State.ReadyToServe and match.server == "Bot" then
		scheduleBotServe()
	end

	return {
		beginServe = beginServe,
		getBall = function()
			return ball
		end,
		getPhase = function()
			return phase
		end,
		referee = referee,
	}
end

return RallyService
