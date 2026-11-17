--!strict
-- ShotSolver: finds a launch velocity that makes the ball land where we want, by SIMULATING the real flight
-- (gravity + drag + Magnus, same BallPhysics code and constants) and correcting the guess. So every bot return,
-- auto-return and serve is a physically coherent trajectory; nothing is teleported or forced mid-flight.
-- Pure: no Instances. Used by the server (authoritative shots); safe for clients (prediction) too.

local BallPhysics = require(script.Parent:WaitForChild("BallPhysics"))

local ShotSolver = {}

export type Shot = {
	ok: boolean,
	velocity: Vector3,
	spin: Vector3,
	landing: Vector3?,
	flightTime: number,
	netClearance: number?, -- studs between the ball's bottom and the net top when crossing (nil: did not cross)
}

export type Options = {
	speed: number, -- initial HORIZONTAL speed, studs/s
	topspin: number?, -- rad/s; negative = backspin
	sidespin: number?, -- rad/s about +Y (positive curves the ball to its left)
	netZ: number?,
	netTopY: number?,
	clearance: number?, -- minimum studs between ball bottom and net top
	edgeZ: number?, -- optional: the hitter's own end line; a ball struck below table height must clear it too
	edgeTopY: number?, -- table-top height at that edge
	maxTime: number?,
	-- cost bounds (2026-11-17, serves): inner iterations per speed (default 24), slower-speed retries (default 8) and the
	-- landing tolerance in studs (default 0.05). The serve solve does not need 0.05-stud precision on its first bounce.
	maxIterations: number?,
	maxFactors: number?,
	tolerance: number?,
}

-- Spin vector for a ball travelling horizontally along `dir`: topspin is about (up x dir), sidespin about up.
function ShotSolver.spinVector(dir: Vector3, topspin: number?, sidespin: number?): Vector3
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 1e-6 then
		return Vector3.yAxis * (sidespin or 0)
	end
	return Vector3.yAxis:Cross(flat.Unit) * (topspin or 0) + Vector3.yAxis * (sidespin or 0)
end

local EMPTY_WORLD = { surfaces = {} }

-- Free flight (no contacts) from p0 until the ball descends through planeY. Returns landing point, time, and the
-- ball-centre heights where it crossed netZ and edgeZ (if it did).
local function fly(
	config: BallPhysics.Config,
	p0: Vector3,
	v0: Vector3,
	w0: Vector3,
	planeY: number,
	netZ: number?,
	maxTime: number,
	edgeZ: number?
): (Vector3?, number, number?, number?)
	local s = BallPhysics.newState(p0, v0, w0)
	local yNet: number? = nil
	local yEdge: number? = nil
	local n = math.floor(maxTime / config.fixedStep)
	for _ = 1, n do
		local prev = s.position
		BallPhysics.tick(s, config, EMPTY_WORLD)
		local p = s.position
		if netZ and yNet == nil and (prev.Z - netZ) * (p.Z - netZ) <= 0 and prev.Z ~= p.Z then
			local f = (prev.Z - netZ) / (prev.Z - p.Z)
			yNet = prev.Y + (p.Y - prev.Y) * f
		end
		if edgeZ and yEdge == nil and (prev.Z - edgeZ) * (p.Z - edgeZ) <= 0 and prev.Z ~= p.Z then
			local f = (prev.Z - edgeZ) / (prev.Z - p.Z)
			yEdge = prev.Y + (p.Y - prev.Y) * f
		end
		if s.velocity.Y < 0 and p.Y <= planeY then
			local f = (prev.Y - planeY) / (prev.Y - p.Y)
			return prev:Lerp(p, f), s.time, yNet, yEdge
		end
	end
	return nil, s.time, yNet, yEdge
end

local function rotY(v: Vector3, a: number): Vector3
	local c, s = math.cos(a), math.sin(a)
	return Vector3.new(v.X * c + v.Z * s, 0, -v.X * s + v.Z * c)
end

