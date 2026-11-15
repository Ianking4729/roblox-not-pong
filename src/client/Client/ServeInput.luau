-- ServeInput (client): TEMPORARY serve control. Space asks the server to serve when it is the player's serve.
-- Only a request: the server validates seat, state, turn, distance and timing (RallyService). When it is not the
-- player's serve, Space is passed through so it still jumps.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GameStates = require(Shared:WaitForChild("GameStates"))

local ServeInput = {}

function ServeInput.start()
	local arena = workspace:WaitForChild(Config.Names.Arena)
	local serveRemote = ReplicatedStorage:WaitForChild(Config.Names.Remotes):WaitForChild("ServeRequest") :: RemoteEvent
	local Attr = GameStates.Attributes
	ContextActionService:BindActionAtPriority("NotPongServe", function(_, inputState)
		local myServe = arena:GetAttribute(Attr.State) == GameStates.State.ReadyToServe
			and arena:GetAttribute(Attr.Server) == GameStates.Side.Player
		if not myServe then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			serveRemote:FireServer()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space)
end

return ServeInput
