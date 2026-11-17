-- MovementService (server): the only place that decides how fast and how high a player's character can move.
--   * Shift boost: the client sends a boolean request (BoostRequest); the server validates it and sets
--     Humanoid.WalkSpeed to Config.Avatar.WalkSpeed * Config.Movement.BoostMultiplier for a living, placed character
--     while it is held, drains server-owned stamina, and restores normal speed on release or exhaustion. A charge
--     slow-motion scale applies on top of either speed. The client never sends a speed or stamina value.
--   * Optional jump cap (Movement.MaxJumpHeight, off by default). Keeping players off the table is TableGuard's job.
--   * DIVE (F): the client sends only "dive" + a horizontal direction (DiveRequest). The server checks the character,
--     the cooldown, that it is not already diving or serving, the stamina (Movement.DiveStaminaCost) and finally
--     RallyService's gate (live rally, one dive per incoming ball). It then drives a fixed-length lunge with a
--     server-created LinearVelocity on the root (physics, never a teleport; the table guard still blocks it; Shift boost
--     does not lengthen it), holds WalkSpeed at 0 through the lunge and the 1.3 s recovery, and publishes the phase on
--     the character (Names.DiveStateAttribute). RallyService plays the AUTOMATIC dive return during the dive's contact
--     window (MovementService.diveContact; 2026-11-16 pass 3) and refuses manual swings for the whole dive.
--   * SERVE LOCK: from the moment a toss starts until the serve is struck or resolved, the server holds WalkSpeed at 0
--     and refuses dives and boosting (setServeLock), so the serving spot cannot change mid-attempt.
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
-- dive state per player: { phase = "lunge" | "recover", startedAt, dir, startPos, serial, mover }
export type Dive = { phase: string, startedAt: number, contactUntil: number, dir: Vector3, startPos: Vector3, serial: number, mover: Instance? }
local dives: { [Player]: Dive } = {}
local lastDiveAt: { [Player]: number } = {}
local diveSerial = 0
local diveGate: ((Player) -> (boolean, string?))? = nil
local serveLocked: { [Player]: boolean } = {}

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
		dives[player] = nil -- (the old character's mover went with it)
		serveLocked[player] = nil
		publishStamina(player, true)
	end)
end

local function applySpeed(player: Player, humanoid: Humanoid)
	if dives[player] or serveLocked[player] then
		humanoid.WalkSpeed = 0 -- lunging (the LinearVelocity moves the body), recovering, or committed to a serve toss
		return
	end
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

-- RallyService decides whether a dive may start (live rally, one per incoming ball); called last, after every other
-- check passed, and may record that the dive happened.
function MovementService.setDiveGate(fn: (Player) -> (boolean, string?))
	diveGate = fn
end

-- The player's current dive (nil when not diving). Read-only for RallyService.
function MovementService.getDive(player: Player): Dive?
	return dives[player]
end

-- During a dive: its direction while its contact window is open (a swing then gets the extended reach), and whether the
-- player is diving at all (true after the window too: recovering, no contact possible).
function MovementService.diveContact(player: Player): (Vector3?, boolean)
	local d = dives[player]
	if not d then
		return nil, false
	end
	return if os.clock() <= d.contactUntil then d.dir else nil, true
end

-- Serve toss commitment (RallyService): no walking, boosting or diving until released.
function MovementService.setServeLock(player: Player, on: boolean)
	serveLocked[player] = if on then true else nil
	local humanoid = humanoidOf(player)
	if humanoid and humanoid.Health > 0 then
		applySpeed(player, humanoid)
	end
end

local function setDivePhase(player: Player, phase: string)
	local character = player.Character
	if character then
		character:SetAttribute(Config.Names.DiveStateAttribute, phase)
	end
end

local function endDive(player: Player, serial: number?)
	local d = dives[player]
	if not d or (serial and d.serial ~= serial) then
		return
	end
	if d.mover then
		d.mover:Destroy()
	end
	dives[player] = nil
	setDivePhase(player, "")
	local humanoid = humanoidOf(player)
	if humanoid and humanoid.Health > 0 then
		applySpeed(player, humanoid)
	end
end

