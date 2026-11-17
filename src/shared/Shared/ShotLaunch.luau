--!strict
-- ShotLaunch: the CHARGE -> CURVE -> RELEASE shot model. Pure and deterministic: the server uses it for the real shot,
-- the client uses it for the 3D trajectory arrow, so both get the identical launch from the identical inputs.
-- No Instances, no input, no networking.
--
--   power (0..1, from hold time only)  -> launch speed + a calibration depth
--   spin (from the mouse drag)          -> topspin / sidespin, applied in FULL to the launch
--   contact point                       -> where the flight starts
--
-- The launch DIRECTION and ELEVATION are calibrated so that a shot of this power, with only part of its spin
-- (Top/Back/SidespinCompensation), would land at a default point on the opponent's half: straight ahead-ish (FollowLateral),
-- deeper for more power (Min/MaxShotDepth). Then the ball is launched with ALL of its spin and flies by the real
-- physics, so spin genuinely changes the path and the landing (topspin dips and lands shorter, backspin floats
-- longer, sidespin curves sideways), and a shot can miss. Nothing is steered after contact. The cursor plays no part.
--
-- TIMING ERROR (2026-11-15): after the calibration, the launch direction and elevation are turned by a DETERMINISTIC
-- error from the release timing (opts.timing, ShotInput.timingValue), scaled by the shot's risk (power, stretch, smash;
-- Config.ShotControl.Error* / Timing*). Early = across the body and higher (long); late = the other way and lower (net).
-- The client's arrow calls compute with "release right now", so it shows exactly this error; nothing is random.
-- SMASH (opts.smash): faster, deeper, half the spin, SmashTimingMultiplier x the full-power risk.
-- PLAYER SERVE (ShotLaunch.serve) and AUTOMATIC DIVE RETURNS (diveReturn / diveMishit) are solved here too
-- (2026-11-16 pass 3), with the same physics.

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

-- Hold duration (seconds) -> power 0..1.
function ShotLaunch.powerFromHold(hold: number): number
	local S = Config.ShotControl
	if hold ~= hold then
		return 0
	end
	local n = math.clamp(hold / math.max(S.ChargeTime, 1e-3), 0, 1)
	return n ^ S.ChargeExponent
end

