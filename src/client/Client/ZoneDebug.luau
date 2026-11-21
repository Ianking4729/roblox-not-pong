-- ZoneDebug (client, TEMPORARY developer visualisation; Config.ContactZone.Visualize, toggled with
-- Player.NotPongZoneDebug:Invoke("toggle")): outlines the contact reach the shot controller (and the server, with the
-- same ShotInput rules) is using right now, on the floor around you:
--   green   the NORMAL zone (Body model: the symmetric torso-centred half-ellipses; Anchor model: the stroke's circle)
--   orange  the EMERGENCY zone
--   a post  at the ideal-contact (sweet) point, from the zone's low to its high contact height
-- Cosmetic only: CanCollide / CanQuery / CanTouch off, parented to the camera (never replicated, never a hit box).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ShotInput = require(Shared:WaitForChild("ShotInput"))

local ZoneDebug = {}

local SEGMENTS = 48

local function part(parent: Instance, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 0.35
	p.Size = Vector3.new(0.2, 0.08, 1)
	p.Parent = parent
	return p
end

function ZoneDebug.start(player: Player, controller: any)
	local folder = Instance.new("Folder")
	folder.Name = "NotPongZoneDebug"
	folder.Parent = workspace.CurrentCamera
	local rings = {}
	for k, color in { normal = Color3.fromRGB(80, 230, 120), emergency = Color3.fromRGB(255, 150, 40) } do
		local segs = {}
		for i = 1, SEGMENTS do
			segs[i] = part(folder, color)
		end
		rings[k] = segs
	end
	local post = part(folder, Color3.fromRGB(80, 230, 120))
	local visible = Config.ContactZone.Visualize == true

	local function outline(r: any, radius: number): { Vector3 }
		local pts = table.create(SEGMENTS)
		local y = Config.Layout.FloorY + 0.1
		for i = 1, SEGMENTS do
			local a = (i - 1) / SEGMENTS * 2 * math.pi
			local c, s = math.cos(a), math.sin(a)
			local p
			if typeof(r) == "table" then
				local depth = if s >= 0 then r.front else r.back
				local q = r.center + r.right * (c * r.side) + r.forward * (s * depth)
				p = Vector3.new(q.X, y, q.Z)
			else
				p = Vector3.new(r.X + c * radius, y, r.Z + s * radius)
			end
			pts[i] = p
		end
		return pts
	end
	local function draw(segs: { BasePart }, pts: { Vector3 }?)
		for i, seg in segs do
			if not pts or not visible then
				seg.Transparency = 1
			else
				local a, b = pts[i], pts[i % #pts + 1]
				local len = (b - a).Magnitude
				seg.Size = Vector3.new(0.25, 0.08, math.max(len, 0.05))
				seg.CFrame = CFrame.lookAt((a + b) / 2, b)
				seg.Transparency = 0.35
			end
		end
	end

	RunService.RenderStepped:Connect(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not visible or not root or not controller.reach then
			draw(rings.normal, nil)
			draw(rings.emergency, nil)
			post.Transparency = 1
			return
		end
		local n, nr = ShotInput.reachZone(root.CFrame, Config.ShotControl, controller.stroke, false)
		local e, er = ShotInput.reachZone(root.CFrame, Config.ShotControl, controller.stroke, true)
		draw(rings.normal, n and outline(n, nr) or nil)
		draw(rings.emergency, e and outline(e, er) or nil)
		local sweet = ShotInput.reachPoint(n)
		if sweet then
			local floor = Config.Layout.FloorY
			local lo = if typeof(n) == "table" then n.lowY else floor + Config.Rally.ContactMinAboveFloor
			local hi = if typeof(n) == "table" then n.highY else floor + Config.Rally.ContactMaxAboveFloor
			post.Size = Vector3.new(0.2, hi - lo, 0.2)
			post.CFrame = CFrame.new(sweet.X, (lo + hi) / 2, sweet.Z)
			post.Transparency = 0.6
		end
	end)

	local bridge = Instance.new("BindableFunction")
	bridge.Name = "NotPongZoneDebug"
	bridge.OnInvoke = function(cmd: string?)
		if cmd == "toggle" then
			visible = not visible
		elseif cmd == "on" then
			visible = true
		elseif cmd == "off" then
			visible = false
		end
		return visible
	end
	bridge.Parent = player
end

return ZoneDebug
