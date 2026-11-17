--!strict
-- PaddleArm: the paddle arm's poses for CLICK-AND-FLICK (2026-11-17). Visual only; nothing here affects a hit.
--   * PREPARATION grid: per stroke, 3 heights (low / mid / high) x 3 positions across (inner = near the body, mid, outer =
--     wide), joint angles in degrees { shoulder x, y, z, elbow x, y (forearm pronation), wrist x, y, z }. SOLVED OFFLINE
--     with forward kinematics on the avatar's real joint attachments (the same method as the backhand face flip): blade
--     centre on its target (+-2.6 studs across, +-2.6 up/down around the approved ready pose, which is the exact middle),
--     the striking face toward the table (forehand: the front / red rubber; backhand: the back / black), the tip leaning
--     to the stroke's side, joint limits, and no blade / hand / forearm contact with the torso, head or upper arm. The
--     game blends the 4 neighbouring poses joint by joint (prepPose), so a cursor anywhere gives a pose between solved
--     ones (no free paddle teleporting, no impossible joints).
--   * CONTACT: solveContact moves the blade centre onto a target point (the ball, minus the face offset) with the striking
--     face along the outgoing direction, starting from the current pose, by a short bounded coordinate descent on the
--     same live forward kinematics, with joint limits and clearance from the torso, head, upper arm and the table top.
--     If the ball is beyond the arm, the blade gets as close as the limits allow (the reach that counts is the server's).
-- Run on the client that animates the character (StancePose arm layer). Config.ArmLayer holds the timings.

local Config = require(script.Parent:WaitForChild("Config"))

local PaddleArm = {}

-- rows: 1 = low, 2 = mid, 3 = high; columns: 1 = inner, 2 = mid, 3 = outer. Mid / mid = Config.Stance (Backhand).
PaddleArm.Prep = {
	Forehand = {
		{ { 21, 6, -4, 57, 10, 14, -28, -2 }, { 29, -3, 10, 51, 2, 1, -38, 0 }, { 45, -3, 23, 39, -14, -17, -45, -8 } },
		{ { 39, 9, 4, 68, 10, 12, -31, -2 }, { 45, 0, 18, 60, 0, 0, -40, 0 }, { 54, 0, 35, 42, -12, -20, -43, -4 } },
		{ { 60, 21, 18, 68, -1, -4, -38, -3 }, { 62, 14, 33, 56, -8, -14, -43, -2 }, { 66, 12, 47, 38, -18, -31, -38, -7 } },
	},
	Backhand = {
		{ { 27, 56, 2, 63, -70, -2, 25, -54 }, { 34, 61, 2, 60, -78, -20, 25, -42 }, { 50, 85, 5, 52, -91, -28, 7, -35 } },
		{ { 38, 62, 3, 81, -74, -8, 27, -46 }, { 50, 71, 2, 71, -83, -17, 19, -39 }, { 62, 89, 14, 55, -94, -32, 5, -39 } },
		{ { 65, 61, 14, 75, -87, -23, 16, -43 }, { 73, 75, 14, 61, -94, -26, 10, -44 }, { 82, 82, 7, 55, -96, -37, 10, -38 } },
	},
}

-- s / e / w: shoulder, elbow, wrist rotations. t: an EXTRA waist rotation on top of the stance's (upper-body support
-- for far contacts: twist, side bend, lean); identity in every preparation pose. a: the 11 joint angles (degrees) the
-- rotations were built from: poses are blended in ANGLE space (neighbouring solved poses are similar, so this is smooth)
-- and the solver starts from these numbers, never from angles read back out of a rotation (which would flip to an
-- equivalent set past 90 degrees, e.g. the backhand's forearm pronation).
export type Pose = { s: CFrame, e: CFrame, w: CFrame, t: CFrame, a: { number } }

local function rot(x: number, y: number, z: number): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y), math.rad(z))
end

