-- Main (client): starts the camera, debug HUD, stance, facing, ball renderer, serve input, shot controls and the Phase 4
-- feedback layers (indicators, trail, impact, avatar fade, Shift boost input, receiver outline). Visuals only; the server owns all gameplay state.

local Players = game:GetService("Players")

local Client = script.Parent
local CameraController = require(Client:WaitForChild("CameraController"))
local DebugHud = require(Client:WaitForChild("DebugHud"))
local StanceController = require(Client:WaitForChild("StanceController"))
local FacingController = require(Client:WaitForChild("FacingController"))
local BallView = require(Client:WaitForChild("BallView"))
local ServeInput = require(Client:WaitForChild("ServeInput"))
local ShotController = require(Client:WaitForChild("ShotController"))
local ShotFeedback = require(Client:WaitForChild("ShotFeedback"))
local ImpactFx = require(Client:WaitForChild("ImpactFx"))
local BallTrail = require(Client:WaitForChild("BallTrail"))
local CharacterFade = require(Client:WaitForChild("CharacterFade"))
local MovementInput = require(Client:WaitForChild("MovementInput"))
local ReceiverOutline = require(Client:WaitForChild("ReceiverOutline"))
local FrameDriver = require(Client:WaitForChild("FrameDriver"))

local player = Players.LocalPlayer

-- Animation retargeting off before any character animates (Config.Animation: it double-scaled the default walk's hip
-- motion on our 3.37x avatars, which made walking off the platform look shaky). The local character animates here.
do
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
	pcall(function()
		workspace.Retargeting = Config.Animation.Retargeting
	end)
end

-- One shared on/off-platform state for the camera, facing, stance/footwork and fade (Client/PlatformZone).
require(Client:WaitForChild("PlatformZone")).start()

local camera = CameraController.new(player)
camera:start()

FrameDriver.startDebugBridge(player) -- (a child of the Player survives respawns; PlayerGui contents do not)
DebugHud.start(player:WaitForChild("PlayerGui"))
StanceController.start(player)
FacingController.new(player):start()
task.spawn(BallView.start)
task.spawn(ServeInput.start)
task.spawn(function()
	local controller = ShotController.start(player)
	if controller then
		-- Forehand / backhand: the shot controller decides (screen side, locked from the click); the stance shows it, and
		-- the paddle arm follows the controller's preparation, commitment and swings (StanceController.attachShot).
		StanceController.setStroke(controller.stroke)
		StanceController.attachShot(controller)
		ServeInput.attachShotController(controller) -- the serve strike + the aim lock follow the shot input
		controller.on(function(event: string, data: any)
			if event == "stroke" then
				StanceController.setStroke(data.stroke)
			end
		end)
		ShotFeedback.start(player, controller, { impact = ImpactFx.start() })
		require(Client:WaitForChild("Telemetry")).start(player, controller) -- (diagnosis only: Config.Telemetry)
		require(Client:WaitForChild("ShotVfx")).start(player, controller) -- (contact accents + paddle trail: Config.Feedback.ShotVfx)
		require(Client:WaitForChild("ZoneDebug")).start(player, controller) -- (developer zone outlines: Config.ContactZone.Visualize)
	end
end)
task.spawn(function()
	local trail = BallTrail.start()
	BallView.onFrame(trail.onFrame) -- the trail is drawn from the rendered ball every frame
end)
task.spawn(CharacterFade.start, player)
task.spawn(MovementInput.start, player)
task.spawn(require(Client:WaitForChild("JumpController")).start, player) -- (ordinary jump: Config.Movement.Jump)
task.spawn(require(Client:WaitForChild("MatchOverUI")).start, player) -- (match over: ball in hand, "Start new match")
task.spawn(ReceiverOutline.start, player)
