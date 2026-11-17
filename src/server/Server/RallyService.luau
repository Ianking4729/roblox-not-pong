-- RallyService (server): owns the ONE authoritative ball and runs points end to end.
--   * simulates the ball with BallPhysics at a fixed 240 Hz inside Heartbeat (frame-rate independent),
--   * moves only the invisible gameplay part (BallTemplate.Ball); clients render the cosmetic BallVisual themselves
--     from snapshots (Client/BallView) using the same deterministic simulation,
--   * serving: the PLAYER serves by hand: the ball rests in their free hand, Space (ServeRequest) tosses it from their own
--     spot (validated against the legal region, then the spot is locked), the toss flies at NORMAL speed (2026-11-16
--     pass 3: no serve slow motion), and the player strikes it with a normal swing judged here: a contact inside the
--     toss's contact phase (ServeRules.phase, at release + HitDelay) is a LEGAL serve solved by ShotLaunch.serve; early,
--     late, out of reach or never struck are real faults. The BOT serves automatically,
--   * per physics tick asks the bot's Striker whether it can legally hit, and applies the player's judged contact on the
--     tick that reaches its time,
--   * feeds contacts to RallyReferee and applies outcomes to the existing MatchState (score, serve rotation).
-- Clients only send requests: "serve now" (checked: seat, state, turn, distance, delay, rate limit) and "I flicked"
-- (CLICK-AND-FLICK, 2026-11-17): the flick's start time, its raw measurements (distance, duration, direction), the stroke,
-- base aim and drive/arc profile locked at the click, the click time and the root. A swing is judged HERE from the
-- ball's own simulated history: the flick time is clamped to MaxLatencyCompensation + Flick.RecognitionAllowance of its
-- arrival; the paddle meets the ball Flick.ContactDelay later; the contact must fall inside the contact window of the
-- incoming ball against the stroke's reach from the player's real position (ShotInput.contactWindow / classify), or, for
-- a ball that never enters that reach, inside the outer EMERGENCY ring's window (a defensive lob, Config.Emergency).
-- Power and spin are recomputed here from the validated flick measurements (ShotInput.validateFlick / flickShot); one
-- swing per incoming ball and per toss; the launch uses the shared ShotLaunch model and real physics. The client never
-- claims a hit or a contact point and never sends a power, a velocity or a target.
--
-- CHARGE SLOW MOTION (Config.ChargeFreeze): OFF for rallies since click-and-flick (no trigger exists; the plumbing that
-- slows the ball, player and bot is kept for a future decision). Serves never slow down.

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
local ServeRules = require(Shared:WaitForChild("ServeRules"))

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
	-- (ChargeStart, the hold-to-charge press message, was retired with click-and-flick)
	return remote("BallSnapshot"), remote("ServeRequest"), remote("SwingRequest"), remote("SwingResult"), remote("ServeResult")
end

local function finite(n: any): boolean
	return typeof(n) == "number" and n == n and math.abs(n) < 1e10 -- (server time is ~1.8e9)
end

