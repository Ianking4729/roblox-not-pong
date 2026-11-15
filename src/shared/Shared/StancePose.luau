-- StancePose: builds and plays the placeholder table-tennis ready stance as a looping KeyframeSequence.
-- No uploaded asset: the pose is generated from Config.Stance and registered at runtime. Visual only.
--
-- Why an animation and not joint edits: current Roblox characters use AnimationConstraint joints whose C0 is
-- read-only, and the default idle/walk animation rewrites joint transforms every frame anyway. A higher-priority
-- track is the supported way to hold a pose. Poses are rotations relative to the rig's rest pose, about each
-- joint (R15 axes: +X swings a hanging limb forward; -X pitches an upright segment forward; +Z on the right
-- arm moves it outward).
--
-- Two tracks: the upper body (always on) and the legs (faded out while moving, so the avatar steps instead of gliding).
-- See StancePose.start.

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local RunService = game:GetService("RunService")

local Config = require(script.Parent:WaitForChild("Config"))

local StancePose = {}

local function rot(deg: Vector3): CFrame
	return CFrame.Angles(math.rad(deg.X), math.rad(deg.Y), math.rad(deg.Z))
end

local function pose(name: string, deg: Vector3?, children: { Pose }?): Pose
	local p = Instance.new("Pose")
	p.Name = name
	p.CFrame = if deg then rot(deg) else CFrame.identity
	p.Weight = if deg then 1 else 0 -- weight 0: this joint is left to lower-priority animations
	for _, c in children or {} do
		c.Parent = p
	end
	return p
end

-- Builds one KeyframeSequence (looping, two identical keyframes) from Config.Stance.
--   part = "Upper": torso lean, head and both arms. Stays on while walking (the paddle arm keeps its ready pose).
--   part = "Legs" : bent knees, AND the LowerTorso held still at `hips` (the avatar's AVERAGE idle hip transform,
--                   measured by StancePose.start). Holding it stops the idle animation's hip bob, which otherwise moved
--                   the whole body (and so the feet) up and down by ~0.4 studs. Holding it at the rig's rest pose
--                   instead dropped the hips ~2 studs below the idle/walk height, so starting to walk lifted the body.
--                   This track is faded out while the character moves so the walk cycle drives the legs.
function StancePose.build(part: string?, hips: CFrame?): KeyframeSequence
	local S = Config.Stance
	local a = S.KneeBendDegrees
	local legs = part == "Legs"
	local function leg(side: string): Pose
		return pose(side .. "UpperLeg", Vector3.new(a, 0, 0), {
			pose(side .. "LowerLeg", Vector3.new(-2 * a, 0, 0), {
				pose(side .. "Foot", Vector3.new(a, 0, 0)),
			}),
		})
	end
	local function arm(side: string, shoulder: Vector3, elbow: Vector3): Pose
		return pose(side .. "UpperArm", shoulder, {
			pose(side .. "LowerArm", elbow, { pose(side .. "Hand") }),
		})
	end

	local tree
	if legs then
		local lowerTorso = pose("LowerTorso", Vector3.zero, { leg("Right"), leg("Left") })
		lowerTorso.CFrame = hips or CFrame.identity
		tree = pose("HumanoidRootPart", nil, { lowerTorso })
	else
		tree = pose("HumanoidRootPart", nil, {
			pose("LowerTorso", nil, {
				pose("UpperTorso", Vector3.new(-S.LeanDegrees, 0, 0), {
					pose("Head", Vector3.new(S.HeadCounterDegrees, 0, 0)),
					arm("Right", S.RightShoulder, S.RightElbow),
					arm("Left", S.LeftShoulder, S.LeftElbow),
				}),
			}),
		})
	end

	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "NotPongReadyStance" .. (if legs then "Legs" else "")
	sequence.Loop = true
	sequence.Priority = Enum.AnimationPriority.Action
	for _, t in { 0, 1 } do
		local k = Instance.new("Keyframe")
		k.Time = t
		local copy = if t == 0 then tree else tree:Clone()
		copy.Parent = k
		k.Parent = sequence
	end
	return sequence
