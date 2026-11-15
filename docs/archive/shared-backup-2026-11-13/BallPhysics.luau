--!strict
-- BallPhysics: pure, deterministic ball simulation (no Roblox physics engine).
-- Server owns the simulation; clients may later use this same module for prediction/visuals.
-- No Instances are touched here, so the module is unit-testable and replaceable.

local BallPhysics = {}

export type Config = {
	radius: number,
	gravity: number, -- studs/s^2, positive = downward
	restitution: number, -- 0..1, fraction of vertical speed kept on bounce
	friction: number, -- 0..1, fraction of horizontal speed kept on bounce
	restSpeed: number, -- outgoing vertical speed below which the ball settles instead of bouncing
	fixedStep: number, -- seconds per simulation tick
	maxStepsPerUpdate: number, -- caps catch-up work after a hitch
}

-- Axis-aligned flat surface (e.g. a table top). Ball bounces only while over it.
export type Surface = {
	topY: number,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

export type State = {
	position: Vector3,
	velocity: Vector3,
	accumulator: number,
	bounces: number,
}

BallPhysics.DefaultConfig = table.freeze({
	radius = 0.5,
	gravity = 60,
	restitution = 0.8,
	friction = 0.98,
	restSpeed = 1,
	fixedStep = 1 / 120,
	maxStepsPerUpdate = 12,
}) :: Config

function BallPhysics.newState(position: Vector3, velocity: Vector3?): State
	return {
		position = position,
		velocity = velocity or Vector3.zero,
		accumulator = 0,
		bounces = 0,
	}
end

function BallPhysics.surfaceFromPart(part: BasePart): Surface
	-- Assumes the part is not rotated (placeholder table is axis-aligned).
	local pos, size = part.Position, part.Size
	return {
		topY = pos.Y + size.Y / 2,
		minX = pos.X - size.X / 2,
		maxX = pos.X + size.X / 2,
		minZ = pos.Z - size.Z / 2,
		maxZ = pos.Z + size.Z / 2,
	}
end

local function isOver(surface: Surface, p: Vector3): boolean
	return p.X >= surface.minX and p.X <= surface.maxX and p.Z >= surface.minZ and p.Z <= surface.maxZ
end

-- Advance exactly one fixed tick. Returns true if a bounce occurred this tick.
function BallPhysics.tick(state: State, config: Config, surfaces: { Surface }): boolean
	local dt = config.fixedStep
	local prev = state.position
	local vel = state.velocity - Vector3.new(0, config.gravity * dt, 0)
	local pos = prev + vel * dt
	local bounced = false

	for _, s in surfaces do
		local restY = s.topY + config.radius
		-- Crossed the surface plane this tick while moving down and over the surface.
		if vel.Y < 0 and prev.Y >= restY and pos.Y < restY and isOver(s, pos) then
			pos = Vector3.new(pos.X, restY, pos.Z)
			local outVy = -vel.Y * config.restitution
			if outVy < config.restSpeed then
				-- Too slow to bounce: settle on the surface (not counted as a bounce).
				vel = Vector3.new(vel.X * config.friction, 0, vel.Z * config.friction)
			else
				vel = Vector3.new(vel.X * config.friction, outVy, vel.Z * config.friction)
				bounced = true
				state.bounces += 1
			end
			break
		end
	end

	state.position = pos
	state.velocity = vel
	return bounced
end

-- Advance by a variable frame dt using a fixed-step accumulator.
-- Returns the number of bounces that occurred during this update.
function BallPhysics.step(state: State, config: Config, surfaces: { Surface }, dt: number): number
	state.accumulator += dt
	local steps, bounces = 0, 0
	while state.accumulator >= config.fixedStep and steps < config.maxStepsPerUpdate do
		if BallPhysics.tick(state, config, surfaces) then
			bounces += 1
		end
		state.accumulator -= config.fixedStep
		steps += 1
	end
	if steps >= config.maxStepsPerUpdate then
		state.accumulator = 0 -- drop backlog rather than spiral
	end
	return bounces
end

return BallPhysics
