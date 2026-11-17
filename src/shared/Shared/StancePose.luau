-- StancePose: builds and plays the placeholder table-tennis ready stance as a looping KeyframeSequence.
-- No uploaded asset: the pose is generated from Config.Stance and registered at runtime. Visual only.
--
-- Why an animation and not joint edits: current Roblox characters use AnimationConstraint joints whose C0 is
-- read-only, and the default idle/walk animation rewrites joint transforms every frame anyway. A higher-priority
-- track is the supported way to hold a pose. Poses are rotations relative to the rig's rest pose, about each
-- joint (R15 axes: +X swings a hanging limb forward; -X pitches an upright segment forward; +Z on the right
-- arm moves it outward).
--
-- The UPPER body comes from Config.Stance (built here, one track per stroke); the LEGS come from the /animate footwork
-- clips (NP_Ready, NP_Shuffle*, NP_Run*: Shared/NotPongAnimData). See StancePose.start.

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local RunService = game:GetService("RunService")

local Config = require(script.Parent:WaitForChild("Config"))
local NotPongAnims = require(script.Parent:WaitForChild("NotPongAnims"))

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
--   part = "Upper": torso lean, head and both arms. Stays on while moving (the paddle arm keeps its ready pose).
--   part = "Legs" : (legacy, unused since the footwork clips) bent knees with the LowerTorso held at `hips`.
-- The upper-body ready pose for a stroke ("Forehand" = the base Config.Stance values, "Backhand" = Config.Stance.Backhand).
-- Returns torso rotation, right shoulder, right elbow, left shoulder, left elbow (degrees).
-- (2026-11-17) + the paddle wrist (RightWrist): the cursor-side HOLDING LEAN (the blade tip leans toward the stroke's side
-- instead of standing straight up). It lives in the stroke's own ready pose, so it switches, locks at charge and
-- unlocks after recovery exactly like the stroke (one owner: this stance track; the swing leaves the wrist unkeyed).
local function strokePose(stroke: string?): (Vector3, Vector3, Vector3, Vector3, Vector3, Vector3?)
	local S = Config.Stance
	local B = S.Backhand
	if stroke == "Backhand" and B then
		return Vector3.new(-S.LeanDegrees, B.TorsoTwist or 0, 0), B.RightShoulder, B.RightElbow, B.LeftShoulder, B.LeftElbow, B.RightWrist
	end
	return Vector3.new(-S.LeanDegrees, 0, 0), S.RightShoulder, S.RightElbow, S.LeftShoulder, S.LeftElbow, S.RightWrist
end

function StancePose.build(part: string?, hips: CFrame?, stroke: string?): KeyframeSequence
	local S = Config.Stance
	local a = S.KneeBendDegrees
	local legs = part == "Legs"
	-- Feet wider than the hips (the reference sheet's wide base): each hip opens LegSpreadDegrees outward (+Z on the
	-- right leg), and the foot turns back by the same amount so the sole stays flat.
	local spread = S.LegSpreadDegrees or 0
	local function leg(side: string): Pose
		local out = if side == "Right" then spread else -spread
		return pose(side .. "UpperLeg", Vector3.new(a, 0, out), {
			pose(side .. "LowerLeg", Vector3.new(-2 * a, 0, 0), {
				pose(side .. "Foot", Vector3.new(a, 0, -out)),
			}),
		})
	end
	local function arm(side: string, shoulder: Vector3, elbow: Vector3, wrist: Vector3?): Pose
		return pose(side .. "UpperArm", shoulder, {
			pose(side .. "LowerArm", elbow, { pose(side .. "Hand", wrist) }),
		})
	end

	local tree
	if legs then
		local lowerTorso = pose("LowerTorso", Vector3.zero, { leg("Right"), leg("Left") })
		lowerTorso.CFrame = hips or CFrame.identity
		tree = pose("HumanoidRootPart", nil, { lowerTorso })
	else
		local torso, rs, re, ls, le, rw = strokePose(stroke)
		tree = pose("HumanoidRootPart", nil, {
			pose("LowerTorso", nil, {
				pose("UpperTorso", torso, {
					-- the head turns back against the chest twist so the eyes stay on the table
					pose("Head", Vector3.new(S.HeadCounterDegrees, -torso.Y, 0)),
					arm("Right", rs, re, rw),
					arm("Left", ls, le),
				}),
			}),
		})
	end

	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = "NotPongReadyStance" .. (if legs then "Legs" else (stroke or ""))
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

