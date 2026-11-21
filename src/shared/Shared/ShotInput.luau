--!strict
-- ShotInput: the pure rules behind the player's shot controls (CLICK-AND-FLICK, 2026-11-17: prepare with the cursor,
-- hold left-click to commit, flick to strike). Shared so the client (instant feedback, prediction) and the server
-- (authoritative judgement) compute the SAME answers from the same numbers. No Instances, no input, no networking.
--   * prep: cursor screen position -> stroke, base aim, drive/arc profile, paddle preparation (u, v)
--   * flickShot / validateFlick: a recognised flick (Shared/FlickGesture) -> power + spin; the server's input checks
--   * contactWindow: simulates the incoming ball with the real BallPhysics and finds when it is within paddle reach
--     (after its bounce on the player's half): enter, ideal (closest to the paddle), exit
--   * classify: contact time (flick start + Flick.ContactDelay) vs that window -> "clean" | "weak" | "miss"
--   * emergencyReach: the outer save ring (Config.Emergency)
-- The launch itself lives in ShotLaunch.

local Config = require(script.Parent:WaitForChild("Config"))
local BallPhysics = require(script.Parent:WaitForChild("BallPhysics"))
local TableWorld = require(script.Parent:WaitForChild("TableWorld"))

local ShotInput = {}

export type Window = {
	enter: number, -- seconds after the predicted-from state
	ideal: number,
	exit: number,
	idealPosition: Vector3,
	-- an EARLIER in-reach pass of the same ball (a high bounce: in reach on the way up, above the height band at the
	-- apex, in reach again on the way down). classify judges a contact inside it against it; nil when there was none.
	earlier: Window?,
}

-- Shift a window (and its earlier pass) by `dt` seconds (relative <-> absolute times).
function ShotInput.shiftWindow(w: Window?, dt: number): Window?
	if not w then
		return nil
	end
	return {
		enter = w.enter + dt,
		ideal = w.ideal + dt,
		exit = w.exit + dt,
		idealPosition = w.idealPosition,
		earlier = ShotInput.shiftWindow(w.earlier, dt),
	}
end

-- The paddle reach anchor: in front of the character's root and to its right (FOREHAND, same rule as the bot's
-- Striker), or mirrored to its left for a BACKHAND (`stroke` = "Backhand" uses settings.BackhandAnchorRight).
function ShotInput.anchor(rootCFrame: CFrame, settings: any, stroke: string?): Vector3?
	local right = Vector3.new(rootCFrame.RightVector.X, 0, rootCFrame.RightVector.Z)
	local fwd = Vector3.new(rootCFrame.LookVector.X, 0, rootCFrame.LookVector.Z)
	if right.Magnitude < 1e-3 or fwd.Magnitude < 1e-3 then
		return nil
	end
	local side = settings.AnchorRight
	if stroke == "Backhand" and settings.BackhandAnchorRight ~= nil then
		side = settings.BackhandAnchorRight
	end
	return rootCFrame.Position + right.Unit * side + fwd.Unit * settings.AnchorForward
end