end

local cachedIds: { [string]: string } = {}

local function animationId(part: string, hips: CFrame?): string
	local key = part
	if hips then
		local p = hips.Position
		key ..= ("%.2f,%.2f,%.2f"):format(p.X, p.Y, p.Z) -- one registration per measured hip pose (per avatar)
	end
	if not cachedIds[key] then
		cachedIds[key] = KeyframeSequenceProvider:RegisterKeyframeSequence(StancePose.build(part, hips))
	end
	return cachedIds[key]
end

-- The LowerTorso's root joint (Motor6D or AnimationConstraint, both named "Root" on R15 rigs).
local function rootJoint(character: Model): Instance?
	local lt = character:FindFirstChild("LowerTorso")
	return lt and lt:FindFirstChild("Root")
end

-- Average animated transform of the root joint over `seconds` (position averaged; rotation from the middle sample),
-- returned in keyframe units (divided by the character scale).
local function averageHips(character: Model, seconds: number): CFrame?
	local joint = rootJoint(character) :: any
	if not joint then
		return nil
	end
	local sum, n, mid = Vector3.zero, 0, nil
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		local ok, t = pcall(function()
			return joint.Transform
		end)
		if ok and typeof(t) == "CFrame" then
			sum += t.Position
			n += 1
			if os.clock() - t0 >= seconds / 2 and not mid then
				mid = t.Rotation
			end
		end
		RunService.Heartbeat:Wait()
	end
	if n == 0 then
		return nil
	end
	-- Keyframe translations are authored at scale 1 and multiplied by the character's scale when played (measured:
	-- an unscaled value came out 3.37x too large on a 3.37-scale avatar), so store the unscaled offset.
	local scale = character:GetScale()
	return CFrame.new(sum / n / (if scale > 0 then scale else 1)) * (mid or CFrame.identity)
end

local function load(character: Model, id: string, name: string, priority: Enum.AnimationPriority): AnimationTrack?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		warn("[StancePose] no Animator on", character.Name)
		return nil
	end
	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = id
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if not ok or not track then
		warn("[StancePose] could not load", name, track)
		return nil
	end
	track.Priority = priority
	track.Looped = true
	return track
end

-- Start the UPPER-body stance track on `character`. Returns the track or nil. (Kept for callers that only want the
-- arms; StancePose.start below is the full controller.)
function StancePose.play(character: Model): AnimationTrack?
	local track = load(character, animationId("Upper"), "NotPongReadyStance", Enum.AnimationPriority.Action)
	if track then
		track:Play(0.2)
	end
	return track
end

-- ===== Paddle swing (Phase 4): a short, non-looping layer over the ready stance =====
-- Same machinery as the stance (a generated KeyframeSequence), one priority higher (Action2), so the paddle arm swings
-- through back -> strike -> follow-through and returns to the stance pose; the legs, hips and facing are untouched and
-- the paddle (a Motor6D on the hand) simply rides the arm. Visual only: it never decides whether the ball is hit.
-- `strength` scales the amplitude (1 = clean, less for weak/miss swings).
function StancePose.buildSwing(strength: number): KeyframeSequence
	local S, W = Config.Stance, Config.Swing
	local function frame(time: number, shoulder: Vector3, elbow: Vector3, torso: Vector3): Keyframe
		local tree = pose("HumanoidRootPart", nil, {
			pose("LowerTorso", nil, {
				pose("UpperTorso", Vector3.new(-S.LeanDegrees, 0, 0) + torso * strength, {
					pose("RightUpperArm", S.RightShoulder + shoulder * strength, {
						pose("RightLowerArm", S.RightElbow + elbow * strength, { pose("RightHand") }),
					}),
				}),
			}),
		})
		local k = Instance.new("Keyframe")
		k.Time = time
		tree.Parent = k
		return k
	end
	local T = W.Duration
	local keys = {
		frame(0, Vector3.zero, Vector3.zero, Vector3.zero),
		frame(T * 0.28, W.BackShoulder, W.BackElbow, W.BackTorso),
		frame(T * 0.5, W.StrikeShoulder, W.StrikeElbow, W.StrikeTorso),
		frame(T * 0.74, W.FollowShoulder, W.FollowElbow, W.FollowTorso),
		frame(T, Vector3.zero, Vector3.zero, Vector3.zero),
	}
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "NotPongSwing"
	sequence.Loop = false
	sequence.Priority = Enum.AnimationPriority.Action2
	for _, k in keys do
		k.Parent = sequence
	end
	return sequence
