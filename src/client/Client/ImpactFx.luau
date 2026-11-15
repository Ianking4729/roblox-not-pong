-- ImpactFx (client, cosmetic): a small burst where the ball was struck, shown only after the SERVER confirms a hit.
-- Clean contact: bright particle burst + an expanding ring. Weak contact: a few dull particles, small ring.
-- One pooled emitter part and one ring part are reused for every hit (nothing is created per hit). Visual only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local FrameDriver = require(script.Parent:WaitForChild("FrameDriver"))

local ImpactFx = {}

local RING_TIME = 0.22

function ImpactFx.start()
	local I = Config.Feedback.Impact

	local burst = Instance.new("Part")
	burst.Name = "NotPongImpactBurst"
	burst.Size = Vector3.new(0.2, 0.2, 0.2)
	burst.Transparency = 1
	burst.Anchored, burst.CanCollide, burst.CanQuery, burst.CanTouch, burst.CastShadow = true, false, false, false, false
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.2, 0.42)
	emitter.Speed = NumberRange.new(10, 26)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 5
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.38), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	emitter.Parent = burst
	burst.Parent = workspace.CurrentCamera

	local ring = Instance.new("Part")
	ring.Name = "NotPongImpactRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Size = Vector3.new(0.05, 1, 1)
	ring.Transparency = 1
	ring.Anchored, ring.CanCollide, ring.CanQuery, ring.CanTouch, ring.CastShadow = true, false, false, false, false
	ring.Parent = workspace.CurrentCamera

	local ringAge, ringMax = math.huge, I.RingSize

	FrameDriver.bind("NotPongImpactFx", Enum.RenderPriority.Last.Value - 20, function(dt)
		if ringAge >= RING_TIME then
			return
		end
		ringAge += dt
		local f = math.clamp(ringAge / RING_TIME, 0, 1)
		local d = ringMax * (0.25 + 0.75 * (1 - (1 - f) ^ 2)) -- ease-out growth
		ring.Size = Vector3.new(0.05, d, d)
		ring.Transparency = if f >= 1 then 1 else 0.25 + 0.75 * f
	end)

	local self = {}

	-- quality: "clean" | "weak"
	function self.play(position: Vector3, quality: string)
		local clean = quality == "clean"
		local color = if clean then I.CleanColor else I.WeakColor
		emitter.Color = ColorSequence.new(color)
		burst.CFrame = CFrame.new(position)
		emitter:Emit(if clean then I.CleanParticles else I.WeakParticles)
		ring.Color = color
		ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
		ringMax = if clean then I.RingSize else I.RingSize * 0.45
		ringAge = 0
	end

	return self
end

return ImpactFx
