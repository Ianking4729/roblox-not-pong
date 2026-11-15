-- ReceiverOutline (client, cosmetic): both competitors get a thin outline; the one about to RECEIVE the ball is green.
-- Uses one Roblox Highlight per competitor (outline only, no fill), adorned to the whole character, so hair, hats and
-- any future avatar customisation are covered without per-part work.
--
-- Who receives, from replicated state only:
--   ReadyToServe / Serving  -> the side that is NOT serving (Arena attribute "Server")
--   Rally                   -> the ball's direction (BallView: incoming = on its way to the player, else to the bot)
--   anything else (point scored, waiting, match over, ball held with no match) -> nobody: both neutral
-- Switching and resets follow because the inputs do; colours ease over FadeTime so changes do not flash.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GameStates = require(Shared:WaitForChild("GameStates"))

local BallView = require(script.Parent:WaitForChild("BallView"))

local ReceiverOutline = {}

local Attr, State, Side = GameStates.Attributes, GameStates.State, GameStates.Side

function ReceiverOutline.start(player: Player)
	local O = Config.Feedback.Outline
	if not O.Enabled then
		return
	end
	local arena = workspace:WaitForChild(Config.Names.Arena)

	local function makeHighlight(name: string): Highlight
		local h = Instance.new("Highlight")
		h.Name = name
		h.FillTransparency = 1
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.OutlineColor = O.NeutralColor
		h.OutlineTransparency = O.NeutralTransparency
		h.Enabled = false
		h.Parent = workspace.CurrentCamera
		return h
	end
	local highlights = { [Side.Player] = makeHighlight("NotPongOutlinePlayer"), [Side.Bot] = makeHighlight("NotPongOutlineBot") }
	local blend = { [Side.Player] = 0, [Side.Bot] = 0 } -- 0 = neutral, 1 = receiver

	local function receiver(): string?
		local state = arena:GetAttribute(Attr.State)
		if state == State.ReadyToServe or state == State.Serving then
			local server = arena:GetAttribute(Attr.Server)
			if server == Side.Player then
				return Side.Bot
			elseif server == Side.Bot then
				return Side.Player
			end
			return nil
		elseif state == State.Rally then
			local info = BallView.getInfo()
			if info.mode ~= "free" then
				return nil
			end
			return if info.incoming then Side.Player else Side.Bot
		end
		return nil
	end

	local botCharacter: Model? = nil
	local function characterOf(side: string): Model?
		if side == Side.Player then
			return player.Character
		end
		if not botCharacter or not botCharacter.Parent then
			-- the bot is spawned inside the arena folder
			botCharacter = arena:FindFirstChild(Config.Bot.Name, true) :: Model?
		end
		return botCharacter
	end

	RunService.Heartbeat:Connect(function(dt)
		local who = receiver()
		for side, h in highlights do
			local character = characterOf(side)
			if h.Adornee ~= character then
				h.Adornee = character -- covers respawn and the bot appearing later
			end
			h.Enabled = character ~= nil
			local goal = if who == side then 1 else 0
			local b = blend[side]
			if b ~= goal then
				b += (goal - b) * (1 - math.exp(-dt / math.max(O.FadeTime, 1e-3) * 3))
				if math.abs(goal - b) < 0.01 then
					b = goal
				end
				blend[side] = b
			end
			h.OutlineColor = O.NeutralColor:Lerp(O.ReceiverColor, b)
			h.OutlineTransparency = O.NeutralTransparency + (O.ReceiverTransparency - O.NeutralTransparency) * b
		end
	end)
end

return ReceiverOutline
