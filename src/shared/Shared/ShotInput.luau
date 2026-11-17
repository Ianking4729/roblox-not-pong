--!strict
-- ShotInput: the pure rules behind the player's shot controls (HOLD TO CHARGE + DRAG TO CURVE -> RELEASE -> CONTACT).
-- Shared so the client (instant feedback, the trajectory arrow) and the server (authoritative judgement) compute the
-- SAME answers from the same numbers. No Instances, no input, no networking.
--   * dragToSpin / clampDrag: accumulated mouse drag (pixels) -> topspin / sidespin (rad/s), normalised curve, clamped
--   * contactWindow: simulates the incoming ball with the real BallPhysics and finds when it is within paddle reach
--     (after its bounce on the player's half): enter, ideal (closest to the paddle), exit
--   * classify: release time vs that window -> "clean" | "weak" | "miss"
-- Power (hold time) and the launch itself live in ShotLaunch. Nothing here reads the cursor position.

local Config = require(script.Parent:WaitForChild("Config"))
local BallPhysics = require(script.Parent:WaitForChild("BallPhysics"))
local TableWorld = require(script.Parent:WaitForChild("TableWorld"))

local ShotInput = {}

export type Window = {
	enter: number, -- seconds after the predicted-from state
	ideal: number,
	exit: number,
	idealPosition: Vector3,
}

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

-- DIVES (Config.Movement.Dive*). Which dive a horizontal direction is, relative to the court-facing direction (the
-- avatar's facing): "Back" when its backward share is at least DiveBackwardThreshold (S, S+A, S+D), else "Right" /
-- "Left" by its sideways sign. Used by the client (animation) and the server alike.
function ShotInput.diveKind(dir: Vector3, rootCFrame: CFrame): string
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 1e-3 then
		return "Right"
	end
	flat = flat.Unit
	local look = Vector3.new(rootCFrame.LookVector.X, 0, rootCFrame.LookVector.Z)
	local right = Vector3.new(rootCFrame.RightVector.X, 0, rootCFrame.RightVector.Z)
	if look.Magnitude > 1e-3 and -flat:Dot(look.Unit) >= Config.Movement.DiveBackwardThreshold then
		return "Back"
	end
	return if right.Magnitude > 1e-3 and flat:Dot(right.Unit) < 0 then "Left" else "Right"
end

-- The reach for a swing right now: the stroke's anchor and radius, extended while a dive's contact window is open
-- (`diveDir` = that dive's horizontal direction, nil when not in a dive's contact window).
function ShotInput.reachFor(rootCFrame: CFrame, settings: any, stroke: string?, diveDir: Vector3?): (Vector3?, number)
	local anchor = ShotInput.anchor(rootCFrame, settings, stroke)
	local reach = settings.PaddleReach
	if anchor and diveDir then
		local M = Config.Movement
		local flat = Vector3.new(diveDir.X, 0, diveDir.Z)
		if flat.Magnitude > 1e-3 then
			anchor += flat.Unit * M.DiveAnchorAhead
		end
		reach += M.DiveReachBonus
	end
	return anchor, reach
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

-- Is a ball centre at `p` inside the paddle's reach (horizontal radius + height band above the floor)?
function ShotInput.inReach(p: Vector3, anchor: Vector3, reach: number): boolean
	local R, floor = Config.Rally, Config.Layout.FloorY
	if p.Y < floor + R.ContactMinAboveFloor or p.Y > floor + R.ContactMaxAboveFloor then
		return false
	end
	return Vector2.new(p.X - anchor.X, p.Z - anchor.Z).Magnitude <= reach
end

-- Clamp an accumulated drag (pixels) to just past full spin, so dragging further does nothing and dragging back
-- starts reducing the spin right away (instead of first "unwinding" a huge overshoot).
function ShotInput.clampDrag(drag: Vector2): Vector2
	local S = Config.ShotControl
	local full = S.SpinDeadzonePixels + S.SpinDragPixels / math.max(S.SpinSensitivity, 1e-3)
	local limit = full + S.DragOvershootPixels
	if drag.Magnitude > limit then
		return drag.Unit * limit
	end
	return drag
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

-- Drag in screen pixels (dx right +, dy DOWN +, as Roblox reports mouse positions) -> topspin, sidespin (rad/s).
--   up = topspin, down = backspin, right = right sidespin (ball curves to the player's right), left = left sidespin.
-- Magnitude: past a small dead zone, n = distance * SpinSensitivity / SpinDragPixels (0..1), intensity =
-- n ^ SpinCurveExponent * MaxSpin, so the total spin never exceeds MaxSpin; a diagonal splits it between the axes.
-- Sidespin sign follows ShotSolver: positive curves the ball to ITS left, so "right" sidespin is negative.
function ShotInput.dragToSpin(dx: number, dy: number): (number, number, number)
	local S = Config.ShotControl
	if dx ~= dx or dy ~= dy then -- NaN
		return 0, 0, 0
	end
	local mag = math.sqrt(dx * dx + dy * dy)
	if mag <= S.SpinDeadzonePixels then
		return 0, 0, 0
	end
	local n = math.clamp((mag - S.SpinDeadzonePixels) * S.SpinSensitivity / S.SpinDragPixels, 0, 1)
	local intensity = (n ^ S.SpinCurveExponent) * S.MaxSpin
	local topspin = intensity * (-dy / mag)
	local sidespin = intensity * (-dx / mag)
	return topspin, sidespin, intensity
end

local function finish(enter: number?, exit: number?, ideal: number, pos: Vector3): Window?
	if not enter or not exit then
		return nil
	end
	return { enter = enter, exit = exit, ideal = ideal, idealPosition = pos }
end

-- Simulate `state` forward (exactly like the live ball) and find the paddle contact window for a paddle at `anchor`.
-- `bounced`: the ball has ALREADY bounced on the player's half (otherwise that bounce must happen in the prediction).
-- Hittable = bounced on the Player half, in reach, and falling or already past the player's end line (same rule as
-- the bot). Returns nil when the ball never becomes hittable within `horizon` seconds.
function ShotInput.contactWindow(
	state: BallPhysics.State,
	anchor: Vector3,
	reach: number,
	bounced: boolean,
	horizon: number?
): Window?
	local cfg, world = TableWorld.physics, TableWorld.world
	local s = BallPhysics.copyState(state)
	s.resting = false
	local events: { BallPhysics.Event } = {}
	local endZ = TableWorld.endLineZ("Player")
	-- 3 s: the server predicts from the moment of the opponent's hit, and a high lob (bot pop-up) takes well over 1.5 s
	-- to bounce and fall back into reach (1.5 s made every lob "ball never in reach" on the server).
	local n = math.floor((horizon or 3) / cfg.fixedStep)
	local enter, exit, ideal, best, bestPos = nil :: number?, nil :: number?, 0, math.huge, Vector3.zero
	for i = 1, n do
		local before = #events
		BallPhysics.tick(s, cfg, world, events)
		for k = before + 1, #events do
			local e = events[k]
			if e.kind == "table" then
				if e.surface == "Player" then
					if bounced then
						return finish(enter, exit, ideal, bestPos) -- second bounce: nothing later is legal
					end
					bounced = true
				elseif bounced then
					return finish(enter, exit, ideal, bestPos)
				end -- (a serve's first bounce, on the server's own half, is expected)
			elseif e.kind == "floor" then
				return finish(enter, exit, ideal, bestPos)
			end
		end
		local t = i * cfg.fixedStep
		local p = s.position
		local hittable = bounced and ShotInput.inReach(p, anchor, reach) and (s.velocity.Y <= 0 or p.Z > endZ)
		if hittable then
			enter = enter or t
			exit = t
			local d = Vector2.new(p.X - anchor.X, p.Z - anchor.Z).Magnitude
			if d < best then
				best, ideal, bestPos = d, t, p
			end
		elseif enter then
			break -- left the reach zone
		end
		if s.resting then
			break
		end
	end
	return finish(enter, exit, ideal, bestPos)
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
