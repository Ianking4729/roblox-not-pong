--!strict
-- ShotLaunch: the shot model (CLICK-AND-FLICK since 2026-11-17). Pure and deterministic: the server uses it for the real
-- shot, the client for its post-flick prediction, so both get the identical launch from the identical inputs.
-- No Instances, no input, no networking.
--
--   power (0..1, from the flick's speed) -> launch speed + a calibration depth
--   spin (from the flick's direction)    -> topspin / sidespin, applied in FULL to the launch
--   base aim + profile (locked at click) -> the calibration point's side and the drive / arc speed, depth, clearance
--   contact point                        -> where the flight starts
--
-- The launch DIRECTION and ELEVATION are calibrated so that a shot of this power, with only part of its spin
-- (Top/Back/SidespinCompensation), would land at a point on the opponent's half: on the side the BASE AIM locked at the
-- click points to (opts.aim; without it the old default FollowLateral direction), deeper for more power
-- (Min/MaxShotDepth) and for a higher-arc profile (Config.Prep). Then the ball is launched with ALL of its spin and flies
-- by the real physics, so spin genuinely changes the path and the landing (topspin dips and lands shorter, backspin
-- floats longer, sidespin curves sideways) around the base aim, and a shot can miss. Nothing is steered after contact.
--
-- TIMING ERROR (2026-11-15): after the calibration, the launch direction and elevation are turned by a DETERMINISTIC
-- error from the contact timing (opts.timing, ShotInput.timingValue), scaled by the shot's risk (power, stretch, smash;
-- Config.ShotControl.Error* / Timing*). Early = across the body and higher (long); late = the other way and lower (net).
-- The client's post-flick prediction calls compute with the same timing, so it shows exactly this error; nothing is random.
-- SMASH (opts.smash): faster, deeper, half the spin, SmashTimingMultiplier x the full-power risk.
-- PLAYER SERVE (ShotLaunch.serve) and the EMERGENCY SAVE lob (emergencyLob) are solved here too, with the same physics.

local Config = require(script.Parent:WaitForChild("Config"))
local BallPhysics = require(script.Parent:WaitForChild("BallPhysics"))
local ShotSolver = require(script.Parent:WaitForChild("ShotSolver"))
local TableWorld = require(script.Parent:WaitForChild("TableWorld"))
local ServeRules = require(script.Parent:WaitForChild("ServeRules"))

local ShotLaunch = {}

export type Launch = {
	velocity: Vector3,
	spin: Vector3,
	aim: Vector3, -- the calibration point (where a partly-compensated shot would land); NOT a player-chosen target
	speed: number, -- requested horizontal speed
	how: string, -- "calibrated" | "calibrated (low net clearance)" | "spin-free calibration" | "fallback guess"
	risk: number, -- timing-error scale used (0 = no error)
	yawError: number, -- degrees the direction was turned (+ = toward the hitter's left)
	pitchError: number, -- degrees the elevation was changed (+ = higher)
}

export type PathResult = {
	kind: string, -- "ok" (lands on the opponent's half) | "net" | "own" (hits the hitter's own half) | "out"
	position: Vector3, -- the first contact (or the last simulated point)
	time: number, -- seconds of flight to that point
}

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Horizontal launch speed for a power.
-- RALLY PACE (Config.RallyPace, disabled by default): the speed multiplier for return number `returnIndex` of the point
-- (1 = the first return after the serve). `baseSpeed` (optional) applies the overall cap: the escalated speed never exceeds
-- MaxSpeed (a shot already faster than that is left at its baseline). Returns 1 when disabled.
-- (Pass 12) The rally's escalation STAGE as a percent (0 .. MaxPercent) for return number `returnIndex`, from the same
-- schedule as rallyPaceFactor but without any per-shot speed cap: the source of the trail's rally colours. 0 when the
-- pace experiment is off.
function ShotLaunch.rallyPacePercent(returnIndex: number): number
	local R = Config.RallyPace
	if not R or not R.Enabled or returnIndex ~= returnIndex then
		return 0
	end
	return math.clamp((returnIndex - R.FreeReturns) * R.StepPercent, 0, R.MaxPercent)
end

function ShotLaunch.rallyPaceFactor(returnIndex: number, baseSpeed: number?): number
	local R = Config.RallyPace
	if not R or not R.Enabled or returnIndex ~= returnIndex then
		return 1
	end
	local extra = math.clamp((returnIndex - R.FreeReturns) * R.StepPercent, 0, R.MaxPercent) / 100
	local f = 1 + extra
	if baseSpeed and baseSpeed > 0 and R.MaxSpeed then
		f = math.max(1, math.min(f, R.MaxSpeed / baseSpeed))
	end
	return f
end

function ShotLaunch.speedFor(power: number): number
	local S = Config.ShotControl
	return lerp(S.MinShotSpeed, S.MaxShotSpeed, math.clamp(power, 0, 1))
end

-- The default calibration point on `opponent`'s half for a shot of `power` from `contact` (`depthOverride`: a fixed
-- depth instead of the power's, used by smashes and dive returns).
function ShotLaunch.aimPoint(contact: Vector3, power: number, opponent: string?, offset: Vector3?, depthOverride: number?): Vector3
	local S = Config.ShotControl
	local side = opponent or "Bot"
	local c = TableWorld.center
	local depth = depthOverride or lerp(S.MinShotDepth, S.MaxShotDepth, math.clamp(power, 0, 1))
	local maxX = math.max(TableWorld.halfWidth - S.LateralMargin, 0)
	local x = math.clamp((contact.X - c.X) * S.FollowLateral, -maxX, maxX)
	local p = TableWorld.pointOnHalf(side, depth, x)
	if offset then
		p += Vector3.new(offset.X, 0, offset.Z)
		-- keep it on the half (inside the lines, past the net)
		local hl = TableWorld.halfLength
		local toward = TableWorld.towardSide(side)
		local d = math.clamp((p.Z - c.Z) * toward, 1, hl - 0.5)
		p = Vector3.new(math.clamp(p.X, c.X - maxX, c.X + maxX), p.Y, c.Z + toward * d)
	end
	return p
end

export type Options = {
	hitter: string?, -- default "Player"
	speedFactor: number?, -- weak contacts: launch slower
	aimOffset: Vector3?, -- (legacy) offset of the calibration point
	timing: number?, -- ShotInput.timingValue of the release (-2..2); nil = no timing error
	stretch: number?, -- contact distance from the paddle anchor / reach (0..1+)
	stroke: string?, -- "Forehand" | "Backhand": which way "across the body" is
	smash: boolean?,
	-- click-and-flick (2026-11-17): the base aim locked at the click. nil = the old default direction (FollowLateral)
	aim: number?, -- -1 .. 1 across the opponent's half, as the HITTER sees it (+ = their right)
	profile: number?, -- 0 (low drive) .. 1 (high arc)
}

-- The lateral world-X offset for a base aim (-1..1, the hitter's own left/right) on the opponent's half. The hitter at
-- the Player end faces -Z (their right = world +X); at the Bot end their right is -X.
function ShotLaunch.aimLateral(aim: number, hitter: string?): number
	local S, P = Config.ShotControl, Config.Prep
	local maxX = math.max(TableWorld.halfWidth - S.LateralMargin, 0)
	local rightIsPlusX = (hitter or "Player") == "Player"
	local x = math.clamp(aim, -1, 1) * maxX * P.AimLateral
	return if rightIsPlusX then x else -x
end

local function ramp(x: number, from: number): number
	return math.clamp((x - from) / math.max(1 - from, 1e-3), 0, 1)
end

-- The timing-error scale for a shot (see Config.ShotControl.Error*).
function ShotLaunch.risk(power: number, stretch: number?, smash: boolean?): number
	local S = Config.ShotControl
	local stretchTerm = S.ErrorStretchWeight * ramp(stretch or 0, S.ErrorStretchFrom)
	if smash then
		return (S.ErrorBase + S.ErrorPowerWeight + stretchTerm) * S.SmashTimingMultiplier
	end
	return S.ErrorBase + S.ErrorPowerWeight * ramp(power, S.ErrorPowerFrom) + stretchTerm
end

-- The timing value the error model uses (2026-11-16 pass 3). Inside the CLEAN window (|timing| <= 1) only
-- CleanTimingScale of it counts, so a green release is reliable; in the weak band it ramps continuously from there up to
-- the full value at the band's edge (|timing| = 2), so mistimed contacts keep their full risk.
function ShotLaunch.effectiveTiming(timing: number): number
	local S = Config.ShotControl
	local t = math.clamp(timing, -2, 2)
	local a = math.abs(t)
	local k = math.clamp(S.CleanTimingScale or 1, 0, 1)
	local e = if a <= 1 then a * k else k + (a - 1) * (2 - k)
	return if t < 0 then -e else e
end

-- Turn a launch velocity by `yawDeg` toward the hitter-facing LEFT of its own direction and raise its elevation by
-- `pitchDeg`, keeping the launch speed.
local function turn(v: Vector3, yawDeg: number, pitchDeg: number): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	local h = flat.Magnitude
	if h < 1e-6 then
		return v
	end
	local d = flat / h
	local left = Vector3.yAxis:Cross(d)
	local a = math.rad(yawDeg)
	local dir = d * math.cos(a) + left * math.sin(a)
	local total = math.sqrt(h * h + v.Y * v.Y)
	local elev = math.atan2(v.Y, h) + math.rad(pitchDeg)
	return dir * (total * math.cos(elev)) + Vector3.yAxis * (total * math.sin(elev))
end

-- The launch for a shot from `contact` with `power` (0..1) and spin (rad/s; topspin < 0 = backspin, sidespin sign as
-- ShotSolver: positive curves the ball to ITS left).
function ShotLaunch.compute(contact: Vector3, power: number, topspin: number, sidespin: number, opts: Options?): Launch
	local S = Config.ShotControl
	local cfg = TableWorld.physics
	local hitter = opts and opts.hitter or "Player"
	local opponent = if hitter == "Player" then "Bot" else "Player"
	local smash = opts ~= nil and opts.smash == true
	if smash then
		topspin, sidespin = topspin * S.SmashSpinFactor, sidespin * S.SmashSpinFactor
	end
	-- Topspin plays a faster, flatter-driven shot; backspin a slightly slower, floated one (both scale with the spin).
	local spinFrac = math.clamp(topspin / math.max(S.MaxSpin, 1e-3), -1, 1)
	local spinSpeed = if spinFrac >= 0 then 1 + (S.TopspinSpeedBonus or 0) * spinFrac else 1 + (S.BackspinSpeedPenalty or 0) * spinFrac
	local baseSpeed = if smash then S.SmashSpeed else ShotLaunch.speedFor(power)
	-- the drive / arc profile (Config.Prep): a high arc launches slower for the same landing (a higher flight), lands a
	-- little deeper and asks the calibration for more net clearance
	local P = Config.Prep
	local profile = if opts and opts.profile and not smash then math.clamp(opts.profile, 0, 1) else nil
	local profileSpeed = if profile then lerp(P.DriveSpeedFactor, P.ArcSpeedFactor, profile) else 1
	local speed = baseSpeed * spinSpeed * profileSpeed * (opts and opts.speedFactor or 1)
	local depth = if smash then S.SmashDepth else nil
	if profile then
		depth = math.clamp(lerp(S.MinShotDepth, S.MaxShotDepth, math.clamp(power, 0, 1)) + lerp(P.DriveDepthBonus, P.ArcDepthBonus, profile), 0.2, 0.92)
	end
	local aim = ShotLaunch.aimPoint(contact, power, opponent, opts and opts.aimOffset, depth)
	if opts and opts.aim then
		-- the locked base aim replaces the default direction (spin then bends the real flight around it)
		aim = Vector3.new(TableWorld.center.X + ShotLaunch.aimLateral(opts.aim, hitter), aim.Y, aim.Z)
	end
	local solveOpts: ShotSolver.Options = {
		speed = speed,
		topspin = topspin * (if topspin >= 0 then S.TopspinCompensation else S.BackspinCompensation),
		sidespin = sidespin * S.SidespinCompensation,
		netZ = TableWorld.netZ,
		netTopY = TableWorld.netTopY,
		clearance = if profile then lerp(Config.Rally.NetClearance, P.ArcClearance, profile) else Config.Rally.NetClearance,
		edgeZ = TableWorld.endLineZ(hitter), -- a contact below table height must clear our own table edge
		edgeTopY = Config.Layout.SurfaceY,
		maxTime = 3,
	}
	local how = "calibrated"
	-- (2026-11-16 pass 3: when the partly compensated spin has no solution, the compensation is stepped down in the same
	-- spin direction instead of jumping straight to a spin-free calibration, whose full-spin launch could land far off)
	local ref, compScale = ShotSolver.solveWithSpinFallback(cfg, contact, aim, solveOpts)
	if ref.velocity.Magnitude > 0 and compScale < 1 then
		how = ("calibrated (compensation x%.2f)"):format(compScale)
	end
	if ref.velocity.Magnitude > 0 and not ref.ok then
		how ..= " (low net clearance)"
	end
	local velocity: Vector3
	if ref.velocity.Magnitude > 0 then
		velocity = ref.velocity
	else
		-- No calibration found (e.g. a contact far below the table): a plain drag-free lob guess. The ball still flies
		-- by the real physics; the referee judges wherever it goes.
		local d = aim - contact
		local t = math.max(Vector3.new(d.X, 0, d.Z).Magnitude / speed, 0.2)
		velocity = Vector3.new(d.X / t, (d.Y + 0.5 * cfg.gravity * t * t) / t, d.Z / t)
		how = "fallback guess"
	end
	-- Deterministic errors, decided once at contact (nothing is steered afterwards).
	local risk, yawErr, pitchErr = 0, 0, 0
	if opts and opts.timing then
		local t = ShotLaunch.effectiveTiming(opts.timing)
		risk = ShotLaunch.risk(power, opts.stretch, smash)
		local across = if opts.stroke == "Backhand" then -1 else 1 -- forehand: across the body = toward the left
		yawErr = -t * risk * S.TimingYawDegrees * across -- early (t < 0): across the body
		pitchErr = -t * risk * S.TimingPitchDegrees -- early: higher (long); late: lower (net)
	end
	if yawErr ~= 0 or pitchErr ~= 0 then
		velocity = turn(velocity, yawErr, pitchErr)
	end
	local spin = ShotSolver.spinVector(velocity, topspin, sidespin) -- the FULL spin
	return {
		velocity = velocity,
		spin = spin,
		aim = aim,
		speed = speed,
		how = how .. (if smash then " (smash)" else ""),
		risk = risk,
		yawError = yawErr,
		pitchError = pitchErr,
	}
end

-- SAFE SERVE ENVELOPE (2026-11-17; Config.Serve.Envelope). A serve is accepted only if its WHOLE predicted flight,
-- including after the receiver-side bounce, satisfies all of:
--   E1 legal: first table bounce on the server's half, the next on the receiver's half, nothing else in between;
--   E2 inside: the receiver-side bounce lands at least BounceMargin inside the side lines (ball centre), and from there
--      until the ball passes the receiver's end-line plane its centre stays within the side lines minus SideMargin
--      (further bounces on the receiver's half are fine: a slow serve may bounce twice); it may not leave the table
--      area any other way (a floor / table-side contact before the end line = an escape);
--   E3 heading: right after that bounce the sideways speed is at most MaxLateralRatio x the speed toward the end line;
--   E4 playable: the horizontal speed after that bounce is at most MaxReceiveSpeed, and the ball crosses the end-line
--      plane no higher than EndLineMaxHeight above the floor (inside a receiver's reach band).
-- Same physics as the real flight (BallPhysics over TableWorld). Returns ok and the measurements (also used by tests).
export type ServeEnvelope = {
	ok: boolean,
	legal: boolean,
	reason: string,
	second: Vector3?, -- the receiver-side bounce
	ratio: number, -- |sideways| / |toward the end line| right after it
	speed: number, -- horizontal speed right after it
	drift: number, -- sideways travel from that bounce to the end-line plane (extrapolated if it escaped first)
	endX: number?, -- offset from the centre line where it crossed the end-line plane
	endY: number?, -- height above the floor there
	apex: number, -- highest point after the bounce, above the table surface
}

function ShotLaunch.serveEnvelope(contact: Vector3, velocity: Vector3, spin: Vector3, receiver: string?): ServeEnvelope
	local E = Config.Serve.Envelope
	local cfg, world = TableWorld.physics, TableWorld.world
	local recv = receiver or "Bot"
	local server = if recv == "Bot" then "Player" else "Bot"
	local cx, hw = TableWorld.center.X, TableWorld.halfWidth
	local toward = TableWorld.towardSide(recv)
	local netZ, endZ = TableWorld.netZ, TableWorld.endLineZ(recv)
	local floorY, surfaceY = Config.Layout.FloorY, Config.Layout.SurfaceY
	local res: ServeEnvelope = { ok = false, legal = false, reason = "", second = nil, ratio = 0, speed = 0, drift = 0, endX = nil, endY = nil, apex = 0 }
	local s = BallPhysics.newState(contact, velocity, spin)
	local events: { BallPhysics.Event } = {}
	local tableBounces = 0
	local escaped = false
	for _ = 1, math.floor(E.Horizon / cfg.fixedStep) do
		local before = #events
		local prev = s.position
		BallPhysics.tick(s, cfg, world, events)
		for k = before + 1, #events do
			local e = events[k]
			if e.kind == "table" then
				tableBounces += 1
				if tableBounces == 1 and e.surface ~= server then
					res.reason = "first bounce not on the server's half"
					return res
				elseif tableBounces == 2 then
					if e.surface ~= recv then
						res.reason = "bounced twice on the server's half"
						return res
					end
					res.legal = true
					res.second = e.position
					local v = s.velocity
					local along = math.abs(v.Z)
					res.ratio = math.abs(v.X) / math.max(along, 1e-3)
					res.speed = Vector3.new(v.X, 0, v.Z).Magnitude
					res.apex = s.position.Y - surfaceY
				end
			elseif tableBounces < 2 then
				res.reason = if e.kind == "net" or e.kind == "netCord" then "net" else "out before the receiver's bounce"
				return res
			elseif not escaped and (s.position.Z - endZ) * toward < 0 then
				escaped = true -- left the table area (floor / table side) before reaching the end-line plane
			end
		end
		local p = s.position
		if res.second then
			res.apex = math.max(res.apex, p.Y - surfaceY)
			local depth = (p.Z - netZ) * toward -- studs past the net on the receiver's half
			local past = (p.Z - endZ) * toward -- > 0 once beyond the end-line plane
			if past < 0 and depth >= 0 and math.abs(p.X - cx) > hw - E.SideMargin then
				escaped = true
			end
			if escaped and not res.endX then
				-- extrapolate where it would have crossed the end-line plane (for the pre-contact compensation)
				local v = s.velocity
				local remain = math.max(-past, 0)
				local t = remain / math.max(math.abs(v.Z), 1)
				res.endX = p.X + v.X * t - cx
				res.endY = nil
				break
			end
			if (prev.Z - endZ) * toward < 0 and past >= 0 then
				res.endX, res.endY = p.X - cx, p.Y - floorY
				break
			end
			if s.resting then
				break -- a slow serve that stopped on the receiver's half: never escaped
			end
		end
	end
	if not res.legal then
		res.reason = "no receiver-side bounce"
		return res
	end
	local second = res.second :: Vector3
	res.drift = if res.endX then (res.endX + cx) - second.X else 0
	if math.abs(second.X - cx) > hw - E.BounceMargin then
		res.reason = "bounce too near the side line"
	elseif escaped then
		res.reason = "escapes over the side line"
	elseif res.ratio > E.MaxLateralRatio then
		res.reason = "heads sideways after the bounce"
	elseif res.speed > E.MaxReceiveSpeed then
		res.reason = "too fast to receive"
	elseif res.endY and res.endY > E.EndLineMaxHeight then
		res.reason = "too high at the end line"
	else
		res.ok = true
		res.reason = "safe"
	end
	return res
end

-- PLAYER SERVE (Config.Serve; 2026-11-16 pass 3, envelope 2026-11-17). Called once, when the paddle has met the falling
-- toss inside its contact phase (ServeRules). Solves a serve with the shared physics, before the ball is struck (nothing
-- is steered afterwards): second bounce aimed by `aim` (across) and `power` (depth = pace), first bounce on the server's
-- half on the way there, flown with the requested spin (ShotSolver.solveServe simulates the world with it, so spin
-- genuinely changes the flight and the kick). Every candidate must pass the SAFE SERVE ENVELOPE above. Order of attempts:
--   1. the requested spin, aimed as asked; then the same spin with the aimed second bounce shifted against the predicted
--      post-bounce drift (CompensationSteps times): the curve stays, the serve no longer escapes sideways;
--   2. sidespin reduced along SideSpinLadder (topspin / backspin kept), each with the same compensation;
--   3. the aim eased toward the centre without sidespin; 4. a spin-free centre serve (always safe in testing).
-- Past SolveBudget seconds the solve skips to step 4. Results are cached by quantized inputs and re-validated against the
-- exact contact before reuse. Returns the launch plus ok (false only if every attempt failed: logged by the server).
export type ServeLaunch = Launch & { ok: boolean, spinScale: number, firstBounce: Vector3?, secondBounce: Vector3?, envelope: ServeEnvelope? }

local serveCache: { [string]: { velocity: Vector3, spin: Vector3, how: string, spinScale: number, first: Vector3?, second: Vector3? } } = {}
local serveCacheSize = 0
ShotLaunch.serveStats = { calls = 0, cacheHits = 0, budgetFallbacks = 0, maxMs = 0, lastMs = 0 }

function ShotLaunch.serve(contact: Vector3, power: number, topspin: number, sidespin: number, aim: number, quality: string?): ServeLaunch
	local S = Config.Serve
	local cfg, world = TableWorld.physics, TableWorld.world
	local t0 = os.clock()
	local stats = ShotLaunch.serveStats
	stats.calls += 1
	power = math.clamp(power, 0, 1)
	aim = math.clamp(aim, -1, 1)
	local base = if quality == "weak" then S.WeakDepthFactor else 1
	local netZ = TableWorld.netZ
	local towardBot = TableWorld.towardSide("Bot")
	local maxFirstX = TableWorld.halfWidth - 1.5
	local maxTargetX = math.max(TableWorld.halfWidth - S.LateralMargin, 0)
	local cx = TableWorld.center.X
	local solveOpts = S.SolveCost
	-- (Pass 12) contacts outside the table's width (the wider serving area) get WideSolveBudgetExtra more: measured, some
	-- strong-sidespin serves from the widest corners ran out of the normal budget although a legal choice existed
	local wide = math.abs(contact.X - TableWorld.center.X) > TableWorld.halfWidth
	local deadline = t0 + S.SolveBudget + (if wide then (S.WideSolveBudgetExtra or 0) else 0)

	local function finish(out: ServeLaunch): ServeLaunch
		local ms = (os.clock() - t0) * 1000
		stats.lastMs = ms
		stats.maxMs = math.max(stats.maxMs, ms)
		return out
	end
	local function launch(v: Vector3, w: Vector3, how: string, spinScale: number, target: Vector3, first: Vector3?, env: ServeEnvelope?): ServeLaunch
		return {
			velocity = v,
			spin = w,
			aim = target,
			speed = Vector3.new(v.X, 0, v.Z).Magnitude,
			how = how,
			risk = 0,
			yawError = 0,
			pitchError = 0,
			ok = env ~= nil and env.ok,
			spinScale = spinScale,
			firstBounce = first,
			secondBounce = env and env.second,
			envelope = env,
		}
	end

	-- cache (quantized key; the hit is re-validated with the exact contact)
	local q = function(x: number, step: number): number
		return math.floor(x / step + 0.5)
	end
	local key = table.concat({
		q(contact.X, 0.25), q(contact.Y, 0.25), q(contact.Z, 0.25), q(power, 0.02), q(topspin, 2), q(sidespin, 2), q(aim, 0.02), quality or "clean",
	}, ",")
	local cached = serveCache[key]
	if cached then
		local env = ShotLaunch.serveEnvelope(contact, cached.velocity, cached.spin)
		if env.ok then
			stats.cacheHits += 1
			return finish(launch(cached.velocity, cached.spin, cached.how .. " (cached)", cached.spinScale, cached.second or contact, cached.first, env))
		end
	end
	local function remember(out: ServeLaunch)
		if serveCacheSize > 256 then
			table.clear(serveCache)
			serveCacheSize = 0
		end
		serveCache[key] = { velocity = out.velocity, spin = out.spin, how = out.how, spinScale = out.spinScale, first = out.firstBounce, second = out.secondBounce }
		serveCacheSize += 1
	end

	local function firstBounceFor(target: Vector3, depth: number): Vector3
		local fz = TableWorld.center.Z + TableWorld.towardSide("Player") * TableWorld.halfLength * depth
		local f = math.clamp((contact.Z - fz) / math.max(contact.Z - target.Z, 1e-3), 0, 1)
		local fx = math.clamp(contact.X + (target.X - contact.X) * f, cx - maxFirstX, cx + maxFirstX)
		return Vector3.new(fx, TableWorld.landingY, fz)
	end
	-- One attempt toward `target` with this spin: bisection on the speed, then a coarse scan. Returns the first candidate
	-- inside the envelope, else the envelope of the last legal candidate (for the drift compensation).
	local function attempt(target: Vector3, top: number, side: number): (ShotSolver.Shot?, Vector3?, ServeEnvelope?)
		local wantDepth = (target.Z - netZ) * towardBot
		local first = firstBounceFor(target, S.FirstBounceDepth)
		local shot = ShotSolver.solveServe(cfg, world, contact, first, {
			speed = lerp(S.PlayerMinSpeed, S.PlayerMaxSpeed, 0.4 + 0.4 * power),
			minSpeed = S.PlayerMinSpeed,
			maxSpeed = S.PlayerMaxSpeed,
			topspin = top,
			sidespin = side,
			server = "Player",
			receiver = "Bot",
			secondDepth = wantDepth,
			netZ = netZ,
			maxTime = S.SolveFlightTime,
			maxIterations = solveOpts.MaxIterations,
			maxFactors = solveOpts.MaxFactors,
			tolerance = solveOpts.Tolerance,
			maxSteps = solveOpts.BisectSteps,
		})
		local lastEnv: ServeEnvelope? = nil
		if shot.ok then
			local env = ShotLaunch.serveEnvelope(contact, shot.velocity, shot.spin)
			if env.ok then
				return shot, first, env
			end
			if env.legal then
				-- legal but outside the envelope: the caller compensates the drift / reduces the sidespin; the costly scan
				-- below is only needed when the bisection found nothing legal at all
				return nil, nil, env
			end
		end
		-- coarse scan (speed vs depth is not monotonic for some contacts): the safe sample nearest the aimed depth
		local best, bestFirst, bestEnv, bestErr = nil, nil, nil, math.huge
		for _, depth in S.ScanFirstDepths do
			local f = firstBounceFor(target, depth)
			for _, speed in S.ScanSpeeds do
				if os.clock() > deadline then
					return best, bestFirst, bestEnv or lastEnv
				end
				local cand = ShotSolver.solve(cfg, contact, f, {
					speed = speed,
					topspin = top,
					sidespin = side,
					maxTime = S.SolveFlightTime,
					maxIterations = solveOpts.MaxIterations,
					maxFactors = solveOpts.MaxFactors,
					tolerance = solveOpts.Tolerance,
				})
				if cand.ok then
					local env = ShotLaunch.serveEnvelope(contact, cand.velocity, cand.spin)
					if env.ok and env.second then
						local err = math.abs(((env.second :: Vector3).Z - netZ) * towardBot - wantDepth)
						if err < bestErr then
							best, bestFirst, bestEnv, bestErr = cand, f, env, err
						end
						if err < 2.5 then
							return best, bestFirst, bestEnv
						end
					elseif env.legal and not lastEnv then
						lastEnv = env
					end
				end
			end
			if best then
				break
			end
		end
		return best, bestFirst, bestEnv or lastEnv
	end

	local aimedTarget = ServeRules.target(aim, power, base)
	local spinless = topspin == 0 and sidespin == 0
	-- 1 + 2: requested spin, then less sidespin; each with the drift compensation
	local ladder = if sidespin == 0 then { 1 } else S.SideSpinLadder
	for _, sideScale in ladder do
		local target = aimedTarget
		for step = 0, S.CompensationSteps do
			if os.clock() > deadline then
				break
			end
			local shot, first, env = attempt(target, topspin, sidespin * sideScale)
			if shot and env and env.ok then
				local how = "legal serve"
				if sideScale < 1 then
					how ..= (" (sidespin x%.2f)"):format(sideScale)
				end
				if step > 0 then
					how ..= " (curve compensated)"
				end
				local out = launch(shot.velocity, shot.spin, how, sideScale, target, first, env)
				remember(out)
				return finish(out)
			end
			if not env or env.drift == 0 then
				break -- nothing to compensate from: try less sidespin
			end
			-- shift the aimed bounce against the predicted post-bounce drift (kept inside the aim envelope)
			local nx = math.clamp(target.X - env.drift * S.CompensationGain, cx - maxTargetX, cx + maxTargetX)
			if math.abs(nx - target.X) < 0.2 then
				break
			end
			target = Vector3.new(nx, target.Y, target.Z)
		end
		if os.clock() > deadline then
			break
		end
	end
	-- 3: the aim eased toward the centre, no sidespin (the topspin / backspin kept); then (Pass 12, wide serving spots)
	-- half the topspin / backspin at the centre-most aims, before the spin-free centre serve gives up the spin entirely
	if os.clock() <= deadline then
		local tries = { { 0.6, 1 }, { 0.25, 1 }, { 0, 1 }, { 0.25, 0.5 }, { 0, 0.5 } }
		for _, tr in tries do
			if tr[2] < 1 and topspin == 0 then
				break
			end
			local target = ServeRules.target(aim * tr[1], power, base)
			local shot, first, env = attempt(target, topspin * tr[2], 0)
			if shot and env and env.ok then
				local how = if tr[2] < 1 then "legal serve (aim eased, no sidespin, half spin)" else "legal serve (aim eased, no sidespin)"
				local out = launch(shot.velocity, shot.spin, how, 0, target, first, env)
				remember(out)
				return finish(out)
			end
			if os.clock() > deadline then
				break
			end
		end
	end
	-- 5 (Pass 12): the WIDE-ANGLE SCAN. From the widest serving spots close to the end line (about 11 studs outside a side
	-- line, a few behind the end line) only a narrow band of launches is legal AND inside the envelope, which the aimed
	-- first-bounce solve above can miss. A bounded grid of spin-free launches (WideScan: speeds x yaw toward the centre x
	-- pitch; measured ~25-30 ms, found a safe serve at every such spot tested) picks the safe one whose receiver-side
	-- bounce is nearest the aimed spot. Only reached when everything above failed; cached like every other result.
	local function wideScan(): ServeLaunch?
		local W = S.WideScan
		if W then
			local towardCentre = if contact.X < cx then 1 else -1
			local aimed = ServeRules.target(aim, power, base)
			local best: ServeLaunch? = nil
			local bestErr = math.huge
			for _, speed in W.Speeds do
				for yawDeg = 0, W.MaxYaw, W.YawStep do
					for pitchDeg = W.MinPitch, W.MaxPitch, W.PitchStep do
						local yaw, pitch = math.rad(yawDeg) * towardCentre, math.rad(pitchDeg)
						local dir = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), towardBot * math.cos(yaw) * math.cos(pitch))
						local v = dir * speed
						local env = ShotLaunch.serveEnvelope(contact, v, Vector3.zero)
						if env.ok and env.second then
							local err = ((env.second :: Vector3) - aimed).Magnitude
							if err < bestErr then
								bestErr = err
								best = launch(v, Vector3.zero, "legal serve (wide-angle scan)", 0, aimed, nil, env)
							end
						end
					end
				end
			end
			if best then
				remember(best)
				return best
			end
		end
		return nil
	end
	-- (wide spots: the scan before the centre fallback's costlier attempts; elsewhere it stays the last resort)
	if math.abs(contact.X - cx) > TableWorld.halfWidth + (S.WideScanFirstBeyond or 4) then
		local best = wideScan()
		if best then
			return finish(best)
		end
	end
	-- 4: the spin-free centre serve (always found within the budget in testing; the budget does not apply to it)
	if os.clock() > deadline then
		stats.budgetFallbacks += 1
	end
	deadline = math.huge
	for _, depthPower in { 0.5, 0.25, 0.8 } do
		local target = ServeRules.target(0, depthPower, 1)
		local shot, first, env = attempt(target, 0, 0)
		if shot and env and env.ok then
			return finish(launch(shot.velocity, shot.spin, if spinless then "legal serve (centre)" else "legal serve (spin-free centre fallback)", 0, target, first, env))
		end
	end
	do
		local best = wideScan()
		if best then
			return finish(best)
		end
	end
	-- Unexpected: no safe serve from this contact. A plain drag-free guess toward the default first bounce; the ball still
	-- flies by the real physics and the referee judges it (the server logs this separately).
	local first = TableWorld.pointOnHalf("Player", S.FirstBounceDepth, 0)
	local d = first - contact
	local speed = lerp(S.PlayerMinSpeed, S.PlayerMaxSpeed, 0.5)
	local t = math.max(Vector3.new(d.X, 0, d.Z).Magnitude / speed, 0.15)
	local velocity = Vector3.new(d.X / t, (d.Y + 0.5 * cfg.gravity * t * t) / t, d.Z / t)
	return finish({
		velocity = velocity,
		spin = Vector3.zero,
		aim = first,
		speed = speed,
		how = "serve solver failed (fallback guess)",
		risk = 0,
		yawError = 0,
		pitchError = 0,
		ok = false,
		spinScale = 0,
		firstBounce = first,
		secondBounce = nil,
		envelope = nil,
	})
end

-- EMERGENCY SAVE (Config.Emergency; 2026-11-17, replaces the automatic dive return and its mishits). A successful
-- emergency contact is a DEFENSIVE lob, never an attack: the SLOWEST launch speed of Emergency.Speeds (slow to fast)
-- whose flight lands legally AND peaks no higher than MaxApex above the table, toward Depth on the opponent's half,
-- following the locked base aim by AimFollow, with the flick's spin already capped by the caller (SpinFactor / MaxSpin).
-- Each try is a bounded solve; past SolveBudget seconds the remaining (faster, cheaper) speeds aim at the centre. ok =
-- false only when nothing lands legally (an unexpected solver failure: logged by the server, the best attempt still flies
-- physically). Decided once at the contact; nothing is steered afterwards.
export type SaveLaunch = Launch & { ok: boolean, result: string }

local function launchOf(velocity: Vector3, spin: Vector3, aim: Vector3, how: string, ok: boolean, result: string): SaveLaunch
	return {
		velocity = velocity,
		spin = spin,
		aim = aim,
		speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude,
		how = how,
		risk = 0,
		yawError = 0,
		pitchError = 0,
		ok = ok,
		result = result,
	}
end

function ShotLaunch.emergencyLob(contact: Vector3, aim: number, topspin: number, sidespin: number, hitter: string?): SaveLaunch
	local E = Config.Emergency
	local cfg = TableWorld.physics
	local who = hitter or "Player"
	local opponent = if who == "Player" then "Bot" else "Player"
	local c = TableWorld.center
	local surfaceY = Config.Layout.SurfaceY
	local deadline = os.clock() + E.SolveBudget
	local best: SaveLaunch? = nil
	local bestApex = math.huge
	local pts: { Vector3 } = {}
	for _, speed in E.Speeds do
		local follow = if os.clock() > deadline then 0 else E.AimFollow
		local x = math.clamp(ShotLaunch.aimLateral(aim, who) * follow, -(TableWorld.halfWidth - 6), TableWorld.halfWidth - 6)
		local target = TableWorld.pointOnHalf(opponent, E.Depth, x)
		local shot = ShotSolver.solve(cfg, contact, target, {
			speed = speed,
			topspin = topspin,
			sidespin = sidespin,
			netZ = TableWorld.netZ,
			netTopY = TableWorld.netTopY,
			clearance = Config.Rally.NetClearance,
			edgeZ = TableWorld.endLineZ(who),
			edgeTopY = surfaceY,
			maxTime = 2.5,
			maxIterations = 16,
			maxFactors = 1,
			tolerance = 0.2,
		})
		if shot.ok then
			local path = ShotLaunch.predictPath(contact, shot.velocity, shot.spin, pts, 4, who)
			if path.kind == "ok" then
				local apex = -math.huge
				for _, p in pts do
					apex = math.max(apex, p.Y - surfaceY)
				end
				local launch = launchOf(shot.velocity, shot.spin, target, ("emergency save (%.0f studs/s, apex %.1f)"):format(speed, apex), true, "ok")
				if apex <= E.MaxApex then
					return launch -- the slowest legal one under the height cap
				end
				if apex < bestApex then
					best, bestApex = launch, apex
				end
			end
		end
	end
	if best then
		return best -- legal, but every candidate peaked above the cap: the lowest of them
	end
	local target = TableWorld.pointOnHalf(opponent, E.Depth, 0)
	local d = target - contact
	local t = math.max(Vector3.new(d.X, 0, d.Z).Magnitude / E.Speeds[1], 0.2)
	local v = Vector3.new(d.X / t, (d.Y + 0.5 * cfg.gravity * t * t) / t, d.Z / t)
	return launchOf(v, Vector3.zero, target, "emergency save (fallback guess)", false, "fallback")
end
-- Simulate the launched ball through the real world (table, net, table body, floor) until its first contact.
-- Appends sampled positions to `out` (cleared first; one every `every` ticks, plus the start and the end point) and
-- returns what the first contact was. Used by the arrow and by tests; the server simulates the real ball itself.
function ShotLaunch.predictPath(
	contact: Vector3,
	velocity: Vector3,
	spin: Vector3,
	out: { Vector3 }?,
	every: number?,
	hitter: string?
): PathResult
	local cfg, world = TableWorld.physics, TableWorld.world
	local opponent = if (hitter or "Player") == "Player" then "Bot" else "Player"
	local s = BallPhysics.newState(contact, velocity, spin)
	local events: { BallPhysics.Event } = {}
	local stride = every or 2
	if out then
		table.clear(out)
		table.insert(out, contact)
	end
	local n = math.floor(2.5 / cfg.fixedStep)
	for i = 1, n do
		BallPhysics.tick(s, cfg, world, events)
		local e = events[1]
		if e then
			if out then
				table.insert(out, e.position)
			end
			local kind = "out"
			if e.kind == "table" then
				kind = if e.surface == opponent then "ok" else "own"
			elseif e.kind == "net" or e.kind == "netCord" then
				kind = "net"
			end
			return { kind = kind, position = e.position, time = s.time }
		end
		if out and i % stride == 0 then
			table.insert(out, s.position)
		end
		if s.resting then
			break
		end
	end
	if out then
		table.insert(out, s.position)
	end
	return { kind = "out", position = s.position, time = s.time }
end

return ShotLaunch
