-- MatchOverUI (client; Pass 13, 2026-11-19): after a match ends the ball rides in your free hand (server: RallyService
-- holds it there) and nothing restarts by itself. On the platform you get a "Start new match" button (or E); off the
-- platform a short hint says to come back. The button only REQUESTS a new match: the server validates the seat, the
-- state and that you stand on the platform (StartMatchRequest) and resets the match. Space keeps jumping here; it only
-- tosses during your own serve (ServeInput), so the two never share a key.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GameStates = require(Shared:WaitForChild("GameStates"))

local PlatformZone = require(script.Parent:WaitForChild("PlatformZone"))

local MatchOverUI = {}

function MatchOverUI.start(player: Player)
	local arena = workspace:WaitForChild(Config.Names.Arena)
	local remotes = ReplicatedStorage:WaitForChild(Config.Names.Remotes)
	local request = remotes:WaitForChild("StartMatchRequest") :: RemoteEvent
	local result = remotes:WaitForChild("StartMatchResult") :: RemoteEvent
	local Attr = GameStates.Attributes

	local gui = Instance.new("ScreenGui")
	gui.Name = "NotPongMatchOver"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 7
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -210)
	panel.Size = UDim2.fromOffset(420, 96)
	panel.BackgroundTransparency = 1
	panel.Parent = gui

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 22
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeTransparency = 0.4
	title.Text = "Match over"
	title.Parent = panel

	local button = Instance.new("TextButton")
	button.Name = "StartNewMatch"
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Position = UDim2.new(0.5, 0, 0, 36)
	button.Size = UDim2.fromOffset(260, 44)
	button.BackgroundColor3 = Color3.fromRGB(40, 44, 56)
	button.BackgroundTransparency = 0.15
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Text = "Start new match  [E]"
	button.AutoButtonColor = true
	button.Parent = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 220, 255)
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, 0, 0, 24)
	hint.Position = UDim2.new(0, 0, 0, 40)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamBold
	hint.TextSize = 16
	hint.TextColor3 = Color3.fromRGB(200, 210, 225)
	hint.TextStrokeTransparency = 0.5
	hint.Text = "Return to the platform to start a new match"
	hint.Parent = panel

	local status, statusUntil = "", 0
	local pendingUntil = 0
	local stats = { requests = 0, lastReply = nil :: any }

	local function eligibleHere(): boolean
		return arena:GetAttribute(Attr.State) == GameStates.State.MatchOver
			and arena:GetAttribute(Config.Names.SeatedPlayerAttribute) == player.UserId
	end
	local function canRequest(): boolean
		return eligibleHere() and PlatformZone.isOn() and os.clock() >= pendingUntil
	end
	local function requestStart(): boolean
		if not canRequest() then
			return false
		end
		pendingUntil = os.clock() + 1
		stats.requests += 1
		request:FireServer()
		return true
	end

	button.Activated:Connect(requestStart)
	ContextActionService:BindActionAtPriority("NotPongStartMatch", function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if eligibleHere() and PlatformZone.isOn() then
			requestStart()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.E)

	result.OnClientEvent:Connect(function(msg)
		if typeof(msg) ~= "table" then
			return
		end
		stats.lastReply = msg
		pendingUntil = 0
		if not msg.ok then
			status, statusUntil = "Can't start: " .. tostring(msg.reason), os.clock() + 2
		end
	end)

	RunService.RenderStepped:Connect(function()
		local show = eligibleHere()
		gui.Enabled = show
		if not show then
			return
		end
		local on = PlatformZone.isOn()
		button.Visible = on
		hint.Visible = not on or os.clock() < statusUntil
		if os.clock() < statusUntil then
			hint.Text = status
			hint.Position = UDim2.new(0, 0, 0, if on then 84 else 40)
		else
			hint.Text = "Return to the platform to start a new match"
			hint.Position = UDim2.new(0, 0, 0, 40)
		end
		local p, b = arena:GetAttribute(Attr.ScorePlayer) or 0, arena:GetAttribute(Attr.ScoreBot) or 0
		title.Text = ("Match over  -  You %d : %d Bot"):format(p, b)
	end)

	if Config.ShotControl.ShowDiagnostics then
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongMatchDebug"
		bridge.OnInvoke = function(cmd: string?)
			local fired = if cmd == "start" then requestStart() else nil
			return { visible = gui.Enabled, button = button.Visible, hint = hint.Visible and hint.Text or nil, requests = stats.requests, lastReply = stats.lastReply, fired = fired, onPlatform = PlatformZone.isOn() }
		end
		bridge.Parent = player
	end
end

return MatchOverUI
