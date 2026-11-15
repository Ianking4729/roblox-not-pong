-- DebugHud: a small text label showing the replicated match state. Placeholder UI for development only.
-- Event-driven: it re-renders from attribute change signals on the arena folder (written by the server).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Attr = require(Shared:WaitForChild("GameStates")).Attributes

local DebugHud = {}

function DebugHud.start(playerGui: PlayerGui)
	if not Config.Debug.ShowStateLabel then
		return
	end
	local arena = workspace:WaitForChild(Config.Names.Arena)

	local gui = Instance.new("ScreenGui")
	gui.Name = "NotPongDebug"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false

	local label = Instance.new("TextLabel")
	label.Name = "State"
	label.AnchorPoint = Vector2.new(0, 0)
	label.Position = UDim2.new(0, 8, 0, 8) -- top-left: keeps the opponent's head, top-centre, unobstructed
	label.Size = UDim2.fromOffset(470, 52)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 16
	label.Parent = gui

	local function render()
		label.Text = ("%s  |  Serve: %s  |  You %s - %s Bot  |  Rally: %s\n%s"):format(
			tostring(arena:GetAttribute(Attr.State)),
			tostring(arena:GetAttribute(Attr.Server)),
			tostring(arena:GetAttribute(Attr.ScorePlayer)),
			tostring(arena:GetAttribute(Attr.ScoreBot)),
			tostring(arena:GetAttribute(Attr.RallyHits)),
			tostring(arena:GetAttribute(Attr.LastEvent) or "")
		)
	end
	for _, name in Attr do
		arena:GetAttributeChangedSignal(name):Connect(render)
	end
	render()
	gui.Parent = playerGui
end

return DebugHud
