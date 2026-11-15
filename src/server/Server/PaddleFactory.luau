-- PaddleFactory: builds a placeholder paddle and welds it to a character's hand.
-- Visual only. Gameplay (future hit detection) reads Config.Paddle's real dimensions, never these parts.
--
-- Paddle local frame: handle centred on the origin, +Y toward the blade tip, blade faces +/-Z.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CollisionSetup = require(script.Parent:WaitForChild("CollisionSetup"))

local PaddleFactory = {}

local function inertPart(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

function PaddleFactory.create(): Model
	local P = Config.Paddle
	local s = P.VisualScale
	local model = Instance.new("Model")
	model.Name = "Paddle"

	local handle = inertPart({
		Name = "Handle",
		Size = Vector3.new(P.HandleWidth, P.HandleLength, P.HandleThickness) * s,
		Color = Config.Colors.PaddleHandle,
		Parent = model,
	})

	local bladeCenterY = (P.HandleLength / 2 + P.BladeHeight / 2) * s
	local blade = inertPart({
		Name = "Blade",
		Shape = Enum.PartType.Cylinder, -- cylinder axis is local X; rotate so it points along Z
		Size = Vector3.new(P.BladeThickness, P.BladeHeight, P.BladeWidth) * s,
		Color = Config.Colors.PaddleBlade,
		Parent = model,
	})
	model.PrimaryPart = handle
	handle.CFrame = CFrame.new()
	blade.CFrame = CFrame.new(0, bladeCenterY, 0) * CFrame.Angles(0, math.rad(90), 0)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = blade
	weld.Parent = handle

	CollisionSetup.assign(model, Config.CollisionGroups.Paddle)
	return model
end

-- The grip transform (hand space -> paddle Handle space), from Config.Paddle.Grip. Exposed for tests and for future
-- custom animations that want a different grip.
function PaddleFactory.gripC0(gripAttachment: Attachment?): CFrame
	local G = Config.Paddle.Grip
	local base = if gripAttachment then gripAttachment.CFrame else CFrame.identity
	local r = G.RotationDegrees
	return base * CFrame.new(G.Offset) * CFrame.Angles(math.rad(r.X), math.rad(r.Y), math.rad(r.Z))
end

-- Create a paddle and attach its handle to the character's right hand with a Motor6D named "PaddleGrip".
-- The joint is defined in the HAND's own frame, at the hand's RightGripAttachment (the standard Roblox grip point),
-- so it does not depend on the pose at the moment of attaching and follows the hand through every animation.
-- Visual only: hit detection never reads these parts. Returns the paddle (or nil + warning).
function PaddleFactory.attachToHand(character: Model): Model?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		warn("[PaddleFactory] no right hand on", character.Name)
		return nil
	end
	local old = character:FindFirstChild("Paddle")
	if old then
		old:Destroy()
	end
	local paddle = PaddleFactory.create()
	local handle = paddle.PrimaryPart :: BasePart
	paddle:PivotTo(hand.CFrame)
	paddle.Parent = character

	local grip = Instance.new("Motor6D")
	grip.Name = "PaddleGrip"
	grip.Part0 = hand
	grip.Part1 = handle
	grip.C0 = PaddleFactory.gripC0(hand:FindFirstChild("RightGripAttachment") :: Attachment?)
	-- The fist closes this far up the handle from its centre (negative = toward the butt end).
	grip.C1 = CFrame.new(0, Config.Paddle.Grip.HandlePoint * Config.Paddle.HandleLength * Config.Paddle.VisualScale, 0)
	grip.Parent = handle
	return paddle
end

return PaddleFactory