-- v = { shoulder x, y, z, elbow x, y, wrist x, y, z [, waist lean x, twist y, side bend z] } (degrees)
function PaddleArm.poseOf(v: { number }): Pose
	local a = table.create(11, 0)
	for i = 1, 11 do
		a[i] = v[i] or 0
	end
	return {
		s = rot(a[1], a[2], a[3]),
		e = rot(a[4], a[5], 0),
		w = rot(a[6], a[7], a[8]),
		t = rot(a[9], a[10], a[11]),
		a = a,
	}
end

function PaddleArm.lerp(p: Pose, q: Pose, t: number): Pose
	local a = table.create(11, 0)
	for i = 1, 11 do
		a[i] = p.a[i] + (q.a[i] - p.a[i]) * t
	end
	return PaddleArm.poseOf(a)
end

local cache: { [string]: { { Pose } } } = {}
local function grid(stroke: string): { { Pose } }
	local key = if stroke == "Backhand" then "Backhand" else "Forehand"
	local g = cache[key]
	if not g then
		g = {}
		for r, row in PaddleArm.Prep[key] do
			g[r] = {}
			for c, v in row do
				g[r][c] = PaddleArm.poseOf(v)
			end
		end
		cache[key] = g
	end
	return g
end

-- The prepared pose for `stroke` at `across` (0 = inner .. 1 = outer) and `height` (0 = low .. 1 = high): the four
-- neighbouring solved poses blended joint by joint.
function PaddleArm.prepPose(stroke: string, across: number, height: number): Pose
	local g = grid(stroke)
	local gx = math.clamp(across, 0, 1) * 2
	local gy = math.clamp(height, 0, 1) * 2
	local ix, iy = math.min(math.floor(gx), 1), math.min(math.floor(gy), 1)
	local fx, fy = gx - ix, gy - iy
	local low = PaddleArm.lerp(g[iy + 1][ix + 1], g[iy + 1][ix + 2], fx)
	local high = PaddleArm.lerp(g[iy + 2][ix + 1], g[iy + 2][ix + 2], fx)
	return PaddleArm.lerp(low, high, fy)
end

-- ===== live forward kinematics =====
export type Rig = {
	shoulder: any, -- AnimationConstraint / Motor-like with Attachment0/1 (RightShoulder)
	elbow: any,
	wrist: any,
	waist: any?, -- UpperTorso.Waist (the upper-body support rotates about it)
	grip: CFrame, -- hand -> paddle Handle (PaddleGrip C0 * C1^-1)
	bladeOff: CFrame, -- Handle -> WoodBlade centre
	upperArmSize: Vector3,
	torso: BasePart,
	head: BasePart?,
	faceSign: { [string]: number },
}

local function attach(j: any): (CFrame, CFrame)
	return j.Attachment0.CFrame, j.Attachment1.CFrame
end

-- Rig description from a live character (nil when the arm or the paddle is missing).
function PaddleArm.rig(character: Model): Rig?
	local ua = character:FindFirstChild("RightUpperArm")
	local la = character:FindFirstChild("RightLowerArm")
	local hand = character:FindFirstChild("RightHand")
	local torso = character:FindFirstChild("UpperTorso") :: BasePart?
	local paddle = character:FindFirstChild("Paddle")
	local handle = paddle and paddle:FindFirstChild("Handle") :: BasePart?
	local blade = paddle and paddle:FindFirstChild("WoodBlade") :: BasePart?
	local gripJoint = handle and handle:FindFirstChild("PaddleGrip") :: Motor6D?
	if not (ua and la and hand and torso and handle and blade and gripJoint) then
		return nil
	end
	local sh = ua:FindFirstChild("RightShoulder") :: any
	local el = la:FindFirstChild("RightElbow") :: any
	local wr = hand:FindFirstChild("RightWrist") :: any
	if not (sh and el and wr and sh.Attachment0 and el.Attachment0 and wr.Attachment0) then
		return nil
	end
	local g = gripJoint :: Motor6D
	local waist = (torso :: BasePart):FindFirstChild("Waist") :: any
	return {
		shoulder = sh,
		elbow = el,
		wrist = wr,
		waist = if waist and waist.Attachment1 then waist else nil,
		grip = g.C0 * g.C1:Inverse(),
		bladeOff = (handle :: BasePart).CFrame:ToObjectSpace((blade :: BasePart).CFrame),
		upperArmSize = (ua :: BasePart).Size,
		torso = torso :: BasePart,
		head = character:FindFirstChild("Head") :: BasePart?,
		faceSign = { Forehand = 1, Backhand = -1 }, -- the striking face: front (+Z of the blade) / back
	}
