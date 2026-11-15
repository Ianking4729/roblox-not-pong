-- Stance (server): runs the ready-stance controller on a SERVER-simulated character (the bot).
-- A player's character is simulated by their own client, so Client/StanceController does the same for them.
-- The pose, the legs fade while walking and the HipHeight grounding all live in Shared/StancePose.start.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StancePose = require(Shared:WaitForChild("StancePose"))

local Stance = {}

-- The R15 walk animation from the rig's own (non-running) Animate script, so the bot steps when it moves.
local function walkId(character: Model): string?
	local animate = character:FindFirstChild("Animate")
	local walk = animate and animate:FindFirstChild("walk")
	local anim = walk and walk:FindFirstChildWhichIsA("Animation")
	return anim and anim.AnimationId or nil
end

-- Start the stance controller. Yields ~1 s while it measures the feet. Returns the controller or nil.
function Stance.apply(character: Model)
	if character:GetAttribute("StanceApplied") then
		return nil
	end
	character:SetAttribute("StanceApplied", true)
	return StancePose.start(character, walkId(character))
end

return Stance
