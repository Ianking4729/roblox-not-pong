--!strict
-- ServeRules: the PLAYER's manual serve, as pure shared rules (no Instances, no input, no networking), so the server
-- (authority) and the client (hand-held ball, region outline, aim line, timing) compute the same answers.
--   * handPoint      : where the ball sits in the free (left) hand, from the root's CFrame and the avatar's scale
--   * region / check : the legal serving region behind the player's end line, and whether a toss from here is legal
--   * phase/classify : the toss's CONTACT PHASE (falling, inside a height band, inside reach; 2026-11-16 pass 3: replaces
--                      the old fixed-height timer) and the verdict for a release
--   * target         : where the serve's second bounce is aimed from the aim and the power (the legal-serve solve)
-- The launch itself is Shared/ShotLaunch.serve. Config.Serve holds every number. Player side only: the bot serves
-- with its own automatic path (RallyService). No slow motion is involved anywhere in the serve.

local Config = require(script.Parent:WaitForChild("Config"))
local BallPhysics = require(script.Parent:WaitForChild("BallPhysics"))
local TableWorld = require(script.Parent:WaitForChild("TableWorld"))
local CourtShape = require(script.Parent:WaitForChild("CourtShape"))

local ServeRules = {}

export type Region = { minX: number, maxX: number, minZ: number, maxZ: number }

-- World position of the ball centre resting on the free hand. `which` = "hold" (before the toss) | "release" (the frame
-- the ball leaves the hand). From the authored clip's hand position, scaled to the avatar.
function ServeRules.handPoint(rootCFrame: CFrame, scale: number, which: string?, posture: string?): Vector3
	local S = Config.Serve
	local hand = if which == "release" then S.HandRelease else S.HandHold
	-- the serving posture turns the chest (and the free hand with it) about the vertical through the root
	hand = CFrame.Angles(0, ServeRules.chestYaw(posture), 0) * hand
	local p = rootCFrame:PointToWorldSpace(hand * scale)
	return p + Vector3.new(0, S.HandTop * scale + Config.Ball.Radius, 0)
end

-- Serving posture (Config.Serve.Posture): a valid name, the hips' and the chest's yaw (radians, + = turned left), and
-- the serve stroke it implies (the cursor never picks the serve stroke).
function ServeRules.posture(name: any): string
	if name == "LeftLead" or name == "RightLead" then
		return name
	end
	return Config.Serve.Posture.Default
end
function ServeRules.hipYaw(posture: string?): number
	if posture == nil then
		return 0
	end
	local P = Config.Serve.Posture
	-- LeftLead: the left hip leads toward the table = the body turned to its right (negative yaw)
	return math.rad(P.HipYaw) * (if ServeRules.posture(posture) == "LeftLead" then -1 else 1)
end
function ServeRules.chestYaw(posture: string?): number
	return ServeRules.hipYaw(posture) * Config.Serve.Posture.ChestFollow
end
function ServeRules.postureStroke(posture: string?): string
	return if ServeRules.posture(posture) == "RightLead" then "Backhand" else "Forehand"
end

-- The platform's footprint BOUNDS (studs, world X / Z), from Config.Layout.PlatformCenter and Config.Platform.Size. Since
-- 2026-11-21 the court is a disc: these are its bounding square (for outlines); on-court tests use CourtShape.
function ServeRules.platformBounds(): Region
	local pc, size = Config.Layout.PlatformCenter, Config.Platform.Size
	return { minX = pc.X - size.X / 2, maxX = pc.X + size.X / 2, minZ = pc.Z - size.Z / 2, maxZ = pc.Z + size.Z / 2 }
end