end

local swingTracks: { [Model]: AnimationTrack } = {}

-- Play one swing on `character` (the client that simulates it). Returns the track, or nil if the rig cannot play it.
function StancePose.playSwing(character: Model, strength: number): AnimationTrack?
	local key = ("Swing%.2f"):format(strength)
	if not cachedIds[key] then
		cachedIds[key] = KeyframeSequenceProvider:RegisterKeyframeSequence(StancePose.buildSwing(strength))
	end
	local previous = swingTracks[character]
	if previous then
		previous:Stop(0.03)
	end
	local track = load(character, cachedIds[key], "NotPongSwing", Enum.AnimationPriority.Action2)
	if not track then
		return nil
	end
	track.Looped = false
	track:Play(0.03)
	swingTracks[character] = track
	track.Stopped:Once(function()
		if swingTracks[character] == track then
			swingTracks[character] = nil
		end
		track:Destroy()
	end)
	return track
end

-- Lowest point of the feet below the root, in studs (root.Y - lowest foot corner). Uses the parts' real corners.
local function footDrop(character: Model): number?
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local lowest = math.huge
	for _, name in { "LeftFoot", "RightFoot" } do
		local foot = character:FindFirstChild(name) :: BasePart?
		if foot then
			local cf, h = foot.CFrame, foot.Size / 2
			for _, x in { -1, 1 } do
				for _, y in { -1, 1 } do
					for _, z in { -1, 1 } do
						lowest = math.min(lowest, (cf * Vector3.new(h.X * x, h.Y * y, h.Z * z)).Y)
					end
				end
			end
		end
	end
	if lowest == math.huge then
		return nil
	end
	return root.Position.Y - lowest
end

-- The HipHeight at which the feet, in the CURRENT pose, rest exactly on the floor. Independent of where the body is
-- right now (HipHeight = root bottom above the floor; the root must sit `drop` above the floor). Averages a few frames.
local function measureHip(character: Model, samples: number): number?
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local total, n = 0, 0
	for _ = 1, samples do
		local drop = footDrop(character)
		if drop then
			total += drop
			n += 1
		end
		task.wait(0.05)
	end
	if n == 0 then
		return nil
	end
	return math.max(0, total / n - root.Size.Y / 2 - Config.Stance.FootSink)
end

export type Controller = {
	upper: AnimationTrack,
	legs: AnimationTrack,
	walk: AnimationTrack?,
	hipStance: number,
	hipStraight: number,
	legsWeight: number,
	stop: (Controller) -> (),
}

