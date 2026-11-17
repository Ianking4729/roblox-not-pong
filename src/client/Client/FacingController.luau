-- FacingController (client): keeps the LOCAL player's avatar facing the table while they move around.
--
-- Uses Humanoid.AutoRotate = false (so movement input no longer turns the avatar) plus an AlignOrientation constraint
-- on the root part: a torque-driven rotation that the physics engine eases toward the target yaw. It does not
-- teleport or reset the character, so there is no snapping, and the paddle (welded to the hand), the stance
-- animation and the camera are unaffected. The target is a pure yaw toward an aim point on the opponent's side
-- (Config.Facing); with AimFollowX = 0 that is straight down the table.
--
-- A player's character is simulated by their own client, so this runs here. It is cosmetic: where the avatar looks
-- never decides anything about a hit; the server owns that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local PlatformZone = require(script.Parent:WaitForChild("PlatformZone"))

local BIND_NAME = "NotPongFacing"

local FacingController = {}
FacingController.__index = FacingController

function FacingController.new(player: Player)
	return setmetatable({
		player = player,
		align = nil :: AlignOrientation?,
		attachment = nil :: Attachment?,
		character = nil :: Model?,
		humanoid = nil :: Humanoid?,
	}, FacingController)
end

-- Target yaw direction (a unit vector on the XZ plane) for a character whose root is at `rootPosition`. Pure.
function FacingController.facingDirection(rootPosition: Vector3): Vector3
	local F, L, O = Config.Facing, Config.Layout, Config.Arena.Origin
	-- Aim point slides smoothly along the table's length with the player's position: behind an end it is the far end
	-- line, alongside the table it is the table centre, behind the other end it is the near end line. No jumps, so
	-- walking round the table never snaps the avatar. AimFollowX only applies behind an end (weight 0 alongside).
	local halfL = Config.Table.Length / 2
	local s = math.clamp((rootPosition.Z - O.Z) / halfL, -1, 1)
	local aimX = O.X + (rootPosition.X - O.X) * F.AimFollowX * math.abs(s)
	local aimZ = O.Z - halfL * s
	local direction = Vector3.new(aimX - rootPosition.X, 0, aimZ - rootPosition.Z)
	if direction.Magnitude < 1e-3 then
		return L.PlayerFacing
	end
	return direction.Unit
end

function FacingController:_release()
	if self.align then
		self.align:Destroy()
		self.align = nil
	end
	if self.attachment then
		self.attachment:Destroy()
		self.attachment = nil
	end
	if self.humanoid and self.humanoid.Parent then
		self.humanoid.AutoRotate = true
	end
	self.character, self.humanoid = nil, nil
end

function FacingController:_attach(character: Model)
	self:_release()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root then
		return
	end
	local F = Config.Facing
	humanoid.AutoRotate = false

	local attachment = Instance.new("Attachment")
	attachment.Name = "NotPongFacingAttachment"
	attachment.Parent = root

	local align = Instance.new("AlignOrientation")
	align.Name = "NotPongFacing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.AlignType = Enum.AlignType.AllAxes
	align.RigidityEnabled = false
	align.MaxTorque = F.MaxTorque
	align.Responsiveness = F.Responsiveness
	align.CFrame = CFrame.lookAt(Vector3.zero, FacingController.facingDirection(root.Position))
	align.Parent = root

	self.character, self.humanoid, self.align, self.attachment = character, humanoid, align, attachment
end

function FacingController:_update()
	local align, character = self.align, self.character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if align and root then
		align.CFrame = CFrame.lookAt(Vector3.zero, FacingController.facingDirection(root.Position))
	end
end

function FacingController:start()
	if not Config.Facing.Enabled then
		return
	end
	local function onCharacter(character: Model)
		-- Wait until the server has scaled and placed the character, so we do not fight the spawn placement.
		if not character:GetAttribute("NotPongPlaced") then
			character:GetAttributeChangedSignal("NotPongPlaced"):Wait()
		end
		self.placed = character
		if character.Parent and PlatformZone.isOn() then
			self:_attach(character)
		end
	end
	-- Off the platform: standard Roblox facing (AutoRotate, the avatar turns toward its movement). Back on: face the table
	-- again; the AlignOrientation eases the turn (Responsiveness), so there is no snap.
	PlatformZone.onChanged(function(on)
		local character = self.player.Character
		if on then
			if character and character.Parent and self.placed == character and self.character ~= character then
				self:_attach(character)
			end
		else
			self:_release()
		end
	end)
	self.player.CharacterAdded:Connect(function(character)
		task.spawn(onCharacter, character)
	end)
	self.player.CharacterRemoving:Connect(function()
		self:_release()
	end)
	if self.player.Character then
		task.spawn(onCharacter, self.player.Character)
	end
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Character.Value + 1, function()
		self:_update()
	end)
end

function FacingController:stop()
	RunService:UnbindFromRenderStep(BIND_NAME)
	self:_release()
end

return FacingController
