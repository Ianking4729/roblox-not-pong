--!strict
-- CourtShape (2026-11-21 coastal pier): the playing court's footprint in one place, so every system that asks "is this
-- on the court?" (serve eligibility, match start, the on/off-platform zone, the avatar fade, the bot's lateral limit)
-- agrees. The court is Config.Platform: a flat DISC (Shape "Disc", Radius) centred on Layout.PlatformCenter, or the old
-- rectangle (Shape "Rect", Size). Distances are horizontal (world X / Z); positive = inside, negative = outside.

local Config = require(script.Parent:WaitForChild("Config"))

local CourtShape = {}

-- Signed horizontal distance from the court's edge, from Config (no Instances): + inside, - outside.
function CourtShape.insideDistance(position: Vector3): number
	local P = Config.Platform
	local c = Config.Layout.PlatformCenter
	if P.Shape == "Disc" then
		return P.Radius - Vector2.new(position.X - c.X, position.Z - c.Z).Magnitude
	end
	return math.min(P.Size.X / 2 - math.abs(position.X - c.X), P.Size.Z / 2 - math.abs(position.Z - c.Z))
end

function CourtShape.contains(position: Vector3, margin: number?): boolean
	return CourtShape.insideDistance(position) >= (margin or 0)
end

-- The same, from the real Platform part (its CFrame and Size, so moving / resizing it in Studio is honoured). A Cylinder
-- part is a disc whose axis is the part's X axis (vertical when placed as the court); anything else is a box.
function CourtShape.partInsideDistance(platform: BasePart, position: Vector3): number
	local l = platform.CFrame:PointToObjectSpace(position)
	if platform:IsA("Part") and platform.Shape == Enum.PartType.Cylinder then
		local r = math.min(platform.Size.Y, platform.Size.Z) / 2
		return r - Vector2.new(l.Y, l.Z).Magnitude
	end
	return math.min(platform.Size.X / 2 - math.abs(l.X), platform.Size.Z / 2 - math.abs(l.Z))
end

-- Half-width of the court (world X, from its centre line) at world Z = z; 0 beyond its ends.
function CourtShape.halfWidthAt(z: number): number
	local P = Config.Platform
	local c = Config.Layout.PlatformCenter
	if P.Shape == "Disc" then
		local dz = z - c.Z
		return math.sqrt(math.max(P.Radius * P.Radius - dz * dz, 0))
	end
	return if math.abs(z - c.Z) <= P.Size.Z / 2 then P.Size.X / 2 else 0
end

-- COASTAL PIER bands (Config.Pier): the radius of every band edge from the court centre. `cfg` = a Config table (defaults
-- to the shared one; Edit-mode tools pass a freshly loaded Config).
function CourtShape.pierRadii(cfg: any?)
	local C = cfg or Config
	local P, R = C.Pier, C.Platform.Radius
	local rimOut = R + P.RimWidth
	local glassOut = rimOut + P.GlassWidth
	local innerBorderOut = glassOut + (P.InnerBorderWidth or 0)
	local trimOut = innerBorderOut + P.TrimWidth
	local outerBorderOut = trimOut + (P.OuterBorderWidth or 0)
	local promOut = outerBorderOut + P.PromenadeWidth
	return {
		court = R,
		rimOut = rimOut,
		glassOut = glassOut,
		innerBorderOut = innerBorderOut,
		trimOut = trimOut,
		outerBorderOut = outerBorderOut,
		promOut = promOut,
	}
end

-- The ONE radial height function of the pier's walkable top surface at horizontal distance r from the court centre:
-- flat (FloorY + RimLift) across the court and rim, then rising RiseSlope per stud outward. Used by PierBuilder (the
-- geometry) and TableWorld (the ball's ground), so what you see is what the ball lands on.
function CourtShape.deckHeightAt(r: number, cfg: any?): number
	local C = cfg or Config
	local P = C.Pier
	local h0 = C.Layout.FloorY + (P.RimLift or 0)
	local rimOut = C.Platform.Radius + P.RimWidth
	if r <= rimOut then
		return if r <= C.Platform.Radius then C.Layout.FloorY else h0
	end
	return h0 + P.RiseSlope * (r - rimOut)
end

return CourtShape
