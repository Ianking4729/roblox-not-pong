-- PierBuilder (Edit-mode tool; never runs at Play): SYNCS the coastal pier's structural geometry into
-- Workspace.<Config.Pier.Folder> from Config.Pier / Config.Platform (2026-11-21 blockout; cleanup pass 2026-11-21b).
--
-- LAYERS, centre outward, all directly adjoining: turf (visual; the invisible NotPongArena/Platform disc is the court's
-- collision) -> white rim -> walkable glass -> dark inner border -> turquoise band -> dark outer border -> warm
-- promenade -> railing. One height function (Shared/CourtShape.deckHeightAt, also the ball's ground) gives every top
-- surface: flat across turf and rim, then rising RiseSlope outward. Every circular edge comes from the same centre,
-- radii and Segments divisions, so neighbouring bands share vertices exactly: no cracks, no overlaps, no z-fighting.
-- Each band segment is a planar trapezoid (a centre block + two edge wedges, which tile exactly); the turf and the deck
-- slab under it are fans of triangles (two wedges each). Glass segments are unioned in pairs into single panels.
--
-- OWNERSHIP (what a rerun does):
--   * Builder-owned parts carry the attribute PierBuilt = true and a stable name. A rerun FINDS each by name and only
--     writes its GEOMETRY (Size, CFrame, Shape) and its STRUCTURAL flags (Anchored, CanCollide, CanQuery, CanTouch).
--     Colour, material, transparency, reflectance, CastShadow and any children you add (textures, decals,
--     SurfaceAppearance, attachments...) are written only when the part is first created, then left alone.
--   * Glass panels are CSG unions: a rerun keeps a panel whose geometry key (GeomKey) is unchanged; a panel whose shape
--     must change is rebuilt and inherits the old panel's look and children.
--   * Builder parts no longer produced by Config (e.g. after lowering Segments) are MOVED to ServerStorage
--     (NotPongCoast_Stale), never destroyed, and reported.
--   * Anything without PierBuilt (your detail assets, props, extra parts, folders) is never touched, moved or deleted.
--     Put detailed scenery in its own folder (Workspace.NotPongCoastDetail is reserved for that) or anywhere outside
--     the builder's band folders.
--   * The Baseplate (the beach) only has its size / position set; its look is set once (attribute PierBeach).
--
-- Usage (Edit mode, e.g. through the Studio MCP): require(this).build(Config) -> report table.

local GeometryService = game:GetService("GeometryService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CourtShape = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CourtShape"))

local PierBuilder = {}

local TOL = 1e-4

function PierBuilder.radii(Config)
	return CourtShape.pierRadii(Config)
end

function PierBuilder.heightAt(Config, r: number): number
	return CourtShape.deckHeightAt(r, Config)
end

-- ===== sync primitives =====

local function newCtx(root: Folder)
	return { root = root, seen = {}, created = 0, updated = 0, kept = 0, unionsBuilt = 0, unionsKept = 0, stale = 0, updatedNames = {} }
end

