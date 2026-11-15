--!strict
-- BallPhysics: pure, deterministic ball simulation (no Roblox physics engine, no Instances).
-- The server owns the official simulation; the client runs this same code to render the ball between server
-- snapshots, and ShotSolver/bots use it to predict trajectories. Units: studs, seconds, radians (see Config header).
--
-- Model (per fixed tick, semi-implicit Euler):
--   gravity      a = (0, -g, 0)
--   air drag     a = -drag * |v| * v                       (quadratic; drag = 0.5*rho*Cd*A/m, ~0.014 / stud for a real ball)
--   Magnus       a = magnus * (spin x v)                   (spin in rad/s; topspin dips, backspin floats, sidespin curves)
--   spin decay   spin *= (1 - spinDecay * dt)
-- Contacts are SWEPT along each tick's segment (the earliest one wins), so a fast ball cannot tunnel through the
-- table top, the table sides or the 0.05-stud net:
--   table top    normal restitution + Coulomb friction with spin coupling (hollow sphere, I = 2/3 m r^2): a sliding
--                ball grips the table, which changes both its speed and its spin (backspin checks up, topspin kicks)
--   table side   simple reflection (the ball is dead for the rules anyway)
--   net          body hit: reflected and heavily damped; cord clip (top band of one radius): slowed and popped up
--   floor        damped bounce (dead ball for the rules)
-- Fixed step + accumulator => results do not depend on the frame rate.

local BallPhysics = {}

