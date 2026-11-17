-- StanceController (client): runs the ready-stance controller (Shared/StancePose.start) on the LOCAL player's character.
-- A player's character is simulated by their own client, so the pose, the legs fade while walking and the HipHeight
-- grounding must run here (the server's copy of an animation would not drive it). Waits for the server to scale and
-- place the character (attribute NotPongPlaced). Visual only; the server never trusts anything from this.
--
-- Respawn race: a track started within a frame of spawning can be discarded by the animation system. So we wait a
-- moment after placement, and the controller itself restarts its tracks every frame if they ever stop.
--
-- FOREHAND / BACKHAND: StanceController.setStroke(stroke) cross-fades the upper-body ready pose. The requested stroke is
-- remembered, so a request made while the controller is still measuring the feet (or across a respawn) is applied as
-- soon as the controller exists. ShotController decides WHICH stroke (screen side of the mouse, locked while charging).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StancePose = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("StancePose"))
local PlatformZone = require(script.Parent:WaitForChild("PlatformZone"))

local StanceController = {}

local SETTLE_DELAY = 0.5

local desiredStroke = "Forehand"
local desiredPosture = 0 -- serving-posture hip yaw (radians), see setServePosture
local current: StancePose.Controller? = nil
local shot: any = nil -- the ShotController (click-and-flick): drives the paddle arm (StancePose arm layer)

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
	local controller = StancePose.start(character, nil, desiredStroke)
	if not controller then
		warn("[StanceController] could not start the ready stance on", character.Name)
		return
	end
	if character.Parent == nil then
		return
	end
	current = controller
	controller:setStroke(desiredStroke)
	controller:setServePosture(desiredPosture)
	if shot and (controller :: any).setShot then
		(controller :: any):setShot(shot)
	end
	controller:setActive(PlatformZone.isOn())
end

-- The paddle arm follows the shot controller's preparation, commitment and swings (StancePose arm layer). Remembered
-- across controller restarts (respawns).
function StanceController.attachShot(controller: any)
	shot = controller
	if current and (current :: any).setShot then
		(current :: any):setShot(controller)
	end
end

-- Request the ready pose for "Forehand" | "Backhand".
function StanceController.setStroke(stroke: string)
	desiredStroke = if stroke == "Backhand" then "Backhand" else "Forehand"
	if current then
		current:setStroke(desiredStroke)
	end
end

-- Serving posture (Config.Serve.Posture): hip yaw in radians (0 = none). Remembered across controller restarts.
function StanceController.setServePosture(yaw: number)
	desiredPosture = yaw
	if current then
		current:setServePosture(yaw)
	end
end
-- Footwork state for tests / debug (nil while the controller is starting).
function StanceController.debug(): { [string]: number }?
	local c = current :: any
	if not c then
		return nil
	end
	return { move = c.moveWeight, cross = c.crossWeight or 0, run = c.runWeight, phase = c.phase }
end

function StanceController.getServePostureYaw(): number
	return current and current.servePostureYaw or 0
end

-- The stroke the pose currently shows (nil while the controller is starting). For tests and debug.
function StanceController.getStroke(): string?
	return current and current.stroke or nil
end

function StanceController.start(player: Player)
	-- Off the platform the stance and footwork stop (standard Roblox animations); back on, they fade back in.
	PlatformZone.onChanged(function(on)
		if current then
			current:setActive(on)
		end
	end)
	player.CharacterAdded:Connect(function(character)
		current = nil -- the old character's controller stops itself when its character goes away
		task.spawn(pose, character)
	end)
	if player.Character then
		task.spawn(pose, player.Character)
	end
end

return StanceController
