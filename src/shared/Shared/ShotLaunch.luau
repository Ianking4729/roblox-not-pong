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

local Config = require(script.Parent:WaitForChild("Config"))
local BallPhysics = require(script.Parent:WaitForChild("BallPhysics"))
local ShotSolver = require(script.Parent:WaitForChild("ShotSolver"))
local TableWorld = require(script.Parent:WaitForChild("TableWorld"))

local ShotLaunch = {}

export type Launch = {
	velocity: Vector3,
	spin: Vector3,
	aim: Vector3, -- the calibration point (where a partly-compensated shot would land); NOT a player-chosen target
	speed: number, -- requested horizontal speed
	how: string, -- "calibrated" | "calibrated (low net clearance)" | "spin-free calibration" | "fallback guess"
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

-- The default calibration point on `opponent`'s half for a shot of `power` from `contact`.
function ShotLaunch.aimPoint(contact: Vector3, power: number, opponent: string?, offset: Vector3?): Vector3
	local S = Config.ShotControl
	local side = opponent or "Bot"
	local c = TableWorld.center
	local depth = lerp(S.MinShotDepth, S.MaxShotDepth, math.clamp(power, 0, 1))
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
	aimOffset: Vector3?, -- weak contacts: random error in the calibration point
}

-- The launch for a shot from `contact` with `power` (0..1) and spin (rad/s; topspin < 0 = backspin, sidespin sign as
-- ShotSolver: positive curves the ball to ITS left).
function ShotLaunch.compute(contact: Vector3, power: number, topspin: number, sidespin: number, opts: Options?): Launch
	local S = Config.ShotControl
	local cfg = TableWorld.physics
	local hitter = opts and opts.hitter or "Player"
	local opponent = if hitter == "Player" then "Bot" else "Player"
	-- Topspin plays a faster, flatter-driven shot; backspin a slightly slower, floated one (both scale with the spin).
	local spinFrac = math.clamp(topspin / math.max(S.MaxSpin, 1e-3), -1, 1)
	local spinSpeed = if spinFrac >= 0 then 1 + (S.TopspinSpeedBonus or 0) * spinFrac else 1 + (S.BackspinSpeedPenalty or 0) * spinFrac
	local speed = ShotLaunch.speedFor(power) * spinSpeed * (opts and opts.speedFactor or 1)
	local aim = ShotLaunch.aimPoint(contact, power, opponent, opts and opts.aimOffset)
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
	local ref = ShotSolver.solve(cfg, contact, aim, solveOpts)
	if ref.velocity.Magnitude == 0 then
		solveOpts.topspin, solveOpts.sidespin = 0, 0
		ref = ShotSolver.solve(cfg, contact, aim, solveOpts)
		how = "spin-free calibration"
	elseif not ref.ok then
		how = "calibrated (low net clearance)"
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
	local spin = ShotSolver.spinVector(velocity, topspin, sidespin) -- the FULL spin
	return { velocity = velocity, spin = spin, aim = aim, speed = speed, how = how }
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
