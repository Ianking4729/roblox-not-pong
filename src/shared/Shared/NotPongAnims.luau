-- NotPongAnims: builds the /animate clips (Shared/NotPongAnimData: dive + get-up, shuffle footwork) into
-- KeyframeSequences at runtime and registers them with KeyframeSequenceProvider, exactly like the generated ready
-- stance. Nothing is uploaded or published (KeyframeSequenceProvider works in Studio; see docs/current-state.md).
--
-- Per-avatar fit: the clips were authored on the block R15 rig, whose HumanoidRootPart centre is 3 units above the
-- floor (HipHeight 2). Keyframe translations are multiplied by the character's scale when played. Since 2026-11-15
-- pass 2 the game leaves every avatar on its OWN HipHeight, which already equals its leg length, so the clips need NO
-- vertical shift (measured: the test avatar's feet 0.007 studs from the floor; the bot, whose legs are 9% longer than
-- the block rig's, sank 0.69 studs with the old shift and sits on the floor without it). `rootHeight` = nil -> no shift.
-- (The old shift, for a root raised ABOVE the legs' natural height: every LowerTorso translation moved down by
-- (rootHeight / scale - 3) units.) Joint rotations are used as authored. Visual only.

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local Data = require(script.Parent:WaitForChild("NotPongAnimData"))

local NotPongAnims = {}

local STYLES = { "Linear", "Constant", "CubicV2", "Elastic", "Bounce", "Cubic" }
local DIRS = { "In", "Out", "InOut" }
local BLOCK_ROOT_HEIGHT = 3

NotPongAnims.data = Data

-- Vertical LowerTorso offset (keyframe units) for `character` with its root `rootHeight` studs above the floor.
function NotPongAnims.rootOffset(character: Model, rootHeight: number?): number
	if rootHeight == nil then
		return 0
	end
	local scale = character:GetScale()
	if scale <= 0 then
		scale = 1
	end
	return math.clamp(BLOCK_ROOT_HEIGHT - rootHeight / scale, -3, 3)
end

local function buildSequence(name: string, offset: number): KeyframeSequence
	local clip = Data[name]
	assert(clip, "unknown clip " .. name)
	local seq = Instance.new("KeyframeSequence")
	seq.Name = name
	seq.Loop = clip.loop
	seq.Priority = (Enum.AnimationPriority :: any)[clip.priority]
	local joints, parents = clip.joints, clip.parents
	for _, kf in clip.keyframes do
		local keyframe = Instance.new("Keyframe")
		keyframe.Time = kf[1]
		local poses: { [string]: Pose } = {}
		local root = Instance.new("Pose")
		root.Name = "HumanoidRootPart"
		root.Weight = 0
		poses.HumanoidRootPart = root
		local function poseFor(joint: string): Pose
			local existing = poses[joint]
			if existing then
				return existing
			end
			local p = Instance.new("Pose")
			p.Name = joint
			p.Weight = 0 -- placeholder (a parent of a keyed joint); weight 0 leaves it to other tracks
			p.Parent = poseFor(parents[joint])
			poses[joint] = p
			return p
		end
		for index, v in kf[2] do
			local joint = joints[index]
			local p = poseFor(joint)
			local x, y, z = v[1], v[2], v[3]
			if joint == "LowerTorso" then
				y += offset
			end
			p.CFrame = CFrame.new(x, y, z, v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12])
			p.Weight = 1
			p.EasingStyle = (Enum.PoseEasingStyle :: any)[STYLES[v[13]]]
			p.EasingDirection = (Enum.PoseEasingDirection :: any)[DIRS[v[14]]]
		end
		root.Parent = keyframe
		for _, m in clip.markers do
			if math.abs(m[2] - kf[1]) < 1e-3 then
				local marker = Instance.new("KeyframeMarker")
				marker.Name = m[1]
				marker.Parent = keyframe
			end
		end
		keyframe.Parent = seq
	end
	return seq
end

local cache: { [string]: string } = {}

-- Animation id for clip `name` fitted with root offset `offset` (cached per clip and offset to 0.02 units).
function NotPongAnims.id(name: string, offset: number): string
	local q = math.floor(offset * 50 + 0.5) / 50
	local key = ("%s@%.2f"):format(name, q)
	if not cache[key] then
		cache[key] = KeyframeSequenceProvider:RegisterKeyframeSequence(buildSequence(name, q))
	end
	return cache[key]
end

-- Seconds of the clip and the time of a marker (nil if absent).
function NotPongAnims.length(name: string): number
	return Data[name].length
end
function NotPongAnims.markerTime(name: string, marker: string): number?
	for _, m in Data[name].markers do
		if m[1] == marker then
			return m[2]
		end
	end
	return nil
end

-- Load clip `name` on `character`'s Animator (fitted to it). Returns the track or nil.
function NotPongAnims.load(character: Model, name: string, rootHeight: number?): AnimationTrack?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = NotPongAnims.id(name, NotPongAnims.rootOffset(character, rootHeight))
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if not ok or not track then
		warn("[NotPongAnims] could not load", name, track)
		return nil
	end
	local clip = Data[name]
	track.Priority = (Enum.AnimationPriority :: any)[clip.priority]
	track.Looped = clip.loop
	return track
end

return NotPongAnims
