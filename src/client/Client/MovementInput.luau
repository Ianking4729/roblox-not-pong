-- MovementInput (client): Shift = movement boost REQUEST. The client only reports "Shift is held"; the server
-- (Server/MovementService) validates it and sets the real WalkSpeed, so the client cannot pick its own speed.
--
-- Shift is bound at high priority and SUNK so Roblox's default Shift Lock toggle (LeftShift) never fires. It does not
-- touch the mouse, so aiming, dragging and releasing shots are unaffected. The request is cancelled whenever Shift
-- is released, the window loses focus, or the character respawns (the server also resets the boost on respawn).

--
-- DIVE (Config.Movement.DiveKey, F): sends a dive REQUEST with a direction: the movement input (Humanoid.MoveDirection,
-- i.e. WASD relative to the camera, which sits behind the player facing the table) or, with no keys held (or W alone),
-- toward the current stroke's side (backhand = left, forehand = right). S (alone or with A/D) dives BACKWARD along the
-- held direction. The server validates everything (stamina, cooldown, live rally, one per ball, not while serving) and
-- moves the body; this module only plays the matching dive (ShotInput.diveKind: Right / Left / Back) when the server
-- confirms it, and flashes NO STAMINA when it refuses for stamina. A dive never hits: the swing does (ShotController).

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local StancePose = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StancePose"))
local ShotInput = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShotInput"))

local MovementInput = {}
local M = Config.Movement

local strokeGetter: (() -> string)? = nil
-- ShotController owns the stroke; Main wires it here (used for a dive with no movement keys held).
function MovementInput.setStrokeGetter(fn: () -> string)
	strokeGetter = fn
end

local function createStaminaHud(player: Player)
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "NotPongStamina"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 5
	screen.Parent = playerGui

	local width = Config.Feedback.PowerMeter.Width + 96
	local panel = Instance.new("Frame")
	panel.Name = "Stamina"
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -24, 1, -232)
	panel.Size = UDim2.fromOffset(width, 36)
	panel.BackgroundColor3 = Color3.fromRGB(22, 14, 40)
	panel.BackgroundTransparency = 0.3
	panel.BorderSizePixel = 0
	panel.Parent = screen
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(190, 140, 255)
	panelStroke.Transparency = 0.45
	panelStroke.Thickness = 1.5
	panelStroke.Parent = panel

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(12, 0)
	label.Size = UDim2.fromOffset(92, 36)
	label.Font = Enum.Font.GothamBold
	label.Text = "STAMINA"
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = panel

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(106, 11)
	track.Size = UDim2.fromOffset(width - 120, 14)
	track.BackgroundColor3 = Color3.fromRGB(10, 6, 22)
	track.BackgroundTransparency = 0.2
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = panel
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0.5, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(105, 230, 150)
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = fill

	local amount = Instance.new("TextLabel")
	amount.Name = "Amount"
	amount.BackgroundTransparency = 1
	amount.Size = UDim2.fromScale(1, 1)
	amount.Font = Enum.Font.GothamBold
	amount.TextColor3 = Color3.new(1, 1, 1)
	amount.TextSize = 11
	amount.ZIndex = 2
	amount.Parent = track

	-- Dive cost marker on the bar (stamina needed for one dive)
	if M.DiveEnabled then
		local mark = Instance.new("Frame")
		mark.Name = "DiveCost"
		mark.AnchorPoint = Vector2.new(0.5, 0.5)
		mark.Position = UDim2.fromScale(math.clamp(M.DiveStaminaCost / M.MaxStamina, 0, 1), 0.5)
		mark.Size = UDim2.new(0, 2, 1, 4)
		mark.BackgroundColor3 = Color3.new(1, 1, 1)
		mark.BackgroundTransparency = 0.35
		mark.BorderSizePixel = 0
		mark.ZIndex = 3
		mark.Parent = track
	end

	local flashUntil = 0
	local function update()
		local current = player:GetAttribute(Config.Names.BoostStaminaAttribute)
		local value = if typeof(current) == "number" then current else M.MaxStamina
		local ratio = math.clamp(value / M.MaxStamina, 0, 1)
		local isExhausted = player:GetAttribute(Config.Names.BoostExhaustedAttribute) == true
		fill.Size = UDim2.fromScale(ratio, 1)
		fill.BackgroundColor3 = if ratio <= 0.25
			then Color3.fromRGB(255, 100, 110)
			elseif ratio <= 0.55 then Color3.fromRGB(255, 195, 90)
			else Color3.fromRGB(105, 230, 150)
		local flashing = os.clock() < flashUntil
		label.Text = if flashing then "NO STAMINA" elseif isExhausted then "RELEASE SHIFT" else "STAMINA"
		label.TextColor3 = if flashing or isExhausted then Color3.fromRGB(255, 130, 140) else Color3.new(1, 1, 1)
		panelStroke.Color = if flashing then Color3.fromRGB(255, 110, 120) else Color3.fromRGB(190, 140, 255)
		amount.Text = ("%d%%"):format(math.floor(ratio * 100 + 0.5))
	end

	player:GetAttributeChangedSignal(Config.Names.BoostStaminaAttribute):Connect(update)
	player:GetAttributeChangedSignal(Config.Names.BoostExhaustedAttribute):Connect(update)
	player:GetAttributeChangedSignal(Config.Names.DiveRefusedAttribute):Connect(function()
		flashUntil = os.clock() + 0.8
		update()
		task.delay(0.85, update)
	end)
	update()
