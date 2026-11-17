-- RallyService (server): owns the ONE authoritative ball and runs points end to end.
--   * simulates the ball with BallPhysics at a fixed 240 Hz inside Heartbeat (frame-rate independent),
--   * moves only the invisible gameplay part (BallTemplate.Ball); clients render the cosmetic BallVisual themselves
--     from snapshots (Client/BallView) using the same deterministic simulation,
--   * serving: the PLAYER serves by hand: the ball rests in their free hand, Space (ServeRequest) tosses it from their own
--     spot (validated against the legal region, then the spot is locked), the toss flies at NORMAL speed (2026-11-16
--     pass 3: no serve slow motion), and the player strikes it with a normal swing judged here: a contact inside the
--     toss's contact phase (ServeRules.phase, at release + HitDelay) is a LEGAL serve solved by ShotLaunch.serve; early,
--     late, out of reach or never struck are real faults. The BOT serves automatically,
--   * per physics tick asks the bot's Striker whether it can legally hit, and resolves the player's AUTOMATIC DIVE RETURN
--     (2026-11-16 pass 3): the first legal, in-reach tick of a dive's contact window rolls the outcome once,
--     (DiveReturnChance: a legal defensive return, else a physical mishit),
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
	return remote("BallSnapshot"), remote("ServeRequest"), remote("SwingRequest"), remote("SwingResult"), remote("ChargeStart"), remote("ServeResult")
end

local function finite(n: any): boolean
	return typeof(n) == "number" and n == n and math.abs(n) < 1e10 -- (server time is ~1.8e9)
end

