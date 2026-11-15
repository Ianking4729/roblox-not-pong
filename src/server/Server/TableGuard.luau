-- TableGuard (server): keeps characters off the table without fencing it in.
--
-- Why: the avatar is scaled ~3.4x, so its legs reach higher (hip height 9.2) than the table is tall (8.7). Roblox's
-- Humanoid simply STEPS UP onto such a ledge, so a player could walk (or jump) onto the tabletop.
--
-- What: one invisible, solid block that occupies ONLY the table's own footprint, from the playing surface up to Height
-- studs (about two avatar heights, above any jump). Table + block form a column far too tall to step or jump onto, from
-- every side and corner. There are no walls around the table: players can still walk right up to every edge.
--
-- Isolation:
--   * Collision group NP_Boundary collides with characters only (CollisionSetup), never with the ball or paddles. The ball
--     is simulated by BallPhysics anyway and never touches the Roblox physics world.
--   * It is built at runtime from TableWorld (Config), never saved in the place, so resizing the table or editing the
--     arena resizes it too. The bot stands at its end line, outside the footprint, and is unaffected.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))

local TableGuard = {}

function TableGuard.build(parent: Instance): BasePart?
	local G = Config.TableGuard
	if not G.Enabled then
		return nil
	end
	local old = parent:FindFirstChild(G.Name)
	if old then
		old:Destroy()
	end
	local box = TableWorld.world.tableBox :: any
	local m = G.Margin
	local part = Instance.new("Part")
	part.Name = G.Name
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = false -- invisible to raycasts (cameras, bots, tests) so nothing aims at or through it
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.CollisionGroup = Config.CollisionGroups.Boundary
	part.Size = Vector3.new(box.maxX - box.minX + 2 * m, G.Height, box.maxZ - box.minZ + 2 * m)
	part.CFrame = CFrame.new((box.minX + box.maxX) / 2, box.maxY + G.Height / 2, (box.minZ + box.maxZ) / 2)
	part.Parent = parent
	return part
end

return TableGuard
