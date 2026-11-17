--!strict
-- MouseSwing (pure; no Instances, no input): the MOUSE-ONLY rally prototype's classifier (2026-11-17,
-- Config.ShotControl.RallyInput = "MouseOnly"). It watches free cursor movement and separates
--   A. moving the paddle into position (including fast forehand <-> backhand switches)  -> nothing (preparation)
--   B. a deliberate flick                                                               -> a "flick" event (the swing)
-- It never decides WHEN a swing may count (the shot controller only feeds it while the ball is coming, and only accepts
-- a flick whose contact falls in the attempt zone); it only decides WHAT the movement was.
--
-- Rules (tunables: Config.MouseOnlyRally; the flick itself is measured by Shared/FlickGesture with Config.Flick, the same
-- thresholds as click-to-lock):
--   1. A flick candidate starts when FlickGesture recognises an onset ("onset" event: the controller freezes the
--      preparation and may show a reversible wind-up).
--   2. SHORT vs SUSTAINED. A flick is a short burst that ends by slowing down or turning. When the measurement instead
--      runs out of time (SegmentMax) with the hand still moving, the next SweepCheck seconds decide: if the hand keeps
--      going the same way at >= SweepFraction of the flick's speed, it was a SWEEP (a reposition): "discard". Otherwise
--      the flick stands.
--      And a movement longer than MaxFlickDistance (flicks are ~40-300 ref px; crossing the screen is far more) is a
--      sweep however it ends.
--   3. After a discarded sweep (or an accepted / rejected flick, or a cursor warp) nothing can start until the movement
--      SETTLES: a pause of QuietGap, a sample slower than QuietSpeed, or a turn of more than QuietTurnDeg away from the
--      previous movement (so "switch stance, then flick up" needs no pause, while the tail of a sweep never becomes a swing).
--   4. A single movement event longer than WarpPixels (a cursor warp / reset / focus return) is never movement: the
--      candidate is dropped and the classifier settles first.
-- Genuinely ambiguous: a short, fast sideways reposition (e.g. ~100 ref px in ~60 ms across the screen centre) has the
-- same shape as a sideways flick; inside the attempt zone it IS taken as a swing.
--
-- Feed:  m:add(t, tPrev, dx, dy) per movement event (ref px, y down; the same units as FlickGesture) and m:update(t) per
-- frame. Both return an event or nil:
--   { kind = "onset", startT, onsetEventT }                 a candidate began (startT = the flick's start, os.clock)
--   { kind = "flick", flick = FlickGesture.Flick }          the candidate is a flick (the swing)
--   { kind = "discard", reason = "sweep" | "invalid" | "warp", flick = Flick? }

local Config = require(script.Parent:WaitForChild("Config"))
local FlickGesture = require(script.Parent:WaitForChild("FlickGesture"))

local MouseSwing = {}
MouseSwing.__index = MouseSwing

export type Event = { kind: string, startT: number?, onsetEventT: number?, flick: FlickGesture.Flick?, reason: string? }

export type Classifier = typeof(setmetatable(
	{} :: {
		state: string, -- "watch" (detector running) | "check" (sweep check) | "quiet" (settling)
		detector: FlickGesture.Detector,
		inCandidate: boolean, -- the detector has an onset (between "onset" and "flick"/"discard")
		pending: FlickGesture.Flick?, -- the flick under the sweep check
		checkProj: number, -- movement along the pending flick's direction since its end (ref px)
		quietDirX: number,
		quietDirY: number,
		lastMoveT: number,
		P: any,
		FP: any,
		stats: { [string]: number },
	},
	MouseSwing
))

function MouseSwing.new(params: any?, flickParams: any?): Classifier
	local self = setmetatable({
		state = "watch",
		detector = FlickGesture.new(flickParams),
		inCandidate = false,
		pending = nil,
		checkProj = 0,
		quietDirX = 0,
		quietDirY = 0,
		lastMoveT = -math.huge,
		P = params or Config.MouseOnlyRally,
		FP = flickParams or Config.Flick,
		stats = { onsets = 0, flicks = 0, sweeps = 0, warps = 0, invalid = 0 },
	}, MouseSwing)
	return self
end

local function finite(n: number): boolean
	return n == n and math.abs(n) < 1e9
end

-- Settle before anything new can start; `dx, dy` = the movement direction to compare a turn against (0, 0 = none).
function MouseSwing.settle(self: Classifier, dx: number, dy: number)
	local len = math.sqrt(dx * dx + dy * dy)
	self.state = "quiet"
	self.quietDirX, self.quietDirY = if len > 1e-6 then dx / len else 0, if len > 1e-6 then dy / len else 0
	self.inCandidate = false
	self.pending = nil
	self.detector = FlickGesture.new(self.FP)
end

-- The controller rejected an onset / flick (outside the attempt zone, wrong state): settle, nothing more from it.
function MouseSwing.reject(self: Classifier, dirX: number?, dirY: number?)
	self:settle(dirX or 0, dirY or 0)
end

-- Forget everything (reset, respawn, focus loss, the ball changed). No settling needed: the next sample starts fresh.
function MouseSwing.reset(self: Classifier)
	self.state = "watch"
	self.inCandidate = false
	self.pending = nil
	self.lastMoveT = -math.huge
	self.detector = FlickGesture.new(self.FP)
end

function MouseSwing.candidate(self: Classifier): boolean
	return self.inCandidate or self.state == "check"
end

-- The detector produced a flick: accept it now, or start the sweep check when it ran out of time while still moving.
function MouseSwing._closed(self: Classifier, flick: FlickGesture.Flick): Event?
	if flick.distance > self.P.MaxFlickDistance then
		self.stats.sweeps += 1 -- too long for a flick: a reposition
		self:settle(flick.dirX, flick.dirY)
		return { kind = "discard", reason = "sweep", flick = flick }
	end
	if flick.closedBy == "timeout" and self.P.SweepCheck > 0 then
		self.state = "check"
		self.pending = flick
		self.checkProj = 0
		return nil
	end
	self.stats.flicks += 1
	self:settle(flick.dirX, flick.dirY)
	return { kind = "flick", flick = flick }
end

function MouseSwing._afterDetector(self: Classifier, flick: FlickGesture.Flick?): Event?
	if flick then
		return self:_closed(flick)
	end
	local d = self.detector
	if d.state == "invalid" then
		self.stats.invalid += 1
		local was = self.inCandidate
		self:settle(0, 0)
		return if was then { kind = "discard", reason = "invalid" } else nil
	end
	if d.state == "segment" and not self.inCandidate then
		self.inCandidate = true
		self.stats.onsets += 1
		local startT, eventT = d:onset()
		return { kind = "onset", startT = startT, onsetEventT = eventT }
	end
	return nil
end

-- Sweep check verdict at time t (or earlier when the continuation already proves a sweep).
function MouseSwing._checkVerdict(self: Classifier, t: number, final: boolean): Event?
	local f = self.pending :: FlickGesture.Flick
	local P = self.P
	local need = P.SweepFraction * f.speed * P.SweepCheck -- ref px the hand must keep moving the same way
	if self.checkProj >= need or f.distance + self.checkProj > P.MaxFlickDistance then
		self.stats.sweeps += 1
		self:settle(f.dirX, f.dirY)
		return { kind = "discard", reason = "sweep", flick = f }
	end
	if final or t - f.endT >= P.SweepCheck then
		self.stats.flicks += 1
		self:settle(f.dirX, f.dirY)
		return { kind = "flick", flick = f }
	end
	return nil
end

function MouseSwing.add(self: Classifier, t: number, tPrev: number, dx: number, dy: number): Event?
	if not (finite(t) and finite(tPrev) and finite(dx) and finite(dy)) then
		return nil
	end
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 then
		return nil
	end
	local P = self.P
	local gapBefore = t - self.lastMoveT
	self.lastMoveT = t
	if len > P.WarpPixels then
		-- a cursor warp / reset / focus return: never movement
		self.stats.warps += 1
		local was = self:candidate()
		self:settle(0, 0)
		return if was then { kind = "discard", reason = "warp" } else nil
	end
	if self.state == "check" then
		local f = self.pending :: FlickGesture.Flick
		self.checkProj += dx * f.dirX + dy * f.dirY
		return self:_checkVerdict(t, false)
	end
	if self.state == "quiet" then
		local elapsed = math.max(t - tPrev, self.FP.MinElapsed)
		local speed = len / elapsed
		local cos = (dx * self.quietDirX + dy * self.quietDirY) / len
		local turned = (self.quietDirX ~= 0 or self.quietDirY ~= 0) and cos < math.cos(math.rad(P.QuietTurnDeg))
		if gapBefore >= P.QuietGap or speed < P.QuietSpeed or turned then
			self.state = "watch" -- settled: this sample may begin the next gesture
		else
			return nil
		end
	end
	return self:_afterDetector(self.detector:add(t, tPrev, dx, dy))
end

function MouseSwing.update(self: Classifier, t: number): Event?
	if self.state == "check" then
		return self:_checkVerdict(t, false)
	end
	if self.state == "quiet" then
		if t - self.lastMoveT >= self.P.QuietGap then
			self.state = "watch"
		end
		return nil
	end
	return self:_afterDetector(self.detector:update(t))
end

return MouseSwing