-- The legal region for the RELEASE POINT (the ball's position as it leaves the hand) (2026-11-19 Pass 12): ANYWHERE on
-- the platform behind the player's own end line, beyond either side line included. Derived from the platform's real
-- bounds and the court-relative end line (by at least the ball's radius): no radius, no lateral or depth allowance.
function ServeRules.region(): Region
	local b = ServeRules.platformBounds()
	local endZ = TableWorld.endLineZ("Player")
	local toward = TableWorld.towardSide("Player") -- +1: the player's side is +Z (behind = larger Z)
	local front = endZ + toward * Config.Ball.Radius
	local back = if toward > 0 then b.maxZ else b.minZ
	return {
		minX = b.minX,
		maxX = b.maxX,
		minZ = math.min(front, back),
		maxZ = math.max(front, back),
	}
end

-- May the player toss from here? Returns ok, reason (for the player), and the release point. The release point must be
-- in the region and the character's root on the platform (server-authoritative: RallyService also requires the feet on
-- the ground).
function ServeRules.check(rootCFrame: CFrame, scale: number, posture: string?): (boolean, string, Vector3)
	local r = ServeRules.region()
	local b = ServeRules.platformBounds()
	local p = ServeRules.handPoint(rootCFrame, scale, "release", posture)
	local root = rootCFrame.Position
	local behind = (p.Z - TableWorld.endLineZ("Player")) * TableWorld.towardSide("Player")
	if root.X < b.minX or root.X > b.maxX or root.Z < b.minZ or root.Z > b.maxZ then
		return false, "stand on the court", p
	elseif not CourtShape.contains(root) then
		return false, "stand on the court", p
	elseif behind < Config.Ball.Radius then
		return false, "step back behind your end line", p
	elseif p.X < r.minX or p.X > r.maxX or p.Z < r.minZ or p.Z > r.maxZ or not CourtShape.contains(p) then
		return false, "stay on the platform", p
	end
	return true, "ok", p
end

export type Phase = {
	enter: number, -- RELEASE times (seconds after the reference toss state) whose contact lands inside the phase
	ideal: number, -- the middle of the phase
	exit: number,
	cleanStart: number, -- releases between cleanStart and cleanEnd are clean contacts, the rest of the phase weak
	cleanEnd: number,
	idealPosition: Vector3, -- the ball at the ideal contact
	apex: number, -- release time whose contact would be at the toss's apex (before it: "still rising")
}

-- The contact phase of a toss: `toss` = the ball the moment it left the hand (or any later state of the same toss).
-- Simulates the toss with the shared physics; the paddle meets the ball HitDelay after a release, so every time returned
-- is a RELEASE time (contact time - HitDelay). The phase = the ball falling, its centre within ContactMin..MaxHeight above
-- the table and inside the stroke's reach (`anchor`, `reach`). nil if the toss is never strikable from there.
function ServeRules.phase(toss: BallPhysics.State, anchor: Vector3, reach: number): Phase?
	local S = Config.Serve
	local cfg, world = TableWorld.physics, TableWorld.world
	local lowY, highY = Config.Layout.SurfaceY + S.ContactMinHeight, Config.Layout.SurfaceY + S.ContactMaxHeight
	local s = BallPhysics.copyState(toss)
	s.resting = false
	local events: { BallPhysics.Event } = {}
	local n = math.floor(3 / cfg.fixedStep)
	local firstIn, lastIn, apex = nil :: number?, nil :: number?, nil :: number?
	local positions: { [number]: Vector3 } = {}
	for i = 1, n do
		local before = #events
		BallPhysics.tick(s, cfg, world, events)
		local t = i * cfg.fixedStep
		local p = s.position
		local falling = s.velocity.Y <= 0
		if falling and not apex then
			apex = t
		end
		-- (horizontal reach only: the serve's own height band replaces the rally's floor-height band, whose ceiling of
		-- 20 studs above the floor would cut the top of the toss's phase)
		if falling and p.Y <= highY and p.Y >= lowY and Vector2.new(p.X - anchor.X, p.Z - anchor.Z).Magnitude <= reach then
			firstIn = firstIn or t
			lastIn = t
			positions[i] = p
		elseif firstIn then
			break -- left the phase (below the band or out of reach): nothing later is strikable
		end
		if #events > before or s.resting then
			break -- the toss hit something (the floor / table): nothing later is strikable
		end
	end
	if not firstIn or not lastIn then
		return nil
	end
	local enter, exit = firstIn :: number, lastIn :: number
	local mid = (enter + exit) / 2
	local edge = (exit - enter) * math.clamp(S.WeakEdge, 0, 0.49)
	local midIndex = math.floor(mid / cfg.fixedStep + 0.5)
	local d = S.HitDelay
	return {
		enter = enter - d,
		ideal = mid - d,
		exit = exit - d,
		cleanStart = enter + edge - d,
		cleanEnd = exit - edge - d,
		idealPosition = positions[midIndex] or positions[math.floor(enter / cfg.fixedStep + 0.5)] or s.position,
		apex = (apex or enter) - d,
	}
end

-- Judge a release `t` seconds after the phase's reference state: "clean" | "weak" | "miss", and the reason.
function ServeRules.classify(t: number, w: Phase?): (string, string)
	if not w then
		return "miss", "the toss was never in reach"
	end
	if t < w.enter then
		return "miss", if t < w.apex then "too early (the ball was still rising)" elseif t < w.enter - 0.02 then "too early (the ball was still high)" else "out of reach"
	elseif t > w.exit then
		return "miss", "too late (the ball dropped past the paddle)"
	elseif t >= w.cleanStart and t <= w.cleanEnd then
		return "clean", "on time"
	end
	return "weak", if t < w.ideal then "early" else "late"
end

-- Where the serve's SECOND bounce is aimed (on the receiver's half, at landing height): across by `aim` (-1..1, screen
-- left .. right as the server looks down the table), along by `power` (0..1). Shared by the solver and the aim ring.
function ServeRules.target(aim: number, power: number, depthFactor: number?): Vector3
	local S = Config.Serve
	local c = TableWorld.center
	local maxX = math.max(TableWorld.halfWidth - S.LateralMargin, 0)
	local depth = (S.SecondDepthMin + (S.SecondDepthMax - S.SecondDepthMin) * math.clamp(power, 0, 1)) * (depthFactor or 1)
	depth = math.clamp(depth, 2, TableWorld.halfLength - 1)
	local toward = TableWorld.towardSide("Bot")
	return Vector3.new(c.X + math.clamp(aim, -1, 1) * maxX, Config.Layout.SurfaceY + Config.Ball.Radius, c.Z + toward * depth)
end

-- The cursor's horizontal position -> serve aim (-1 left .. +1 right), with a small dead zone at the centre.
function ServeRules.aimFromScreen(fraction: number): number
	local a = math.clamp((fraction - 0.5) * 2, -1, 1)
	local dead = Config.Serve.AimDeadZone
	if math.abs(a) <= dead then
		return 0
	end
	return math.sign(a) * (math.abs(a) - dead) / (1 - dead)
end

return ServeRules
