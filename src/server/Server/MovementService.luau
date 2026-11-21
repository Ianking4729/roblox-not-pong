-- MovementService (server): the only place that decides how fast and how high a player's character can move.
--   * Shift boost: the client sends a boolean request (BoostRequest); the server validates it and sets
--     Humanoid.WalkSpeed to Config.Avatar.WalkSpeed * Config.Movement.BoostMultiplier for a living, placed character
--     while it is held, drains server-owned stamina, and restores normal speed on release or exhaustion. A charge
--     slow-motion scale applies on top of either speed (slow motion is currently never started).
--   * Optional jump cap (Movement.MaxJumpHeight, off by default). Keeping players off the table is TableGuard's job.
--   * EMERGENCY-SAVE GET-UP (Config.Emergency; 2026-11-17, replaces the F dive's lunge and 1.3 s recovery): RallyService
--     calls setRecovery when an emergency attempt lands; for StandUpTime from landing the WalkSpeed is multiplied by
--     RecoverySpeedFactor. The window is TIMESTAMPED (a start and an end on os.clock) and re-evaluated every Heartbeat,
--     so nothing can leave the speed stuck: it ends by itself, and respawn / leaving clear it too. The character root is
--     never moved by this service (the save's reach is animation only).
--   * SERVE LOCK: from the moment a toss starts until the serve is struck or resolved, the server holds WalkSpeed at 0
--     and refuses boosting (setServeLock), so the serving spot cannot change mid-attempt.
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
local serveLocked: { [Player]: boolean } = {}
-- emergency-save get-up: { from, to, factor } on os.clock (speed x factor while from <= now < to)
local recovery: { [Player]: { from: number, to: number, factor: number } } = {}
local appliedFactor: { [Player]: number } = {} -- the recovery factor last written into WalkSpeed

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

-- The get-up's speed factor right now (1 outside the window).
local function recoveryFactor(player: Player): number
	local r = recovery[player]
	if not r then
		return 1
	end
	local now = os.clock()
	if now >= r.to then
		recovery[player] = nil
		return 1
	end
	return if now >= r.from then r.factor else 1
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
		serveLocked[player] = nil
		recovery[player], appliedFactor[player] = nil, nil -- a respawn never inherits a get-up
		publishStamina(player, true)
	end)
end

local function applySpeed(player: Player, humanoid: Humanoid)
	if serveLocked[player] then
		humanoid.WalkSpeed = 0 -- committed to a serve toss
		return
	end
	local factor = recoveryFactor(player)
	appliedFactor[player] = factor
	humanoid.WalkSpeed = MovementService.speedFor(boosting[player] == true) * (slowMotionScale[player] or 1) * factor
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

-- Called once the avatar has been scaled and placed (and again on every respawn): speed from the
-- player's current boost request (false until they hold Shift, so a respawn starts at normal speed).
function MovementService.apply(player: Player, humanoid: Humanoid)
	initializePlayer(player)
	local J = M.Jump
	if J and J.Enabled then
		-- (Pass 12) the take-off speed for Height under the character's extra gravity (Client/JumpController applies
		-- the rest of the gravity while airborne): g = 8 h / T^2, v = sqrt(2 g h) = 4 h / T
		humanoid.UseJumpPower = true
		humanoid.JumpPower = 4 * J.Height / math.max(J.AirTime, 0.1) * (J.TakeoffScale or 1)
	elseif M.MaxJumpHeight then
		humanoid.UseJumpPower = false
		humanoid.JumpHeight = M.MaxJumpHeight
	end
	applySpeed(player, humanoid)
end

-- Serve toss commitment (RallyService): no walking or boosting until released.
function MovementService.setServeLock(player: Player, on: boolean)
	serveLocked[player] = if on then true else nil
	local humanoid = humanoidOf(player)
	if humanoid and humanoid.Health > 0 then
		applySpeed(player, humanoid)
	end
end

-- EMERGENCY-SAVE GET-UP: starting `startsIn` seconds from now (landing; may be <= 0 under latency) for `duration`
-- seconds, WalkSpeed x `factor`. A new call replaces any previous window (never stacks). Ends by itself.
function MovementService.setRecovery(player: Player, startsIn: number, duration: number, factor: number)
	if startsIn ~= startsIn or duration ~= duration or factor ~= factor then
		return
	end
	local now = os.clock()
	local from = now + math.max(startsIn, 0)
	local to = now + math.max(startsIn, 0) + math.clamp(duration, 0, 5) + math.min(startsIn, 0) -- a late landing ends on time
	if to <= now then
		return
	end
	recovery[player] = { from = from, to = to, factor = math.clamp(factor, 0, 1) }
	local humanoid = humanoidOf(player)
	if humanoid and humanoid.Health > 0 then
		applySpeed(player, humanoid)
	end
end

-- (tests) the get-up window, or nil
function MovementService.getRecovery(player: Player): { from: number, to: number, factor: number }?
	return recovery[player]
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
	-- (DiveRequest, the F dive, was retired on 2026-11-17: Config.Emergency replaces it)

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

			-- the get-up window starts / ends: rewrite the speed when its factor changes (and never leave it behind)
			if humanoid and humanoid.Health > 0 and not serveLocked[player] then
				local f = recoveryFactor(player)
				if f ~= (appliedFactor[player] or 1) then
					applySpeed(player, humanoid)
				end
			end

			if boosting[player] == true
				and not serveLocked[player] -- no drain while committed to a serve toss
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
		serveLocked[player], recovery[player], appliedFactor[player] = nil, nil, nil
		stamina[player], boostEndedAt[player], exhausted[player], lastStaminaSync[player] = nil, nil, nil, nil
	end)
end

return MovementService