end

-- Plays the dive + get-up when the server confirms a dive on `character`, following the server's phases: "lunge"
-- starts the clip, "recover" re-syncs it to the get-up, "" (dive over) lets it finish or blends it out if cut short.
-- Jumping is disabled for the whole dive (the body must not leave the floor pose). Visual only.
local function watchDivePose(character: Model)
	local handle: StancePose.DiveHandle? = nil
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	character:GetAttributeChangedSignal(Config.Names.DiveStateAttribute):Connect(function()
		local phase = character:GetAttribute(Config.Names.DiveStateAttribute) or ""
		if phase == "lunge" then
			local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local dir = character:GetAttribute(Config.Names.DiveDirAttribute)
			local side = "Right"
			if root and typeof(dir) == "Vector3" then
				side = ShotInput.diveKind(dir, root.CFrame)
			end
			if humanoid then
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
			end
			handle = StancePose.dive(character, side)
		elseif phase == "recover" then
			if handle then
				handle:recover()
			end
		else
			if humanoid then
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			end
			if handle then
				handle:finish()
				handle = nil
			end
		end
	end)
end

function MovementInput.start(player: Player)
	if not Config.Movement.BoostEnabled then
		return
	end
	createStaminaHud(player)
	local remotesFolder = ReplicatedStorage:WaitForChild(Config.Names.Remotes)
	local boostRemote = remotesFolder:WaitForChild("BoostRequest") :: RemoteEvent

	if M.DiveEnabled then
		local diveRemote = remotesFolder:WaitForChild("DiveRequest") :: RemoteEvent
		ContextActionService:BindActionAtPriority("NotPongDive", function(_, inputState)
			if inputState ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			local character = player.Character
			local hum = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not hum or not root then
				return Enum.ContextActionResult.Pass
			end
			local move = Vector3.new(hum.MoveDirection.X, 0, hum.MoveDirection.Z)
			local right = Vector3.new(root.CFrame.RightVector.X, 0, root.CFrame.RightVector.Z).Unit
			local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
			local dir
			-- W alone (toward the table, no sideways input) is not a dive direction: like no input, the stroke's side
			local forwardOnly = move.Magnitude > 0.1 and math.abs(move.Unit:Dot(right)) < 0.3 and move.Unit:Dot(look) > 0
			if move.Magnitude > 0.1 and not forwardOnly then
				dir = move.Unit
			else
				local stroke = if strokeGetter then strokeGetter() else "Forehand"
				dir = if stroke == "Backhand" then -right else right
			end
			diveRemote:FireServer(dir)
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, M.DiveKey)
		if player.Character then
			watchDivePose(player.Character)
		end
		player.CharacterAdded:Connect(watchDivePose)
	end
	local held = false

	local function set(value: boolean)
		if held == value then
			return
		end
		held = value
		boostRemote:FireServer(value)
	end

	ContextActionService:BindActionAtPriority("NotPongBoost", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			set(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			-- (holding both Shift keys: stay boosted until both are up)
			set(UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift))
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)

	UserInputService.WindowFocusReleased:Connect(function()
		set(false)
	end)
	player.CharacterAdded:Connect(function()
		held = false -- the server reset the boost on respawn; the next press sends a fresh request
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
			set(true)
		end
	end)
end

return MovementInput
