-- MovementInput (client): Shift = movement boost REQUEST. The client only reports "Shift is held"; the server
-- (Server/MovementService) validates it and sets the real WalkSpeed, so the client cannot pick its own speed.
--
-- Shift is bound at high priority and SUNK so Roblox's default Shift Lock toggle (LeftShift) never fires. It does not
-- touch the mouse, so aiming, dragging and releasing shots are unaffected. The request is cancelled whenever Shift
-- is released, the window loses focus, or the character respawns (the server also resets the boost on respawn).

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local MovementInput = {}
local M = Config.Movement

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
		label.Text = if isExhausted then "RELEASE SHIFT" else "STAMINA"
		label.TextColor3 = if isExhausted then Color3.fromRGB(255, 130, 140) else Color3.new(1, 1, 1)
		amount.Text = ("%d%%"):format(math.floor(ratio * 100 + 0.5))
	end

	player:GetAttributeChangedSignal(Config.Names.BoostStaminaAttribute):Connect(update)
	player:GetAttributeChangedSignal(Config.Names.BoostExhaustedAttribute):Connect(update)
	update()
end

function MovementInput.start(player: Player)
	if not Config.Movement.BoostEnabled then
		return
	end
	createStaminaHud(player)
	local boostRemote = ReplicatedStorage:WaitForChild(Config.Names.Remotes):WaitForChild("BoostRequest") :: RemoteEvent
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
