-- Stance (server): runs the ready-stance controller on a SERVER-simulated character (the bot).
-- A player's character is simulated by their own client, so Client/StanceController does the same for them.
-- The pose and the footwork live in Shared/StancePose.start (the bot uses the same shuffle footwork as players; the
-- walk id below is passed for reference only and is ignored since 2026-11-15 pass 2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StancePose = require(Shared:WaitForChild("StancePose"))

local Stance = {}

local controllers = setmetatable({}, { __mode = "k" }) :: { [Model]: StancePose.Controller }

-- The running stance controller of a server-simulated character (the bot), for its stroke pose.
function Stance.controllerOf(character: Model): StancePose.Controller?
	return controllers[character]
end

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
	local controller = StancePose.start(character, walkId(character))
	if controller then
		controllers[character] = controller
	end
	return controller
end

return Stance
