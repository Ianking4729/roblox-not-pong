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
		ShotFeedback.start(player, controller, { impact = ImpactFx.start() })
	end
end)
task.spawn(function()
	local trail = BallTrail.start()
	BallView.onFrame(trail.onFrame) -- the trail is drawn from the rendered ball every frame
end)
task.spawn(CharacterFade.start, player)
task.spawn(MovementInput.start, player)
task.spawn(ReceiverOutline.start, player)
