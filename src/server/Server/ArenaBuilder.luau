-- ArenaBuilder: the NOT PONG arena as a hybrid of STATIC (persistent in Studio) and DYNAMIC (runtime) objects.
--
-- STATIC, saved in the place and editable in Edit mode (Workspace.NotPongArena):
--   Table/Collision/TableTop   invisible solid block, floor to playing surface (gameplay: do not edit)
--   Table/Visual/*             TableSurface, lines, legs (cosmetic: recolour, re-material, add textures freely)
--   Net/*                      NetMesh, NetTape, PostLeft, PostRight
--   Platform                   the playing slab
--   BallTemplate/Ball          the one ball (gameplay part + BallVisual shell); appearance is yours
--   PlayerSpawn, BotSpawn      markers: their X/Z is where each competitor stands (move them freely)
-- DYNAMIC, created at runtime and never saved: Ball (+ BallVisual), the characters, paddles.
--
-- Two entry points:
--   syncGeometry(folder?)  create-or-update every static part BY NAME from Config. Geometry properties (size, position,
--                          anchoring, collision, collision group) are always enforced; cosmetic properties (colour,
--                          material, transparency, textures) are written only when a part is first created, so your
--                          edits are never overwritten. Idempotent. Run it in Edit mode after changing Config.
--   load()                 what the game calls at Play. Finds the existing arena (never rebuilds it), reports duplicates,
--                          re-syncs geometry IN MEMORY if the saved arena is out of date with Config (and warns), then
--                          adds the dynamic ball. Falls back to creating the arena only if none exists.
--
-- GAMEPLAY vs COSMETIC (kept separate on purpose)
--   Ball:  `Ball` is the gameplay part (canonical diameter, invisible, what the physics moves). `Ball/BallVisual` is
--          the shell (Config.Ball.VisualDiameter) that styles touch. Styles never change sizes or collision.
--          Both are anchored, so MOVE THE BALL ONLY THROUGH ArenaBuilder.moveBall.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CollisionSetup = require(script.Parent:WaitForChild("CollisionSetup"))

local ArenaBuilder = {}

ArenaBuilder.VERSION = 1
local TOLERANCE = 1e-3
local LINE_HEIGHT = 0.02 -- 2 mm of paint, sitting on the playing surface
local WALL_THICKNESS, WALL_HEIGHT = 4, 80

-- Tooling hook: edit-mode scripts cache required modules, so a tool can hand in a fresh Config.
function ArenaBuilder.setConfig(newConfig)
	Config = newConfig
end

-- Create-or-find a child by name. Returns the instance and whether it was created.
local function ensure(parent: Instance, className: string, name: string): (Instance, boolean)
	local existing = parent:FindFirstChild(name)
	-- A user may swap a Part for a MeshPart/UnionOperation for looks: keep any BasePart where a Part is expected.
	if existing and (existing.ClassName == className or (className == "Part" and existing:IsA("BasePart") and not existing:IsA("SpawnLocation"))) then
		return existing, false
	end
	if existing then
		existing:Destroy() -- wrong class under a reserved name: replace it
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst, true
end

-- Geometry (always enforced) vs cosmetics (first creation only).
local function setGeometry(part: BasePart, size: Vector3, cframe: CFrame, collides: boolean, group: string)
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.CanCollide = collides
	part.CanQuery = collides
	part.CanTouch = false
	part.CollisionGroup = group
end

local function cosmetic(part: BasePart, created: boolean, props: { [string]: any })
	if not created then
		return
	end
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		(part :: any)[k] = v
	end
end

local function part(parent: Instance, name: string): (Part, boolean)
	local p, created = ensure(parent, "Part", name)
	return p :: Part, created
end

-- STATIC GEOMETRY ---------------------------------------------------------------------------------------

-- The uploaded table model (Table/Visual/TableAsset), or nil when the arena still uses the primitive placeholder visuals.
function ArenaBuilder.tableAsset(arena: Instance?): Model?
	local folder = arena or Workspace:FindFirstChild(Config.Names.Arena)
	local t = folder and folder:FindFirstChild("Table")
	local v = t and t:FindFirstChild("Visual")
	local asset = v and v:FindFirstChild(Config.Names.TableAsset)
	return if asset and asset:IsA("Model") then asset else nil
end

-- `gameplayOnly` (used at Play when the saved arena is out of date): only the gameplay parts (collision table block, net
-- collision, platform, ball sizes) are corrected; visual parts, the table asset and the spawn markers are not touched.
function ArenaBuilder.syncGeometry(existing: Folder?, gameplayOnly: boolean?): Folder
	local T, N, L, P, C = Config.Table, Config.Net, Config.Layout, Config.Platform, Config.Colors
	local G = Config.CollisionGroups
	local origin = Config.Arena.Origin
	local halfW, halfL = T.Width / 2, T.Length / 2

	local folder = existing or Workspace:FindFirstChild(Config.Names.Arena)
	if not folder then
		local f = Instance.new("Folder")
		f.Name = Config.Names.Arena
		f.Parent = Workspace
		folder = f
	end
	local arena = folder :: Folder
	arena:SetAttribute(Config.Names.ArenaVersionAttribute, ArenaBuilder.VERSION)

	-- TABLE ------------------------------------------------------------------------------------------
	local tableModel = ensure(arena, "Model", "Table") :: Model
	local collisionFolder = ensure(tableModel, "Folder", "Collision")
	local visualFolder = ensure(tableModel, "Folder", "Visual")
	-- With an uploaded table asset, the asset IS the visual table (fitted by fitTableAsset); the primitive placeholder
	-- visuals are neither created nor updated, and the net parts below are collision only (invisible).
	local hasAsset = ArenaBuilder.tableAsset(arena) ~= nil
	local buildVisuals = not gameplayOnly and not hasAsset

	-- Gameplay: one invisible block from the floor to the playing surface (also stops avatars walking under it).
	local top, topNew = part(collisionFolder, "TableTop")
	setGeometry(
		top,
		Vector3.new(T.Width, T.Height, T.Length),
		CFrame.new(origin.X, L.FloorY + T.Height / 2, origin.Z),
		true,
		G.Table
	)
	cosmetic(top, topNew, { Transparency = 1 })
	top.CanQuery = false

	if buildVisuals then
	local surface, surfaceNew = part(visualFolder, "TableSurface")
	setGeometry(surface, Vector3.new(T.Width, T.TopThickness, T.Length), CFrame.new(L.TableTopCenter), false, G.Table)
	cosmetic(surface, surfaceNew, {})
	surface:SetAttribute("StyleRole", "Surface")
	if surfaceNew then
		ArenaBuilder.applyTableStyle({ Table = tableModel }, Config.Table.Style) -- initial look only
	end

	local lineY = L.SurfaceY + LINE_HEIGHT / 2
	local function line(name: string, size: Vector3, offsetX: number, offsetZ: number)
		local p, created = part(visualFolder, name)
		setGeometry(p, size, CFrame.new(origin.X + offsetX, lineY, origin.Z + offsetZ), false, G.Table)
		cosmetic(p, created, { Color = Config.TableStyles[Config.Table.Style].LineColor })
		p:SetAttribute("StyleRole", "Line")
	end
	line("SideLineLeft", Vector3.new(T.LineWidth, LINE_HEIGHT, T.Length), -(halfW - T.LineWidth / 2), 0)
	line("SideLineRight", Vector3.new(T.LineWidth, LINE_HEIGHT, T.Length), halfW - T.LineWidth / 2, 0)
	line("EndLinePlayer", Vector3.new(T.Width, LINE_HEIGHT, T.LineWidth), 0, halfL - T.LineWidth / 2)
	line("EndLineBot", Vector3.new(T.Width, LINE_HEIGHT, T.LineWidth), 0, -(halfL - T.LineWidth / 2))
	line("CenterLine", Vector3.new(T.CenterLineWidth, LINE_HEIGHT, T.Length), 0, 0)

	local legHeight = L.SurfaceY - T.TopThickness - L.FloorY
	local signs = { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
	for i, sign in signs do
		local leg, created = part(visualFolder, "Leg" .. i)
		setGeometry(
			leg,
			Vector3.new(T.LegWidth, legHeight, T.LegWidth),
			CFrame.new(
				origin.X + sign[1] * (halfW - T.LegInsetX),
				L.FloorY + legHeight / 2,
				origin.Z + sign[2] * (halfL - T.LegInsetZ)
			),
			false, -- the Collision block already fills this space
			G.Table
		)
		cosmetic(leg, created, { Color = C.Leg })
	end
	end -- buildVisuals
	tableModel.PrimaryPart = top

	-- NET (collision for characters; the ball uses TableWorld). Visible only without a table asset. ---------------
	local netModel = ensure(arena, "Model", "Net") :: Model
	local mesh, meshNew = part(netModel, "NetMesh")
	setGeometry(mesh, Vector3.new(N.Length, N.Height, N.Thickness), CFrame.new(L.NetCenter), true, G.Table)
	mesh.CanQuery = false
	cosmetic(mesh, meshNew, { Color = C.Net, Transparency = 0.35 })
	local function collisionOnly(p: BasePart)
		if hasAsset then
			p.Transparency = 1 -- the asset's net is the visible one; this part only blocks characters
		end
	end
	collisionOnly(mesh)
	local tape, tapeNew = part(netModel, "NetTape")
	setGeometry(
		tape,
		Vector3.new(N.Length, N.TapeHeight, N.Thickness * 2),
		CFrame.new(origin.X, L.SurfaceY + N.Height - N.TapeHeight / 2, origin.Z),
		true,
		G.Table
	)
	tape.CanQuery = false
	cosmetic(tape, tapeNew, { Color = C.Line })
	collisionOnly(tape)
	local postHeight = N.Height + 0.1
	for _, sign in { -1, 1 } do
		local post, created = part(netModel, if sign < 0 then "PostLeft" else "PostRight")
		setGeometry(
			post,
			Vector3.new(N.PostWidth, postHeight, N.PostWidth * 2),
			CFrame.new(origin.X + sign * (N.Length / 2 + N.PostWidth / 2), L.SurfaceY + postHeight / 2, origin.Z),
			true,
			G.Table
		)
		post.CanQuery = false
		cosmetic(post, created, { Color = C.Leg })
		collisionOnly(post)
	end
	if not netModel.PrimaryPart then
		netModel.PrimaryPart = mesh
	end

	-- PLATFORM -------------------------------------------------------------------------------------
	local platform, platformNew = part(arena, Config.Names.PlatformPart)
	setGeometry(platform, P.Size, CFrame.new(L.PlatformCenter), true, "Default")
	platform.CanQuery = true
	cosmetic(platform, platformNew, { Color = P.Color, Material = P.Material })

	-- BALL TEMPLATE (visible in Edit mode) ------------------------------------------------------------
	-- `Ball` is the canonical gameplay part (invisible); `Ball/BallVisual` is the cosmetic shell. Sizes are enforced,
	-- appearance is yours. The Edit-mode position is only a preview: Play moves the ball to the serve point.
	local B = Config.Ball
	local ballFolder = ensure(arena, "Folder", "BallTemplate")
	local ball, ballNew = part(ballFolder, "Ball")
	setGeometry(ball, Vector3.new(B.Diameter, B.Diameter, B.Diameter), ball.CFrame, false, G.Ball)
	ball.CanQuery = false
	if ballNew then
		ball.Shape = Enum.PartType.Ball
		ball.CFrame = CFrame.new(L.ServeBall[Config.Match.FirstServer])
		ball.Transparency = 1
	end
	local visual, visualNew = part(ball, "BallVisual")
	-- The visual's SIZE is gameplay-matched (Config.Ball.VisualDiameter = the collision diameter at BallVisualScale 1);
	-- its appearance (colour, material, textures, trail, decals) is yours and never written after creation.
	setGeometry(visual, Vector3.new(B.VisualDiameter, B.VisualDiameter, B.VisualDiameter), ball.CFrame, false, G.Ball)
	visual.CanQuery = false
	if visualNew then
		visual.Shape = Enum.PartType.Ball
		ArenaBuilder.applyBallStyle({ BallVisual = visual }, Config.Ball.Style) -- initial look only
	end
	if gameplayOnly then
		return arena
	end

	-- SPAWN MARKERS (position is YOURS to edit; only created here, never repositioned) -----------------
	local spawn, spawnNew = ensure(arena, "SpawnLocation", Config.Names.PlayerSpawn)
	local sp = spawn :: SpawnLocation
	sp.Anchored = true
	sp.Neutral = true
	sp.Duration = 0
	sp.CanCollide = false
	sp.CanQuery = false
	sp.CanTouch = false
	if spawnNew then
		sp.Size = Vector3.new(6, 1, 6)
		sp.CFrame = CFrame.lookAt(L.PlayerStand + Vector3.new(0, 0.5, 0), L.PlayerStand + Vector3.new(0, 0.5, 0) + L.PlayerFacing)
		sp.Color = Color3.fromRGB(80, 200, 120)
		sp.Transparency = 0.5
		sp.Material = Enum.Material.Neon
		local decal = sp:FindFirstChildOfClass("Decal")
		if decal then
			decal:Destroy()
		end
	end
	local botSpawn, botNew = part(arena, Config.Names.BotSpawn)
	botSpawn.Anchored = true
	botSpawn.CanCollide = false
	botSpawn.CanQuery = false
	botSpawn.CanTouch = false
	if botNew then
		botSpawn.Size = Vector3.new(6, 1, 6)
		botSpawn.CFrame = CFrame.lookAt(L.BotStand + Vector3.new(0, 0.5, 0), L.BotStand + Vector3.new(0, 0.5, 0) + L.BotFacing)
		botSpawn.Color = Color3.fromRGB(220, 90, 90)
		botSpawn.Transparency = 0.5
		botSpawn.Material = Enum.Material.Neon
	end

	return arena
end

-- TABLE ASSET FIT ---------------------------------------------------------------------------------------
-- The uploaded table (Table/Visual/TableAsset) is authored at its own native size. fitTableAsset() maps it onto the
-- gameplay table from Config with a per-zone linear map, recorded so re-fitting is exact and idempotent:
--   * model attributes  Native*      : the native table (surface centre, width, length, surface/underside/floor heights,
--                                      net height above the surface, net length), recorded on the FIRST fit;
--   * part attributes   FitZone      : "Top" (the slab: top + lines), "Legs" (below the slab), "Net" (above the surface);
--                       FitStructural: true = must match gameplay (top, lines, net); checked at Play and corrected in
--                                      memory if it drifted. false = cosmetic geometry (legs, holders, clamp): only
--                                      written by fitTableAsset(), never at Play, so your resizing of them sticks;
--                       FitSource*   : the part's native size, position and rotation.
-- Parts without FitZone (anything you add to the model later) are never moved or resized by code.
-- Only Size and CFrame are ever written: colour, material, textures, SurfaceAppearance, children are untouched.

local function zoneMap()
	local T, N, L = Config.Table, Config.Net, Config.Layout
	local O = Config.Arena.Origin
	return {
		origin = Vector3.new(O.X, L.SurfaceY, O.Z),
		width = T.Width,
		length = T.Length,
		netLength = N.Length,
		netHeight = N.Height,
		surfaceY = L.SurfaceY,
		topThickness = T.TopThickness,
		floorY = L.FloorY,
	}
end

-- Expected (size, cframe) for a fitted part, or nil if the part is not part of the fit.
local function fittedPose(model: Model, p: BasePart): (Vector3?, CFrame?)
	local zone = p:GetAttribute("FitZone")
	local srcSize = p:GetAttribute("FitSourceSize")
	local srcPos = p:GetAttribute("FitSourcePos")
	local srcRot = p:GetAttribute("FitSourceRot")
	local nc = model:GetAttribute("NativeCenter")
	if typeof(zone) ~= "string" or typeof(srcSize) ~= "Vector3" or typeof(srcPos) ~= "Vector3" or typeof(nc) ~= "Vector3" then
		return nil, nil
	end
	local rot = if typeof(srcRot) == "CFrame" then srcRot else CFrame.identity
	local m = zoneMap()
	local nW, nL = model:GetAttribute("NativeWidth") :: number, model:GetAttribute("NativeLength") :: number
	local nUnder, nFloor = model:GetAttribute("NativeUndersideY") :: number, model:GetAttribute("NativeFloorY") :: number
	local nNetH, nNetL = model:GetAttribute("NativeNetHeight") :: number, model:GetAttribute("NativeNetLength") :: number
	local nSurf = nc.Y
	local sz = m.length / nL
	local sx, sy, y
	local d = srcPos - nc
	if zone == "Net" then
		sx, sy = m.netLength / nNetL, m.netHeight / nNetH
		y = m.surfaceY + d.Y * sy
	elseif zone == "Legs" then
		sx = m.width / nW
		sy = (m.surfaceY - m.topThickness - m.floorY) / (nUnder - nFloor)
		y = m.floorY + (srcPos.Y - nFloor) * sy
	else -- "Top"
		sx = m.width / nW
		sy = m.topThickness / (nSurf - nUnder)
		y = m.surfaceY + d.Y * sy
	end
	local scale = Vector3.new(sx, sy, sz)
	-- Scale along each of the part's own axes (exact for axis-aligned parts, which the fit requires).
	local function axisScale(axis: Vector3): number
		return (axis * scale).Magnitude
	end
	local size = Vector3.new(
		srcSize.X * axisScale(rot.RightVector),
		srcSize.Y * axisScale(rot.UpVector),
		srcSize.Z * axisScale(rot.LookVector)
	)
	local pos = Vector3.new(m.origin.X + d.X * sx, y, m.origin.Z + d.Z * sz)
	return size, CFrame.new(pos) * rot
end

-- One-time setup of an imported table model: record the native layout. `surfacePart` is the playing-surface part
-- (its top face is the playing surface), `netTopPart` the part whose top is the net's top and whose X size is the net
-- length, `floorY` the native floor. Zones/structural flags come from `roles` (part name -> {zone, structural}).
function ArenaBuilder.prepareTableAsset(model: Model, surfacePart: BasePart, netTopPart: BasePart, floorY: number, roles: { [string]: { any } })
	local surfaceY = surfacePart.Position.Y + surfacePart.Size.Y / 2
	model:SetAttribute("NativeCenter", Vector3.new(surfacePart.Position.X, surfaceY, surfacePart.Position.Z))
	model:SetAttribute("NativeWidth", surfacePart.Size.X)
	model:SetAttribute("NativeLength", surfacePart.Size.Z)
	model:SetAttribute("NativeUndersideY", surfacePart.Position.Y - surfacePart.Size.Y / 2)
	model:SetAttribute("NativeFloorY", floorY)
	model:SetAttribute("NativeNetHeight", netTopPart.Position.Y + netTopPart.Size.Y / 2 - surfaceY)
	model:SetAttribute("NativeNetLength", netTopPart.Size.X)
	for _, p in model:GetDescendants() do
		local role = p:IsA("BasePart") and roles[p.Name]
		if role then
			p:SetAttribute("FitZone", role[1])
			p:SetAttribute("FitStructural", role[2] == true)
			p:SetAttribute("FitSourceSize", p.Size)
			p:SetAttribute("FitSourcePos", p.Position)
			p:SetAttribute("FitSourceRot", p.CFrame.Rotation)
		end
	end
end

-- Fit the table asset to Config (Edit mode, after changing table dimensions; or at Play for drifted structural parts).
-- structuralOnly: only parts with FitStructural (what Play does). Returns how many parts were changed.
function ArenaBuilder.fitTableAsset(model: Model?, structuralOnly: boolean?): number
	local asset = model or ArenaBuilder.tableAsset()
	if not asset then
		warn("[ArenaBuilder] no " .. Config.Names.TableAsset .. " under NotPongArena/Table/Visual")
		return 0
	end
	local changed = 0
	for _, p in asset:GetDescendants() do
		if p:IsA("BasePart") and (not structuralOnly or p:GetAttribute("FitStructural")) then
			local size, cf = fittedPose(asset, p)
			if size and cf then
				if (p.Size - size).Magnitude > TOLERANCE or (p.Position - cf.Position).Magnitude > TOLERANCE then
					p.Size = size
					p.CFrame = cf
					changed += 1
				end
			end
		end
	end
	return changed
end

-- Structural asset parts that disagree with the gameplay table (empty = the visible table matches the simulation).
function ArenaBuilder.validateTableAsset(model: Model): { string }
	local problems = {}
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p:GetAttribute("FitStructural") then
			local size, cf = fittedPose(model, p)
			if size and cf and ((p.Size - size).Magnitude > TOLERANCE or (p.Position - cf.Position).Magnitude > TOLERANCE) then
				table.insert(problems, ("%s %s at %s, expected %s at %s"):format(p.Name, tostring(p.Size), tostring(p.Position), tostring(size), tostring(cf.Position)))
			end
		end
	end
	return problems
end

-- Compare the saved arena with Config. Returns a list of human-readable problems (empty = in sync).
function ArenaBuilder.validate(arena: Folder): { string }
	local problems = {}
	local T, N, L = Config.Table, Config.Net, Config.Layout
	local function expect(path: string, size: Vector3?, position: Vector3?)
		local inst = arena
		for segment in string.gmatch(path, "[^/]+") do
			inst = inst and inst:FindFirstChild(segment) :: any
		end
		if not inst or not inst:IsA("BasePart") then
			table.insert(problems, "missing " .. path)
			return
		end
		if size and (inst.Size - size).Magnitude > TOLERANCE then
			table.insert(problems, ("%s size %s, expected %s"):format(path, tostring(inst.Size), tostring(size)))
		end
		if position and (inst.Position - position).Magnitude > TOLERANCE then
			table.insert(problems, ("%s position %s, expected %s"):format(path, tostring(inst.Position), tostring(position)))
		end
	end
	expect("Table/Collision/TableTop", Vector3.new(T.Width, T.Height, T.Length), Vector3.new(Config.Arena.Origin.X, L.FloorY + T.Height / 2, Config.Arena.Origin.Z))
	expect("Net/NetMesh", Vector3.new(N.Length, N.Height, N.Thickness), L.NetCenter)
	expect(Config.Names.PlatformPart, Config.Platform.Size, L.PlatformCenter)
	for _, name in { Config.Names.PlayerSpawn, Config.Names.BotSpawn } do
		expect(name, nil, nil)
	end
	local B = Config.Ball
	expect("BallTemplate/Ball", Vector3.new(B.Diameter, B.Diameter, B.Diameter), nil)
	expect("BallTemplate/Ball/BallVisual", Vector3.new(B.VisualDiameter, B.VisualDiameter, B.VisualDiameter), nil)
	return problems
end

-- RUNTIME ---------------------------------------------------------------------------------------------

-- Static spawn point -> a floor-level stand position (X/Z from the marker, Y from the playing floor).
local function standFrom(marker: BasePart): Vector3
	return Vector3.new(marker.Position.X, Config.Layout.FloorY, marker.Position.Z)
end

function ArenaBuilder.load()
	local found = {}
	for _, child in Workspace:GetChildren() do
		if child.Name == Config.Names.Arena and child:IsA("Folder") then
			table.insert(found, child)
		end
	end
	if #found == 0 then
		warn("[ArenaBuilder] no static arena in Workspace; creating one (run ArenaBuilder.syncGeometry() in Edit mode to save it)")
		found[1] = ArenaBuilder.syncGeometry()
	elseif #found > 1 then
		warn("[ArenaBuilder] " .. #found .. " arenas named " .. Config.Names.Arena .. "; using the first. Delete the extras.")
	end
	local folder = found[1] :: Folder

	local problems = ArenaBuilder.validate(folder)
	if #problems > 0 then
		warn("[ArenaBuilder] saved arena differs from Config (" .. #problems .. " issues); correcting in memory for this session.")
		for i = 1, math.min(#problems, 5) do
			warn("  " .. problems[i])
		end
		warn("  Run ArenaBuilder.syncGeometry() in Edit mode (or use the MCP) to make the fix permanent.")
	end
	-- Play writes NOTHING to the static arena unless its GAMEPLAY geometry is out of date (or the ball template is
	-- missing); even then only the gameplay parts are corrected (gameplayOnly): visual parts, the table asset's cosmetic
	-- parts, appearance and spawn-marker positions are never touched.
	if #problems > 0 or not folder:FindFirstChild("BallTemplate") then
		ArenaBuilder.syncGeometry(folder, true)
	end
	-- The visible table must agree with the simulated one: structural asset parts (top, lines, net) that drifted from
	-- Config are re-fitted in memory, loudly. Cosmetic geometry (legs, holders) and every appearance property are kept.
	local asset = ArenaBuilder.tableAsset(folder)
	if asset then
		local assetProblems = ArenaBuilder.validateTableAsset(asset)
		if #assetProblems > 0 then
			warn("[ArenaBuilder] table asset differs from the gameplay table (" .. #assetProblems .. " parts); re-fitting them in memory for this session.")
			for i = 1, math.min(#assetProblems, 3) do
				warn("  " .. assetProblems[i])
			end
			warn("  To resize the table change Config.Presentation, then run syncGeometry() and fitTableAsset() in Edit mode.")
			ArenaBuilder.fitTableAsset(asset, true)
		end
	end

	local tableModel = folder:FindFirstChild("Table") :: Model
	local playerSpawn = folder:FindFirstChild(Config.Names.PlayerSpawn) :: SpawnLocation
	local botSpawn = folder:FindFirstChild(Config.Names.BotSpawn) :: BasePart

	-- Spawn markers are visible in Studio for editing; hide them while playing.
	playerSpawn.Transparency = 1
	botSpawn.Transparency = 1
	-- The paddle template is visible in Edit mode for editing; at Play it moves (unchanged) to ServerStorage, where
	-- PaddleFactory clones it for every competitor.
	local paddleTemplate = folder:FindFirstChild(Config.Names.PaddleTemplate)
	if paddleTemplate then
		paddleTemplate.Parent = game:GetService("ServerStorage")
	end

	-- DYNAMIC: the ONE active ball is the saved template; its appearance is left exactly as you made it. Any other
	-- ball is removed so duplicates cannot appear.
	local L = Config.Layout
	local ball = (folder :: any).BallTemplate.Ball :: BasePart
	local ballVisual = ball:FindFirstChild("BallVisual") :: BasePart
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "Ball" or d.Name == "BallVisual") and d ~= ball and d ~= ballVisual then
			d:Destroy()
		end
	end
	ball.Transparency = 1
	ball.Anchored, ballVisual.Anchored = true, true
	CollisionSetup.assign(ball, Config.CollisionGroups.Ball)
	ball.Position = L.ServeBall[Config.Match.FirstServer] -- gameplay spawn; the Edit-mode position was a preview
	ballVisual.Position = ball.Position

	local arena = {
		Folder = folder,
		Table = tableModel,
		TableTop = (tableModel :: any).Collision.TableTop,
		Net = folder:FindFirstChild("Net"),
		Platform = folder:FindFirstChild(Config.Names.PlatformPart),
		Ball = ball,
		BallVisual = ballVisual,
		PlayerSpawn = playerSpawn,
		BotSpawn = botSpawn,
		PlayerStand = standFrom(playerSpawn),
		BotStand = standFrom(botSpawn),
	}
	return arena
end

-- COSMETICS ------------------------------------------------------------------------------------------
-- Both functions only touch appearance properties of Visual parts. They never resize, move or change collision.
-- applyTableStyle is NOT called at Play (it would overwrite your Studio edits); it runs once when the table is first
-- created, or whenever you call it yourself.

function ArenaBuilder.applyTableStyle(arena, styleName: string)
	local style = Config.TableStyles[styleName]
	if not style then
		warn("[ArenaBuilder] unknown table style", styleName)
		return false
	end
	for _, part in arena.Table.Visual:GetChildren() do
		local role = part:GetAttribute("StyleRole")
		if role == "Surface" then
			part.Color = style.SurfaceColor
			part.Material = style.Material
			local tex = part:FindFirstChildOfClass("Texture")
			if style.TextureId ~= "" then
				tex = tex or Instance.new("Texture")
				tex.Texture = style.TextureId
				tex.Face = Enum.NormalId.Top
				tex.Parent = part
			elseif tex then
				tex:Destroy()
			end
		elseif role == "Line" then
			part.Color = style.LineColor
		end
	end
	return true
end

function ArenaBuilder.applyBallStyle(arena, styleName: string)
	local style = Config.BallStyles[styleName]
	if not style then
		warn("[ArenaBuilder] unknown ball style", styleName)
		return false
	end
	local v = arena.BallVisual
	v.Color = style.Color
	v.Material = style.Material
	v.Reflectance = style.Reflectance
	for _, d in v:GetChildren() do
		if d:IsA("Decal") or d:IsA("Trail") or d:IsA("Attachment") then
			d:Destroy()
		end
	end
	if style.TextureId ~= "" then
		for _, face in Enum.NormalId:GetEnumItems() do
			local d = Instance.new("Decal")
			d.Texture = style.TextureId
			d.Face = face
			d.Parent = v
		end
	end
	if style.Trail.Enabled then
		local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
		local half = style.Trail.Width / 2
		a0.Position, a1.Position = Vector3.new(0, half, 0), Vector3.new(0, -half, 0)
		a0.Parent, a1.Parent = v, v
		local t = Instance.new("Trail")
		t.Attachment0, t.Attachment1 = a0, a1
		t.Color = ColorSequence.new(style.Trail.Color)
		t.Lifetime = style.Trail.Lifetime
		t.Transparency = NumberSequence.new(0.2, 1)
		t.Parent = v
	end
	return true
end

-- Move the ball (gameplay part and visual shell together) to `position`.
function ArenaBuilder.moveBall(arena, position: Vector3)
	arena.Ball.Position = position
	arena.BallVisual.Position = position
end

-- Move the ball to where `side` serves from.
function ArenaBuilder.placeBallForServe(arena, side: string)
	ArenaBuilder.moveBall(arena, Config.Layout.ServeBall[side])
end

return ArenaBuilder