export type Config = {
	radius: number,
	gravity: number, -- studs/s^2, positive = downward
	restitution: number, -- table: fraction of normal speed kept
	tableFriction: number?, -- table: Coulomb friction coefficient (0 = no spin coupling)
	friction: number?, -- LEGACY (pre-spin model): ignored when tableFriction is set
	restSpeed: number, -- outgoing normal speed below which the ball settles on a surface instead of bouncing
	fixedStep: number, -- seconds per tick
	maxStepsPerUpdate: number, -- caps catch-up work after a hitch
	drag: number?, -- 1/stud
	magnus: number?, -- dimensionless (a = magnus * spin x v)
	magnusGain: number?, -- Phase 4: multiplies magnus (exaggerated curvature); nil = 1
	magnusSaturation: number?, -- Phase 4: spin (rad/s) at which the curvature gain has halved; nil/0 = linear
	magnusSideGain: number?, -- extra multiplier on the vertical-axis (side) spin's Magnus push only; nil = 1
	magnusSideSpeedRef: number?, -- studs/s: side push also scales with horizontal speed / this (same curve shape at any power); nil/0 = off
	bounceSpinKick: number?, -- Phase 4: table bounce adds -kick * (spin's contact-point velocity): topspin kicks forward, backspin checks, sidespin kicks sideways; nil/0 = Phase 3
	spinDecay: number?, -- 1/s
	netRestitution: number?,
	netFriction: number?, -- fraction of the along-net velocity kept on a net body hit
	netCordKeep: number?, -- fraction of forward speed kept when clipping the net cord
	floorRestitution: number?,
	floorFriction: number?,
	sideRestitution: number?,
	maxSpeed: number?,
	maxSpin: number?,
}

-- Axis-aligned flat surface (e.g. one half of the table top). Ball bounces only while over it.
export type Surface = {
	topY: number,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	name: string?, -- reported in events (e.g. "Player" / "Bot" for the table halves)
}

-- The net: a thin vertical slab across the table at z, from bottomY to topY, spanning minX..maxX.
export type Net = {
	z: number,
	minX: number,
	maxX: number,
	bottomY: number,
	topY: number,
	halfThickness: number,
}

-- The table body below the top (for side hits): an axis-aligned box.
export type Box = { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number }

export type World = {
	surfaces: { Surface },
	net: Net?,
	tableBox: Box?,
	floorY: number?,
}

export type Event = {
	kind: string, -- "table" | "net" | "netCord" | "side" | "floor"
	surface: string?, -- table surface name for "table"
	position: Vector3,
	velocity: Vector3, -- after the contact
	time: number,
}

export type State = {
	position: Vector3,
	velocity: Vector3,
	spin: Vector3, -- angular velocity, rad/s
	accumulator: number,
	bounces: number, -- table bounces (kept for older callers)
	time: number, -- simulated seconds
	resting: boolean,
}

BallPhysics.DefaultConfig = table.freeze({
	radius = 0.2,
	gravity = 98.1,
	restitution = 0.9,
	tableFriction = 0.25,
	restSpeed = 1,
	fixedStep = 1 / 240,
	maxStepsPerUpdate = 40,
	drag = 0.014,
	magnus = 0.0056,
	spinDecay = 0.2,
	netRestitution = 0.15,
	netFriction = 0.4,
	netCordKeep = 0.7,
	floorRestitution = 0.55,
	floorFriction = 0.5,
	sideRestitution = 0.4,
	maxSpeed = 400,
	maxSpin = 1000,
}) :: Config

function BallPhysics.newState(position: Vector3, velocity: Vector3?, spin: Vector3?): State
	return {
		position = position,
		velocity = velocity or Vector3.zero,
		spin = spin or Vector3.zero,
		accumulator = 0,
		bounces = 0,
		time = 0,
		resting = false,
	}
end

function BallPhysics.copyState(s: State): State
	return {
		position = s.position,
		velocity = s.velocity,
		spin = s.spin,
		accumulator = s.accumulator,
		bounces = s.bounces,
		time = s.time,
		resting = s.resting,
	}
end

function BallPhysics.surfaceFromPart(part: BasePart): Surface
	-- Assumes the part is not rotated (the table is axis-aligned).
	local pos, size = part.Position, part.Size
	return {
		topY = pos.Y + size.Y / 2,
		minX = pos.X - size.X / 2,
		maxX = pos.X + size.X / 2,
		minZ = pos.Z - size.Z / 2,
		maxZ = pos.Z + size.Z / 2,
	}
end

-- Older callers passed a plain list of surfaces.
local function asWorld(world: any): World
	if world.surfaces then
		return world
	end
	return { surfaces = world }
end

local function over(s: Surface, p: Vector3): boolean
	return p.X >= s.minX and p.X <= s.maxX and p.Z >= s.minZ and p.Z <= s.maxZ
end

-- Velocity and spin after an impulsive contact with a surface of normal `n` moving at `surfaceVel`.
-- e: normal restitution, mu: Coulomb friction. Hollow sphere (I = 2/3 m r^2): the tangential impulse that brings the
-- contact point to rest (rolling) is 0.4 * |contact slip|; friction caps it at mu * normal impulse.
function BallPhysics.contact(
	velocity: Vector3,
	spin: Vector3,
	n: Vector3,
	e: number,
	mu: number,
	radius: number,
	surfaceVel: Vector3?,
	spinKick: number? -- extra tangential impulse = -spinKick * (spin x rvec); nil/0 = none
): (Vector3, Vector3)
	local sv = surfaceVel or Vector3.zero
	local vr = velocity - sv
	local vn = vr:Dot(n)
	if vn >= 0 then
		return velocity, spin -- separating
	end
	local rvec = -n * radius -- centre -> contact point
	local vt = vr - n * vn
	local slip = vt + spin:Cross(rvec) -- contact-point velocity along the surface
	local jn = -(1 + e) * vn
	local out = vr + n * jn
	local slipMag = slip.Magnitude
	if mu > 0 and slipMag > 1e-6 then
		local jt = math.min(0.4 * slipMag, mu * jn)
		local dv = -slip / slipMag * jt
		out += dv
		spin += rvec:Cross(dv) * (3 / (2 * radius * radius))
	end
	if spinKick and spinKick > 0 then
		-- The spin's own contact-point velocity (tangential by construction). Topspin moves the contact point backward,
		-- so subtracting it pushes the ball forward; backspin brakes it; sidespin pushes it sideways. The spin gives up
		-- the matching angular momentum so the exchange stays consistent.
		-- (capped at 2/3: beyond that the exchange would overshoot and reverse the spin)
		local dv2 = -spin:Cross(rvec) * math.min(spinKick, 2 / 3)
		out += dv2
		spin += rvec:Cross(dv2) * (3 / (2 * radius * radius))
	end
	return out + sv, spin
end

local function clampVec(v: Vector3, maxMag: number?): Vector3
	if maxMag and v.Magnitude > maxMag then
		return v.Unit * maxMag
	end
	return v
end

-- Advance exactly one fixed tick. Returns true if a TABLE bounce occurred. Contacts are appended to `events` if given.
function BallPhysics.tick(state: State, config: Config, worldIn: any, events: { Event }?): boolean
	local world = asWorld(worldIn)
	local dt = config.fixedStep
	local r = config.radius
	if state.resting then
		state.time += dt
		return false
	end

	local v = state.velocity
	local w = state.spin
	local acc = Vector3.new(0, -config.gravity, 0)
	local drag = config.drag or 0
	if drag > 0 then
		acc -= v * (drag * v.Magnitude)
	end
	local magnus = config.magnus or 0
	if magnus > 0 then
		-- Curvature response: magnus * gain, with diminishing returns as the spin grows (coefficient / (1 + |w|/sat)),
		-- so medium spin bends noticeably while maximum spin cannot run away. sat = 0 or nil keeps it linear.
		local sat = config.magnusSaturation or 0
		local coeff = magnus * (config.magnusGain or 1)
		if sat > 0 then
			coeff /= 1 + w.Magnitude / sat
		end
		-- Sidespin (the spin component about the vertical axis) only ever pushes the ball SIDEWAYS (up x v is horizontal),
		-- so it can be exaggerated on its own without making top/backspin dip or lift any harder.
		-- With magnusSideSpeedRef set, that push also scales with horizontal speed / ref: the ball then TURNS by the same
		-- angle per stud travelled at any speed, so a curve has the same shape whether the shot is soft or hard (instead
		-- of slow shots hooking far more simply because they spend longer in the air).
		local sideGain = config.magnusSideGain or 1
		local ref = config.magnusSideSpeedRef or 0
		if ref > 0 then
			sideGain *= math.sqrt(v.X * v.X + v.Z * v.Z) / ref
		end
		local wm = if sideGain ~= 1 then Vector3.new(w.X, w.Y * sideGain, w.Z) else w
		acc += wm:Cross(v) * coeff
	end
	v = clampVec(v + acc * dt, config.maxSpeed)
	w = w * math.max(0, 1 - (config.spinDecay or 0) * dt)

	local prev = state.position
	local pos = prev + v * dt
	state.time += dt

	-- Find the earliest contact along prev -> pos.
	local bestF, bestKind, bestData = 2, nil :: string?, nil :: any

	-- table top (any surface), swept on the plane y = topY + r
	for _, s in world.surfaces do
		local restY = s.topY + r
		if v.Y < 0 and prev.Y >= restY and pos.Y < restY then
			local f = (prev.Y - restY) / (prev.Y - pos.Y)
			local c = prev:Lerp(pos, f)
			if over(s, c) and f < bestF then
				bestF, bestKind, bestData = f, "table", s
			end
		end
	end

	-- net, swept on its centre plane
	local net = world.net
	if net and (prev.Z - net.z) * (pos.Z - net.z) < 0 then
		local f = (prev.Z - net.z) / (prev.Z - pos.Z)
		local c = prev:Lerp(pos, f)
		if c.X >= net.minX - r and c.X <= net.maxX + r and c.Y >= net.bottomY and c.Y <= net.topY + r and f < bestF then
			bestF, bestKind, bestData = f, if c.Y <= net.topY then "net" else "netCord", nil
		end
	end

	-- table sides: entering the table body (below the top) through a vertical face
	local box = world.tableBox
	if box then
		local inside = function(p: Vector3): boolean
			return p.X > box.minX - r
				and p.X < box.maxX + r
				and p.Z > box.minZ - r
				and p.Z < box.maxZ + r
				and p.Y < box.maxY
				and p.Y > box.minY
		end
		if not inside(prev) and inside(pos) and prev.Y < box.maxY then
			-- which face: the axis along which prev was outside
			local f = 0
			local axis = "x"
			if prev.X <= box.minX - r or prev.X >= box.maxX + r then
				local face = if prev.X <= box.minX - r then box.minX - r else box.maxX + r
				f = (prev.X - face) / (prev.X - pos.X)
			else
				axis = "z"
				local face = if prev.Z <= box.minZ - r then box.minZ - r else box.maxZ + r
				f = (prev.Z - face) / (prev.Z - pos.Z)
			end
			if f < bestF then
				bestF, bestKind, bestData = f, "side", axis
			end
		end
	end

	-- floor
	if world.floorY then
		local restY = world.floorY + r
		if v.Y < 0 and prev.Y >= restY and pos.Y < restY then
			local f = (prev.Y - restY) / (prev.Y - pos.Y)
			if f < bestF then
				bestF, bestKind, bestData = f, "floor", nil
			end
		end
	end

	local bounced = false
	local surfaceName: string? = nil
	if bestKind then
		local c = prev:Lerp(pos, bestF)
		if bestKind == "table" or bestKind == "floor" then
			local s = if bestKind == "table" then bestData :: Surface else nil
			local restY = if s then s.topY + r else (world.floorY :: number) + r
			local e = if s then config.restitution else (config.floorRestitution or 0.5)
			local mu = if s then (config.tableFriction or 0) else (config.floorFriction or 0.5)
			local legacyFriction = s and config.tableFriction == nil and config.friction
			v, w = BallPhysics.contact(v, w, Vector3.yAxis, e, mu, r, nil, if s then config.bounceSpinKick else nil)
			if legacyFriction then
				v = Vector3.new(v.X * legacyFriction, v.Y, v.Z * legacyFriction)
			end
			pos = Vector3.new(c.X, restY, c.Z)
			if v.Y < config.restSpeed then
				v = Vector3.new(v.X, 0, v.Z)
				if bestKind == "floor" or v.Magnitude < config.restSpeed then
					state.resting = true
					v = Vector3.zero
					w = Vector3.zero
				end
			elseif s then
				bounced = true
				state.bounces += 1
				surfaceName = s.name
			end
		elseif bestKind == "net" then
			local n = net :: Net
			local side = if prev.Z > n.z then 1 else -1
			v = Vector3.new(
				v.X * (config.netFriction or 0.4),
				v.Y * (config.netFriction or 0.4),
				-v.Z * (config.netRestitution or 0.15)
			)
			w *= 0.5
			pos = Vector3.new(c.X, c.Y, n.z + side * (n.halfThickness + r))
		elseif bestKind == "netCord" then
			local keep = config.netCordKeep or 0.7
			v = Vector3.new(v.X * keep, math.abs(v.Y) * 0.5 + math.abs(v.Z) * 0.15, v.Z * keep)
			pos = c + v * dt * (1 - bestF)
		elseif bestKind == "side" then
			local e = config.sideRestitution or 0.4
			if bestData == "x" then
				v = Vector3.new(-v.X * e, v.Y, v.Z)
			else
				v = Vector3.new(v.X, v.Y, -v.Z * e)
			end
			pos = c
		end
		if events then
			table.insert(events, {
				kind = bestKind :: string,
				surface = surfaceName,
				position = pos,
				velocity = v,
				time = state.time,
			})
		end
	end

	state.position = pos
	state.velocity = v
	state.spin = clampVec(w, config.maxSpin)
	return bounced
end

-- Advance by a variable frame dt using the fixed-step accumulator. Returns the number of table bounces.
-- `onTick(state)` (optional) runs after every tick, e.g. for per-tick gameplay checks.
function BallPhysics.step(
	state: State,
	config: Config,
	world: any,
	dt: number,
	events: { Event }?,
	onTick: ((State) -> ())?
): number
	state.accumulator += dt
	local steps, bounces = 0, 0
	while state.accumulator >= config.fixedStep and steps < config.maxStepsPerUpdate do
		if BallPhysics.tick(state, config, world, events) then
			bounces += 1
		end
		state.accumulator -= config.fixedStep
		steps += 1
		if onTick then
			onTick(state)
		end
	end
	if steps >= config.maxStepsPerUpdate then
		state.accumulator = 0 -- drop backlog rather than spiral
	end
	return bounces
end

-- Paddle contact: a moving paddle with face normal `normal` (pointing toward where the ball should go) and velocity
-- `paddleVelocity`. Uses the same impulse model as the table. Returns true if the ball was struck (it was moving
-- into the face). FUTURE (Phase 3): the player's swing will call this; Phase 2 shots use ShotSolver instead.
function BallPhysics.paddleHit(
	state: State,
	config: Config,
	normal: Vector3,
	paddleVelocity: Vector3,
	restitution: number,
	friction: number
): boolean
	local vr = state.velocity - paddleVelocity
	if vr:Dot(normal) >= 0 then
		return false
	end
	state.velocity, state.spin =
		BallPhysics.contact(state.velocity, state.spin, normal.Unit, restitution, friction, config.radius, paddleVelocity)
	state.velocity = clampVec(state.velocity, config.maxSpeed)
	state.spin = clampVec(state.spin, config.maxSpin)
	state.resting = false
	return true
end

-- Simulate a COPY of `state` for up to `duration` seconds. Returns the sampled positions (every tick), their times,
-- and all contact events. `stop(state, event?)` may return true to end early. Never mutates `state`.
function BallPhysics.predict(
	state: State,
	config: Config,
	world: any,
	duration: number,
	stop: ((State, Event?) -> boolean)?
): ({ State }, { Event })
	local s = BallPhysics.copyState(state)
	local samples: { State } = {}
	local events: { Event } = {}
	local n = math.floor(duration / config.fixedStep)
	for _ = 1, n do
		local before = #events
		BallPhysics.tick(s, config, world, events)
		table.insert(samples, BallPhysics.copyState(s))
		if stop and stop(s, events[#events] ~= nil and #events > before and events[#events] or nil) then
			break
		end
		if s.resting then
			break
		end
	end
	return samples, events
end

return BallPhysics
