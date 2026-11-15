-- BotService: spawns the humanoid opponent at the far end of the table, holding a paddle.
-- Movement toward the ball is BotController's job (driven by RallyService); this module only builds the bot.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CollisionSetup = require(script.Parent:WaitForChild("CollisionSetup"))
local PaddleFactory = require(script.Parent:WaitForChild("PaddleFactory"))
local AvatarService = require(script.Parent:WaitForChild("AvatarService"))

local BotService = {}

-- Builds the bot under `parent`. Yields (it asks Roblox to build a rig). Returns the bot Model, or nil + warns.
function BotService.spawn(parent: Instance, stand: Vector3?): Model?
	local B = Config.Bot
	local desc = Instance.new("HumanoidDescription")
	desc.HeadColor = B.SkinColor
	desc.TorsoColor = B.ShirtColor
	desc.LeftArmColor = B.ShirtColor
	desc.RightArmColor = B.SkinColor
	desc.LeftLegColor = B.PantsColor
	desc.RightLegColor = B.PantsColor

	local ok, bot = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not bot then
		warn("[BotService] could not build bot rig:", bot)
		return nil
	end

	bot.Name = B.Name
	local humanoid = bot:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)

	bot.Parent = parent
	CollisionSetup.assignLive(bot, Config.CollisionGroups.Character)
	AvatarService.placeCharacter(bot, stand or Config.Layout.BotStand, Config.Layout.BotFacing)
	humanoid.WalkSpeed = B.WalkSpeed -- AFTER scaling (ScaleTo multiplies WalkSpeed)
	PaddleFactory.attachToHand(bot) -- the paddle's parts are already in the Paddle group

	-- Keep the bot facing the table while BotController walks it around (sidesteps instead of turning).
	humanoid.AutoRotate = false
	local root = bot:FindFirstChild("HumanoidRootPart") :: BasePart
	local att = Instance.new("Attachment")
	att.Name = "NotPongFacing"
	att.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "NotPongFacing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = false
	align.Responsiveness = Config.Facing.Responsiveness
	align.MaxTorque = Config.Facing.MaxTorque
	align.CFrame = CFrame.lookAt(Vector3.zero, Config.Layout.BotFacing)
	align.Parent = root

	-- The server drives the bot. The API only exists while the game is running (not in Edit-mode previews).
	if RunService:IsRunning() then
		(bot:FindFirstChild("HumanoidRootPart") :: BasePart):SetNetworkOwner(nil)
	end
	return bot
end

return BotService
