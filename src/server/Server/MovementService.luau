-- MovementService (server): the only place that decides how fast and how high a player's character can move.
--   * Shift boost: the client sends a boolean request (BoostRequest); the server validates it and sets
--     Humanoid.WalkSpeed to Config.Avatar.WalkSpeed * Config.Movement.BoostMultiplier for a living, placed character
--     while it is held, drains server-owned stamina, and restores normal speed on release or exhaustion. A charge
--     slow-motion scale applies on top of either speed. The client never sends a speed or stamina value.
--   * Optional jump cap (Movement.MaxJumpHeight, off by default). Keeping players off the table is TableGuard's job.
-- Applied by AvatarService.setupCharacter through MovementService.apply, after the avatar is scaled.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local MovementService = {}

local M = Config.Movement
local boosting: { [Player]: boolean } = {}
local slowMotionScale: { [Player]: number } = {}
local lastRequest: { [Player]: number } = {}
local stamina: { [Player]: number } = {}
local boostEndedAt: { [Player]: number } = {}
local exhausted: { [Player]: boolean } = {}
local lastStaminaSync: { [Player]: number } = {}
local staminaSyncInterval = 0.1

-- The walking speed for a player's current boost state. Public for tests.
function MovementService.speedFor(boost: boolean): number
	return Config.Avatar.WalkSpeed * (if boost and M.BoostEnabled then M.BoostMultiplier else 1)
end

local function publishStamina(player: Player, force: boolean?)
	local now = os.clock()
	if not force and now - (lastStaminaSync[player] or 0) < staminaSyncInterval then
		return
	end
	lastStaminaSync[player] = now
	player:SetAttribute(Config.Names.BoostStaminaAttribute, stamina[player] or M.MaxStamina)
	player:SetAttribute(Config.Names.BoostExhaustedAttribute, exhausted[player] == true)
end

local function initializePlayer(player: Player)
	if stamina[player] ~= nil then
		return
	end
	stamina[player] = M.MaxStamina
	boosting[player] = false
	exhausted[player] = false
	publishStamina(player, true)
	player.CharacterAdded:Connect(function()
		boosting[player] = false
		boostEndedAt[player] = os.clock()
		publishStamina(player, true)
	end)
end

local function applySpeed(player: Player, humanoid: Humanoid)
	humanoid.WalkSpeed = MovementService.speedFor(boosting[player] == true) * (slowMotionScale[player] or 1)
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

-- Called once the avatar has been scaled and placed (and again on every respawn): speed from the
-- player's current boost request (false until they hold Shift, so a respawn starts at normal speed).
function MovementService.apply(player: Player, humanoid: Humanoid)
	initializePlayer(player)
	if M.MaxJumpHeight then
		humanoid.UseJumpPower = false
		humanoid.JumpHeight = M.MaxJumpHeight
	end
	applySpeed(player, humanoid)
end

function MovementService.setSlowMotion(player: Player, scale: number)
	slowMotionScale[player] = math.clamp(scale, 0, 1)
	local humanoid = humanoidOf(player)
	local character = player.Character
	if humanoid and humanoid.Health > 0 and character and character:GetAttribute("NotPongPlaced") then
		applySpeed(player, humanoid)
	end
end

function MovementService.start()
	Players.PlayerAdded:Connect(initializePlayer)
	for _, player in Players:GetPlayers() do
		initializePlayer(player)
	end

	-- Roblox's own Shift Lock would also claim Shift; this game has its own camera and facing.
	pcall(function()
		StarterPlayer.EnableMouseLockOption = false
	end)

	local folder = ReplicatedStorage:FindFirstChild(Config.Names.Remotes)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.Names.Remotes
		folder.Parent = ReplicatedStorage
	end
	local remote = folder:FindFirstChild("BoostRequest") :: RemoteEvent?
	if not remote then
		local created = Instance.new("RemoteEvent")
		created.Name = "BoostRequest"
		created.Parent = folder
		remote = created
	end
	local boostRemote = remote :: RemoteEvent

	boostRemote.OnServerEvent:Connect(function(player: Player, wanted: any)
		if typeof(wanted) ~= "boolean" then
			return
		end
		initializePlayer(player)
		local now = os.clock()
		local humanoid = humanoidOf(player)

		if not wanted then
			local wasBoosting = boosting[player] == true
			local wasExhausted = exhausted[player] == true
			if not wasBoosting and not wasExhausted then
				return
			end
			boosting[player] = false
			if wasBoosting then
				boostEndedAt[player] = now
			end
			exhausted[player] = false
			if humanoid and humanoid.Health > 0 then
				applySpeed(player, humanoid)
			end
			publishStamina(player, true)
			return
		end

		if not M.BoostEnabled or now - (lastRequest[player] or -math.huge) < M.BoostRequestInterval then
			return -- only boost-on requests are rate limited; boost-off must always stop movement
		end
		lastRequest[player] = now
		if exhausted[player] or (stamina[player] or 0) <= 0 then
			exhausted[player] = true
			publishStamina(player, true)
			return
		end

		boosting[player] = true -- remembered until placed, but stamina only drains for a living placed avatar
		if humanoid and humanoid.Health > 0 and player.Character and player.Character:GetAttribute("NotPongPlaced") then
			applySpeed(player, humanoid)
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			initializePlayer(player)
			local current = stamina[player] or M.MaxStamina
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")

			if boosting[player] == true
				and humanoid
				and humanoid.Health > 0
				and character
				and character:GetAttribute("NotPongPlaced") == true
			then
				current = math.max(0, current - M.MaxStamina / M.BoostDuration * dt)
				if current <= 0 then
					boosting[player] = false
					exhausted[player] = true
					boostEndedAt[player] = now
					applySpeed(player, humanoid)
				end
			elseif not boosting[player] and current < M.MaxStamina then
				local endedAt = boostEndedAt[player] or now
				if now >= endedAt + M.StaminaRegenerationDelay then
					current = math.min(
						M.MaxStamina,
						current + M.MaxStamina / M.StaminaRegenerationDuration * dt
					)
				end
			end

			stamina[player] = current
			publishStamina(player, false)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		boosting[player], slowMotionScale[player], lastRequest[player] = nil, nil, nil
		stamina[player], boostEndedAt[player], exhausted[player], lastStaminaSync[player] = nil, nil, nil, nil
	end)
end

return MovementService