local function folderIn(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = name
	nf.Parent = parent
	return nf
end

-- Find-or-create a builder part by name and enforce its geometry; cosmetics only on creation.
local function put(ctx, parent: Instance, name: string, className: string, size: Vector3, cframe: CFrame, structural, looks, shape: Enum.PartType?): BasePart
	local p = parent:FindFirstChild(name)
	if p and (p.ClassName ~= className or not p:GetAttribute("PierBuilt")) then
		if p:GetAttribute("PierBuilt") then
			p = nil -- wrong class: the stale sweep moves it away (it is not marked seen)
		else
			-- a non-builder instance sits on a builder name: never touch it; build ours alongside under a suffixed name
			name ..= "_pb"
			p = parent:FindFirstChild(name)
		end
	end
	local created = false
	if not p then
		p = Instance.new(className)
		p.Name = name
		;(p :: BasePart).TopSurface = Enum.SurfaceType.Smooth
		;(p :: BasePart).BottomSurface = Enum.SurfaceType.Smooth
		;(p :: BasePart).Material = Enum.Material.SmoothPlastic
		for k, v in looks do
			(p :: any)[k] = v
		end
		p:SetAttribute("PierBuilt", true)
		created = true
	end
	local part = p :: BasePart
	if shape and part:IsA("Part") and part.Shape ~= shape then
		part.Shape = shape
	end
	local changed = created
	if (part.Size - size).Magnitude > TOL then
		part.Size = size
		changed = true
	end
	local pc = part.CFrame
	if (pc.Position - cframe.Position).Magnitude > TOL or (pc.LookVector - cframe.LookVector).Magnitude > TOL or (pc.UpVector - cframe.UpVector).Magnitude > TOL then
		part.CFrame = cframe
		changed = true
	end
	part.Anchored = true
	part.CanCollide = structural.CanCollide
	part.CanQuery = structural.CanQuery
	part.CanTouch = false
	if part.Parent ~= parent then
		part.Parent = parent
	end
	ctx.seen[part] = true
	if created then
		ctx.created += 1
	elseif changed then
		ctx.updated += 1
		if #ctx.updatedNames < 8 then
			table.insert(ctx.updatedNames, part:GetFullName())
		end
	else
		ctx.kept += 1
	end
	return part
end

local SOLID = { CanCollide = true, CanQuery = true }
local VISUAL = { CanCollide = false, CanQuery = false }

-- ===== geometry =====

-- The parts of one planar trapezoid segment (top surface on the cone) between radii rIn..rOut and angles th0..th1.
local function trapezoidSpecs(Config, centre: Vector3, rIn: number, rOut: number, th0: number, th1: number, thk: number)
	local half = (th1 - th0) / 2
	local phi = th0 + half
	local c, s = math.cos(half), math.sin(half)
	local a, b = rIn * s, rOut * s
	local hIn, hOut = PierBuilder.heightAt(Config, rIn), PierBuilder.heightAt(Config, rOut)
	local dr, dh = (rOut - rIn) * c, hOut - hIn
	local L = math.sqrt(dr * dr + dh * dh)
	local u = Vector3.new(math.cos(phi), 0, math.sin(phi))
	local R = (u * dr + Vector3.yAxis * dh) / L
	local T = Vector3.new(math.sin(phi), 0, -math.cos(phi))
	local N = R:Cross(T)
	local top = Vector3.new(centre.X, 0, centre.Z) + u * ((rIn + rOut) / 2 * c) + Vector3.yAxis * ((hIn + hOut) / 2)
	local mid = top - N * (thk / 2)
	local list = { { "Part", Vector3.new(2 * a, thk, L), CFrame.fromMatrix(mid, T, N) } }
	if b - a > 1e-3 then
		table.insert(list, { "WedgePart", Vector3.new(thk, b - a, L), CFrame.fromMatrix(mid + T * ((a + b) / 2), -N, T) })
		table.insert(list, { "WedgePart", Vector3.new(thk, b - a, L), CFrame.fromMatrix(mid - T * ((a + b) / 2), N, -T) })
	end
	return list
end

-- The two wedges of one flat fan slice (centre -> the circle's vertices at th0, th1), top at `topY`, `thk` thick.
local function fanSpecs(centre: Vector3, R: number, th0: number, th1: number, topY: number, thk: number)
	local half = (th1 - th0) / 2
	local phi = th0 + half
	local u = Vector3.new(math.cos(phi), 0, math.sin(phi))
	local Tp = Vector3.new(-math.sin(phi), 0, math.cos(phi)) -- toward increasing angle
	local L, H = R * math.cos(half), R * math.sin(half)
	local M = Vector3.new(centre.X, topY - thk / 2, centre.Z) + u * L -- chord midpoint, at the slab's mid-depth
	local list = {}
	for _, yDir in { Tp, -Tp } do
		local pos = M - u * (L / 2) + yDir * (H / 2)
		table.insert(list, { "WedgePart", Vector3.new(thk, H, L), CFrame.fromMatrix(pos, yDir:Cross(u), yDir) })
	end
	return list
end

local function bandPlain(ctx, Config, parent: Folder, name: string, rIn: number, rOut: number, thk: number, structural, looks)
	local n = Config.Pier.Segments
	local centre = Config.Layout.PlatformCenter
	for i = 0, n - 1 do
		local th0, th1 = i / n * 2 * math.pi, (i + 1) / n * 2 * math.pi
		for k, spec in trapezoidSpecs(Config, centre, rIn, rOut, th0, th1, thk) do
			put(ctx, parent, ("%s_%03d_%d"):format(name, i, k), spec[1], spec[2], spec[3], structural, looks)
		end
	end
end

-- A compact, stable fingerprint of a union's source shapes (a rerun keeps a union whose key is unchanged).
local function geomKey(specs): string
	local h1, h2 = 0, 0
	for i, s in specs do
		local cf = s[3]
		local lv, uv = cf.LookVector, cf.UpVector
		for k, v in { s[2].X, s[2].Y, s[2].Z, cf.X, cf.Y, cf.Z, lv.X, lv.Y, lv.Z, uv.X, uv.Y, uv.Z } do
			local q = math.floor(v * 1000 + 0.5)
			h1 = (h1 * 31 + q + i * 7 + k) % 2147483647
			h2 = (h2 * 131 + q * (k + 3)) % 2147483629
		end
	end
	return ("%d:%d:%d"):format(#specs, h1, h2)
end

-- Find-or-build a CSG union of `specs` named `name` (one mesh: no internal faces or seams). Kept when its geometry key
-- is unchanged; when rebuilt it inherits the old union's look and children.
local function unionPart(ctx, parent: Instance, name: string, specs, looks, structural, fidelity: Enum.CollisionFidelity)
	local key = geomKey(specs)
	local old = parent:FindFirstChild(name)
	if old and old:GetAttribute("PierBuilt") and old:IsA("UnionOperation") and old:GetAttribute("GeomKey") == key then
		old.Anchored, old.CanCollide, old.CanQuery, old.CanTouch = true, structural.CanCollide, structural.CanQuery, false
		ctx.seen[old] = true
		ctx.unionsKept += 1
		return old
	end
	local temp = {}
	for _, spec in specs do
		local p = Instance.new(spec[1]) :: BasePart
		p.Anchored = true
		p.Size, p.CFrame = spec[2], spec[3]
		p.Parent = workspace
		table.insert(temp, p)
	end
	local others = table.clone(temp)
	table.remove(others, 1)
	local ok, res = pcall(function()
		return GeometryService:UnionAsync(temp[1], others, {
			CollisionFidelity = fidelity,
			RenderFidelity = Enum.RenderFidelity.Precise,
			SplitApart = false,
		})
	end)
	for _, p in temp do
		p:Destroy()
	end
	if not (ok and res and res[1]) then
		warn("[PierBuilder] union failed for " .. name .. ": " .. tostring(res))
		if old then
			ctx.seen[old] = true -- keep what was there rather than leave a hole
		end
		return nil
	end
	local u = res[1] :: UnionOperation
	u.Name = name
	u.Anchored, u.CanCollide, u.CanQuery, u.CanTouch = true, structural.CanCollide, structural.CanQuery, false
	u.UsePartColor = true
	if old and old:IsA("BasePart") and old:GetAttribute("PierBuilt") then
		for _, prop in { "Color", "Material", "Transparency", "Reflectance", "CastShadow", "MaterialVariant" } do
			pcall(function()
				(u :: any)[prop] = (old :: any)[prop]
			end)
		end
		for _, ch in old:GetChildren() do
			ch.Parent = u
		end
		old:Destroy()
	else
		u.Material = Enum.Material.SmoothPlastic
		for k, v in looks do
			(u :: any)[k] = v
		end
	end
	u:SetAttribute("PierBuilt", true)
	u:SetAttribute("GeomKey", key)
	u.Parent = parent
	ctx.seen[u] = true
	ctx.unionsBuilt += 1
	if ctx.unionsBuilt % 8 == 0 then
		task.wait()
	end
	return u
end

-- Glass: each panel = GlassPanelSegments adjacent trapezoids unioned (no internal faces show through the glass).
local function bandGlass(ctx, Config, parent: Folder, rIn: number, rOut: number, looks)
	local P = Config.Pier
	local n, per = P.Segments, math.max(P.GlassPanelSegments or 1, 1)
	local centre = Config.Layout.PlatformCenter
	for j = 0, math.ceil(n / per) - 1 do
		local specs = {}
		for i = j * per, math.min((j + 1) * per, n) - 1 do
			for _, spec in trapezoidSpecs(Config, centre, rIn, rOut, i / n * 2 * math.pi, (i + 1) / n * 2 * math.pi, P.GlassThickness) do
				table.insert(specs, spec)
			end
		end
		unionPart(ctx, parent, ("Glass_%03d"):format(j), specs, looks, SOLID, Enum.CollisionFidelity.Hull)
	end
end

-- A part along p0 -> p1 (both on its centre line), cross-section w x h.
local function beamSpec(p0: Vector3, p1: Vector3, w: number, h: number): (Vector3, CFrame)
	return Vector3.new(w, h, (p1 - p0).Magnitude), CFrame.lookAt((p0 + p1) / 2, p1)
end

local function angDiff(a: number, b: number): number
	return math.abs((a - b + math.pi) % (2 * math.pi) - math.pi)
end

-- ===== the build =====

function PierBuilder.build(Config)
	local P = Config.Pier
	local C = P.Colors
	local rr = PierBuilder.radii(Config)
	local centre = Config.Layout.PlatformCenter
	local cx, cz = centre.X, centre.Z
	local floorY = Config.Layout.FloorY
	local n = P.Segments

	local root = workspace:FindFirstChild(P.Folder)
	if not root then
		root = Instance.new("Folder")
		root.Name = P.Folder
		root.Parent = workspace
	end
	root:SetAttribute("Blockout", true)
	root:SetAttribute("BuiltFrom", "Config.Pier (PierBuilder.build: sync)")
	local ctx = newCtx(root :: Folder)
	local function sub(name: string): Folder
		return folderIn(root, name)
	end

	-- TURF (visual) + DECK SLAB: fans on the court circle's own vertices (the rim's inner edge uses the same ones)
	local court = sub("Court")
	local turfTop = floorY
	local turfThk = P.TurfThickness
	local deckThk = P.DeckThickness
	for i = 0, n - 1 do
		local th0, th1 = i / n * 2 * math.pi, (i + 1) / n * 2 * math.pi
		for k, spec in fanSpecs(centre, rr.court, th0, th1, turfTop - turfThk, deckThk) do
			put(ctx, court, ("Deck_%03d_%d"):format(i, k), spec[1], spec[2], spec[3], VISUAL, { Color = C.Deck })
		end
	end
	-- TURF (visual; the court's collision is the invisible NotPongArena/Platform disc). Measured 2026-11-21: a fan of
	-- 256 thin wedges, or CSG unions of it, rendered faint dark specks across the turf from the gameplay camera, while a
	-- single plain part rendered none. So the playing surface uses as few edges as possible:
	--   * TurfCore: one plain disc covering the middle (its own coarse polygon edge lies hidden under the edge ring),
	--     0.005 below the surface;
	--   * TurfEdge ring: TurfEdgeWidth wide, Segments exact trapezoids whose outer edge is the court circle's 128-gon,
	--     shared exactly with the rim. (Where the ring overlaps the core both are the same green.)
	local edgeW = P.TurfEdgeWidth or 2.5
	-- the core's own (coarse, Roblox-tessellated) polygon edge must stay under the ring: its corners at coreR (inside
	-- the court circle) and its flat sides no further in than the ring's inner edge (holds for 16+ sided cylinders)
	local coreR = rr.court - 0.8
	put(ctx, court, "TurfCore", "Part", Vector3.new(turfThk, 2 * coreR, 2 * coreR),
		CFrame.new(cx, turfTop - 0.005 - turfThk / 2, cz) * CFrame.Angles(0, 0, math.pi / 2), VISUAL, { Color = C.Turf }, Enum.PartType.Cylinder)
	bandPlain(ctx, Config, court, "TurfEdge", rr.court - edgeW, rr.court, turfThk, VISUAL, { Color = C.Turf })
	-- (the pre-cleanup single cylinder slab is retired; the stale sweep moves it out)

	-- RIM (flush with the turf; its white fascia reaches the deck's underside)
	bandPlain(ctx, Config, sub("Rim"), "Rim", rr.court, rr.rimOut, P.RimDepth, SOLID, { Color = C.Rim })
	-- GLASS
	bandGlass(ctx, Config, sub("Glass"), rr.rimOut, rr.glassOut, {
		Color = C.Glass,
		Material = Enum.Material.Glass,
		Transparency = P.GlassTransparency or 0.6,
		Reflectance = 0.04,
		CastShadow = false,
	})
	task.wait()
	-- BORDERS + TURQUOISE + PROMENADE (same slope, flush)
	bandPlain(ctx, Config, sub("Trim"), "InnerBorder", rr.glassOut, rr.innerBorderOut, P.TrimThickness, SOLID, { Color = C.Border })
	bandPlain(ctx, Config, sub("Trim"), "Trim", rr.innerBorderOut, rr.trimOut, P.TrimThickness, SOLID, { Color = C.Trim })
	bandPlain(ctx, Config, sub("Trim"), "OuterBorder", rr.trimOut, rr.outerBorderOut, P.TrimThickness, SOLID, { Color = C.Border })
	task.wait()
	bandPlain(ctx, Config, sub("Promenade"), "Promenade", rr.outerBorderOut, rr.promOut, P.PromenadeThickness, SOLID, { Color = C.Promenade })
	task.wait()

	-- GLASS FRAMING: a slim radial mullion under every panel joint
	local frame = sub("GlassFrame")
	local per = math.max(P.GlassPanelSegments or 1, 1)
	for j = 0, math.ceil(n / per) - 1 do
		local th = j * per / n * 2 * math.pi
		local d = Vector3.new(math.cos(th), 0, math.sin(th))
		local function at(r: number): Vector3
			return Vector3.new(cx, 0, cz) + d * r + Vector3.yAxis * (PierBuilder.heightAt(Config, r) - P.GlassThickness - 0.2)
		end
		local size, cf = beamSpec(at(rr.rimOut), at(rr.glassOut), 0.25, 0.4)
		put(ctx, frame, ("Mullion_%03d"):format(j), "Part", size, cf, VISUAL, { Color = C.Frame, CastShadow = false })
	end

	-- PIER COLUMNS
	local cols = sub("Supports")
	local deckUnder = turfTop - turfThk - deckThk
	for ringIndex, ring in P.ColumnRings do
		local r
		if ring.Radius then
			r = ring.Radius
		elseif ring.Band == "Rim" then
			r = (rr.court + rr.rimOut) / 2
		elseif ring.Band == "Trim" then
			r = (rr.glassOut + rr.outerBorderOut) / 2
		elseif ring.Band == "PromenadeOuter" then
			r = rr.promOut - (ring.Inset or 1)
		else
			r = rr.court
		end
		local underside
		if r < rr.court then
			underside = deckUnder
		elseif r <= rr.rimOut then
			underside = PierBuilder.heightAt(Config, r) - P.RimDepth
		elseif r <= rr.glassOut then
			underside = PierBuilder.heightAt(Config, r) - P.GlassThickness
		elseif r <= rr.outerBorderOut then
			underside = PierBuilder.heightAt(Config, r) - P.TrimThickness
		else
			underside = PierBuilder.heightAt(Config, r) - P.PromenadeThickness
		end
		for k = 0, ring.Count - 1 do
			local th = (k + 0.5) / ring.Count * 2 * math.pi
			local x, z = cx + r * math.cos(th), cz + r * math.sin(th)
			local h = underside - P.BeachTopY
			put(ctx, cols, ("Column_%d_%02d"):format(ringIndex, k), "Part", Vector3.new(h, P.ColumnDiameter, P.ColumnDiameter),
				CFrame.new(x, (underside + P.BeachTopY) / 2, z) * CFrame.Angles(0, 0, math.pi / 2), SOLID, { Color = C.Column }, Enum.PartType.Cylinder)
		end
	end

	-- OUTER RAILING: posts every RailPostEvery divisions, top + mid rails, an opening the ramp's width
	local rail = sub("Railing")
	local railLook = { Color = C.Rail }
	local rRail = rr.promOut - 0.5
	local stairDir = math.rad(P.StairAngle)
	local openHalf = (P.StairWidth / 2 + 0.6) / rRail
	local every = math.max(P.RailPostEvery or 1, 1)
	local base = PierBuilder.heightAt(Config, rRail)
	local posts = {}
	local postList = {}
	for i = 0, n - 1, every do
		local th = i / n * 2 * math.pi
		if angDiff(th, stairDir) > openHalf then
			local pp = Vector3.new(cx + rRail * math.cos(th), base, cz + rRail * math.sin(th))
			put(ctx, rail, ("Post_%03d"):format(i), "Part", Vector3.new(0.45, P.RailHeight, 0.45), CFrame.new(pp + Vector3.yAxis * (P.RailHeight / 2)), SOLID, railLook)
			posts[i] = pp
		end
		table.insert(postList, i)
	end
	local function rails(name: string, a: Vector3, b: Vector3)
		local s1, c1 = beamSpec(a + Vector3.yAxis * P.RailHeight, b + Vector3.yAxis * P.RailHeight, 0.4, 0.4)
		put(ctx, rail, "TopRail_" .. name, "Part", s1, c1, SOLID, railLook)
		local s2, c2 = beamSpec(a + Vector3.yAxis * (P.RailHeight * 0.5), b + Vector3.yAxis * (P.RailHeight * 0.5), 0.25, 0.25)
		put(ctx, rail, "MidRail_" .. name, "Part", s2, c2, SOLID, railLook)
	end
	for idx, i in postList do
		local j = postList[idx % #postList + 1]
		if posts[i] and posts[j] then
			rails(("%03d"):format(i), posts[i], posts[j])
		end
	end
	local step = every / n * 2 * math.pi
	for _, side in { -1, 1 } do
		local e = stairDir + side * openHalf
		local ep = Vector3.new(cx + rRail * math.cos(e), base, cz + rRail * math.sin(e))
		local tag = if side < 0 then "A" else "B"
		put(ctx, rail, "StairPost_" .. tag, "Part", Vector3.new(0.45, P.RailHeight, 0.45), CFrame.new(ep + Vector3.yAxis * (P.RailHeight / 2)), SOLID, railLook)
		for i, pp in posts do
			local th = i / n * 2 * math.pi
			if angDiff(th, e) < step then
				rails("Stair" .. tag, ep, pp)
			end
		end
	end

	-- STAIR (plain blockout ramp): a landing continuing the promenade's slope, then a ramp to the beach
	local stair = sub("Stair")
	local d = Vector3.new(math.cos(stairDir), 0, math.sin(stairDir))
	local function surf(r: number): Vector3
		return Vector3.new(cx, 0, cz) + d * r + Vector3.yAxis * PierBuilder.heightAt(Config, r)
	end
	local r0, r1 = rr.promOut - 1.2, rr.promOut + 2
	do
		local size, cf = beamSpec(surf(r0), surf(r1), P.StairWidth, P.PromenadeThickness)
		put(ctx, stair, "Landing", "Part", size, cf * CFrame.new(0, -P.PromenadeThickness / 2, 0), SOLID, { Color = C.Promenade })
		local top = surf(r1)
		local bottom = Vector3.new(cx, P.BeachTopY, cz) + d * (r1 + P.StairRun)
		local s2, c2 = beamSpec(top, bottom, P.StairWidth, 1)
		put(ctx, stair, "Ramp", "Part", s2, c2 * CFrame.new(0, -0.5, 0), SOLID, { Color = C.Promenade })
	end

	-- BEACH (the Baseplate: geometry each run, look once) + WATER
	local beach = workspace:FindFirstChild("Baseplate")
	if beach and beach:IsA("BasePart") then
		local w = 256 - P.ShoreX
		beach.Size = Vector3.new(w, 20, 512)
		beach.CFrame = CFrame.new(P.ShoreX + w / 2, P.BeachTopY - 10, 0)
		if not beach:GetAttribute("PierBeach") then
			beach.Color = C.Sand
			beach.Material = Enum.Material.Sand
			beach:SetAttribute("PierBeach", true)
		end
	end
	local sea = sub("Sea")
	put(ctx, sea, "ShoreSlope", "WedgePart", Vector3.new(512, 1.5, 14), CFrame.new(P.ShoreX - 7, P.BeachTopY - 0.75, 0) * CFrame.Angles(0, math.rad(90), 0), SOLID, { Color = C.Sand, Material = Enum.Material.Sand })
	put(ctx, sea, "Shallows", "Part", Vector3.new(240, 1, 1600), CFrame.new(P.ShoreX - 120, P.BeachTopY - 1.1, 0), VISUAL, { Color = C.Shallow, Transparency = 0.15, CastShadow = false })
	-- (2048 = Roblox's maximum part size; a larger request is clamped and would never match on rerun)
	put(ctx, sea, "DeepWater", "Part", Vector3.new(1400, 1, 2048), CFrame.new(P.ShoreX - 240 - 700, P.BeachTopY - 1.15, 0), VISUAL, { Color = C.Deep, CastShadow = false })

	-- STALE SWEEP: builder parts no longer produced are moved (never destroyed) to ServerStorage
	local staleFolder: Folder? = nil
	for _, x in root:GetDescendants() do
		if x:IsA("BasePart") and x:GetAttribute("PierBuilt") ~= nil and not ctx.seen[x] then
			-- (pre-cleanup parts had no PierBuilt attribute but are recognised by their folder; see the migration below)
			staleFolder = staleFolder or folderIn(game:GetService("ServerStorage"), P.Folder .. "_Stale")
			x.Parent = staleFolder
			ctx.stale += 1
		end
	end
	for _, f in root:GetChildren() do
		if f:IsA("Folder") and #f:GetChildren() == 0 then
			f:Destroy() -- (an emptied builder folder, e.g. the retired CourtDeck)
		end
	end

	local report = {
		created = ctx.created,
		updated = ctx.updated,
		kept = ctx.kept,
		unionsBuilt = ctx.unionsBuilt,
		unionsKept = ctx.unionsKept,
		staleMoved = ctx.stale,
		updatedNames = ctx.updatedNames,
		radii = rr,
		heights = {
			rimOut = PierBuilder.heightAt(Config, rr.rimOut),
			glassOut = PierBuilder.heightAt(Config, rr.glassOut),
			outerBorderOut = PierBuilder.heightAt(Config, rr.outerBorderOut),
			promOut = PierBuilder.heightAt(Config, rr.promOut),
		},
	}
	local count = 0
	for _, x in root:GetDescendants() do
		if x:IsA("BasePart") then
			count += 1
		end
	end
	report.parts = count
	return report
end

-- One-time migration of the first blockout (no PierBuilt attributes): mark every part under the builder's band folders
-- as builder-owned so the next build() replaces / updates them instead of duplicating. Returns how many were marked.
function PierBuilder.adoptLegacy(Config): number
	local root = workspace:FindFirstChild(Config.Pier.Folder)
	if not root then
		return 0
	end
	local n = 0
	for _, f in { "Rim", "Glass", "Trim", "Promenade", "GlassFrame", "CourtDeck", "Supports", "Railing", "Stair", "Sea" } do
		local folder = root:FindFirstChild(f)
		if folder then
			for _, x in folder:GetDescendants() do
				if x:IsA("BasePart") and x:GetAttribute("PierBuilt") == nil then
					x:SetAttribute("PierBuilt", true)
					n += 1
				end
			end
		end
	end
	return n
end

return PierBuilder
