-- CameraController: third-person camera above and behind the local player, aimed at the table.
-- Visual only; it reads Config and the local character, and never touches gameplay state.
--
-- Placement (world axes, because the table is axis-aligned and the player always faces -Z):
--   Let t = how many studs further behind the end line the player is than the reference stand-back distance.
--   position = (table X + (player X offset) * CameraXFollow + ShoulderOffset, floor + Height + HeightPerBackStud * t,
--               player Z + DistanceBehind + DistancePerBackStud * t)
--   aim point = (table X + (player X offset) * LateralFollow, table surface + LookAtHeightOffset,
--                table centre Z - LookAheadStuds + AimPerBackStud * t)
-- So walking backward pulls the camera back and slides the aim point toward the player (the avatar stays in the lower
-- foreground, the table stays centred), and sidestepping makes the camera follow partially. All smoothed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local BIND_NAME = "NotPongCamera"

local CameraController = {}
CameraController.__index = CameraController

function CameraController.new(player: Player)
	return setmetatable({
		player = player,
		position = nil :: Vector3?,
		lookAt = nil :: Vector3?,
		side = 1, -- +1 home half, -1 bot half (see compute)
	}, CameraController)
end

-- Where the camera wants to be and look, given the player's root position. Pure; used by tests too.
-- `side` is +1 when the player is on the home (+Z) half and -1 on the bot's half: the whole framing is mirrored along Z
-- so the camera is always behind the player looking at the table. Alongside the table the player is on either half;
-- the controller flips `side` with hysteresis and the smoothing carries the camera across.
function CameraController.compute(rootPosition: Vector3, side: number?): (Vector3, Vector3)
	local C, L = Config.Camera, Config.Layout
	local sg = side or 1
	local centre = L.TableSurfaceCenter
	-- Distance from the table centre along the player's own axis, but never less than "just behind the end line":
	-- alongside the table the framing stays at the closest standing position, so the whole table remains in view.
	local rz = math.max(sg * (rootPosition.Z - centre.Z), Config.Table.Length / 2 + Config.PlayArea.FrontGap)
	local t = (rz - Config.Table.Length / 2) - Config.Avatar.StandBack -- studs further back than the reference spot
	local dx = rootPosition.X - centre.X
	local desiredPosition = Vector3.new(
		centre.X + dx * C.CameraXFollow + sg * (C.ShoulderOffset or 0),
		L.FloorY + C.Height + C.HeightPerBackStud * t,
		centre.Z + sg * (rz + C.DistanceBehind + C.DistancePerBackStud * t)
	)
	local desiredLookAt = Vector3.new(
		centre.X + dx * C.LateralFollow,
		L.SurfaceY + C.LookAtHeightOffset,
		centre.Z + sg * (-C.LookAheadStuds + C.AimPerBackStud * t)
	)
	return desiredPosition, desiredLookAt
end

function CameraController:_update(dt: number)
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local C = Config.Camera
	-- Lead the target by the player's horizontal velocity so the smoothing does not lag a walking player.
	local velocity = root.AssemblyLinearVelocity
	local lead = Vector3.new(velocity.X, 0, velocity.Z) * C.VelocityLead
	local dz = root.Position.Z - Config.Layout.TableSurfaceCenter.Z
	if (self.side == 1 and dz < -6) or (self.side == -1 and dz > 6) then
		self.side = -self.side -- hysteresis: only flip once clearly past the net plane
	end
	local desiredPosition, desiredLookAt = CameraController.compute(root.Position + lead, self.side)
	if not self.position or not self.lookAt then
		self.position, self.lookAt = desiredPosition, desiredLookAt
	else
		local alpha = 1 - math.exp(-C.Smoothing * dt)
		self.position = self.position:Lerp(desiredPosition, alpha)
		self.lookAt = self.lookAt:Lerp(desiredLookAt, alpha)
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = C.FieldOfView
	camera.CFrame = CFrame.lookAt(self.position, self.lookAt)
end

function CameraController:start()
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_update(dt)
	end)
end

function CameraController:stop()
	RunService:UnbindFromRenderStep(BIND_NAME)
end

return CameraController
