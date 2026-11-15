--!strict
-- TableWorld: the ball-physics description of the arena (table halves, net, table body, floor), built ONCE from
-- Config so the server simulation, the client renderer and the bot/shot prediction all collide with the same world.
-- Gameplay geometry only; the Studio table's cosmetics are irrelevant here (ArenaBuilder keeps the static parts'
-- geometry equal to these same Config values).

local Config = require(script.Parent:WaitForChild("Config"))
local BallPhysics = require(script.Parent:WaitForChild("BallPhysics"))

local L, T, N = Config.Layout, Config.Table, Config.Net
local O = L.TableSurfaceCenter
local halfL, halfW = T.Length / 2, T.Width / 2

local TableWorld = {}

local function half(src: any, name: string): BallPhysics.Surface
	return { topY = src.topY, minX = src.minX, maxX = src.maxX, minZ = src.minZ, maxZ = src.maxZ, name = name }
end

TableWorld.world = {
	surfaces = { half(L.PlayerHalf, "Player"), half(L.BotHalf, "Bot") },
	net = {
		z = O.Z,
		minX = O.X - N.Length / 2,
		maxX = O.X + N.Length / 2,
		bottomY = L.SurfaceY,
		topY = L.SurfaceY + N.Height,
		halfThickness = N.Thickness / 2,
	},
	tableBox = {
		minX = O.X - halfW,
		maxX = O.X + halfW,
		minY = L.FloorY,
		maxY = L.SurfaceY,
		minZ = O.Z - halfL,
		maxZ = O.Z + halfL,
	},
	floorY = L.FloorY,
} :: BallPhysics.World

TableWorld.physics = Config.BallPhysics :: BallPhysics.Config
TableWorld.netTopY = L.SurfaceY + N.Height
TableWorld.netZ = O.Z
TableWorld.landingY = L.SurfaceY + Config.Ball.Radius -- ball-centre height when touching the table

-- +1 toward the Player's end (+Z), -1 toward the Bot's end.
function TableWorld.towardSide(side: string): number
	return if side == "Player" then 1 else -1
end

-- The z of `side`'s end line.
function TableWorld.endLineZ(side: string): number
	return O.Z + TableWorld.towardSide(side) * halfL
end

-- Which half a z lies over.
function TableWorld.halfOf(z: number): string
	return if z >= O.Z then "Player" else "Bot"
end

-- A point on `side`'s half of the table at the ball-touching height. depth: 0 = at the net, 1 = at the end line.
-- x: offset from the centre line.
function TableWorld.pointOnHalf(side: string, depth: number, x: number): Vector3
	return Vector3.new(O.X + x, TableWorld.landingY, O.Z + TableWorld.towardSide(side) * halfL * depth)
end

TableWorld.halfLength = halfL
TableWorld.halfWidth = halfW
TableWorld.center = O

return TableWorld