local function animationId(part: string, hips: CFrame?, stroke: string?): string
	local key = part .. (stroke or "")
	if hips then
		local p = hips.Position
		key ..= ("%.2f,%.2f,%.2f"):format(p.X, p.Y, p.Z) -- one registration per measured hip pose (per avatar)
	end
	if not cachedIds[key] then
		cachedIds[key] = KeyframeSequenceProvider:RegisterKeyframeSequence(StancePose.build(part, hips, stroke))
	end
	return cachedIds[key]
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
-- `strength` scales the amplitude (1 = clean, less for weak/miss swings). `stroke` = "Forehand" (default) | "Backhand":
-- the swing starts and ends at that stroke's ready pose, so it hands back to the (locked) stance track seamlessly.
-- `kind` = "Smash": the overhead smash (Config.Swing.Smash), always from the forehand ready pose.
function StancePose.buildSwing(strength: number, stroke: string?, kind: string?): KeyframeSequence
	local W = Config.Swing
	if kind == "Smash" and W.Smash then
		W = W.Smash
		stroke = "Forehand"
	elseif stroke == "Backhand" and W.Backhand then
		W = W.Backhand
	end
	local baseTorso, baseShoulder, baseElbow = strokePose(stroke)
	-- The wrist is normally left unkeyed (the stance's holding lean / face orientation carries through the swing). The
	-- smash always uses the forehand arm, so it keys the forehand wrist too: otherwise a smash taken while the stance
	-- shows the backhand (face-flip wrist) would twist the blade on the forehand arm.
	local smashWrist = if kind == "Smash" then Config.Stance.RightWrist else nil
	local function frame(time: number, shoulder: Vector3, elbow: Vector3, torso: Vector3): Keyframe
		local tree = pose("HumanoidRootPart", nil, {
			pose("LowerTorso", nil, {
				pose("UpperTorso", baseTorso + torso * strength, {
					pose("RightUpperArm", baseShoulder + shoulder * strength, {
						pose("RightLowerArm", baseElbow + elbow * strength, { pose("RightHand", smashWrist) }),
					}),
				}),
			}),
		})
		local k = Instance.new("Keyframe")
		k.Time = time
		tree.Parent = k
		return k
	end
	local T = Config.Swing.Duration
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
function StancePose.playSwing(character: Model, strength: number, stroke: string?, kind: string?): AnimationTrack?
	local name = if kind == "Smash" then "Smash" elseif stroke == "Backhand" then "Backhand" else "Forehand"
	local key = ("Swing%s%.2f"):format(name, strength)
	if not cachedIds[key] then
		cachedIds[key] = KeyframeSequenceProvider:RegisterKeyframeSequence(StancePose.buildSwing(strength, stroke, kind))
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

-- ===== Dive + get-up (the /animate clips NP_DiveRight / NP_DiveLeft / NP_DiveBack, Shared/NotPongAnimData) =====
-- One clip per direction: push-off -> airborne reach -> floor landing (0.35 s, the server's lunge) -> the 1.3 s get-up
-- (brace, kneel, rise) -> ready. The backward dive lands on the hips / back, sits up, kneels and rises. Action4, above the stance, swing and walk, every joint keyed, so nothing standing
-- shows through while the body is on the floor. The HumanoidRootPart is moved by the server (never by the clip).
-- side = +1 for a dive to the character's right, -1 to its left. The paddle stays in the right hand on both sides.
-- Returns a handle: :recover() when the server enters the recovery (re-syncs the clip to the get-up), :finish() when
-- the dive is over (lets the clip end, or blends it out if it was cut short), :stop(). Visual only.
export type DiveHandle = { track: AnimationTrack, recover: (DiveHandle) -> (), finish: (DiveHandle) -> (), stop: (DiveHandle) -> () }
local diveHandles: { [Model]: DiveHandle } = {}
local timeScale = 1

-- Client slow motion (ShotController) scales the tracks this module drives every frame (the shuffle).
function StancePose.setTimeScale(scale: number)
	timeScale = math.clamp(scale, 0, 1)
end

function StancePose.dive(character: Model, side: number | string): DiveHandle?
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	-- side: "Back" | "Left" | "Right" (ShotInput.diveKind), or a number (+1 right, -1 left) for old callers
	local name = if side == "Back" then "NP_DiveBack"
		elseif side == "Left" or (typeof(side) == "number" and side < 0) then "NP_DiveLeft"
		else "NP_DiveRight"
	local previous = diveHandles[character]
	if previous then
		previous:stop()
	end
	local track = NotPongAnims.load(character, name, nil) -- (own HipHeight: no fit needed)
	if not track then
		return nil
	end
	local D = Config.DivePose
	local length = NotPongAnims.length(name)
	local recoverAt = NotPongAnims.markerTime(name, "Recover") or 0.35
	track:Play(D.BlendIn)
	local handle = { track = track } :: any
	local conn: RBXScriptConnection? = nil
	function handle.stop(self: DiveHandle, fade: number?)
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if track.IsPlaying then
			track:Stop(fade or D.BlendOut)
		end
		if diveHandles[character] == self then
			diveHandles[character] = nil
		end
	end
	function handle.recover(self: DiveHandle)
		-- the lunge is over on the server: the get-up starts now (never jumps backward)
		if track.IsPlaying and track.TimePosition < recoverAt then
			track.TimePosition = recoverAt
		end
	end
	function handle.finish(self: DiveHandle)
		-- the server's dive is over: if the clip still has more than its blend-out left, it was cut short (respawn,
		-- cancel): blend back to the stance now
		if track.IsPlaying and length - track.TimePosition > D.BlendOut + 0.05 then
			self:stop()
		end
	end
	-- blend out into the live ready stance over the clip's last BlendOut seconds (no pop at the end)
	conn = RunService.Heartbeat:Connect(function()
		if character.Parent == nil then
			handle:stop(0)
		elseif track.IsPlaying then
			track:AdjustSpeed(timeScale)
			if track.TimePosition >= length - D.BlendOut then
				handle:stop()
			end
		end
	end)
	track.Stopped:Once(function()
		if diveHandles[character] == handle then
			diveHandles[character] = nil
		end
		task.defer(function()
			track:Destroy()
		end)
	end)
	diveHandles[character] = handle
	return handle :: DiveHandle
end

-- ===== Serve (the /animate clips NP_ServeToss / NP_ServeStrike; upper body only, Action3) =====
-- hold(): the ball rests in the free (left) hand (the toss clip's first frame, held). toss(): plays the toss at
-- Config.Serve.TossAnimSpeed: dip, lift, release at the clip's Release marker (Config.Serve.TossReleaseDelay = marker /
-- speed, the server's release moment), the arm follows up while the paddle draws back, then holds the cocked pose.
-- strike(stroke): forehand = NP_ServeStrike (continues from the cocked pose), backhand = the procedural backhand swing.
-- stop(): back to the ready stance (point reset, refused toss). The footwork layer keeps the legs. Always normal game
-- speed (2026-11-16 pass 3: no serve slow motion). Visual only.
export type ServeHandle = { hold: (ServeHandle) -> (), toss: (ServeHandle) -> (), strike: (ServeHandle, string?) -> (), stop: (ServeHandle) -> () }

function StancePose.serve(character: Model): ServeHandle?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root then
		return nil
	end
	local rootHeight = nil -- (own HipHeight: no fit needed)
	local toss = NotPongAnims.load(character, "NP_ServeToss", rootHeight)
	if not toss then
		return nil
	end
	local length = NotPongAnims.length("NP_ServeToss")
	local tossing = false
	local handle = {} :: any
	local conn: RBXScriptConnection? = nil
	local function hookUpdate()
		if conn then
			return
		end
		conn = RunService.Heartbeat:Connect(function()
			if character.Parent == nil then
				handle:stop()
				return
			end
			if toss.IsPlaying and tossing then
				if toss.TimePosition >= length - 0.03 then
					toss.TimePosition = length - 0.03
					toss:AdjustSpeed(0) -- hold the cocked pose until the strike
				else
					toss:AdjustSpeed(Config.Serve.TossAnimSpeed) -- (always normal game speed: nothing slows a serve)
				end
			end
		end)
	end
	function handle.hold(self: ServeHandle)
		tossing = false
		if not toss.IsPlaying then
			toss:Play(0.2)
		end
		toss.TimePosition = 0
		toss:AdjustSpeed(0)
		hookUpdate()
	end
	function handle.toss(self: ServeHandle)
		if not toss.IsPlaying then
			toss:Play(0.05)
		end
		toss.TimePosition = 0
		tossing = true
		toss:AdjustSpeed(Config.Serve.TossAnimSpeed)
		hookUpdate()
	end
	function handle.strike(self: ServeHandle, stroke: string?)
		tossing = false
		if toss.IsPlaying then
			toss:Stop(0.06)
		end
		if stroke == "Backhand" then
			StancePose.playSwing(character, 1, "Backhand")
			return
		end
		local strikeTrack = NotPongAnims.load(character, "NP_ServeStrike", rootHeight)
		if strikeTrack then
			strikeTrack.Looped = false
			strikeTrack:Play(0.04)
			strikeTrack:AdjustSpeed(1)
			strikeTrack.Stopped:Once(function()
				task.defer(function()
					strikeTrack:Destroy()
				end)
			end)
		end
	end
	function handle.stop(self: ServeHandle)
		tossing = false
		if toss.IsPlaying then
			toss:Stop(0.2)
		end
		if conn then
			conn:Disconnect()
			conn = nil
		end
	end
	return handle :: ServeHandle
end

-- (kept for old callers) play the dive for `side`.
function StancePose.playDive(character: Model, side: number, _totalTime: number?): AnimationTrack?
	local h = StancePose.dive(character, side)
	return h and h.track
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
	upper: AnimationTrack, -- the CURRENT stroke's upper-body track
	ready: AnimationTrack, -- the athletic ready-legs loop (NP_Ready)
	stroke: string, -- "Forehand" | "Backhand"
	active: boolean, -- false while off the platform (standard Roblox animations show)
	moveWeight: number, -- 0 standing .. 1 moving (the legs' share of footwork vs the ready loop)
	runWeight: number, -- 0 shuffle .. 1 Shift run
	phase: number, -- 0..1 of the shared footwork cycle
	setStroke: (Controller, string) -> (),
	setActive: (Controller, boolean) -> (),
	-- serving posture (Config.Serve.Posture): hip yaw in radians (+ = turned left, 0 = none), blended in/out
	setServePosture: (Controller, number) -> (),
	servePostureYaw: number, -- the current (blended) hip yaw of the posture
	stop: (Controller) -> (),
}

-- Full ready-stance + footwork controller (rewritten 2026-11-15, pass 2). Must run on whoever SIMULATES the character
-- (the server for the bot, the owning client for a player): animations only take effect there.
--
-- WHY IT LOOKS LIKE THIS (measured on the test avatar before the rewrite):
--   * the leg tracks' weights dipped to ~0.75 at every start/stop/reversal, so Roblox's default walk (Core) leaked into
--     the legs; the per-frame HipHeight grounding then saw that walk's feet and popped the body up ~0.47 studs;
--   * the shuffle clips keyed the WHOLE body (upper joints at rest), so while moving they averaged the paddle arm and
--     the lean down by half (shoulder 45 -> 22 deg, lean 12 -> 6);
--   * the upper body was one frozen pose.
-- So now:
--   * LEGS = one locomotion layer whose weights ALWAYS sum to 1: NP_Ready (standing) + 4 shuffles + 4 Shift runs,
--     blended by speed and by the direction of travel in the body's own frame. Nothing below it can show through.
--     Every footwork clip is legs + hips only, so it never touches the arms.
--   * One shared cycle clock (`phase`) drives every footwork track (they share one cycle length), so blends and
--     direction changes never restart a track or put the feet out of step. Starting from standing still begins the
--     cycle on the lead foot (the foot nearest the movement direction).
--   * HipHeight is never touched: the clips are authored for the block rig with the root at 3 units, and
--     NotPongAnims.rootOffset fits them to the avatar's own HipHeight once. No grounding feedback loop, no bobbing.
--   * UPPER BODY = the stroke's ready pose (Config.Stance) + a small ADDITIVE layer written after the Animator each
--     frame (RunService.PreSimulation): the waist and neck counter-rotate against the hips (shoulder counter-motion; on
--     a sideways run the hips turn ~25 deg toward travel while the head and paddle stay on play), slow breathing, and the
--     free arm balancing against the hips. Leg joints are never touched by it, so planted feet stay planted.
-- `_walkAnimationId` is ignored (the bot used to walk with its own walk cycle; it now uses the same footwork).
-- `stroke` (optional, default "Forehand"): the upper-body pose to start in.
local FOOTWORK = {
	"NP_ShuffleRight", "NP_ShuffleLeft", "NP_ShuffleForward", "NP_ShuffleBack",
	"NP_CrossRight", "NP_CrossLeft", -- (2026-11-17: crossover strides for sustained sideways movement)
	"NP_RunRight", "NP_RunLeft", "NP_RunForward", "NP_RunBack",
}

function StancePose.start(character: Model, _walkAnimationId: string?, stroke: string?): Controller?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return nil
	end
	local S = Config.Stance
	local L = S.Locomotion
	local A = S.Layer
	local initialStroke = if stroke == "Backhand" then "Backhand" else "Forehand"
	local upper = load(
		character,
		animationId("Upper", nil, initialStroke),
		"NotPongReadyStance" .. (if initialStroke == "Backhand" then "Backhand" else ""),
		Enum.AnimationPriority.Action
	)
	if not upper then
		return nil
	end
	-- the clips' fit to this avatar: none needed on its own (unchanged) HipHeight (NotPongAnims header)
	local rootHeight = nil
	local ready = NotPongAnims.load(character, "NP_Ready", rootHeight)
	if not ready then
		upper:Stop()
		return nil
	end
	local tracks: { [string]: AnimationTrack } = {}
	for _, name in FOOTWORK do
		local t = NotPongAnims.load(character, name, rootHeight)
		if t then
			tracks[name] = t
		end
	end
	local scale = math.max(character:GetScale(), 1e-3)
	local cycle = NotPongAnims.length("NP_ShuffleRight")
	local lengths: { [AnimationTrack]: number } = {} -- each footwork clip's own cycle length (they differ: 0.5 / 0.4 s)
	for name, t in tracks do
		lengths[t] = NotPongAnims.length(name) or cycle
	end
	local sustain, crossing, lastLatSign = 0, false, 0 -- hybrid footwork state (see the heartbeat)

	local controller = {
		upper = upper,
		ready = ready,
		stroke = initialStroke,
		active = true,
		moveWeight = 0,
		runWeight = 0,
		phase = 0,
		crossWeight = 0,
		servePostureYaw = 0,
	} :: any
	local postureTarget = 0 -- requested serving-posture hip yaw (radians)
	function controller.setServePosture(self: Controller, yaw: number)
		postureTarget = if typeof(yaw) == "number" and yaw == yaw then yaw else 0
	end
	local dir = Vector2.zero -- travel direction in the body frame (x right, y forward)
	local shareW = { Right = 1, Left = 0, Forward = 0, Back = 0 } -- eased per-direction clip shares (sum to 1)
	local stillFor = math.huge -- seconds spent standing (a new move after a pause starts on the lead foot)

	local function playAll(fade: number)
		upper:Play(fade)
		ready:Play(fade)
		for _, t in tracks do
			t:Play(fade, 0.001)
			t:AdjustSpeed(0) -- driven by `phase` (TimePosition), never by its own clock
		end
	end
	local function stopAll(fade: number, upperTracks: { [string]: AnimationTrack }?)
		for _, t in upperTracks or { upper } do
			t:Stop(fade)
		end
		ready:Stop(fade)
		for _, t in tracks do
			t:Stop(fade)
		end
	end
	playAll(0.2)

	-- One loaded upper-body track per stroke, reused (never re-created per switch). Only the current one is kept playing.
	local upperTracks: { [string]: AnimationTrack } = { [initialStroke] = upper }
	function controller.setStroke(self: Controller, newStroke: string)
		newStroke = if newStroke == "Backhand" then "Backhand" else "Forehand"
		if newStroke == self.stroke or character.Parent == nil then
			return
		end
		local track = upperTracks[newStroke]
		if not track then
			track = load(character, animationId("Upper", nil, newStroke), "NotPongReadyStance" .. newStroke, Enum.AnimationPriority.Action)
			if not track then
				return -- keep the current pose
			end
			upperTracks[newStroke] = track
		end
		local fade = S.StrokeBlendTime or 0.12
		local old = self.upper
		self.stroke, self.upper = newStroke, track
		upper = track
		if not self.active then
			return -- off the platform: remembered, shown when the stance comes back
		end
		track:Play(fade)
		if old ~= track then
			old:Stop(fade)
		end
	end

	-- OFF THE PLATFORM (Client/PlatformZone): every stance track stops so Roblox's own idle / walk / run / jump show.
	-- (HipHeight is the avatar's own on and off the platform, so nothing jumps.) Back on: everything fades back in.
	function controller.setActive(self: Controller, on: boolean)
		if on == self.active or character.Parent == nil then
			return
		end
		self.active = on
		local fade = S.ActivationBlendTime or 0.25
		if on then
			self.moveWeight, self.runWeight, stillFor = 0, 0, math.huge
			playAll(fade)
		else
			stopAll(fade, upperTracks)
		end
	end

	local diveAttr = Config.Names.DiveStateAttribute
	local function ease(current: number, target: number, rate: number, dt: number): number
		return current + (target - current) * (1 - math.exp(-rate * dt))
	end

	local heartbeat
	heartbeat = RunService.Heartbeat:Connect(function(dt)
		if character.Parent == nil or humanoid.Health <= 0 then
			heartbeat:Disconnect()
			return
		end
		if not controller.active then
			return
		end
		-- keep the tracks alive (a respawn race or another script can stop them)
		if not upper.IsPlaying or not ready.IsPlaying then
			playAll(0.2)
		end
		local diving = (character:GetAttribute(diveAttr) or "") ~= ""
		local v = root.AssemblyLinearVelocity
		local flat = Vector3.new(v.X, 0, v.Z)
		local speed = flat.Magnitude
		local moving = speed > L.MoveThreshold and not diving

		-- standing <-> moving (fast in, a quick settle out), shuffle <-> run (by speed: Shift)
		controller.moveWeight = ease(controller.moveWeight, if moving then 1 else 0, if moving then L.StartRate else L.StopRate, dt)
		local runTarget = math.clamp((speed - L.RunFrom) / math.max(L.RunTo - L.RunFrom, 1e-3), 0, 1)
		controller.runWeight = ease(controller.runWeight, runTarget, L.RunBlendRate, dt)

		-- Travel direction in the body's frame -> each direction clip's share. (2026-11-16 pass 3) Each share eases on its
		-- own toward the share of the CURRENT direction, so a left/right reversal cross-fades Right -> Left directly. (It
		-- used to smooth one direction VECTOR, which passes through ~zero mid-reversal, where the normalised shares briefly
		-- handed the legs to the forward/back clips: a visible leg flick at every reversal.) The shares always sum to 1.
		if moving then
			local local2 = Vector2.new(flat:Dot(root.CFrame.RightVector), flat:Dot(root.CFrame.LookVector)) / speed
			dir = local2
			local total = math.abs(dir.X) + math.abs(dir.Y)
			local lat = if total > 1e-3 then math.abs(dir.X) / total else 1
			local target = {
				Right = if dir.X > 0 then lat else 0,
				Left = if dir.X < 0 then lat else 0,
				Forward = if dir.Y > 0 then 1 - lat else 0,
				Back = if dir.Y < 0 then 1 - lat else 0,
			}
			if stillFor > L.RestartAfterIdle then
				shareW = target -- a fresh move: no blend from an old direction
				controller.phase = 0 -- and the lead foot steps first
			else
				local a = 1 - math.exp(-L.DirectionRate * dt)
				for k, v in target do
					shareW[k] += (v - shareW[k]) * a
				end
			end
			stillFor = 0
		else
			stillFor += dt
		end
		local share = shareW

		-- HYBRID FOOTWORK (2026-11-17): short sideways moves shuffle (step out, close); SUSTAINED sideways movement in one
		-- direction develops into crossover strides. crossW 0..1: the crossover's share of the sideways legs. It rises once
		-- the player has moved sideways the same way for CrossoverAfter seconds above CrossoverMinSpeed, and stays up
		-- (hysteresis) until the sideways speed falls below CrossoverExitSpeed; a reversal drops it at once (the reversal
		-- then plays as a shuffle step in the new direction, never as a finished crossover). The body's real movement is
		-- never delayed: this only picks which clips the legs show.
		local lateral = flat:Dot(root.CFrame.RightVector)
		local latSpeed = math.abs(lateral)
		local latSign = if latSpeed > L.CrossoverExitSpeed then (if lateral > 0 then 1 else -1) else 0
		if latSign ~= 0 and latSign == lastLatSign then
			sustain += dt
		elseif latSign ~= 0 and lastLatSign ~= 0 and latSign ~= lastLatSign then
			sustain, crossing = 0, false -- reversal: a direction-change step, not a crossover
			controller.crossWeight = math.min(controller.crossWeight, L.ReversalCrossCap)
		elseif latSign == 0 then
			sustain, crossing = 0, false
		end
		if latSign ~= 0 then
			lastLatSign = latSign
		elseif not moving then
			lastLatSign = 0
		end
		if not crossing and sustain >= L.CrossoverAfter and latSpeed >= L.CrossoverMinSpeed then
			crossing = true
		end
		controller.crossWeight = ease(controller.crossWeight, if crossing then 1 else 0, if crossing then L.CrossBlendIn else L.CrossBlendOut, dt)

		-- one cycle clock for every footwork track: real speed / the blended clips' STRIDE (studs per cycle on the block
		-- rig, x the avatar's scale), so a planted foot never skates and longer strides mean fewer, slower steps
		local mw, rw, cw = controller.moveWeight, controller.runWeight, controller.crossWeight
		local St = L.Stride
		local function walkStride(name: string): number
			if name == "Right" or name == "Left" then
				return (1 - cw) * St.Shuffle + cw * St.Cross
			end
			return if name == "Forward" then St.Forward else St.Back
		end
		local runStride = { Right = St.RunSide, Left = St.RunSide, Forward = St.RunForward, Back = St.RunBack }
		local strideMix = 0
		for name, k in share do
			strideMix += k * ((1 - rw) * walkStride(name) + rw * runStride[name])
		end
		local cycles = if strideMix > 1e-3 then speed / (strideMix * scale) else 0
		-- (no extra slow-motion factor: slow motion lowers the real walk speed, and this clock follows the real speed)
		cycles = math.clamp(cycles * L.PlaybackScale, L.MinCycleRate, L.MaxCycleRate)
		if mw > 0.01 then
			controller.phase = (controller.phase + dt * cycles) % 1
		end
		local ph = controller.phase

		local function drive(track: AnimationTrack?, weight: number)
			if not track then
				return
			end
			if not track.IsPlaying then
				track:Play(0, 0.001)
				track:AdjustSpeed(0)
			end
			track.TimePosition = ph * (lengths[track] or cycle)
			track:AdjustWeight(math.max(weight, 0.001), 0)
		end
		ready:AdjustWeight(math.max(1 - mw, 0.001), 0)
		for name, k in share do
			local lateralClip = name == "Right" or name == "Left"
			drive(tracks["NP_Shuffle" .. name], mw * (1 - rw) * k * (if lateralClip then 1 - cw else 1))
			if lateralClip then
				drive(tracks["NP_Cross" .. name], mw * (1 - rw) * k * cw)
			end
			drive(tracks["NP_Run" .. name], mw * rw * k)
		end
	end)

	-- ADDITIVE UPPER-BODY LAYER: after the Animator has posed the body, before physics and rendering.
	local lowerTorso = character:FindFirstChild("LowerTorso")
	local upperTorso = character:FindFirstChild("UpperTorso")
	local head = character:FindFirstChild("Head")
	local leftArm = character:FindFirstChild("LeftUpperArm")
	local rootJoint = lowerTorso and lowerTorso:FindFirstChild("Root") :: any
	local waist = upperTorso and upperTorso:FindFirstChild("Waist") :: any
	local neck = head and head:FindFirstChild("Neck") :: any
	local shoulder = leftArm and leftArm:FindFirstChild("LeftShoulder") :: any
	local breath = math.random() * 10
	local layer
	layer = RunService.PreSimulation:Connect(function(dt)
		if character.Parent == nil or humanoid.Health <= 0 then
			layer:Disconnect()
			return
		end
		if not controller.active or not (rootJoint and waist and neck) then
			return
		end
		if (character:GetAttribute(diveAttr) or "") ~= "" then
			return -- the dive clip owns the whole body
		end
		breath += dt * timeScale
		local _, hipYaw = rootJoint.Transform:ToEulerAnglesYXZ()
		local b = math.rad(A.BreathDegrees) * math.sin(2 * math.pi * breath / A.BreathPeriod)
		-- SERVING POSTURE (Config.Serve.Posture): the hips turn (the legs turn with them about the vertical, so the feet
		-- stay on the floor), the chest keeps ChestFollow of it, the neck turns the rest back: the head stays on the table.
		-- Faded while walking (moveWeight) so repositioning before the toss uses the normal footwork.
		local SP = Config.Serve.Posture
		local blendRate = 3 / math.max(SP.BlendTime, 1e-3)
		local want = postureTarget * (1 - controller.moveWeight)
		controller.servePostureYaw += (want - controller.servePostureYaw) * (1 - math.exp(-blendRate * dt))
		local py = controller.servePostureYaw
		if math.abs(py) > 1e-4 then
			rootJoint.Transform = CFrame.Angles(0, py, 0) * rootJoint.Transform
		end
		local chestBack = -py * (1 - SP.ChestFollow) -- the waist turns the chest back to ChestFollow of the hips' turn
		local headBack = -py * SP.ChestFollow -- the neck turns the head the rest of the way back to the table
		waist.Transform = waist.Transform * CFrame.fromEulerAnglesYXZ(b, -A.WaistCounter * hipYaw + chestBack, 0)
		neck.Transform = neck.Transform * CFrame.fromEulerAnglesYXZ(-b * 0.6, -A.NeckCounter * hipYaw + headBack, 0)
		if shoulder then
			shoulder.Transform = shoulder.Transform * CFrame.Angles(A.FreeArmSwing * hipYaw, 0, 0)
		end
	end)

	function controller.stop(self: Controller)
		heartbeat:Disconnect()
		layer:Disconnect()
		stopAll(0.2, upperTracks)
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
