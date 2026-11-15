-- AvatarService: sets up each player's character for table tennis.
--   * waits for the appearance to load (so hair/accessories are scaled with the body)
--   * scales the avatar to Config.Avatar.Height, places it behind the player's end of the table, facing it
--   * assigns collision groups, attaches a paddle
--   * the first player to arrive holds the single "seat" (the Player side of the match)
-- FUTURE: more than one seat / two-player mode would extend the seat table here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CollisionSetup = require(script.Parent:WaitForChild("CollisionSetup"))
local PaddleFactory = require(script.Parent:WaitForChild("PaddleFactory"))
local Stance = require(script.Parent:WaitForChild("Stance"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))

local AvatarService = {}

local seatedPlayer: Player? = nil
local playerStand: Vector3 = Config.Layout.PlayerStand -- overridden from the static PlayerSpawn marker (see Main)
local onSeatChanged: ((Player?) -> ())? = nil

local function setSeat(player: Player?)
	if seatedPlayer == player then
		return
	end
	seatedPlayer = player
	if onSeatChanged then
		onSeatChanged(player)
	end
end

-- Where the player stands at spawn: the static PlayerSpawn marker's X/Z on the playing floor.
function AvatarService.setPlayerStand(stand: Vector3)
	playerStand = stand
end

function AvatarService.getSeatedPlayer(): Player?
	return seatedPlayer
end

-- Feet-to-top-of-head height of the body in studs at its CURRENT scale (accessories ignored), or nil.
function AvatarService.measureBodyHeight(character: Model): number?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = character:FindFirstChild("Head") :: BasePart?
	if not humanoid or not root or not head then
		return nil
	end
	local feetY = root.Position.Y - root.Size.Y / 2 - humanoid.HipHeight
	local height = head.Position.Y + head.Size.Y / 2 - feetY
	return if height > 0.1 then height else nil
end

-- The absolute scale at which `character`'s body is Config.Avatar.Height tall, or nil.
-- Measured on a static clone (scripts removed, parts anchored) because a live character's idle animation moves
-- its head by about +/-3%, which made repeated measurements of the real thing disagree with each other. Scaling is
-- also not perfectly linear for every avatar (a tested custom avatar was 8% short after a single proportional
-- pass), so this corrects until within 0.2% of the target.
function AvatarService.solveScale(character: Model): number?
	-- Player characters are Archivable = false, which makes Clone() return nil; allow it just for the clone.
	local wasArchivable = character.Archivable
	character.Archivable = true
	local ok, clone = pcall(function()
		return character:Clone()
	end)
	character.Archivable = wasArchivable
	if not ok or not clone then
		return nil
	end
	clone.Archivable = true
	for _, d in clone:GetDescendants() do
		if d:IsA("BaseScript") then
			d:Destroy()
		end
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	clone:PivotTo(CFrame.new(0, 5000, 0)) -- far above everything else
	clone.Parent = workspace

	local target = Config.Avatar.Height
	local result: number? = nil
	for _ = 1, 6 do
		local height = AvatarService.measureBodyHeight(clone)
		if not height then
			break
		end
		if math.abs(height - target) / target < 0.002 then
			result = clone:GetScale()
			break
		end
		clone:ScaleTo(clone:GetScale() * target / height)
	end
	clone:Destroy()
	return result
end

-- Scale `character` to Config.Avatar.Height and stand it at `standPosition` facing `facing`.
-- Shared by players and the bot. The scale factor is computed from the measured body, not assumed.
function AvatarService.placeCharacter(character: Model, standPosition: Vector3, facing: Vector3)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return false
	end
	local scale = AvatarService.solveScale(character)
	if scale then
		character:ScaleTo(scale)
	else
		warn("[AvatarService] could not solve a scale for", character.Name, "- left unscaled")
	end
	local y = standPosition.Y + humanoid.HipHeight + (root :: BasePart).Size.Y / 2
	local pos = Vector3.new(standPosition.X, y, standPosition.Z)
	character:PivotTo(CFrame.lookAt(pos, pos + facing))
	if Players:GetPlayerFromCharacter(character) then
		-- Client-simulated: tell that client (StanceController) the character is scaled and placed.
		character:SetAttribute("NotPongPlaced", true)
	else
		Stance.apply(character) -- the bot: after the scale solve (the stance measures the scaled legs)
	end
	return true
end

local function setupCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root then
		warn("[AvatarService] character incomplete for", player.Name)
		return
	end

	-- Let hair/accessories attach before scaling, otherwise they stay full-size relative to the body.
	if not player:HasAppearanceLoaded() then
		local done = false
		local conn = player.CharacterAppearanceLoaded:Connect(function()
			done = true
		end)
		local t0 = os.clock()
		while not done and os.clock() - t0 < Config.Timing.AppearanceLoadTimeout do
			task.wait(0.1)
		end
		conn:Disconnect()
	end
	if character.Parent == nil then
		return -- respawned/left while we waited
	end

	CollisionSetup.assignLive(character, Config.CollisionGroups.Character)
	AvatarService.placeCharacter(character, playerStand, Config.Layout.PlayerFacing)
	-- Set AFTER scaling: Model:ScaleTo multiplies WalkSpeed (and jump) by the scale factor (a 3.3x scale turned 16 into 52).
	-- MovementService sets the walk speed (boost off after a spawn) and the capped jump height.
	local scaledHumanoid = humanoid :: Humanoid
	MovementService.apply(player, scaledHumanoid)
	PaddleFactory.attachToHand(character) -- the paddle's parts are already in the Paddle group

	if seatedPlayer == nil then
		setSeat(player)
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(setupCharacter, player, character)
	end)
	if player.Character then
		task.spawn(setupCharacter, player, player.Character)
	end
end

function AvatarService.start(callbacks: { onSeatChanged: ((Player?) -> ())? }?)
	onSeatChanged = callbacks and callbacks.onSeatChanged or nil
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		if seatedPlayer == player then
			setSeat(nil)
			-- hand the seat to anyone else already in the game
			for _, other in Players:GetPlayers() do
				if other ~= player and other.Character and other.Character:FindFirstChild("Paddle") then
					setSeat(other)
					break
				end
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return AvatarService