-- Returns ok, reason. Public for tests (the remote calls this).
function MovementService.requestDive(player: Player, dir: any): (boolean, string)
	if not M.DiveEnabled then
		return false, "dive disabled"
	end
	if typeof(dir) ~= "Vector3" or dir.X ~= dir.X or dir.Z ~= dir.Z then
		return false, "bad direction"
	end
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.1 or flat.Magnitude > 1e4 then
		return false, "no direction"
	end
	flat = flat.Unit
	initializePlayer(player)
	local character = player.Character
	local humanoid = humanoidOf(player)
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not humanoid or humanoid.Health <= 0 or not root or not character:GetAttribute("NotPongPlaced") then
		return false, "no character"
	end
	local now = os.clock()
	if dives[player] then
		return false, "already diving"
	end
	if serveLocked[player] then
		return false, "serving"
	end
	if now - (lastDiveAt[player] or -math.huge) < M.DiveCooldown then
		return false, "cooldown"
	end
	if (stamina[player] or 0) < M.DiveStaminaCost then
		player:SetAttribute(Config.Names.DiveRefusedAttribute, (player:GetAttribute(Config.Names.DiveRefusedAttribute) or 0) + 1)
		return false, "not enough stamina"
	end
	if diveGate then
		local ok, why = diveGate(player)
		if not ok then
			return false, why or "not now"
		end
	end
	-- Start: pay, then lunge.
	stamina[player] = (stamina[player] or 0) - M.DiveStaminaCost
	boostEndedAt[player] = now -- regeneration waits its usual delay after the dive starts
	publishStamina(player, true)
	lastDiveAt[player] = now
	diveSerial += 1
	local serial = diveSerial
	local scale = slowMotionScale[player] or 1
	local speed = M.DiveDistance / math.max(M.DiveDuration, 1e-3) * scale
	local attachment = root:FindFirstChild("RootAttachment") :: Attachment?
	local created = false
	if not attachment then
		local a = Instance.new("Attachment")
		a.Name = "NotPongDiveAttachment"
		a.Parent = root
		attachment = a
		created = true
	end
	local mover = Instance.new("LinearVelocity")
	mover.Name = "NotPongDive"
	mover.Attachment0 = attachment
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane -- horizontal only: gravity still applies
	mover.PrimaryTangentAxis = Vector3.xAxis
	mover.SecondaryTangentAxis = Vector3.zAxis
	mover.PlaneVelocity = Vector2.new(flat.X * speed, flat.Z * speed)
	mover.MaxForce = 1e7
	mover.Parent = root
	if created then
		mover.Destroying:Once(function()
			if attachment then
				attachment:Destroy()
			end
		end)
	end
	dives[player] = {
		phase = "lunge",
		startedAt = now,
		contactUntil = now + M.DiveContactWindow / math.max(scale, 0.05), -- (slow motion stretches the lunge)
		dir = flat,
		startPos = root.Position,
		serial = serial,
		mover = mover,
	}
	character:SetAttribute(Config.Names.DiveDirAttribute, flat)
	setDivePhase(player, "lunge")
	applySpeed(player, humanoid)
	task.delay(M.DiveDuration / math.max(scale, 0.05), function()
		local d = dives[player]
		if not d or d.serial ~= serial then
			return
		end
		if d.mover then
			d.mover:Destroy()
			d.mover = nil
		end
		d.phase = "recover"
		setDivePhase(player, "recover")
		task.delay(M.DiveRecovery, function()
			endDive(player, serial)
		end)
	end)
	return true, "diving"
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

	local diveRemote = folder:FindFirstChild("DiveRequest") :: RemoteEvent?
	if not diveRemote then
		local created = Instance.new("RemoteEvent")
		created.Name = "DiveRequest"
		created.Parent = folder
		diveRemote = created
	end
	local lastDiveRequest: { [Player]: number } = {}
	;(diveRemote :: RemoteEvent).OnServerEvent:Connect(function(player: Player, dir: any)
		local now = os.clock()
		if now - (lastDiveRequest[player] or -math.huge) < 0.1 then
			return -- spam
		end
		lastDiveRequest[player] = now
		MovementService.requestDive(player, dir)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastDiveRequest[player] = nil
	end)

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
				and not dives[player] -- no boost drain while diving (the dive paid its own cost)
				and not serveLocked[player] -- nor while committed to a serve toss
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
			elseif not boosting[player] and not dives[player] and current < M.MaxStamina then
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
		dives[player], lastDiveAt[player], serveLocked[player] = nil, nil, nil
		stamina[player], boostEndedAt[player], exhausted[player], lastStaminaSync[player] = nil, nil, nil, nil
	end)
end

return MovementService
