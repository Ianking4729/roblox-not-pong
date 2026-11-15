-- StanceController (client): runs the ready-stance controller (Shared/StancePose.start) on the LOCAL player's character.
-- A player's character is simulated by their own client, so the pose, the legs fade while walking and the HipHeight
-- grounding must run here (the server's copy of an animation would not drive it). Waits for the server to scale and
-- place the character (attribute NotPongPlaced). Visual only; the server never trusts anything from this.
--
-- Respawn race: a track started within a frame of spawning can be discarded by the animation system. So we wait a
-- moment after placement, and the controller itself restarts its tracks every frame if they ever stop.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StancePose = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StancePose"))

local StanceController = {}

local SETTLE_DELAY = 0.5

local function pose(character: Model)
	if not character:GetAttribute("NotPongPlaced") then
		character:GetAttributeChangedSignal("NotPongPlaced"):Wait()
	end
	if character.Parent == nil or character:GetAttribute("StanceStarted") then
		return
	end
	character:SetAttribute("StanceStarted", true) -- local only: attributes set by a client do not replicate
	task.wait(SETTLE_DELAY)
	if character.Parent == nil then
		return
	end
	if not StancePose.start(character) then
		warn("[StanceController] could not start the ready stance on", character.Name)
	end
end

function StanceController.start(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(pose, character)
	end)
	if player.Character then
		task.spawn(pose, player.Character)
	end
end

return StanceController