-- arena: ArenaBuilder.load() result. match: MatchState. avatars: AvatarService. bot: the bot Model (or nil).
function RallyService.start(arena, match, avatars, bot: Model?)
	local cfg, world = TableWorld.physics, TableWorld.world
	local snapshotRemote, serveRemote, swingRemote, swingResultRemote, chargeRemote, serveResultRemote = remotes()
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
	-- a judged serve contact still in the (near) future: applied on the physics tick that reaches its time
	local pendingServe: { time: number, velocity: Vector3, spin: Vector3, finish: () -> () }? = nil
	local pressAim: { [Player]: number } = {} -- serve aim locked at the press (-1 .. 1)
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
	-- The stroke ("Forehand" | "Backhand") the player locked when this charge began. A client CHOICE (like the drag), not a
	-- claim: it is only ever one of the two values and is cleared with the press. Recorded and reported; reach does not
	-- depend on it yet (see docs/current-state.md: stance-specific reach is an open decision).
	local pressStroke: { [Player]: string } = {}
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
	local diveUsedHits = -1 -- referee.hits of the ball the player last dived for (one dive per incoming ball)
	-- automatic dive returns: the dive waiting for its contact (one contact per dive and per incoming ball), and counters
	-- (unreachable attempts, deliberate mishits and unexpected solver failures are logged and counted separately)
	local diveArmed: { player: Player, hits: number, serial: number, resolved: boolean }? = nil
	local diveStats = { dives = 0, eligible = 0, returns = 0, returnsLegal = 0, mishits = 0, unreachable = 0, solverFailures = 0 }

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
			pa = pressAck, -- last press processed (a client that predicted slow motion learns the verdict from this)
			st = tossState and phase == "toss" and { p = tossState.position, v = tossState.velocity, t = tossState.time + timeOffset } or nil, -- the toss as it left the hand (server time)
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
		tossState, pendingServe = nil, nil
		servePosture = nil
		table.clear(pressAim)
		ball = BallPhysics.newState(if side == "Player" then (playerHandPoint("hold") or Config.Layout.ServeBall.Player) else Config.Layout.ServeBall[side])
		ball.resting = true
		timeOffset = workspace:GetServerTimeNow() - ball.time
		table.clear(history)
		incomingState, swingUsed = nil, false
		table.clear(pressAt) -- a charge never carries over into the next point
		table.clear(pressStroke)
		diveUsedHits = -1
		diveArmed = nil
		clearSlowMotion()
		ArenaBuilder.moveBall(arena, ball.position)
		readyAt = os.clock() + Config.Timing.ServeReadyDelay
		snapshot()
	end

	local function endPoint(outcome)
		phase = "dead"
		pendingServe = nil
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
		if MovementService.getDive(player) then
			return false, "still recovering from the dive"
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
		pendingServe = nil
		clearSlowMotion() -- (nothing slows a serve; a leftover rally slow motion never survives into one)
		swingUsed = false
		pressAt[player], pressStroke[player], pressAim[player] = nil, nil, nil -- a press from before the toss never counts
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

	-- ===== dive (Config.Movement.Dive*): MovementService owns the lunge; RallyService gates it and plays the return =====
	-- A dive may start only during a live rally and once per incoming ball (MovementService asks through this gate, as its
	-- last check, so a "yes" means the dive starts). Diving COMMITS (2026-11-16 pass 3): any charge is cancelled (a stale
	-- release can never become a second shot), the incoming ball's manual swing is spent, and the dive is armed for one
	-- automatic contact (tryDiveContact, per physics tick).
	MovementService.setDiveGate(function(player: Player): (boolean, string?)
		if avatars.getSeatedPlayer() ~= player then
			return false, "not seated"
		end
		if phase ~= "live" then
			return false, "no live rally"
		end
		if diveUsedHits == referee.hits then
			return false, "already dived for this ball"
		end
		diveUsedHits = referee.hits
		pressAt[player], pressStroke[player] = nil, nil
		if slowMotion and slowMotion.player == player then
			endSlowMotion("dive") -- (before the lunge's speed is computed: the dive runs at normal speed)
			snapshot()
		end
		if incomingForPlayer() then
			swingUsed = true -- the dive is this ball's one contact attempt
		end
		diveStats.dives += 1
		diveArmed = { player = player, hits = referee.hits, serial = diveStats.dives, resolved = false }
		return true
	end)

	-- The reach a MANUAL swing by `player` gets right now: the stroke's anchor and radius; nil + a reason during a dive
	-- (its return is automatic, and the get-up allows no contact). Server positions only.
	-- `claimed` (2026-11-16 pass 3): the root position the client reports with its press / release. The server sees a
	-- client-owned character ~0.1 s late, so a moving player's anchor (and with it the contact window's ideal moment, the
	-- timing error and the stretch) differed from what the player saw. The claim is used only when it lies within
	-- MaxRootMismatch studs (horizontally) of the server's own view; otherwise the server's position is used.
	local function reachFor(player: Player, stroke: string?, claimed: any): (Vector3?, number, string?)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return nil, SC.PaddleReach, "no character"
		end
		local _, diving = MovementService.diveContact(player)
		if diving then
			return nil, SC.PaddleReach, "diving (the dive plays its own return)"
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

	-- AUTOMATIC DIVE RETURN: during the armed dive's contact window, the first tick at which the ball is legally playable
	-- by the player (the referee: their turn, exactly one bounce on their half) and inside the dive-extended reach is the
	-- contact. The outcome is rolled ONCE here (never per tick, never per request): a legal defensive return
	-- (ShotLaunch.diveReturn) or a physical mishit. If the window closes first, the attempt was unreachable.
	local function tryDiveContact(s): boolean
		local d = diveArmed
		if not d or d.resolved then
			return false
		end
		local player = d.player
		if player.Parent == nil or avatars.getSeatedPlayer() ~= player then
			diveArmed = nil
			return false
		end
		local dir, diving = MovementService.diveContact(player)
		if not diving or not dir then
			d.resolved = true
			diveStats.unreachable += 1
			log(("dive %d: unreachable (no playable ball inside the dive's reach during its contact window)"):format(d.serial))
			setEvent("Dive: the ball was out of reach")
			return false
		end
		if not referee:canHit("Player") then
			return false -- not yet bounced on our half / not our turn: keep waiting inside the window
		end
		local root = rootOf(player.Character)
		if not root then
			return false
		end
		local p, v = s.position, s.velocity
		local right = Vector3.new(root.CFrame.RightVector.X, 0, root.CFrame.RightVector.Z)
		local stroke = if right.Magnitude > 1e-3 and dir:Dot(right.Unit) < -0.2 then "Backhand" else "Forehand"
		local anchor, reach = ShotInput.reachFor(root.CFrame, SC, stroke, dir)
		if not anchor or not ShotInput.inReach(p, anchor, reach) then
			return false
		end
		local endZ = TableWorld.endLineZ("Player")
		if v.Y > 0 and p.Z <= endZ then
			return false -- still rising over the table: same rule as every contact window (falling, or past the end line)
		end
		local tw = TableWorld.world.tableBox
		if p.Y < Config.Layout.SurfaceY + Config.Ball.Radius and p.X > tw.minX and p.X < tw.maxX and p.Z > tw.minZ and p.Z < tw.maxZ then
			return false -- under / inside the table: never through it
		end
		d.resolved = true
		diveStats.eligible += 1
		local M = Config.Movement
		local roll = rng:NextNumber()
		local launch
		if roll < M.DiveReturnChance then
			launch = ShotLaunch.diveReturn(p, "Player")
			diveStats.returns += 1
			if launch.ok then
				diveStats.returnsLegal += 1
			else
				diveStats.solverFailures += 1
				warn(("[Rally] dive %d: return solver found no legal path (%s, predicted %s) - unexpected"):format(d.serial, launch.how, launch.result))
			end
		else
			local kinds = M.DiveMishitKinds
			local kind = kinds[rng:NextInteger(1, #kinds)]
			launch = ShotLaunch.diveMishit(p, kind, if p.X >= TableWorld.center.X then 1 else -1, "Player")
			diveStats.mishits += 1
		end
		swingUsed = true
		pressAt[player], pressStroke[player] = nil, nil
		log(("dive %d: contact %.2f above the table, roll %.3f -> %s (predicted %s)"):format(d.serial, p.Y - Config.Layout.SurfaceY, roll, launch.how, launch.result))
		strike("Player", launch.velocity, launch.spin)
		local saved = roll < M.DiveReturnChance
		setEvent(if saved then "Dive save! (automatic return)" else ("Dive mishit: %s"):format(launch.how))
		swingResultRemote:FireClient(player, {
			seq = -2,
			dive = true,
			result = if saved then "dive" else "diveMishit",
			reason = if saved then "dive save" else launch.how,
			contact = p,
			roll = roll,
		})
		return true
	end

	-- Per physics tick (240 Hz): the bot's serve strike / the player's judged serve contact, then paddle contacts.
	local historyLength = SC.MaxLatencyCompensation + 0.05
	local function onTick(s)
		if phase == "live" or phase == "toss" then
			table.insert(history, BallPhysics.copyState(s))
			while #history > 0 and s.time - history[1].time > historyLength do
				table.remove(history, 1)
			end
		end
		if phase == "toss" then
			if serveSide == "Bot" then
				local holdY = Config.Layout.ServeBall.Bot.Y
				if s.velocity.Y < 0 and s.position.Y <= holdY then
					local v, w = serveShot("Bot")
					strike("Bot", v, w)
				end
			elseif pendingServe and s.time >= pendingServe.time - 1e-6 then
				-- the paddle meets the toss now (the contact judged at the release, HitDelay ago)
				local ps = pendingServe
				pendingServe = nil
				strike("Player", ps.velocity, ps.spin)
				ps.finish()
			end
		elseif phase == "live" then
			if diveArmed and not diveArmed.resolved and tryDiveContact(s) then
				return
			end
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
				pressAt[f.player] = nil
				endSlowMotion(if phase ~= "live" then "phase over" else "player gone")
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

	-- "I started charging": remember WHEN (server time), trusting the client's clock only within
	-- MaxLatencyCompensation of the moment the message arrived. One small message per press; nothing per frame.
	-- Charge slow motion: may this press slow the rally? Decided ONLY here, from the server's own ball history and the
	-- character's replicated position. Returns nothing; starts slow motion when the press qualifies.
	local function trySlowMotion(player: Player, pressT: number, claimedRoot: any)
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
		local anchor, reach = reachFor(player, pressStroke[player], claimedRoot)
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
		local window = ShotInput.contactWindow(inc, anchor, reach, false)
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
		slowMotion.kind = "charge"
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
			pressAt[player], pressStroke[player] = nil, nil
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
		if serveSide == "Player" and (phase == "windup" or phase == "toss") then
			-- the player's serve: a FRESH press after the toss began (a button held from before never counts), with the
			-- aim locked now (the cursor's later movement only shapes the spin)
			if servePlayer ~= player or swingUsed or req.t < serveBeganServer - SC.MaxLatencyCompensation then
				return
			end
			pressAt[player] = math.clamp(req.t, serverNow - SC.MaxLatencyCompensation, serverNow)
			pressStroke[player] = ServeRules.postureStroke(servePosture) -- the serve stroke is the locked posture's
			pressAim[player] = if finite(req.aim) then math.clamp(req.aim, -1, 1) else 0
			pressAck = req.t
			snapshot()
			return
		end
		pressAt[player] = math.clamp(req.t, serverNow - SC.MaxLatencyCompensation, serverNow)
		pressStroke[player] = if req.stroke == "Backhand" then "Backhand" else "Forehand"
		pressAck = req.t
		trySlowMotion(player, pressAt[player], req.root)
		snapshot() -- always answer: slow or normal (a client that predicted slow motion corrects itself from this)
	end)

	-- The player's launch from a judged contact: spin from the drag, the deterministic timing error (offset from the
	-- ideal moment), stretch (distance from the stroke's anchor) and the SMASH check, all through the shared ShotLaunch
	-- (the arrow runs the same code). Returns the launch, the spin used, whether it was a smash, and the stretch.
	local function playerLaunch(contact: BallPhysics.State, power: number, dx: number, dy: number, quality: string, offset: number, stroke: string, anchor: Vector3)
		local top, side = ShotInput.dragToSpin(dx, dy) -- clamped to MaxSpin
		local p = contact.position
		local smash = (quality == "clean" or quality == "weak") and ShotInput.smashEligible(p, power)
		local opts: ShotLaunch.Options = {
			hitter = "Player",
			stroke = stroke,
			timing = ShotInput.timingValue(offset),
			stretch = Vector2.new(p.X - anchor.X, p.Z - anchor.Z).Magnitude / SC.PaddleReach,
			smash = smash,
		}
		if quality == "weak" and not smash then
			top, side = top * SC.WeakSpinFactor, side * SC.WeakSpinFactor
			opts.speedFactor = SC.WeakSpeedFactor
		end
		if quality == "weak" and (SC.WeakAimError or 0) > 0 then -- (legacy random error; 0 = off)
			local e = SC.WeakAimError
			opts.aimOffset = Vector3.new(rng:NextNumber(-e, e), 0, rng:NextNumber(-e, e))
		end
		return ShotLaunch.compute(p, power, top, side, opts), top, side, smash, opts.stretch :: number
	end

	-- The player's strike at their own toss (2026-11-16 pass 3). Judged on the server's own simulation of the toss at the
	-- validated release time: the paddle meets the ball HitDelay later, and if that is inside the toss's CONTACT PHASE
	-- (ServeRules.phase: falling, in the height band, in the locked stroke's reach) the serve is LEGAL, launched by
	-- ShotLaunch.serve (solved before the contact, never steered). The contact is applied on the physics tick that reaches
	-- it (pendingServe) or, when latency put it in the past, by rewinding to it and re-simulating. One swing per toss.
	local serveStats = { swings = 0, legal = 0, weak = 0, misses = 0, solverFailures = 0 }
	local function judgeServe(player: Player, req, reply)
		if swingUsed then
			return reply("rejected", "already swung at this toss")
		end
		swingUsed = true
		serveStats.swings += 1
		local serverNow = workspace:GetServerTimeNow()
		local release = math.clamp(req.t, serverNow - SC.MaxLatencyCompensation, serverNow)
		local pressed = pressAt[player]
		local stroke = ServeRules.postureStroke(servePosture) -- the locked posture decides the serve stroke (never the cursor)
		local aim = pressAim[player] or 0
		pressAt[player], pressStroke[player], pressAim[player] = nil, nil, nil
		local hold = if pressed then math.clamp(release - pressed, 0, 5) else 0
		local power = ShotLaunch.powerFromHold(hold)
		local info: { [string]: any } = { hold = hold, power = power, stroke = stroke, aim = aim, serve = true }
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
		local simRelease = release - timeOffset
		local toss = tossState :: BallPhysics.State
		local window = ServeRules.phase(toss, anchor, SC.PaddleReach)
		local rel = simRelease - toss.time
		local quality, why = ServeRules.classify(rel, window)
		info.offset, info.anchor = if window then rel - window.ideal else 0, anchor
		info.window = window and { enter = window.enter - rel, ideal = window.ideal - rel, exit = window.exit - rel } or nil
		if quality == "miss" then
			return missed(why)
		end
		-- the ball where the paddle meets it
		local contactTime = simRelease + Config.Serve.HitDelay
		local contact
		if contactTime <= ball.time then
			contact = stateAt(contactTime)
		else
			contact = BallPhysics.copyState(ball)
			while contact.time < contactTime - 1e-6 do
				BallPhysics.tick(contact, cfg, world)
			end
		end
		local top, side = ShotInput.dragToSpin(req.dx, req.dy)
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
		local function finish()
			arena.Ball.Position = ball.position
			snapshot()
			setEvent(("You serve (%s %s, %s, power %d%%, aim %+.2f): %s"):format(string.lower(stroke), quality, why, math.floor(power * 100 + 0.5), aim, shot.how))
		end
		if contact.time <= ball.time + 1e-6 then
			local catchUp = math.max(ball.time - contact.time, 0)
			contact.accumulator = 0
			ball = contact
			ball.resting = false
			strike("Player", shot.velocity, shot.spin)
			while catchUp > 1e-6 and phase == "live" do
				local chunk = math.min(catchUp, cfg.fixedStep * cfg.maxStepsPerUpdate * 0.9)
				advance(chunk)
				catchUp -= chunk
			end
			finish()
		else
			pendingServe = { time = contact.time, velocity = shot.velocity, spin = shot.spin, finish = finish }
		end
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

		-- The player's own serve toss.
		if serveSide == "Player" and (phase == "windup" or phase == "toss") and servePlayer == player then
			return judgeServe(player, req, reply)
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
			local stroke = pressStroke[player] or "Forehand"
			pressAt[player], pressStroke[player] = nil, nil
			local hold = if pressed then math.clamp(release - pressed, 0, CF.MaxDuration + SC.MaxLatencyCompensation) else 0
			local power = ShotLaunch.powerFromHold(hold)
			local simRelease = f.startSimTime + math.max(release - f.startServer, 0) * CF.TimeScale
			local inc = incomingState :: BallPhysics.State
			local anchor, reach, refuse = reachFor(player, stroke, req.root)
			if not anchor then
				swingUsed = true
				endSlowMotion(refuse or "no character")
				snapshot()
				setEvent("Swing missed: " .. (refuse or "no character"))
				return reply("miss", refuse or "no character")
			end
			local window = ShotInput.contactWindow(inc, anchor, reach, false)
			local rel = simRelease - inc.time
			local quality, why, offset = ShotInput.classify(rel, window)
			local info = {
				offset = offset,
				lag = serverNow - release,
				hold = hold,
				power = power,
				anchor = anchor,
				stroke = stroke,
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
			local shot, top, side, smash, stretch = playerLaunch(contact, power, dx, dy, quality, offset, stroke, anchor :: Vector3)
			endSlowMotion("released")
			local catchUp = math.max(ball.time - contact.time, 0)
			contact.accumulator = 0
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
			setEvent(("You hit (%s %s%s, %s, power %d%%): %s"):format(string.lower(stroke), if smash then "SMASH " else "", quality, why, math.floor(power * 100 + 0.5), shot.how))
			info.aim, info.topspin, info.sidespin, info.solve = shot.aim, top, side, shot.how
			info.contact, info.velocity, info.spin = contact.position, shot.velocity, shot.spin
			info.smash, info.stretch, info.yawError, info.pitchError = smash, stretch, shot.yawError, shot.pitchError
			reply(quality, why, info)
			return
		end

		if phase ~= "live" or not incomingForPlayer() or not incomingState then
			return reply("rejected", "no ball to hit")
		end
		if swingUsed then
			return reply("rejected", "already swung at this ball")
		end
		local anchor, reach, refuse = reachFor(player, pressStroke[player], req.root)
		if not anchor then
			if refuse and refuse ~= "no character" then
				-- recovering from a dive: the swing is spent, no contact (no free retries during the get-up)
				swingUsed = true
				pressAt[player], pressStroke[player] = nil, nil
				setEvent("Swing missed: " .. refuse)
				return reply("miss", refuse)
			end
			return reply("rejected", "no character")
		end
		swingUsed = true

		-- When did the player release? Trust the client's clock only within MaxLatencyCompensation of now.
		local serverNow = workspace:GetServerTimeNow()
		local release = math.clamp(t, serverNow - SC.MaxLatencyCompensation, serverNow)
		-- Charge, measured by the server: release minus the validated press time (no press on record = no charge).
		local pressed = pressAt[player]
		local stroke = pressStroke[player] or "Forehand"
		pressAt[player], pressStroke[player] = nil, nil
		local hold = if pressed then math.max(release - pressed, 0) else 0
		local power = ShotLaunch.powerFromHold(hold)
		local simRelease = release - timeOffset
		local inc = incomingState :: BallPhysics.State
		local window = ShotInput.contactWindow(inc, anchor, reach, false)
		local quality, why, offset = ShotInput.classify(simRelease - inc.time, window)
		local rel = simRelease - inc.time
		local info = { -- (diagnostics: the server's view, shown by the client panel)
			offset = offset,
			lag = serverNow - release,
			hold = hold,
			power = power,
			anchor = anchor,
			stroke = stroke,
			window = window and { enter = window.enter - rel, ideal = window.ideal - rel, exit = window.exit - rel } or nil,
		}
		if quality == "miss" then
			setEvent("Swing missed: " .. why)
			return reply("miss", why, info)
		end

		-- Contact: where the ball actually was at the release moment.
		local contact = stateAt(simRelease)
		local shot, top, side, smash, stretch = playerLaunch(contact, power, dx, dy, quality, offset, stroke, anchor :: Vector3)
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
		setEvent(("You hit (%s %s%s, %s, power %d%%): %s"):format(string.lower(stroke), if smash then "SMASH " else "", quality, why, math.floor(power * 100 + 0.5), how))
		info.aim, info.topspin, info.sidespin, info.solve = shot.aim, top, side, how
		info.contact, info.velocity, info.spin = contact.position, shot.velocity, shot.spin
		info.smash, info.stretch, info.yawError, info.pitchError = smash, stretch, shot.yawError, shot.pitchError
		reply(quality, why, info)
	end)
	Players.PlayerRemoving:Connect(function(p)
		lastSwing[p] = nil
		pressAt[p], pressStroke[p], pressAim[p] = nil, nil, nil
		lastPressMsg[p] = nil
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
				for k in diveStats do
					diveStats[k] = 0
				end
				for k in serveStats do
					serveStats[k] = 0
				end
			end
			return {
				phase = phase,
				refereePhase = referee.phase,
				hits = referee.hits,
				dive = table.clone(diveStats),
				serve = table.clone(serveStats),
				slowMotion = slowMotion ~= nil,
				diveArmed = diveArmed ~= nil and not diveArmed.resolved,
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
		diveStats = diveStats, -- (tests / diagnostics: live counters)
		serveStats = serveStats,
	}
end

return RallyService