-- arena: ArenaBuilder.load() result. match: MatchState. avatars: AvatarService. bot: the bot Model (or nil).
function RallyService.start(arena, match, avatars, bot: Model?)
	local cfg, world = TableWorld.physics, TableWorld.world
	local snapshotRemote, serveRemote, swingRemote, swingResultRemote, serveResultRemote = remotes()
	local SC = Config.ShotControl
	local rng = Random.new()
	local referee = RallyReferee.new()

	local ball = BallPhysics.newState(Config.Layout.ServeBall[match.server])
	ball.resting = true
	local phase = "held" -- held | windup (player toss started, ball still in the hand) | toss | live | dead
	-- player serve
	local serveBeganServer = -math.huge -- server time the player's toss started (a charge must start after it)
	local tossState: BallPhysics.State? = nil -- the toss the moment it left the hand (the strike window's reference)
	local tossReleaseAt = 0 -- os.clock() the ball leaves the hand
	local servePlayer: Player? = nil -- who is tossing (movement locked until the serve resolves)
	-- the serving posture locked at the toss (Config.Serve.Posture; Q before the toss): decides the serve stroke and the
	-- hand's release point; nil when no player serve is in progress
	local servePosture: string? = nil
	-- a judged player contact (serve or rally) still in the (near) future: applied on the physics tick that reaches its
	-- time (the paddle meets the ball Flick.ContactDelay / Serve.HitDelay after the flick started)
	local pendingContact: { time: number, velocity: Vector3, spin: Vector3, finish: () -> () }? = nil
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
	local swingUsed = false -- one swing per incoming ball (and per toss)
	local lastSwing: { [Player]: number } = {}
	local lastSeq: { [Player]: number } = {} -- duplicate / replayed swing requests are refused
	-- Charge slow motion (kept, never started: Config.ChargeFreeze is off for rallies)
	local CF = Config.ChargeFreeze
	local matchMode = if bot then "Solo" else "PvP"
	local slowMotionAllowed = CF.Enabled and CF.Modes[matchMode] == true
	arena.Folder:SetAttribute("ChargeFreeze", slowMotionAllowed) -- client predicts the slow-motion transition
	arena.Folder:SetAttribute("MatchMode", matchMode)
	local slowMotion: any = nil -- the active charge slow motion (never started since click-and-flick; see the header)
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
	-- emergency saves (Config.Emergency): counters for tests / diagnostics
	local saveStats = { attempts = 0, saves = 0, legal = 0, misses = 0, solverFailures = 0 }
	-- (tuning telemetry: how rally swings resolve; offsetSum / offsetN = mean contact offset from the ideal moment in
	-- seconds (negative = early); early / late / noReach count the misses by cause)
	local swingStats = {
		swings = 0, normal = 0, misses = 0, rejected = 0, clean = 0, weak = 0, earlyMiss = 0, lateMiss = 0, noReach = 0,
		offsetSum = 0, offsetN = 0,
		-- (telemetry) early misses refused only by the falling-ball rule (RequireFallingBall on) / accepted contacts that
		-- rule would have refused (off); incoming balls the player never swung at (and how many of those had a contact
		-- window from where they stood); where accepted contacts were predicted to land
		risingBlocked = 0, risingHit = 0, noSwing = 0, noSwingReachable = 0, landOk = 0, landNet = 0, landOut = 0, landOwn = 0,
	}
	local TEL = Config.Telemetry
	local function tel(line: string)
		if TEL.Enabled and TEL.Print then
			print("[Tel] server " .. line)
		end
	end
	local function f2(n: any, d: number?): string
		return if typeof(n) == "number" then string.format("%." .. tostring(d or 2) .. "f", n) else "-"
	end
	-- Where an accepted shot is predicted to land (the same physics the live ball runs). Always computed: the HUD's brief
	-- verdict uses info.land ("CONTACT • OUT"); the counters are telemetry.
	local function telLand(info: { [string]: any }, from: Vector3, velocity: Vector3, spin: Vector3)
		local path = ShotLaunch.predictPath(from, velocity, spin, nil, 2, "Player")
		info.land = path.kind
		local c = TableWorld.center
		info.landDepth = (path.position.Z - c.Z) * TableWorld.towardSide("Bot") -- studs past the net on the bot's half
		info.landLateral = path.position.X - c.X
		local key = "land" .. string.upper(string.sub(path.kind, 1, 1)) .. string.sub(path.kind, 2)
		if swingStats[key] ~= nil then
			swingStats[key] += 1
		end
	end
	local function telSwing(info: { [string]: any }, quality: string, why: string)
		local w = info.window
		tel(("SWING %s %s (%s) offset %s lag %s | window rel. contact [%s, %s, %s] | rising gap %s%s | power %s flick %s px/s aim %s profile %s | land %s depth %s lateral %s"):format(
			tostring(info.kind), quality, why, f2(info.offset, 3), f2(info.lag, 3), f2(w and w.enter, 3), f2(w and w.ideal, 3),
			f2(w and w.exit, 3), f2(info.risingGap, 3), if info.risingBlocked then " RISING-BLOCKED" elseif info.risingHit then " RISING-HIT" else "", f2(info.power),
			f2(info.flickSpeed, 0), f2(info.aim), f2(info.profile), tostring(info.land), f2(info.landDepth, 1), f2(info.landLateral, 1)))
	end

	-- Is the player the next to play the ball (Bot's return, or the Bot's serve)?
	local function incomingForPlayer(): boolean
		return (referee.phase == "rally" and referee.lastHitter == "Bot")
			or (referee.phase == "serveFlight" and referee.server == "Bot")
	end

	local function ballInHand(): boolean
		return serveSide == "Player" and (phase == "held" or phase == "windup")
	end

	local function packet()
		local f = slowMotion
		return {
			p = ball.position,
			v = ball.velocity,
			w = ball.spin,
			t = workspace:GetServerTimeNow(),
			mode = if f then "slow" elseif ballInHand() then "hand" elseif ball.resting then "held" else "free",
			sv = phase == "toss" and serveSide == "Player" and not swingUsed, -- the player's toss: strike it now
			ts = if f then CF.TimeScale else 1,
			i = incomingForPlayer(), -- the ball is on its way to the player (aim now)
			b = referee.bounces.Player, -- bounces on the player's half since the last hit
			h = referee.hits, -- hit counter: identifies each incoming ball
			st =tossState and phase == "toss" and { p = tossState.position, v = tossState.velocity, t = tossState.time + timeOffset } or nil, -- the toss as it left the hand (server time)
			f = f and { -- the active charge slow motion (rally only; never during a serve)
				id = f.id,
				kind = f.kind,
				ends = f.startServer + CF.MaxDuration, -- server time slow motion runs out
				strikeIn = if f.strikeRel then f.strikeRel - (ball.time - f.incTime) else nil,
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

	-- Release the serving player's movement lock (serve struck, point over, player gone).
	local function unlockServe()
		if servePlayer then
			if servePlayer.Parent ~= nil then
				MovementService.setServeLock(servePlayer, false)
			end
			servePlayer = nil
		end
	end

	-- Where the player's ball sits in their free hand (server view of the root; the client draws it on the real hand).
	local function playerHandPoint(which: string?): Vector3?
		local p = avatars.getSeatedPlayer()
		local character = p and p.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return nil
		end
		return ServeRules.handPoint(root.CFrame, (character :: Model):GetScale(), which, servePosture)
	end

	-- Ball held for `side`'s serve (a reset: the only time the ball is placed rather than simulated). The player's ball
	-- rests in their hand (clients draw it there); the bot's at its fixed serve point.
	local function hold(side: string)
		serial += 1
		phase = "held"
		serveSide = side
		unlockServe()
		serveBeganServer = -math.huge
		tossState, pendingContact = nil, nil
		servePosture = nil
		ball = BallPhysics.newState(if side == "Player" then (playerHandPoint("hold") or Config.Layout.ServeBall.Player) else Config.Layout.ServeBall[side])
		ball.resting = true
		timeOffset = workspace:GetServerTimeNow() - ball.time
		table.clear(history)
		incomingState, swingUsed = nil, false
		clearSlowMotion()
		ArenaBuilder.moveBall(arena, ball.position)
		readyAt = os.clock() + Config.Timing.ServeReadyDelay
		snapshot()
	end

	local function endPoint(outcome)
		-- (telemetry) a ball that came to the player and was never swung at: could they have reached it from where they
		-- ended up (forehand or backhand anchor; normal reach, the save ring, and without the falling-ball rule)?
		if TEL.Enabled and incomingState and not swingUsed and serveSide ~= nil then
			local player = avatars.getSeatedPlayer()
			local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				swingStats.noSwing += 1
				local found = "none"
				for _, stroke in { "Forehand", "Backhand" } do
					local a, reach = ShotInput.reachFor(root.CFrame, SC, stroke)
					if a then
						if ShotInput.contactWindow(incomingState, a, reach, false) then
							found = stroke .. " normal"
							break
						elseif ShotInput.contactWindow(incomingState, a, ShotInput.emergencyReach(SC), false, nil, true) then
							found = stroke .. " save ring"
						elseif found == "none" and SC.RequireFallingBall and ShotInput.contactWindow(incomingState, a, reach, false, nil, false) then
							found = stroke .. " only while rising"
						end
					end
				end
				if found ~= "none" then
					swingStats.noSwingReachable += 1
				end
				tel(("NOSWING the ball came to you and was not swung at; reachable from where you ended: %s"):format(found))
			end
		end
		if TEL.Enabled and not outcome.let then
			tel(("POINT %s wins: %s | hits this rally %d | last hitter %s"):format(tostring(outcome.winner), tostring(outcome.reason), referee.hits or 0, tostring(referee.lastHitter)))
		end
		phase = "dead"
		pendingContact = nil
		unlockServe()
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
		if side == "Player" then
			unlockServe() -- a struck serve frees the server's feet
		end
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

	-- ReadyToServe -> Serving for the BOT: toss the ball straight up from its serve point (struck automatically).
	-- Returns ok, reason.
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

	-- ReadyToServe -> Serving for the PLAYER: validate the spot, lock it, and release the ball from the hand after
	-- TossReleaseDelay (the toss clip's Release marker). Returns ok, reason (shown to the player).
	local function beginPlayerServe(player: Player, posture: string): (boolean, string)
		if match:getState() ~= State.ReadyToServe then
			return false, "not ready to serve"
		end
		if match.server ~= "Player" then
			return false, "not your serve"
		end
		if phase ~= "held" or os.clock() < readyAt then
			return false, "wait a moment"
		end
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not character or not hum or not root or hum.Health <= 0 or not character:GetAttribute("NotPongPlaced") then
			return false, "no character"
		end
		if hum.FloorMaterial == Enum.Material.Air then
			return false, "land first"
		end
		local legal, why = ServeRules.check(root.CFrame, character:GetScale(), posture)
		if not legal then
			return false, why
		end
		local ok, err = match:startServe()
		if not ok then
			return false, err or "cannot serve"
		end
		referee:startServe("Player")
		phase = "windup"
		servePlayer = player
		servePosture = posture -- locked for this serve
		MovementService.setServeLock(player, true)
		serveBeganServer = workspace:GetServerTimeNow()
		tossReleaseAt = os.clock() + Config.Serve.TossReleaseDelay
		pendingContact = nil
		clearSlowMotion() -- (nothing slows a serve; a leftover rally slow motion never survives into one)
		swingUsed = false -- (a click from before the toss never counts: the swing's click time is checked against the toss)
		lastActivity = os.clock()
		snapshot()
		setEvent("Player serves")
		return true, "ok"
	end

	-- The ball leaves the hand: a straight-up toss from the hand's release point (server view of the locked root).
	local function releaseToss()
		local start = playerHandPoint("release") or ball.position
		ball = BallPhysics.newState(start, Vector3.new(0, Config.Serve.PlayerTossSpeed, 0), Vector3.zero)
		ball.resting = false
		phase = "toss"
		tossState = BallPhysics.copyState(ball)
		table.clear(history)
		timeOffset = workspace:GetServerTimeNow() - ball.time
		lastActivity = os.clock()
		arena.Ball.Position = ball.position
		snapshot()
	end

	serveRemote.OnServerEvent:Connect(function(player, req)
		local now = os.clock()
		if now - (lastRequest[player] or 0) < Config.Serve.RequestCooldown then
			return
		end
		lastRequest[player] = now
		if avatars.getSeatedPlayer() ~= player then
			return
		end
		local posture = ServeRules.posture(typeof(req) == "table" and req.posture or nil)
		local ok, why = beginPlayerServe(player, posture)
		serveResultRemote:FireClient(player, { ok = ok, reason = why, posture = if ok then posture else nil })
		if not ok then
			log("serve request refused:", why)
			if why ~= "wait a moment" and why ~= "not ready to serve" and why ~= "not your serve" then
				setEvent("Serve refused: " .. why)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		lastRequest[p] = nil
	end)

	-- The reach a swing by `player` gets right now: the stroke's anchor and its normal radius (the outer emergency radius
	-- is ShotInput.emergencyReach). Server positions only, except: `claimed` (2026-11-16 pass 3), the root position the
	-- client reports with its swing. The server sees a client-owned character ~0.1 s late, so a moving player's anchor (and
	-- with it the contact window's ideal moment, the timing error and the stretch) differed from what the player saw. The
	-- claim is used only when it lies within MaxRootMismatch studs (horizontally) of the server's own view; otherwise the
	-- server's position is used. (The F dive and its automatic return were retired on 2026-11-17: Config.Emergency.)
	local function reachFor(player: Player, stroke: string?, claimed: any): (Vector3?, number, string?)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return nil, SC.PaddleReach, "no character"
		end
		local cf = root.CFrame
		if typeof(claimed) == "Vector3" and finite(claimed.X) and finite(claimed.Z) then
			local d = Vector2.new(claimed.X - cf.Position.X, claimed.Z - cf.Position.Z).Magnitude
			if d <= (SC.MaxRootMismatch or 0) then
				cf = CFrame.new(claimed.X, cf.Position.Y, claimed.Z) * cf.Rotation
			end
		end
		local anchor, reach = ShotInput.reachFor(cf, SC, stroke, nil)
		return anchor, reach, nil
	end
	-- Per physics tick (240 Hz): the bot's serve strike / the player's judged serve contact, then paddle contacts.
	-- (history covers the largest rewind a swing may ask for: latency + the flick recognition interval)
	local historyLength = SC.MaxLatencyCompensation + Config.Flick.RecognitionAllowance + 0.05
	local function onTick(s)
		if phase == "live" or phase == "toss" then
			table.insert(history, BallPhysics.copyState(s))
			while #history > 0 and s.time - history[1].time > historyLength do
				table.remove(history, 1)
			end
		end
		if phase == "toss" and serveSide == "Bot" then
			local holdY = Config.Layout.ServeBall.Bot.Y
			if s.velocity.Y < 0 and s.position.Y <= holdY then
				local v, w = serveShot("Bot")
				strike("Bot", v, w)
			end
			return
		end
		if pendingContact and (phase == "toss" or phase == "live") and s.time >= pendingContact.time - 1e-6 then
			-- the paddle meets the ball now (the contact judged at the flick, ContactDelay ago)
			local pc = pendingContact
			pendingContact = nil
			strike("Player", pc.velocity, pc.spin)
			pc.finish()
			return
		end
		if phase == "live" then
			for _, side in { "Player", "Bot" } do
				if (side == "Bot" or (Config.AutoReturn.Enabled and not SC.Enabled)) and referee:canHit(side) then
					local striker = strikers[side]
					if os.clock() - lastHit[side] > Config.Rally.HitCooldown and striker:shouldStrike(s.position, s.velocity) then
						local shot, _, kind = striker:shot(s.position, rng, s)
						if shot.velocity.Magnitude > 0 then
							if kind == "lob" then
								setEvent(side .. " pops up a high ball: smash it!")
							end
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
				endSlowMotion(if phase ~= "live" then "phase over" else "player gone")
				snapshot()
			elseif os.clock() > f.startedAt + CF.MaxDuration + SC.MaxLatencyCompensation then
				swingUsed = true -- the shot is lost: no hit is ever awarded for running out the clock
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
		if ballInHand() then
			-- the player's ball rides in their hand (gameplay part only; every client draws the visual on the real hand)
			local p = playerHandPoint("hold")
			if p then
				ball.position = p
				arena.Ball.Position = p
			end
			if phase == "windup" and os.clock() >= tossReleaseAt then
				releaseToss()
			elseif os.clock() - lastSnapshot > Config.Rally.SnapshotInterval then
				snapshot() -- (periodic, like every other mode: a client that cannot find the hand still sees where the ball is)
			end
			return
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

	-- ===== Player swings: CLICK-AND-FLICK (2026-11-17) =====
	-- A request = { seq, t (server time the flick STARTED), commitT (server time of the click), stroke, aim, profile,
	-- flick = { d = distance ref px, u = duration s, x, y = unit direction (screen, y down) }, root }.
	-- Checks: seated, duplicate seq, rate limit, finite numbers, a plausible flick (ShotInput.validateFlick: otherwise
	-- REJECTED, never clamped into a shot), the legal state (an incoming ball for the player, or their own toss), one swing
	-- per ball / toss, a click after the toss started (serves). Timing: t is trusted only within maxRewind of its arrival;
	-- the paddle meets the ball Flick.ContactDelay after t (Serve.HitDelay for a serve, the same value).
	local Fl, E = Config.Flick, Config.Emergency
	local maxRewind = SC.MaxLatencyCompensation + Fl.RecognitionAllowance

	-- The ball at simulation time `simT`: from the recent history when that is in the past, else simulated forward from
	-- the live ball (the same deterministic physics the live ball will run).
	local function contactState(simT: number): BallPhysics.State
		if simT <= ball.time then
			return stateAt(simT)
		end
		local c = BallPhysics.copyState(ball)
		while c.time < simT - 1e-6 do
			BallPhysics.tick(c, cfg, world)
		end
		return c
	end

	-- Apply a judged player contact: now (rewind to it, hit, re-simulate to the present; never steered afterwards) or, when
	-- it is still ahead, on the physics tick that reaches it (pendingContact).
	local function applyContact(contact: BallPhysics.State, velocity: Vector3, spin: Vector3, finish: () -> ())
		if contact.time <= ball.time + 1e-6 then
			local catchUp = math.max(ball.time - contact.time, 0)
			contact.accumulator = 0
			ball = contact
			ball.resting = false
			strike("Player", velocity, spin)
			while catchUp > 1e-6 and phase == "live" do
				local chunk = math.min(catchUp, cfg.fixedStep * cfg.maxStepsPerUpdate * 0.9)
				advance(chunk)
				catchUp -= chunk
			end
			finish()
		else
			pendingContact = { time = contact.time, velocity = velocity, spin = spin, finish = finish }
		end
	end

	-- The player's normal launch from a judged contact: the flick's power and spin, the locked base aim and profile, the
	-- deterministic timing error (offset from the ideal moment), stretch (distance from the stroke's anchor) and the SMASH
	-- check, all through the shared ShotLaunch (the client's post-flick prediction runs the same code).
	local function playerLaunch(contact: BallPhysics.State, fl, quality: string, offset: number, stroke: string, anchor: Vector3, aim: number, profile: number)
		local top, side, power = fl.topspin, fl.sidespin, fl.power
		local p = contact.position
		local smash = (quality == "clean" or quality == "weak") and ShotInput.smashEligible(p, power)
		local opts: ShotLaunch.Options = {
			hitter = "Player",
			stroke = stroke,
			timing = ShotInput.timingValue(offset),
			stretch = Vector2.new(p.X - anchor.X, p.Z - anchor.Z).Magnitude / SC.PaddleReach,
			smash = smash,
			aim = aim,
			profile = profile,
		}
		if quality == "weak" and not smash then
			top, side = top * SC.WeakSpinFactor, side * SC.WeakSpinFactor
			opts.speedFactor = SC.WeakSpeedFactor
		end
		return ShotLaunch.compute(p, power, top, side, opts), top, side, smash, opts.stretch :: number
	end

	-- The player's strike at their own toss. Judged on the server's own simulation of the toss at the validated flick
	-- time: the paddle meets the ball HitDelay later, and if that is inside the toss's CONTACT PHASE (ServeRules.phase:
	-- falling, in the height band, in the locked posture-stroke's reach) the serve is LEGAL, launched by ShotLaunch.serve
	-- with the flick's power and spin and the aim locked at the click (solved before the contact, never steered).
	local serveStats = { swings = 0, legal = 0, weak = 0, misses = 0, solverFailures = 0 }
	local function judgeServe(player: Player, req, reply, fl)
		if swingUsed then
			return reply("rejected", "already swung at this toss")
		end
		if not finite(req.commitT) or req.commitT < serveBeganServer - SC.MaxLatencyCompensation then
			return reply("rejected", "click after the toss") -- a click held from before the toss never counts
		end
		swingUsed = true
		serveStats.swings += 1
		local serverNow = workspace:GetServerTimeNow()
		local flickT = math.clamp(req.t, serverNow - maxRewind, serverNow)
		local stroke = ServeRules.postureStroke(servePosture) -- the locked posture decides the serve stroke (never the cursor)
		local aim = if finite(req.aim) then math.clamp(req.aim, -1, 1) else 0
		local power, top, side = fl.power, fl.topspin, fl.sidespin
		local info: { [string]: any } = { power = power, stroke = stroke, aim = aim, serve = true, flickSpeed = fl.speed }
		local function missed(why: string)
			serveStats.misses += 1
			snapshot()
			setEvent("Serve missed: " .. why)
			reply("miss", why, info)
		end
		if phase ~= "toss" or not tossState then
			return missed("swung before the ball left the hand")
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local anchor = root and ShotInput.anchor(root.CFrame, SC, stroke)
		if not anchor then
			return missed("no character")
		end
		local simFlick = flickT - timeOffset
		local toss = tossState :: BallPhysics.State
		local window = ServeRules.phase(toss, anchor, SC.PaddleReach)
		local rel = simFlick - toss.time
		local quality, why = ServeRules.classify(rel, window)
		info.offset, info.anchor = if window then rel - window.ideal else 0, anchor
		info.window = window and { enter = window.enter - rel, ideal = window.ideal - rel, exit = window.exit - rel } or nil
		info.contactT = flickT + Config.Serve.HitDelay
		if quality == "miss" then
			return missed(why)
		end
		local contact = contactState(simFlick + Config.Serve.HitDelay)
		if quality == "weak" then
			top, side = top * SC.WeakSpinFactor, side * SC.WeakSpinFactor
		end
		local shot = ShotLaunch.serve(contact.position, power, top, side, aim, quality)
		if shot.ok then
			serveStats.legal += 1
		else
			serveStats.solverFailures += 1
			warn(("[Rally] serve solver found no legal serve from %s (power %.2f, spin %.0f/%.0f, aim %.2f) - unexpected"):format(tostring(contact.position), power, top, side, aim))
		end
		if quality == "weak" then
			serveStats.weak += 1
		end
		info.contact, info.velocity, info.spin, info.topspin, info.sidespin = contact.position, shot.velocity, shot.spin, top, side
		info.contactHeight = contact.position.Y - Config.Layout.SurfaceY
		info.solve, info.target = shot.how, shot.secondBounce
		applyContact(contact, shot.velocity, shot.spin, function()
			arena.Ball.Position = ball.position
			snapshot()
			setEvent(("You serve (%s %s, %s, power %d%%, aim %+.2f): %s"):format(string.lower(stroke), quality, why, math.floor(power * 100 + 0.5), aim, shot.how))
		end)
		reply(quality, why, info)
	end

	-- A rally swing at the incoming ball. NORMAL: the ball's path enters the stroke's reach -> the contact must fall in
	-- that contact window. EMERGENCY: the path never enters the normal reach but passes through the outer ring -> the
	-- contact must fall in the ring's window; a hit is the defensive lob. A ball inside the ring at the contact time is an
	-- emergency ATTEMPT (the body commits to the reach: the get-up's speed reduction applies), hit or miss.
	local function judgeRally(player: Player, req, reply, fl)
		if phase ~= "live" or not incomingForPlayer() or not incomingState then
			return reply("rejected", "no ball to hit")
		end
		if swingUsed then
			return reply("rejected", "already swung at this ball")
		end
		local stroke = if req.stroke == "Backhand" then "Backhand" else "Forehand"
		local aim = if finite(req.aim) then math.clamp(req.aim, -1, 1) else 0
		local profile = if finite(req.profile) then math.clamp(req.profile, 0, 1) else 0.5
		local anchor, reach, refuse = reachFor(player, stroke, req.root)
		if not anchor then
			return reply("rejected", refuse or "no character")
		end
		swingUsed = true
		swingStats.swings += 1
		local serverNow = workspace:GetServerTimeNow()
		local flickT = math.clamp(req.t, serverNow - maxRewind, serverNow)
		local contactSim = flickT - timeOffset + Fl.ContactDelay
		local inc = incomingState :: BallPhysics.State
		local rel = contactSim - inc.time
		local kind = "normal"
		local window = ShotInput.contactWindow(inc, anchor, reach, false)
		local quality, why, offset
		if window then
			quality, why, offset = ShotInput.classify(rel, window)
		else
			-- (the save ring keeps the falling-ball rule: emergency-save rules are unchanged by the rising-ball change)
			local outer = if E.Enabled then ShotInput.contactWindow(inc, anchor, ShotInput.emergencyReach(SC), false, nil, true) else nil
			if outer then
				kind, window = "emergency", outer
				quality, why, offset = ShotInput.classify(rel, outer)
			else
				quality, why, offset = "miss", "ball never in reach", 0
			end
		end
		local w = window
		local info: { [string]: any } = {
			kind = kind,
			offset = offset,
			lag = serverNow - flickT,
			power = fl.power,
			flickSpeed = fl.speed,
			anchor = anchor,
			stroke = stroke,
			aim = aim,
			profile = profile,
			contactT = flickT + Fl.ContactDelay, -- server time the paddle meets the ball (the client syncs its swing to it)
			window = w and { enter = w.enter - rel, ideal = w.ideal - rel, exit = w.exit - rel } or nil,
		}
		-- (telemetry, diagnosis only) compare with the OTHER legal-contact rule (Config.ShotControl.RequireFallingBall):
		--   rule off (now): risingHit = this contact was accepted but the old "falling, or past the end line" rule would have
		--                   refused it (the ball was still rising); risingGap = how much earlier the window opens now
		--   rule on:        risingBlocked = refused only because the ball was still rising inside the reach
		if TEL.Enabled then
			local fallingRule = SC.RequireFallingBall == true
			local alt = ShotInput.contactWindow(inc, anchor, reach, false, nil, not fallingRule)
			local normalW = if kind == "normal" then w else nil
			if fallingRule then
				if alt then
					info.risingGap = if normalW then normalW.enter - alt.enter else nil
					info.risingBlocked = quality == "miss" and rel >= alt.enter and rel <= alt.exit and (normalW == nil or rel < normalW.enter)
					if info.risingBlocked then
						swingStats.risingBlocked += 1
					end
				end
			elseif normalW then
				info.risingGap = if alt then alt.enter - normalW.enter else nil
				info.risingHit = quality ~= "miss" and (alt == nil or rel < alt.enter or rel > alt.exit)
				if info.risingHit then
					swingStats.risingHit += 1
				end
			end
		end
		if kind == "emergency" and w and rel >= w.enter and rel <= w.exit then
			saveStats.attempts += 1
			info.lunge = true
			-- the get-up: from landing (contact + LandDelay) for StandUpTime, WalkSpeed x RecoverySpeedFactor
			local landIn = (flickT + Fl.ContactDelay + E.LandDelay) - serverNow
			MovementService.setRecovery(player, landIn, E.StandUpTime, E.RecoverySpeedFactor)
		end
		if quality == "clean" then
			swingStats.clean += 1
		elseif quality == "weak" then
			swingStats.weak += 1
		else
			local r = string.lower(why)
			if string.find(r, "early") then
				swingStats.earlyMiss += 1
			elseif string.find(r, "late") then
				swingStats.lateMiss += 1
			else
				swingStats.noReach += 1
			end
		end
		if w and kind then
			swingStats.offsetSum += offset
			swingStats.offsetN += 1
		end
		if quality == "miss" then
			if kind == "emergency" then
				saveStats.misses += 1
			end
			swingStats.misses += 1
			setEvent("Swing missed: " .. why)
			telSwing(info, "miss", why)
			return reply("miss", why, info)
		end
		local contact = contactState(contactSim)
		info.contact = contact.position
		if kind == "emergency" then
			-- the defensive lob: the flick's spin heavily reduced and capped; its power plays no part (never an attack)
			local top = math.clamp(fl.topspin * E.SpinFactor, -E.MaxSpin, E.MaxSpin)
			local side = math.clamp(fl.sidespin * E.SpinFactor, -E.MaxSpin, E.MaxSpin)
			local shot = ShotLaunch.emergencyLob(contact.position, aim, top, side, "Player")
			saveStats.saves += 1
			if shot.ok then
				saveStats.legal += 1
			else
				saveStats.solverFailures += 1
				warn(("[Rally] emergency save: no legal lob found (%s) - unexpected"):format(shot.how))
			end
			info.topspin, info.sidespin, info.solve, info.velocity, info.spin = top, side, shot.how, shot.velocity, shot.spin
			telLand(info, contact.position, shot.velocity, shot.spin)
			telSwing(info, quality, why)
			applyContact(contact, shot.velocity, shot.spin, function()
				arena.Ball.Position = ball.position
				snapshot()
				setEvent(("Emergency save! (%s %s, %s)"):format(string.lower(stroke), quality, shot.how))
			end)
			return reply(quality, why, info)
		end
		local shot, top, side, smash, stretch = playerLaunch(contact, fl, quality, offset, stroke, anchor :: Vector3, aim, profile)
		swingStats.normal += 1
		info.aimPoint, info.topspin, info.sidespin, info.solve = shot.aim, top, side, shot.how
		info.velocity, info.spin = shot.velocity, shot.spin
		info.smash, info.stretch, info.yawError, info.pitchError = smash, stretch, shot.yawError, shot.pitchError
		telLand(info, contact.position, shot.velocity, shot.spin)
		telSwing(info, quality, why)
		applyContact(contact, shot.velocity, shot.spin, function()
			arena.Ball.Position = ball.position
			snapshot()
			setEvent(("You hit (%s %s%s, %s, power %d%%, aim %+.2f, arc %.2f): %s"):format(string.lower(stroke), if smash then "SMASH " else "", quality, why, math.floor(fl.power * 100 + 0.5), aim, profile, shot.how))
		end)
		reply(quality, why, info)
	end

	swingRemote.OnServerEvent:Connect(function(player, req)
		if not SC.Enabled or typeof(req) ~= "table" or not finite(req.seq) then
			return
		end
		local function reply(result: string, reason: string, extra: { [string]: any }?)
			local msg = { seq = req.seq, result = result, reason = reason }
			for k, v in extra or {} do
				msg[k] = v
			end
			if result == "rejected" then
				swingStats.rejected += 1
			end
			swingResultRemote:FireClient(player, msg)
		end
		if req.seq <= (lastSeq[player] or -math.huge) then
			return reply("rejected", "duplicate request")
		end
		lastSeq[player] = req.seq
		local now = os.clock()
		if now - (lastSwing[player] or -math.huge) < SC.SwingCooldown then
			return reply("rejected", "too many swings")
		end
		lastSwing[player] = now
		if avatars.getSeatedPlayer() ~= player then
			return reply("rejected", "not seated")
		end
		if not finite(req.t) then
			return reply("rejected", "bad input")
		end
		local ok, speed, dirX, dirY, why = ShotInput.validateFlick(req.flick)
		if not ok then
			return reply("rejected", why) -- invalid or extreme input never becomes a shot
		end
		local power, top, side = ShotInput.flickShot(speed, dirX, dirY)
		local fl = { speed = speed, dirX = dirX, dirY = dirY, power = power, topspin = top, sidespin = side }
		if serveSide == "Player" and (phase == "windup" or phase == "toss") and servePlayer == player then
			return judgeServe(player, req, reply, fl)
		end
		return judgeRally(player, req, reply, fl)
	end)
	Players.PlayerRemoving:Connect(function(p)
		lastSwing[p], lastSeq[p] = nil, nil
		if servePlayer == p then
			servePlayer = nil
		end
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
				setEvent("Your serve: stand behind your end line, press Space to toss, then strike it")
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

	if SC.ShowDiagnostics then
		-- Development-only bridge for Studio test scripts (a separate Lua context): live counters and the ball's phase.
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongRallyDebug"
		bridge.OnInvoke = function(cmd: string?)
			if cmd == "reset" then
				for _, t in { saveStats, serveStats, swingStats } do
					for k in t do
						t[k] = 0
					end
				end
			end
			return {
				phase = phase,
				refereePhase = referee.phase,
				hits = referee.hits,
				save = table.clone(saveStats),
				swing = table.clone(swingStats),
				serve = table.clone(serveStats),
				slowMotion = slowMotion ~= nil,
				pendingContact = pendingContact ~= nil,
				incoming = incomingForPlayer(),
				swingUsed = swingUsed,
			}
		end
		bridge.Parent = game:GetService("ServerStorage")
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
		saveStats = saveStats, -- (tests / diagnostics: live counters)
		swingStats = swingStats,
		serveStats = serveStats,
	}
end

return RallyService