-- Solve one shot from `start` to land on `target` (target.Y = the landing plane, i.e. table top + radius).
-- If the arc does not clear the net by `clearance`, the shot is slowed (higher arc) and solved again.
function ShotSolver.solve(config: BallPhysics.Config, start: Vector3, target: Vector3, opts: Options): Shot
	local g = config.gravity
	local flatD = Vector3.new(target.X - start.X, 0, target.Z - start.Z)
	local dist = flatD.Magnitude
	local maxTime = opts.maxTime or 4
	local best: Shot? = nil
	if dist < 0.5 then
		return { ok = false, velocity = Vector3.zero, spin = Vector3.zero, flightTime = 0 }
	end
	local dirBase = flatD.Unit
	local perp = rotY(dirBase, math.pi / 2)
	local factor = 1
	local tol = opts.tolerance or 0.05
	for _ = 1, opts.maxFactors or 8 do
		local h = opts.speed * factor
		local t = dist / h
		local vy = (target.Y - start.Y + 0.5 * g * t * t) / t
		local yaw = 0
		local vyPrev: number?, errPrev: number? = nil, nil
		local yawPrev: number?, latPrev: number? = nil, nil
		local converged = false
		local land: Vector3?, tl: number, yNet: number?, yEdge: number? = nil, 0, nil, nil
		local v, w = Vector3.zero, Vector3.zero
		for _ = 1, opts.maxIterations or 24 do
			local dir = rotY(dirBase, yaw)
			v = dir * h + Vector3.yAxis * vy
			w = ShotSolver.spinVector(dir, opts.topspin, opts.sidespin)
			land, tl, yNet, yEdge = fly(config, start, v, w, target.Y, opts.netZ, maxTime, opts.edgeZ)
			if not land then
				vyPrev, errPrev, yawPrev, latPrev = nil, nil, nil, nil
				vy += 5
				continue
			end
			local delta = Vector3.new(land.X - target.X, 0, land.Z - target.Z)
			local rangeErr, latErr = delta:Dot(dirBase), delta:Dot(perp)
			if math.abs(rangeErr) < tol and math.abs(latErr) < tol then
				converged = true
				break
			end
			-- Yaw: secant on the lateral error once two samples exist (a strongly curving ball does not respond 1:1 to
			-- yaw like a straight one does), else the straight-flight estimate. Step capped for stability.
			local nextYaw
			if yawPrev and latPrev and math.abs(latErr - latPrev) > 1e-6 and yaw ~= yawPrev then
				nextYaw = yaw - latErr * (yaw - yawPrev) / (latErr - latPrev)
			else
				nextYaw = yaw - latErr / dist
			end
			yawPrev, latPrev = yaw, latErr
			yaw = yaw + math.clamp(nextYaw - yaw, -0.35, 0.35)
			local nextVy
			if vyPrev and errPrev and math.abs(rangeErr - errPrev) > 1e-6 and vy ~= vyPrev then
				nextVy = vy - rangeErr * (vy - vyPrev) / (rangeErr - errPrev)
			else
				nextVy = vy - rangeErr * g / (2 * h)
			end
			vyPrev, errPrev = vy, rangeErr
			vy = math.clamp(nextVy, -h, 3 * h)
		end
		local clearance: number? = if yNet and opts.netTopY then yNet - config.radius - opts.netTopY else nil
		if yEdge and opts.edgeTopY then -- (reported as part of netClearance: the tightest obstacle wins)
			local edge = yEdge - config.radius - opts.edgeTopY
			clearance = if clearance then math.min(clearance, edge) else edge
		end
		local shot: Shot = {
			ok = converged and (clearance == nil or clearance >= (opts.clearance or 0)),
			velocity = v,
			spin = w,
			landing = land,
			flightTime = tl,
			netClearance = clearance,
		}
		if shot.ok then
			return shot
		end
		if converged and (best == nil or (clearance or -math.huge) > ((best :: Shot).netClearance or -math.huge)) then
			best = shot
		end
		factor *= 0.88 -- slower = higher arc over the net
	end
	return best or { ok = false, velocity = Vector3.zero, spin = Vector3.zero, flightTime = 0 }
end

-- Solve a shot with the requested spin; if that spin is not feasible (e.g. heavy backspin from a contact below table
-- height cannot clear the net), retry with the SAME spin direction at a falling fraction of its strength before giving
-- up on spin. Deterministic, decided once before the ball is struck (nothing is steered afterwards). Returns the
-- shot (best attempt even when not ok) and the fraction of the requested spin that was used (1 = all of it).
local SPIN_LADDER = { 1, 0.75, 0.5, 0.3, 0 }