-- Full ready-stance controller. Must run on whoever SIMULATES the character (the server for the bot, the owning client
-- for a player), because both the animation and HipHeight only take effect there.
--   * plays the upper-body and legs tracks,
--   * measures two HipHeights that put the feet on the floor: one with the bent-knee legs, one with the normal
--     (idle/walk) legs, so grounding works for any avatar's proportions,
--   * every frame, fades the legs track out while the character moves (the walk cycle then shows) and blends
--     HipHeight between the two measurements by the same weight.
-- `walkAnimationId` (optional): a walk animation this controller plays itself while moving (the bot has no running
-- Animate script; a player's Animate script already walks).
function StancePose.start(character: Model, walkAnimationId: string?): Controller?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return nil
	end
	local upper = load(character, animationId("Upper"), "NotPongReadyStance", Enum.AnimationPriority.Action)
	if not upper then
		return nil
	end
	local walk = if walkAnimationId
		then load(character, walkAnimationId, "NotPongWalk", Enum.AnimationPriority.Movement)
		else nil
	upper:Play(0.2)

	-- Straight legs first (legs track off): the walking HipHeight, and the avatar's average idle hip pose.
	task.wait(0.4)
	local hipStraight = measureHip(character, 6) or humanoid.HipHeight -- refined while walking (see below)
	local hips = averageHips(character, 1.0)
	local legs = load(character, animationId("Legs", hips), "NotPongReadyStanceLegs", Enum.AnimationPriority.Action)
	if not legs then
		upper:Stop()
		return nil
	end
	legs:Play(0.2)
	task.wait(0.4)
	local hipStance = measureHip(character, 4) or hipStraight
	humanoid.HipHeight = hipStance

	local S = Config.Stance
	-- Walking grounding: a walk/run cycle carries the hips differently from the idle pose measured above (tested: one
	-- avatar's run held the feet ~1 stud above the floor, the bot's walk sank them ~1.2 studs). While moving we keep a
	-- PEAK of the root-to-lowest-foot distance: it jumps up at once when a stride reaches lower (so feet never sink)
	-- and relaxes at WalkGroundingDecay toward the deepest point of the last WalkGroundingWindow seconds (about one
	-- stride, so the body does not bob within a stride). It persists across short dashes.
	local peakDrop = hipStraight + root.Size.Y / 2 + S.FootSink
	local recent: { { t: number, d: number } } = {}
	local controller = {
		upper = upper,
		legs = legs,
		walk = walk,
		hipStance = hipStance,
		hipStraight = hipStraight,
		legsWeight = 1,
	} :: any
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if character.Parent == nil or humanoid.Health <= 0 then
			conn:Disconnect()
			return
		end
		local v = root.AssemblyLinearVelocity
		local speed = Vector2.new(v.X, v.Z).Magnitude
		local target = if speed > S.MoveSpeedThreshold then 0 else 1
		local k = 1 - math.exp(-S.LegBlendRate * dt)
		controller.legsWeight += (target - controller.legsWeight) * k
		local w = controller.legsWeight
		-- Keep the tracks alive (a respawn race or another script can stop them).
		if not upper.IsPlaying then
			upper:Play(0.2)
		end
		if not legs.IsPlaying then
			legs:Play(0.2)
		end
		legs:AdjustWeight(math.max(w, 0.001), 0)
		if walk then
			if 1 - w > 0.05 then
				if not walk.IsPlaying then
					walk:Play(0.2)
				end
				walk:AdjustWeight(1 - w, 0)
				walk:AdjustSpeed(math.clamp(speed / 16, 0.3, 2))
			elseif walk.IsPlaying then
				walk:Stop(0.2)
			end
		end
		if w < 0.5 then
			local d = footDrop(character)
			if d then
				local now = os.clock()
				table.insert(recent, { t = now, d = d })
				while recent[1] and now - recent[1].t > S.WalkGroundingWindow do
					table.remove(recent, 1)
				end
				local windowMax = 0
				for _, sample in recent do
					windowMax = math.max(windowMax, sample.d)
				end
				if windowMax > peakDrop then
					peakDrop = windowMax
				else
					peakDrop += (windowMax - peakDrop) * (1 - math.exp(-S.WalkGroundingDecay * dt))
				end
				hipStraight = math.max(0, peakDrop - root.Size.Y / 2 - S.FootSink)
				controller.hipStraight = hipStraight
			end
		end
		humanoid.HipHeight = hipStraight + (hipStance - hipStraight) * w
	end)
	function controller.stop(self: Controller)
		conn:Disconnect()
		self.upper:Stop(0.2)
		self.legs:Stop(0.2)
		if self.walk then
			self.walk:Stop(0.2)
		end
	end
	return controller :: Controller
end

-- Older single-shot correction (kept for callers/tests): put the lowest foot on the floor in the current pose.
function StancePose.groundFeet(character: Model): number
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return 0
	end
	task.wait(0.5)
	local hip = measureHip(character, 4)
	if not hip then
		return 0
	end
	local delta = hip - humanoid.HipHeight
	humanoid.HipHeight = hip
	character:PivotTo(character:GetPivot() + Vector3.new(0, delta, 0))
	return delta
end

return StancePose