-- The reach for a swing right now: the stroke's anchor and its NORMAL radius (the outer emergency radius is
-- ShotInput.emergencyReach). (The F dive's extended reach was retired on 2026-11-17; the 4th argument is ignored.)
-- (Anchor model only; the zone-aware entry point is ShotInput.reachZone.)
function ShotInput.reachFor(rootCFrame: CFrame, settings: any, stroke: string?, _unused: any?): (Vector3?, number)
	return ShotInput.anchor(rootCFrame, settings, stroke), settings.PaddleReach
end

-- ===== BODY-CENTRED CONTACT ZONE (2026-11-18, Config.ShotControl.ContactModel = "Body", sizes Config.ContactZone) =====
-- One symmetric volume around the torso, the same for forehand and backhand: horizontally two half-ellipses on the
-- root's position (Forward studs ahead / Back studs behind, Side studs to either side), between LowAboveFloor and
-- HighAboveFloor. It is oriented along the TABLE AXIS (forward = toward the opponent), not the character's facing, so the
-- client and the server (which sees the character slightly late) agree from the root position alone. Assisted
-- gameplay reach: no body part, accessory or paddle collision ever creates a contact; only the ball centre inside the
-- volume at the judged contact moment counts. The emergency zone is the same shape, bigger (Config.ContactZone.Emergency).
export type Zone = {
	center: Vector3, -- root position (horizontal centre; Y unused)
	forward: Vector3, -- unit, horizontal: toward the opponent
	right: Vector3, -- unit, horizontal
	side: number,
	front: number,
	back: number,
	lowY: number, -- absolute
	highY: number,
	sweet: Vector3, -- the ideal-contact point (ball closest to it = the ideal moment; also the reach "anchor")
	emergency: boolean,
}

local function zoneOf(rootPos: Vector3, dims: any, emergency: boolean): Zone
	local C = Config.ContactZone
	local floor = Config.Layout.FloorY
	local fwd = Vector3.new(0, 0, TableWorld.towardSide("Bot")).Unit
	local right = Vector3.new(-fwd.Z, 0, fwd.X) -- (forward x up: the player's right as they face the opponent)
	local center = Vector3.new(rootPos.X, 0, rootPos.Z)
	return {
		center = center,
		forward = fwd,
		right = right,
		side = dims.Side,
		front = dims.Forward,
		back = dims.Back,
		lowY = floor + dims.LowAboveFloor,
		highY = floor + dims.HighAboveFloor,
		sweet = center + fwd * C.SweetForward,
		emergency = emergency,
	}
end

-- The normal (or emergency) zone for a root at `rootCFrame` (only its position is used).
function ShotInput.bodyZone(rootCFrame: CFrame, emergency: boolean?): Zone
	local C = Config.ContactZone
	return zoneOf(rootCFrame.Position, if emergency then C.Emergency else C.Normal, emergency == true)
end

-- Zone-local horizontal coordinates of `p`: x to the right, z forward.
function ShotInput.zoneLocal(z: Zone, p: Vector3): (number, number)
	local d = Vector3.new(p.X - z.center.X, 0, p.Z - z.center.Z)
	return d:Dot(z.right), d:Dot(z.forward)
end

-- Normalised horizontal radius of `p` in the zone: 0 at the centre, 1 on the boundary (> 1 outside).
function ShotInput.zoneRadius(z: Zone, p: Vector3): number
	local x, f = ShotInput.zoneLocal(z, p)
	local depth = if f >= 0 then z.front else z.back
	return math.sqrt((x / math.max(z.side, 1e-3)) ^ 2 + (f / math.max(depth, 1e-3)) ^ 2)
end

function ShotInput.zoneContains(z: Zone, p: Vector3): boolean
	if p.Y < z.lowY or p.Y > z.highY then
		return false
	end
	return ShotInput.zoneRadius(z, p) <= 1
end

-- How far a contact at `p` is from the comfortable middle (feeds ShotLaunch's "stretch", 0 .. 1): the normalised
-- distance from the sweet point toward the zone boundary.
function ShotInput.zoneStretch(z: Zone, p: Vector3): number
	local d = Vector2.new(p.X - z.sweet.X, p.Z - z.sweet.Z).Magnitude
	local scale = math.max(z.side, z.front)
	return math.clamp(d / math.max(scale, 1e-3), 0, 1)
end

-- THE entry point for a rally swing's reach (both models): returns what contactWindow takes as its 2nd and 3rd
-- arguments. Body model: (Zone, 0); Anchor model: (anchor point, PaddleReach or the emergency radius).
function ShotInput.reachZone(rootCFrame: CFrame, settings: any, stroke: string?, emergency: boolean?): (any, number)
	if settings.ContactModel == "Body" then
		return ShotInput.bodyZone(rootCFrame, emergency), 0
	end
	return ShotInput.anchor(rootCFrame, settings, stroke), if emergency then ShotInput.emergencyReach(settings) else settings.PaddleReach
end

-- The point a reach is centred on (Body: the sweet point; Anchor: the anchor itself).
function ShotInput.reachPoint(r: any): Vector3?
	if typeof(r) == "table" then
		return (r :: Zone).sweet
	end
	return r
end

-- Stretch for the launch from a reach (either model) and a contact point.
function ShotInput.reachStretch(r: any, p: Vector3): number
	if typeof(r) == "table" then
		return ShotInput.zoneStretch(r :: Zone, p)
	end
	local a = r :: Vector3
	return Vector2.new(p.X - a.X, p.Z - a.Z).Magnitude / Config.ShotControl.PaddleReach
end

-- Timing value used by the shot error model: release offset from the ideal moment, in half clean-windows.
-- -1..+1 inside the clean window; a weak contact continues linearly to -2 / +2 at the edge of its band.
function ShotInput.timingValue(offset: number): number
	local S = Config.ShotControl
	local half = math.max(S.ContactWindowDuration / 2, 1e-3)
	if offset ~= offset then
		return 0
	end
	local a = math.abs(offset)
	local v
	if a <= half then
		v = a / half
	else
		local tol = math.max(if offset < 0 then S.EarlyReleaseTolerance else S.LateReleaseTolerance, 1e-3)
		v = 1 + math.min((a - half) / tol, 1)
	end
	return if offset < 0 then -v else v
end

-- Is a contact at `p` (ball centre) with `power` a smash opportunity? (Height above the table, how far behind the
-- player's own end line, and power: Config.ShotControl.Smash*.) Timing quality is checked separately by the caller.
function ShotInput.smashEligible(p: Vector3, power: number): boolean
	local S = Config.ShotControl
	if power < S.SmashMinPower then
		return false
	end
	if p.Y - Config.Layout.SurfaceY < S.SmashMinHeight then
		return false
	end
	local behind = (p.Z - TableWorld.endLineZ("Player")) * TableWorld.towardSide("Player")
	return behind <= S.SmashMaxBehindEndLine
end

-- ATTACKABLE HIGH BALL (2026-11-18): simulate a just-hit ball (`state`) and find when it gives `receiver` ("Player" |
-- "Bot") a SMASH opportunity under the smash rule's geometry: after its one legal bounce on the receiver's half (never
-- before it: no volleys) and before a second bounce / the floor, the ball centre is at least SmashMinHeight above the
-- table, no higher than the reachable contact height (ContactZone.Normal.HighAboveFloor) and no more than
-- SmashMaxBehindEndLine behind the receiver's end line. (The flick's power and timing still decide whether a real
-- swing becomes a smash.) Returns { from, to } in seconds after `state`, or nil. Used by the server for every hit; the
-- clients only draw what the server classified.
function ShotInput.highBallWindow(state: BallPhysics.State, receiver: string, horizon: number?): { from: number, to: number, apex: number, flightApex: number }?
	local S = Config.ShotControl
	local cfg, world = TableWorld.physics, TableWorld.world
	local s = BallPhysics.copyState(state)
	s.resting = false
	local events: { BallPhysics.Event } = {}
	local endZ = TableWorld.endLineZ(receiver)
	local toward = TableWorld.towardSide(receiver)
	local surface = Config.Layout.SurfaceY
	local highY = Config.Layout.FloorY + Config.ContactZone.Normal.HighAboveFloor
	local bounced = false
	local apex = 0 -- highest centre above the table after the legal bounce
	local flightApex = state.position.Y - surface -- (Pass 12) highest centre above the table BEFORE that bounce (a lob flies high)
	local from: number?, to: number? = nil, nil
	local n = math.floor((horizon or 3) / cfg.fixedStep)
	for i = 1, n do
		local before = #events
		BallPhysics.tick(s, cfg, world, events)
		for k = before + 1, #events do
			local e = events[k]
			if e.kind == "table" then
				if e.surface == receiver then
					if bounced then
						return if from and to then { from = from, to = to, apex = apex, flightApex = flightApex } else nil -- a second bounce: the opportunity is over
					end
					bounced = true
				elseif bounced then
					return if from and to then { from = from, to = to, apex = apex, flightApex = flightApex } else nil
				end -- (a serve's first bounce on the server's own half is expected)
			elseif e.kind == "floor" or e.kind == "net" then
				return if from and to then { from = from, to = to, apex = apex, flightApex = flightApex } else nil
			end
		end
		if not bounced then
			flightApex = math.max(flightApex, s.position.Y - surface)
		end
		if bounced then
			local p = s.position
			apex = math.max(apex, p.Y - surface)
			local behind = (p.Z - endZ) * toward
			if p.Y - surface >= S.SmashMinHeight and p.Y <= highY and behind <= S.SmashMaxBehindEndLine then
				local t = i * cfg.fixedStep
				from = from or t
				to = t
			end
		end
		if s.resting then
			break
		end
	end
	return if from and to then { from = from, to = to, apex = apex, flightApex = flightApex } else nil
end

-- (Pass 12) Seconds from `state` until its flight ends for `receiver`: the first contact after its legal bounce on the
-- receiver's half (a second bounce, the floor, the net) or `horizon`. Used to time a lob's orange trail with no smash window.
function ShotInput.flightEnd(state: BallPhysics.State, receiver: string, horizon: number?): number
	local cfg, world = TableWorld.physics, TableWorld.world
	local s = BallPhysics.copyState(state)
	s.resting = false
	local events: { BallPhysics.Event } = {}
	local bounced = false
	local n = math.floor((horizon or 3) / cfg.fixedStep)
	for i = 1, n do
		local before = #events
		BallPhysics.tick(s, cfg, world, events)
		for k = before + 1, #events do
			local e = events[k]
			if e.kind == "table" and e.surface == receiver and not bounced then
				bounced = true
			elseif e.kind == "table" or e.kind == "floor" or e.kind == "net" then
				return i * cfg.fixedStep
			end
		end
		if s.resting then
			return i * cfg.fixedStep
		end
	end
	return horizon or 3
end

-- Is a ball centre at `p` inside the paddle's reach (horizontal radius + height band above the floor)?
function ShotInput.inReach(p: Vector3, anchor: Vector3, reach: number): boolean
	local R, floor = Config.Rally, Config.Layout.FloorY
	if p.Y < floor + R.ContactMinAboveFloor or p.Y > floor + R.ContactMaxAboveFloor then
		return false
	end
	return Vector2.new(p.X - anchor.X, p.Z - anchor.Z).Magnitude <= reach
end

-- ===== CLICK-AND-FLICK (2026-11-17) =====

-- PREPARATION from the cursor's screen position (fractions of the viewport: fx 0 = left edge .. 1 = right, fy 0 = top ..
-- 1 = bottom). Returns:
--   stroke   "Forehand" | "Backhand": with ShotControl.StrokeSelect = "Q" (default) always `currentStroke` (Q selects
--            it); with "Cursor", left of the dead zone = backhand, right = forehand, inside it the current stroke is kept.
--            Either stroke aims across the whole opponent's half (aim comes from the cursor alone).
--   aim      -1 .. 1 base placement across the opponent's half (cursor left = their left as you see it)
--   profile  0 (low drive) .. 1 (high arc): higher on the screen = a higher arc
--   u, v     the prepared paddle position for the arm: u -1..1 across the screen, v 0 (low) .. 1 (high)
function ShotInput.prep(fx: number, fy: number, currentStroke: string?): (string, number, number, number, number)
	local S, P = Config.ShotControl, Config.Prep
	if fx ~= fx or fy ~= fy then
		fx, fy = 0.5, 0.5
	end
	fx, fy = math.clamp(fx, 0, 1), math.clamp(fy, 0, 1)
	local f = fx - 0.5
	local dead = S.StrokeDeadZone or 0
	local stroke = currentStroke or "Forehand"
	if S.StrokeSelect == "Cursor" then -- (2026-11-18 default "Q": the Q key selects the stroke; the cursor never does)
		if f < -dead then
			stroke = "Backhand"
		elseif f > dead then
			stroke = "Forehand"
		end
	end
	local aim = math.clamp(f / math.max(P.AimHalfSpan, 1e-3), -P.AimMaxX, P.AimMaxX)
	local profile = math.clamp((P.ProfileBottom - fy) / math.max(P.ProfileBottom - P.ProfileTop, 1e-3), 0, 1)
	local u = math.clamp(f / 0.5, -1, 1)
	return stroke, aim, profile, u, profile
end

-- A recognised flick (average speed in ref px/s, unit screen direction, y DOWN) -> power 0..1, topspin, sidespin (rad/s).
-- power: MinPower at OnsetSpeed rising to 1 at FullPowerSpeed. Spin strength grows with the power (SpinAtMinPower ..
-- SpinAtFullPower) and points along the flick: up = topspin, down = backspin, right = curve to the right (negative
-- sidespin: ShotSolver's positive sidespin curves the ball to ITS left), left = curve left; diagonals split it.
function ShotInput.flickShot(speed: number, dirX: number, dirY: number): (number, number, number)
	local F = Config.Flick
	if speed ~= speed or dirX ~= dirX or dirY ~= dirY then
		return 0, 0, 0
	end
	local n = math.clamp((speed - F.OnsetSpeed) / math.max(F.FullPowerSpeed - F.OnsetSpeed, 1e-3), 0, 1)
	local power = F.MinPower + (1 - F.MinPower) * n ^ F.PowerExponent
	local mag = math.sqrt(dirX * dirX + dirY * dirY)
	if mag < 1e-6 then
		return power, 0, 0
	end
	local intensity = math.min(F.SpinAtMinPower + (F.SpinAtFullPower - F.SpinAtMinPower) * n, Config.ShotControl.MaxSpin)
	return power, intensity * (-dirY / mag), intensity * (-dirX / mag)
end

-- SERVER validation of the flick measurements a client reports ({ d = distance ref px, u = duration s, x, y = direction }).
-- Recomputes the speed itself; rejects values no recognised flick can produce (instead of clamping them into a shot).
-- Returns ok, speed, dirX, dirY, reason.
function ShotInput.validateFlick(raw: any): (boolean, number, number, number, string)
	local F = Config.Flick
	if typeof(raw) ~= "table" then
		return false, 0, 0, 0, "no flick"
	end
	local d, u, x, y = raw.d, raw.u, raw.x, raw.y
	for _, v in { d, u, x, y } do
		if typeof(v) ~= "number" or v ~= v or math.abs(v) > 1e6 then
			return false, 0, 0, 0, "bad flick values"
		end
	end
	local mag = math.sqrt(x * x + y * y)
	if mag < 0.9 or mag > 1.1 then
		return false, 0, 0, 0, "bad flick direction"
	end
	if u < F.MinElapsed * 0.99 or u > F.OnsetWindow + F.SegmentMax + 0.1 then
		return false, 0, 0, 0, "flick duration out of range"
	end
	if d < F.OnsetDistance * 0.9 then
		return false, 0, 0, 0, "flick too short"
	end
	local speed = d / u
	if speed < F.OnsetSpeed * 0.9 or speed > F.MaxSpeed then
		return false, 0, 0, 0, "flick speed out of range"
	end
	return true, speed, x / mag, y / mag, "ok"
end

-- The outer (emergency save) reach radius around the stroke's anchor.
function ShotInput.emergencyReach(settings: any): number
	local E = Config.Emergency
	return settings.PaddleReach + (if E.Enabled then E.ReachExtra else 0)
end

-- One mouse-movement event -> the relative movement (pixels, y down) to add to the drag, and where it came from.
-- Roblox reports `input.Delta` for relative movement, but with an unlocked mouse it can be (0, 0) on every event even
-- though the cursor moves (measured in Studio: positions change, Delta stays zero), so Delta alone never produced spin.
-- Rule: use Delta when it is non-zero (a locked / relative mouse); otherwise the change in the cursor position since the
-- previous movement event. `lastPos` is nil for the first event (no movement can be derived from it).
function ShotInput.movementOf(delta: Vector2, pos: Vector2, lastPos: Vector2?): (Vector2, string)
	if delta.X ~= delta.X or delta.Y ~= delta.Y or pos.X ~= pos.X or pos.Y ~= pos.Y then
		return Vector2.zero, "invalid"
	end
	if delta.X ~= 0 or delta.Y ~= 0 then
		return delta, "delta"
	end
	if lastPos then
		local d = pos - lastPos
		if d.X ~= 0 or d.Y ~= 0 then
			return d, "position"
		end
	end
	return Vector2.zero, "none"
end

-- Simulate `state` forward (exactly like the live ball) and find the paddle contact window for a paddle at `anchor`.
-- `bounced`: the ball has ALREADY bounced on the player's half (otherwise that bounce must happen in the prediction).
-- Hittable = bounced exactly once on the Player half and in reach (horizontal radius + height band). RISING OR FALLING
-- (2026-11-17 Stage 1): the old extra condition "falling, or already past the player's end line" is now
-- Config.ShotControl.RequireFallingBall (false). `requireFalling` overrides it per call: true = the old gate (kept for the
-- emergency-save ring, whose rules are unchanged, and for telemetry comparisons).
-- A high ball can pass through the reach on the way UP, leave it above the height band and come back DOWN through it:
-- each pass is a separate segment (the window is never open while the ball is out of reach) and the window is the pass
-- where the ball comes closest to the anchor (the later pass when they are within SegmentPreferLater studs).
-- Returns nil when the ball never becomes hittable within `horizon` seconds.
local SEGMENT_PREFER_LATER = 0.5

-- `anchor` is EITHER a point (Anchor model, with `reach` its radius) OR a ShotInput.Zone (Body model; `reach` ignored,
-- the ideal moment = the ball closest to the zone's sweet point). ShotInput.reachZone returns the right pair.
function ShotInput.contactWindow(
	state: BallPhysics.State,
	anchor: any,
	reach: number,
	bounced: boolean,
	horizon: number?,
	requireFalling: boolean? -- nil = Config.ShotControl.RequireFallingBall; true = only falling (or past the end line)
): Window?
	local zone: Zone? = if typeof(anchor) == "table" then anchor :: Zone else nil
	local point: Vector3 = if zone then zone.sweet else anchor :: Vector3
	local cfg, world = TableWorld.physics, TableWorld.world
	local falling = if requireFalling ~= nil then requireFalling else Config.ShotControl.RequireFallingBall == true
	local s = BallPhysics.copyState(state)
	s.resting = false
	local events: { BallPhysics.Event } = {}
	local endZ = TableWorld.endLineZ("Player")
	-- 3 s: the server predicts from the moment of the opponent's hit, and a high lob (bot pop-up) takes well over 1.5 s
	-- to bounce and fall back into reach (1.5 s made every lob "ball never in reach" on the server).
	local n = math.floor((horizon or 3) / cfg.fixedStep)
	local chosen: Window? = nil
	local chosenBest = math.huge
	local cur: any = nil -- the pass in progress: { enter, exit, ideal, best, pos }
	local function close()
		if cur then
			-- a later pass becomes the main window unless the earlier came clearly (> SEGMENT_PREFER_LATER) closer; the
			-- other pass stays hittable as `earlier` (only the two most relevant passes are kept)
			local w: Window = { enter = cur.enter, exit = cur.exit, ideal = cur.ideal, idealPosition = cur.pos }
			if not chosen then
				chosen, chosenBest = w, cur.best
			elseif cur.best <= chosenBest + SEGMENT_PREFER_LATER then
				local prev = chosen :: Window
				prev.earlier = nil
				w.earlier = prev
				chosen, chosenBest = w, cur.best
			end -- (else the earlier pass stays the main window and this later one is ignored: a contact after the main
			--      window's exit is "too late", the ball already went past the paddle once)
			cur = nil
		end
	end
	for i = 1, n do
		local before = #events
		BallPhysics.tick(s, cfg, world, events)
		local stop = false
		for k = before + 1, #events do
			local e = events[k]
			if e.kind == "table" then
				if e.surface == "Player" then
					if bounced then
						stop = true -- second bounce: nothing later is legal
					end
					bounced = true
				elseif bounced then
					stop = true
				end -- (a serve's first bounce, on the server's own half, is expected)
			elseif e.kind == "floor" then
				stop = true
			end
		end
		if stop then
			break
		end
		local t = i * cfg.fixedStep
		local p = s.position
		local inside = if zone then ShotInput.zoneContains(zone, p) else ShotInput.inReach(p, point, reach)
		local hittable = bounced and inside and (not falling or s.velocity.Y <= 0 or p.Z > endZ)
		if hittable then
			local d = Vector2.new(p.X - point.X, p.Z - point.Z).Magnitude
			if not cur then
				cur = { enter = t, exit = t, ideal = t, best = d, pos = p }
			end
			cur.exit = t
			if d < cur.best then
				cur.best, cur.ideal, cur.pos = d, t, p
			end
		elseif cur then
			close() -- left the reach zone (it may come back: keep looking)
		end
		if s.resting then
			break
		end
		-- moving away beyond any chance of coming back into reach: stop early (prediction runs every frame)
		if bounced and not cur then
			local dx, dz = p.X - point.X, p.Z - point.Z
			local extent = if zone then math.max(zone.side, zone.front, zone.back) + math.abs(zone.sweet.X - zone.center.X) + math.abs(zone.sweet.Z - zone.center.Z) else reach
			if dx * dx + dz * dz > (extent + 12) ^ 2 and (dx * s.velocity.X + dz * s.velocity.Z) > 0 then
				break
			end
		end
	end
	close()
	return chosen
end
-- The last moment a release still makes contact (clean or weak).
function ShotInput.windowEnd(w: Window): number
	local S = Config.ShotControl
	return math.min(w.exit, w.ideal + S.ContactWindowDuration / 2 + S.LateReleaseTolerance)
end

-- Judge a release `t` seconds after the window's reference state.
--   ball not in reach at t -> miss; |t - ideal| <= ContactWindowDuration/2 -> clean; up to the Early/Late tolerance
--   beyond that -> weak; further -> miss. Returns quality, reason, offset (t - ideal, seconds; negative = early).
function ShotInput.classify(t: number, w: Window?): (string, string, number)
	if not w then
		return "miss", "ball never in reach", 0
	end
	local S = Config.ShotControl
	if t < w.enter and w.earlier and t >= w.earlier.enter then
		-- before the main pass: judged against the earlier pass; a miss there (or between the passes, while the ball is
		-- above the reach) is reported as too early for the main pass
		local q, why, off = ShotInput.classify(t, w.earlier)
		if q ~= "miss" then
			return q, why, off
		end
		return "miss", "too early (ball not in reach yet)", t - w.ideal
	end
	local offset = t - w.ideal
	if t < w.enter then
		return "miss", "too early (ball not in reach yet)", offset
	elseif t > w.exit then
		return "miss", "too late (ball past the paddle)", offset
	end
	local half = S.ContactWindowDuration / 2
	if math.abs(offset) <= half then
		return "clean", "on time", offset
	elseif offset < 0 then
		return if -offset <= half + S.EarlyReleaseTolerance then "weak" else "miss", "early", offset
	else
		return if offset <= half + S.LateReleaseTolerance then "weak" else "miss", "late", offset
	end
end

return ShotInput
