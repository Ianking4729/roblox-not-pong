-- CharacterFade (client): the LOCAL player's own avatar is translucent while standing on the playing platform (so it
-- never hides the table) and fully visible once it walks off. Purely visual and local: nothing is replicated and other
-- players' characters are never touched.
--
--   * One transparency value for the whole character: head, body, hair, hats, face accessories and decals/textures
--     (Config.CharacterFade.Transparency). The paddle (Model "Paddle") never fades.
--   * Original values are preserved: parts are faded with LocalTransparencyModifier (their real Transparency is not
--     written), decals/textures remember their original Transparency and are restored exactly.
--   * Inside/outside comes from the real Platform part (its CFrame and Size, so rotation and resizing are honoured;
--     no hard-coded coordinates), with hysteresis (EnterMargin / ExitMargin) so standing on the edge cannot flicker.
--   * The fade amount eases between the two states over TransitionTime. Roblox's default camera module rewrites
--     LocalTransparencyModifier every frame, so the value is enforced after it each frame; but a part is only WRITTEN when
--     its current value differs from the wanted one, so in steady state nothing is written at all.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local FrameDriver = require(script.Parent:WaitForChild("FrameDriver"))
local PlatformZone = require(script.Parent:WaitForChild("PlatformZone"))

local CharacterFade = {}

-- Signed distance from the platform's edge in its own XZ plane: positive = inside, negative = outside.
function CharacterFade.insideDistance(platform: BasePart, position: Vector3): number
	local l = platform.CFrame:PointToObjectSpace(position)
	return math.min(platform.Size.X / 2 - math.abs(l.X), platform.Size.Z / 2 - math.abs(l.Z))
end

function CharacterFade.start(player: Player)
	local F = Config.CharacterFade
	local arena = workspace:WaitForChild(Config.Names.Arena)
	local platform = arena:WaitForChild(Config.Names.PlatformPart) :: BasePart

	local parts: { [BasePart]: boolean } = {}
	local decals: { [Instance]: number } = {} -- Decal / Texture -> original Transparency
	local conn: RBXScriptConnection? = nil
	local character: Model? = nil
	local onPlatform = false -- hysteresis state
	local amount = 0 -- 0..1 blend between visible and faded
	local applied = -1 -- the amount last written to the parts
	local dirty = true

	local function isPaddle(inst: Instance): boolean
		return inst.Name == "Paddle" or inst:FindFirstAncestor("Paddle") ~= nil
	end

	local function track(inst: Instance)
		if isPaddle(inst) then
			return
		end
		if inst:IsA("BasePart") then
			parts[inst] = true
			dirty = true
		elseif (inst:IsA("Decal") or inst:IsA("Texture")) and inst.Parent and inst.Parent:IsA("BasePart") then
			if not isPaddle(inst.Parent) and decals[inst] == nil then
				decals[inst] = (inst :: any).Transparency
				dirty = true
			end
		end
	end

	local function restoreAll()
		for part in parts do
			if part.Parent then
				part.LocalTransparencyModifier = 0
			end
		end
		for d, original in decals do
			if d.Parent then
				(d :: any).Transparency = original
			end
		end
	end

	local function attach(newCharacter: Model?)
		if conn then
			conn:Disconnect()
			conn = nil
		end
		restoreAll()
		table.clear(parts)
		table.clear(decals)
		character = newCharacter
		applied, dirty = -1, true
		if not newCharacter then
			return
		end
		for _, d in newCharacter:GetDescendants() do
			track(d)
		end
		conn = newCharacter.DescendantAdded:Connect(function(d)
			task.defer(track, d) -- accessory welds/decals appear a moment after the handle
		end)
		-- Start in the correct state without a pop of visibility on spawn.
		local root = newCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			onPlatform = CharacterFade.insideDistance(platform, root.Position) > 0
			amount = if onPlatform then 1 else 0
		end
	end

	-- Enforce the wanted transparency. Writes only on mismatch (the default camera script resets it every frame).
	local function apply()
		local fade = amount * F.Transparency
		for part in parts do
			if part.Parent then
				if part.LocalTransparencyModifier ~= fade then
					part.LocalTransparencyModifier = fade
				end
			else
				parts[part] = nil
			end
		end
		for d, original in decals do
			if d.Parent then
				local wanted = original + (1 - original) * fade
				if (d :: any).Transparency ~= wanted then
					(d :: any).Transparency = wanted
				end
			else
				decals[d] = nil
			end
		end
		applied, dirty = amount, false
	end

	-- After the camera module (Camera priority) so ours is the last word each frame.
	FrameDriver.bind("NotPongCharacterFade", Enum.RenderPriority.Camera.Value + 2, function(dt)
		local current = player.Character
		if current ~= character then
			attach(current)
		end
		if not character then
			return
		end
		-- the shared on/off-platform state (same margins as before, plus a short dwell), so the fade switches together
		-- with the camera, facing and stance
		onPlatform = PlatformZone.isOn()
		local target = if onPlatform then 1 else 0
		if amount ~= target then
			local step = dt / math.max(F.TransitionTime, 1e-3)
			amount = if amount < target then math.min(target, amount + step) else math.max(target, amount - step)
		end
		apply()
	end)
end

return CharacterFade
