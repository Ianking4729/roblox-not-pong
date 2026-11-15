-- CollisionSetup: registers NOT PONG collision groups and assigns parts to them.
--
-- Matrix (X = collide, - = pass through):
--              Table  Ball  Paddle  Character  Default(floor)
--   Table        X      X     -         X          X
--   Ball         X      -     -         -          -
--   Paddle       -      -     -         -          -
--   Character    X      -     -         -          X      (plus X with Boundary walls, which hit nothing else)
--
-- Why: the official ball is simulated by BallPhysics (not the Roblox engine), so it must never be
-- pushed around by bodies; hits are decided by game logic, not by paddle/ball contact. Paddles are
-- welded visuals and must not shove their owner or the table. Characters must not shove each other
-- but must not walk through the table.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local G = Config.CollisionGroups
local CollisionSetup = {}
local isSetUp = false

function CollisionSetup.setup()
	if isSetUp then
		return
	end
	for _, name in G do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end

	local function set(a: string, b: string, collide: boolean)
		PhysicsService:CollisionGroupSetCollidable(a, b, collide)
	end

	set(G.Table, G.Table, true)
	set(G.Table, G.Ball, true)
	set(G.Table, G.Paddle, false)
	set(G.Table, G.Character, true)
	set(G.Table, "Default", true)

	set(G.Ball, G.Ball, false)
	set(G.Ball, G.Paddle, false)
	set(G.Ball, G.Character, false)
	set(G.Ball, "Default", false)

	set(G.Paddle, G.Paddle, false)
	set(G.Paddle, G.Character, false)
	set(G.Paddle, "Default", false)

	set(G.Character, G.Character, false)
	set(G.Character, "Default", true)

	-- Boundary walls stop characters only.
	set(G.Boundary, G.Boundary, false)
	set(G.Boundary, G.Table, false)
	set(G.Boundary, G.Ball, false)
	set(G.Boundary, G.Paddle, false)
	set(G.Boundary, G.Character, true)
	set(G.Boundary, "Default", false)

	isSetUp = true
end

-- Put `instance` (if it is a BasePart) and every BasePart under it into `group`.
function CollisionSetup.assign(instance: Instance, group: string)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = group
	end
	for _, d in instance:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end
end

-- Like assign, but also covers parts added later (accessories, tools). Returns the connection.
-- Later parts are only claimed while still in "Default", so a part that was already given a specific group
-- (e.g. the paddle, assigned when it is built) is never overwritten. DescendantAdded handlers run deferred,
-- so without this check the hook would clobber groups assigned right after the part was added.
function CollisionSetup.assignLive(instance: Instance, group: string): RBXScriptConnection
	CollisionSetup.assign(instance, group)
	return instance.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") and d.CollisionGroup == "Default" then
			d.CollisionGroup = group
		end
	end)
end

return CollisionSetup
