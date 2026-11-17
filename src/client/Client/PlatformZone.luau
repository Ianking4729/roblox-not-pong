-- PlatformZone (client): is the LOCAL player's character on the playing platform? One shared answer for every client
-- system that behaves differently off the platform (camera, facing, ready stance / footwork, avatar fade), so they all
-- switch at the same moment.
--
--   * Bounds: the real Platform part (its CFrame and Size; no hard-coded coordinates), in its own XZ plane.
--   * Hysteresis: the root must be EnterMargin inside the edge to count as on, ExitMargin outside to count as off
--     (Config.CharacterFade margins, which the fade already used), plus a minimum dwell time (Config.PlatformZone)
--     before a change is published, so walking along the edge cannot flicker anything.
--   * Respawn: a new character starts in the state its spawn position gives, with no dwell (no transition on spawn).
-- Visual / presentation only: gameplay never reads this.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local PlatformZone = {}

local listeners: { (boolean) -> () } = {}
local onPlatform = true
local started = false

-- Signed distance from the platform's edge in its own XZ plane: positive = inside, negative = outside.
function PlatformZone.insideDistance(platform: BasePart, position: Vector3): number
	local l = platform.CFrame:PointToObjectSpace(position)
	return math.min(platform.Size.X / 2 - math.abs(l.X), platform.Size.Z / 2 - math.abs(l.Z))
end

function PlatformZone.isOn(): boolean
	return onPlatform
end

-- fn(on) is called on every published change (not immediately).
function PlatformZone.onChanged(fn: (boolean) -> ())
	table.insert(listeners, fn)
end

local function publish(value: boolean)
	if value == onPlatform then
		return
	end
	onPlatform = value
	for _, fn in listeners do
		task.spawn(fn, value)
	end
end

function PlatformZone.start()
	if started then
		return
	end
	started = true
	local F, Z = Config.CharacterFade, Config.PlatformZone
	local player = Players.LocalPlayer
	local arena = workspace:WaitForChild(Config.Names.Arena)
	local platform = arena:WaitForChild(Config.Names.PlatformPart) :: BasePart
	local character: Model? = nil
	local pending: boolean? = nil -- the raw (hysteresis) state waiting out the dwell time
	local pendingSince = 0
	RunService.Heartbeat:Connect(function()
		local current = player.Character
		local root = current and current:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return
		end
		local d = PlatformZone.insideDistance(platform, root.Position)
		if current ~= character then
			-- new character: take its state at once (no transition on spawn)
			character = current
			pending = nil
			publish(d > 0)
			return
		end
		local raw = onPlatform
		if onPlatform and d < -F.ExitMargin then
			raw = false
		elseif not onPlatform and d > F.EnterMargin then
			raw = true
		end
		if raw == onPlatform then
			pending = nil
		elseif pending ~= raw then
			pending, pendingSince = raw, os.clock()
		elseif os.clock() - pendingSince >= Z.DwellTime then
			pending = nil
			publish(raw)
		end
	end)
end

return PlatformZone
