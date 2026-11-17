-- PaddleFactory: clones the uploaded paddle (NotPongArena/PaddleTemplate) and attaches it to a character's hand; falls
-- back to a primitive placeholder when no template exists.
-- Visual only. Gameplay (hit detection) reads the ShotControl reach, never these parts (its blade term follows
-- Config.Paddle.BladeScale, checked against the template below).
-- Template zones (v4, 2026-11-16, assets/paddle/NotPongPaddle_v4.blend built by tools/build_paddle_v4.py): FrontRubber,
-- BackRubber (flat lower edge), WoodBlade (the wood either side of the band), EdgeBand (black band round the sidewall),
-- Handle (grip), EndCap: separate MeshParts with plain Color + Material. For a custom texture later, add a
-- SurfaceAppearance (AlphaMode Overlay keeps the part's Color under transparent texels) to that zone only; UVs are kept.
--
-- Paddle grip frame: the template's Handle carries an Attachment "Grip" at the fist, +Y toward the blade tip, blade faces
-- +/-Z (red face -Z = toward the table in the ready stance). Move/rotate that attachment in Studio to adjust the grip.
-- Placeholder frame: handle centred on the origin, +Y toward the blade tip, blade faces +/-Z.

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

-- The uploaded paddle template (NotPongArena/PaddleTemplate in Edit mode; ArenaBuilder.load moves it to ServerStorage).
local function findTemplate(): Model?
	local name = Config.Names.PaddleTemplate
	local t = game:GetService("ServerStorage"):FindFirstChild(name)
	if not t then
		local arena = workspace:FindFirstChild(Config.Names.Arena)
		t = arena and arena:FindFirstChild(name)
	end
	return if t and t:IsA("Model") and t:FindFirstChild("Handle") then t else nil
end

-- A clone of the template, made inert (unanchored, massless, no collision/query/touch) and welded to its Handle. Every
-- appearance property, the template's scale and its parts' relative transforms are kept exactly as authored.
local function fromTemplate(template: Model): Model
	local model = template:Clone()
	model.Name = "Paddle" -- CharacterFade and others recognise the paddle by this name
	local handle = model:FindFirstChild("Handle") :: BasePart
	model.PrimaryPart = handle
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			if d ~= handle then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = handle
				weld.Part1 = d
				weld.Parent = d
			end
		end
	end
	CollisionSetup.assign(model, Config.CollisionGroups.Paddle)
	return model
end

-- Handle-space CFrame of the grip point on a paddle made by create(): the template's Grip attachment, or the
-- placeholder's HandlePoint rule.
function PaddleFactory.gripC1(paddle: Model): CFrame
	local handle = paddle.PrimaryPart
	local grip = handle and handle:FindFirstChild(Config.Names.PaddleGripAttachment)
	if grip and grip:IsA("Attachment") then
		return grip.CFrame
	end
	return CFrame.new(0, Config.Paddle.Grip.HandlePoint * Config.Paddle.HandleLength * Config.Paddle.VisualScale, 0)
end

-- The visible blade and the contact radius must agree (Config.Paddle.BladeScale; see the end of Config): warn once if
-- the template's blade (WoodBlade width) differs from BaseBladeRadius x 2 x BladeScale by more than 5%.
local checkedScale = false
local function checkBladeScale(template: Model)
	if checkedScale then
		return
	end
	checkedScale = true
	local blade = template:FindFirstChild("WoodBlade")
	if blade and blade:IsA("BasePart") then
		local want = Config.Paddle.BaseBladeRadius * 2 * Config.Paddle.BladeScale
		local have = blade.Size.X
		if math.abs(have - want) > want * 0.05 then
			warn(("[PaddleFactory] the template's blade is %.2f studs wide but Config.Paddle.BladeScale implies %.2f: the contact radius no longer matches the visible blade"):format(have, want))
		end
	end
end

function PaddleFactory.create(): Model
	local template = findTemplate()
	if template then
		checkBladeScale(template)
		return fromTemplate(template)
	end
	warn("[PaddleFactory] no " .. Config.Names.PaddleTemplate .. " found; using the placeholder paddle")
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
	-- Where the fist closes on the handle: the template's Grip attachment (or the placeholder's HandlePoint rule).
	grip.C1 = PaddleFactory.gripC1(paddle)
	grip.Parent = handle
	return paddle
end

return PaddleFactory