function ShotSolver.solveWithSpinFallback(
	config: BallPhysics.Config,
	start: Vector3,
	target: Vector3,
	opts: Options
): (Shot, number)
	local top, side = opts.topspin or 0, opts.sidespin or 0
	local best: Shot? = nil
	local bestScale = 0
	for _, scale in SPIN_LADDER do
		local o = table.clone(opts)
		o.topspin, o.sidespin = top * scale, side * scale
		local shot = ShotSolver.solve(config, start, target, o)
		if shot.ok then
			return shot, scale
		end
		if shot.velocity.Magnitude > 0 and (best == nil or (shot.netClearance or -math.huge) > ((best :: Shot).netClearance or -math.huge)) then
			best, bestScale = shot, scale
		end
		if top == 0 and side == 0 then
			break
		end
	end
	return best or { ok = false, velocity = Vector3.zero, spin = Vector3.zero, flightTime = 0 }, bestScale
end

export type ServeOptions = {
	speed: number, -- initial guess, horizontal studs/s
	minSpeed: number,
	maxSpeed: number,
	topspin: number?,
	sidespin: number?,
	server: string, -- the serving side ("Player" / "Bot"): table surface names in the world
	receiver: string,
	secondDepth: number, -- desired second-bounce distance past the net, in studs
	netZ: number,
	maxTime: number?, -- flight horizon of each inner solve (seconds; default 4). Serves reach their first bounce fast:
	-- a short horizon bounds the cost of attempts that never land (2026-11-16: 4 s made rare serves cost ~0.4 s)
	maxIterations: number?, -- passed to each inner solve (see Options)
	maxFactors: number?,
	tolerance: number?,
	maxSteps: number?, -- bisection steps (default 12)
}

-- Serve: the first bounce must be on `firstBounce` (server's half), the second on the receiver's half, without
-- touching the net. Bisects the serve speed on where the second bounce lands, simulating the full world each time.
function ShotSolver.solveServe(
	config: BallPhysics.Config,
	world: any,
	start: Vector3,
	firstBounce: Vector3,
	opts: ServeOptions
): (Shot, Vector3?)
	local lo, hi = opts.minSpeed, opts.maxSpeed
	local h = math.clamp(opts.speed, lo, hi)
	local bestShot: Shot? = nil
	local bestSecond: Vector3? = nil
	local bestErr = math.huge
	local towardReceiver = if opts.receiver == "Player" then 1 else -1
	for _ = 1, opts.maxSteps or 12 do
		local shot = ShotSolver.solve(config, start, firstBounce, {
			speed = h,
			topspin = opts.topspin,
			sidespin = opts.sidespin,
			maxTime = opts.maxTime,
			maxIterations = opts.maxIterations,
			maxFactors = opts.maxFactors,
			tolerance = opts.tolerance,
		})
		local second: Vector3? = nil
		local valid = false
		local short = true
		if shot.ok then
			local s = BallPhysics.newState(start, shot.velocity, shot.spin)
			local _, events = BallPhysics.predict(s, config, world, 3, function(_, e)
				return e ~= nil and e.kind ~= "table" or false
			end)
			local first = events[1]
			local nxt = events[2]
			if first and first.kind == "table" and first.surface == opts.server then
				if nxt and nxt.kind == "table" and nxt.surface == opts.receiver then
					second = nxt.position
					valid = true
					short = (nxt.position.Z - opts.netZ) * towardReceiver < opts.secondDepth
				elseif nxt and (nxt.kind == "table" and nxt.surface == opts.server or nxt.kind == "net" or nxt.kind == "netCord") then
					short = true
				else
					short = false -- went long (floor/side) or nothing
				end
			end
		end
		if valid and second then
			local err = math.abs((second.Z - opts.netZ) * towardReceiver - opts.secondDepth)
			if err < bestErr then
				bestErr, bestShot, bestSecond = err, shot, second
			end
			if err < 0.5 then
				break
			end
		end
		if short then
			lo = h
		else
			hi = h
		end
		h = (lo + hi) / 2
	end
	if bestShot then
		return bestShot, bestSecond
	end
	return { ok = false, velocity = Vector3.zero, spin = Vector3.zero, flightTime = 0 }, nil
end

return ShotSolver