-- Horizontal launch speed for a power.
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
}

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
	local speed = baseSpeed * spinSpeed * (opts and opts.speedFactor or 1)
	local depth = if smash then S.SmashDepth else nil
	local aim = ShotLaunch.aimPoint(contact, power, opponent, opts and opts.aimOffset, depth)
	local solveOpts: ShotSolver.Options = {
		speed = speed,
		topspin = topspin * (if topspin >= 0 then S.TopspinCompensation else S.BackspinCompensation),
		sidespin = sidespin * S.SidespinCompensation,
		netZ = TableWorld.netZ,
		netTopY = TableWorld.netTopY,
		clearance = Config.Rally.NetClearance,
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
	local deadline = t0 + S.SolveBudget

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
	-- 3: the aim eased toward the centre, no sidespin
	if os.clock() <= deadline then
		for _, aimScale in { 0.6, 0.25 } do
			local target = ServeRules.target(aim * aimScale, power, base)
			local shot, first, env = attempt(target, topspin, 0)
			if shot and env and env.ok then
				local out = launch(shot.velocity, shot.spin, "legal serve (aim eased, no sidespin)", 0, target, first, env)
				remember(out)
				return finish(out)
			end
			if os.clock() > deadline then
				break
			end
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

-- AUTOMATIC DIVE RETURN (Config.Movement.DiveReturn*; 2026-11-16 pass 3). A defensive emergency return (never a charged
-- shot): moderate pace, a little topspin, toward the middle of the opponent's half. Solved with the shared physics and
-- checked by simulating the whole flight; slower / more central alternatives are tried before giving up. ok = false only
-- when no attempt lands legally (an unexpected solver failure: the server logs it separately and still plays the best
-- attempt, physically). Decided once at the contact; nothing is steered afterwards.
export type DiveLaunch = Launch & { ok: boolean, result: string }

local function launchOf(velocity: Vector3, spin: Vector3, aim: Vector3, how: string, ok: boolean, result: string): DiveLaunch
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

-- (2026-11-17) DEFENSIVE: the SLOWEST launch speed (from DiveReturnSpeeds, slow to fast) whose flight lands legally AND
-- peaks no higher than DiveReturnMaxApex above the table: a slow, high ball that buys recovery time without becoming a
-- moon ball (a fixed slow speed had to arc 25-50 studs high to carry the long table against drag). Each try is a bounded
-- solve; past DiveSolveBudget seconds the remaining (faster, cheaper) speeds are tried toward the table centre.
function ShotLaunch.diveReturn(contact: Vector3, hitter: string?): DiveLaunch
	local M = Config.Movement
	local cfg = TableWorld.physics
	local who = hitter or "Player"
	local opponent = if who == "Player" then "Bot" else "Player"
	local c = TableWorld.center
	local surfaceY = Config.Layout.SurfaceY
	local deadline = os.clock() + M.DiveSolveBudget
	local best: DiveLaunch? = nil
	local bestApex = math.huge
	local pts: { Vector3 } = {}
	for _, speed in M.DiveReturnSpeeds do
		local lateral = if os.clock() > deadline then 0 else M.DiveReturnLateral
		local x = math.clamp((contact.X - c.X) * lateral, -(TableWorld.halfWidth - 6), TableWorld.halfWidth - 6)
		local aim = TableWorld.pointOnHalf(opponent, M.DiveReturnDepth, x)
		local shot = ShotSolver.solve(cfg, contact, aim, {
			speed = speed,
			topspin = M.DiveReturnTopspin,
			sidespin = 0,
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
				local launch = launchOf(shot.velocity, shot.spin, aim, ("dive return (%.0f studs/s, apex %.1f)"):format(speed, apex), true, "ok")
				if apex <= M.DiveReturnMaxApex then
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
	local aim = TableWorld.pointOnHalf(opponent, M.DiveReturnDepth, 0)
	local d = aim - contact
	local t = math.max(Vector3.new(d.X, 0, d.Z).Magnitude / M.DiveReturnSpeed, 0.2)
	local v = Vector3.new(d.X / t, (d.Y + 0.5 * cfg.gravity * t * t) / t, d.Z / t)
	return launchOf(v, Vector3.zero, aim, "dive return (fallback guess)", false, "fallback")
end

-- The deliberate MISHIT of a dive contact (the configurable failure share): a coherent physical miss of `kind` ("long":
-- over the opponent's end line, "wide": past a side line, "net": into the net), solved with the same physics so the
-- ball visibly flies there from the real contact. result = the predicted first contact ("out" / "net" / ...).
function ShotLaunch.diveMishit(contact: Vector3, kind: string, sideSign: number, hitter: string?): DiveLaunch
	local M = Config.Movement
	local cfg = TableWorld.physics
	local who = hitter or "Player"
	local opponent = if who == "Player" then "Bot" else "Player"
	local c = TableWorld.center
	local toward = TableWorld.towardSide(opponent)
	local target: Vector3, clearance: number? = c, nil
	if kind == "net" then
		target = Vector3.new(contact.X + (c.X - contact.X) * 0.5, TableWorld.netTopY - 1.0, TableWorld.netZ)
		clearance = nil
	elseif kind == "wide" then
		local side = if sideSign >= 0 then 1 else -1
		target = Vector3.new(c.X + side * (TableWorld.halfWidth + 5), TableWorld.landingY, c.Z + toward * TableWorld.halfLength * 0.55)
		clearance = Config.Rally.NetClearance
	else -- "long": an over-hit (faster: with air drag a 62 studs/s ball cannot carry past the far end line)
		target = Vector3.new(contact.X + (c.X - contact.X) * 0.4, TableWorld.landingY, c.Z + toward * (TableWorld.halfLength + 4))
		clearance = Config.Rally.NetClearance
	end
	local shot = ShotSolver.solve(cfg, contact, target, {
		speed = if kind == "long" then M.DiveMishitLongSpeed else M.DiveMishitSpeed,
		topspin = 0,
		sidespin = 0,
		netZ = TableWorld.netZ,
		netTopY = if clearance then TableWorld.netTopY else nil,
		clearance = clearance,
		maxTime = 3,
	})
	local v = shot.velocity
	if v.Magnitude == 0 then
		local d = target - contact
		local t = math.max(Vector3.new(d.X, 0, d.Z).Magnitude / M.DiveMishitSpeed, 0.2)
		v = Vector3.new(d.X / t, (d.Y + 0.5 * cfg.gravity * t * t) / t, d.Z / t)
	end
	local path = ShotLaunch.predictPath(contact, v, Vector3.zero, nil, nil, who)
	if path.kind == "ok" and kind ~= "wide" then
		return ShotLaunch.diveMishit(contact, "wide", sideSign, hitter) -- (that mishit would have landed: play a wide one)
	end
	return launchOf(v, Vector3.zero, target, "dive mishit (" .. kind .. ")", path.kind ~= "ok", path.kind)
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