end

-- The upper torso with the pose's extra waist rotation applied (it turns about the waist joint).
function PaddleArm.torsoFor(rig: Rig, torsoCF: CFrame, pose: Pose): CFrame
	if rig.waist == nil or pose.t == CFrame.identity then
		return torsoCF
	end
	local pivot = torsoCF * rig.waist.Attachment1.CFrame -- the waist joint's frame on the upper torso
	return pivot * pose.t * pivot:ToObjectSpace(torsoCF)
end

-- World frames for a pose with the upper torso at `torsoCF` (before the pose's waist extra): blade, hand, lower arm,
-- upper arm, and the upper torso after the waist extra.
function PaddleArm.fk(rig: Rig, torsoCF: CFrame, pose: Pose): (CFrame, CFrame, CFrame, CFrame, CFrame)
	torsoCF = PaddleArm.torsoFor(rig, torsoCF, pose)
	local a0, a1 = attach(rig.shoulder)
	local ua = torsoCF * a0 * pose.s * a1:Inverse()
	a0, a1 = attach(rig.elbow)
	local la = ua * a0 * pose.e * a1:Inverse()
	a0, a1 = attach(rig.wrist)
	local hand = la * a0 * pose.w * a1:Inverse()
	return hand * rig.grip * rig.bladeOff, hand, la, ua, torsoCF
end

-- ===== contact solve =====
local RIM = {}
for k = 0, 7 do
	local a = k / 8 * 2 * math.pi
	table.insert(RIM, Vector3.new(2.08 * math.cos(a), 2.15 * math.sin(a), 0))
end
table.insert(RIM, Vector3.zero)

local function depthIn(cf: CFrame, half: Vector3, p: Vector3): number
	local q = cf:PointToObjectSpace(p)
	local d = math.min(half.X - math.abs(q.X), half.Y - math.abs(q.Y), half.Z - math.abs(q.Z))
	return if d > 0 then d else 0
end

-- Penetration of the blade rim / hand / forearm into the torso, head, upper arm and the table top (0 = clean).
function PaddleArm.clearance(rig: Rig, torsoCF: CFrame, pose: Pose, tableBox: any?, frames: { CFrame }?): number
	local blade, hand, la, ua, turned
	if frames then
		blade, hand, la, ua, turned = frames[1], frames[2], frames[3], frames[4], frames[5]
	else
		blade, hand, la, ua, turned = PaddleArm.fk(rig, torsoCF, pose)
	end
	local tHalf = rig.torso.Size / 2 + Vector3.one * 0.15
	local head = rig.head
	local hHalf = head and head.Size / 2 + Vector3.one * 0.15 or Vector3.zero
	local headCF = head and turned * torsoCF:ToObjectSpace(head.CFrame) -- the head turns with the waist
	torsoCF = turned
	local uHalf = rig.upperArmSize / 2
	local d = 0
	local function test(p: Vector3)
		d += depthIn(torsoCF, tHalf, p)
		if headCF then
			d += depthIn(headCF, hHalf, p)
		end
		if tableBox and p.Y < tableBox.maxY + 0.15 and p.X > tableBox.minX and p.X < tableBox.maxX and p.Z > tableBox.minZ and p.Z < tableBox.maxZ then
			d += tableBox.maxY + 0.15 - p.Y
		end
	end
	for _, r in RIM do
		local p = blade:PointToWorldSpace(r)
		test(p)
		d += depthIn(ua, uHalf, p)
	end
	test(hand.Position)
	test(la.Position:Lerp(hand.Position, 0.5))
	return d
end

local function anglesOf(pose: Pose): { number }
	return table.clone(pose.a)
end

-- Move the blade centre onto `target` with the striking face (stroke) normal along `faceDir`, from `seed`. Bounded:
-- Config.ArmLayer.SolveIterations passes. Returns the pose and the remaining blade-to-target distance.
function PaddleArm.solveContact(rig: Rig, torsoCF: CFrame, stroke: string, target: Vector3, faceDir: Vector3, seed: Pose, tableBox: any?): (Pose, number)
	local A = Config.ArmLayer
	local sign = rig.faceSign[stroke] or 1
	local base = anglesOf(seed)
	local fd = if faceDir.Magnitude > 1e-3 then faceDir.Unit else Vector3.new(0, 0, -1)
	local function poseFrom(x: { number }): Pose
		return PaddleArm.poseOf(x)
	end
	local function cost(x: { number }): number
		local pose = poseFrom(x)
		local blade, hand, la, ua, turned = PaddleArm.fk(rig, torsoCF, pose)
		local c = (blade.Position - target).Magnitude ^ 2
		local n = blade.ZVector * sign
		c += A.FaceWeight * (1 - n:Dot(fd))
		local dev = 0
		for i = 1, 8 do
			dev += (x[i] - base[i]) ^ 2
		end
		c += A.StayWeight * dev
		-- upper-body support (waist lean x, twist y, side bend z): costs more than the arm, so it is only used when the
		-- arm alone cannot reach; hard limits from Config.ArmLayer.WaistLimit
		local L = A.WaistLimit
		c += A.WaistWeight * (x[9] ^ 2 + x[10] ^ 2 + x[11] ^ 2)
		c += 0.05 * (math.max(0, math.abs(x[9]) - L.X) ^ 2 + math.max(0, math.abs(x[10]) - L.Y) ^ 2 + math.max(0, math.abs(x[11]) - L.Z) ^ 2)
		-- joint limits (degrees): elbow flexion, forearm pronation, wrist bend
		c += 0.004 * math.max(0, x[4] - 145) ^ 2 + 0.004 * math.max(0, 0 - x[4]) ^ 2 + 0.004 * math.max(0, math.abs(x[5]) - 100) ^ 2
		local wmag = math.deg(select(2, pose.w:ToAxisAngle()))
		c += 0.004 * math.max(0, wmag - 60) ^ 2
		c += 0.0005 * math.max(0, math.abs(x[2]) - 120) ^ 2 + 0.0005 * math.max(0, math.abs(x[1] - 45) - 110) ^ 2
		c += A.ClearanceWeight * PaddleArm.clearance(rig, torsoCF, pose, tableBox, { blade, hand, la, ua, turned })
		return c
	end
	local x = table.clone(base)
	local n = if rig.waist then 11 else 8
	local cx = cost(x)
	local stepSize = A.SolveStep
	for _ = 1, A.SolveIterations do
		local improved = false
		for i = 1, n do
			for _, sg in { 1, -1 } do
				local y = table.clone(x)
				y[i] += sg * stepSize
				local cy = cost(y)
				if cy < cx then
					x, cx, improved = y, cy, true
				end
			end
		end
		if not improved then
			stepSize *= 0.5
			if stepSize < 0.5 then
				break
			end
		end
	end
	local pose = poseFrom(x)
	local blade = PaddleArm.fk(rig, torsoCF, pose)
	return pose, (blade.Position - target).Magnitude
end

-- A pose turned by extra joint angles (degrees, same layout as the grid) - used for the follow-through.
function PaddleArm.offset(pose: Pose, d: { number }): Pose
	local x = anglesOf(pose)
	for i = 1, 11 do
		x[i] += d[i] or 0
	end
	return PaddleArm.poseOf(x)
end

return PaddleArm
