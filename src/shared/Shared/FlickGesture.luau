--!strict
-- FlickGesture: recognises ONE coherent mouse flick from timestamped relative movement (pure; no Instances, no input).
-- Used by the client (Client/ShotController) while a shot is committed; the server re-validates the measurements it
-- reports (ShotInput.validateFlick). Tunables: Config.Flick (see its header for why the defaults separate a flick from
-- ordinary hand movement).
--
-- Feed it one sample per relative-movement event:  g:add(t, tPrev, dx, dy)
--   t      os.clock() when the event was handled
--   tPrev  the time of the previous rendered frame (input is delivered in frame batches, so a movement event's movement
--          happened between the previous frame and now): elapsed = t - tPrev, floored at MinElapsed. Velocity always
--          comes from elapsed time, never from event or frame counts, so the result does not depend on the frame rate or
--          the mouse's event rate.
--   dx, dy movement in REFERENCE pixels (screen px x ReferenceHeight / viewport height; y down)
-- and call g:update(t) once per frame (it closes a segment when the movement pauses or the segment times out).
-- Both return a Flick table once, the moment the gesture is finalised; afterwards the detector is "done" (one flick per
-- commitment: make a new detector for the next click).
--
-- Recognition: a START needs, inside the last OnsetWindow seconds, net movement >= OnsetDistance, average speed >=
-- OnsetSpeed and coherence >= Coherence (moves smaller than JitterPixels are ignored for this). The flick's SEGMENT
-- begins at the first moving sample of that window and grows until the movement slows below SegmentEndFraction of its
-- peak, turns more than SegmentMaxTurnDeg, pauses for SegmentGap, or SegmentMax seconds after the start was detected
-- (2026-11-18: or, with Config.Flick.MeasureTime, once it has measured MeasureTime seconds from the flick's start: a short
-- bounded measurement, so the swing is not held back waiting for the hand to stop).
-- Its average speed (net distance / elapsed) and direction are the result. A sample faster than MaxSpeed is invalid:
-- the whole gesture is rejected (state "invalid"), never clamped into a shot.

local Config = require(script.Parent:WaitForChild("Config"))

local FlickGesture = {}
FlickGesture.__index = FlickGesture

export type Flick = {
	startT: number, -- os.clock() the flick started (the swing moment; contact = startT + Flick.ContactDelay)
	detectT: number, -- when the start was recognised
	endT: number, -- when the segment was closed (the swing is sent at this time)
	closedBy: string, -- why the segment closed: "slow" | "turn" | "gap" | "measured" (MeasureTime) | "timeout" (SegmentMax)
	onsetEventT: number, -- when the segment's first sample was handled (preparation recorded before this is pre-flick)
	distance: number, -- ref px, net
	duration: number, -- s, elapsed over the segment
	speed: number, -- ref px/s = distance / duration
	dirX: number, -- unit direction on screen (x right, y DOWN)
	dirY: number,
}

type Sample = { t: number, tPrev: number, dx: number, dy: number, len: number }

export type Detector = typeof(setmetatable(
	{} :: {
		state: string, -- "idle" (watching) | "segment" (measuring a flick) | "done" | "invalid"
		stats: { [string]: number }, -- diagnostics only
		samples: { Sample },
		segStart: number, -- index of the segment's first sample
		detectT: number,
		peak: number,
		lastMoveT: number,
		result: Flick?,
		reason: string,
		P: any,
	},
	FlickGesture
))

function FlickGesture.new(params: any?): Detector
	local self = setmetatable({
		state = "idle",
		samples = {},
		segStart = 0,
		detectT = 0,
		peak = 0,
		lastMoveT = -math.huge,
		result = nil,
		reason = "",
		P = params or Config.Flick,
		-- DIAGNOSTICS ONLY (never read by the recogniser): how close the hand's movement came to a flick while no flick was
		-- recognised, so telemetry can tell "tried to flick but failed recognition" from "did not flick"
		stats = { events = 0, jitterEvents = 0, maxNet = 0, maxSpeed = 0, coherenceAtMax = 0, maxMove = 0, pathTotal = 0 },
	}, FlickGesture)
	return self
end

local function finite(n: number): boolean
	return n == n and math.abs(n) < 1e9
end

-- elapsed time covered by samples i..j (the movement of sample i happened after its tPrev)
local function span(samples: { Sample }, i: number, j: number, minElapsed: number): number
	local e = samples[j].t - samples[i].tPrev
	return math.max(e, minElapsed * (j - i + 1))
end

local function sum(samples: { Sample }, i: number, j: number): (number, number, number)
	local sx, sy, path = 0, 0, 0
	for k = i, j do
		local s = samples[k]
		sx += s.dx
		sy += s.dy
		path += s.len
	end
	return sx, sy, path
end

-- While measuring ("segment"): when the flick's first sample happened (its tPrev, the flick's start) and was handled.
function FlickGesture.onset(self: Detector): (number?, number?)
	if self.state ~= "segment" then
		return nil, nil
	end
	local s = self.samples[self.segStart]
	return s and s.tPrev, s and s.t
end

function FlickGesture.finish(self: Detector, t: number, closedBy: string?): Flick?
	local P = self.P
	local samples = self.samples
	local i, j = self.segStart, #samples
	local sx, sy = sum(samples, i, j)
	local dist = math.sqrt(sx * sx + sy * sy)
	local dur = span(samples, i, j, P.MinElapsed)
	if dist < 1e-6 then
		self.state, self.reason = "invalid", "no movement"
		return nil
	end
	local speed = dist / dur
	if not finite(speed) or speed > P.MaxSpeed then
		self.state, self.reason = "invalid", "speed out of range"
		return nil
	end
	local flick: Flick = {
		startT = samples[i].tPrev,
		detectT = self.detectT,
		endT = t,
		closedBy = closedBy or "timeout",
		onsetEventT = samples[i].t,
		distance = dist,
		duration = dur,
		speed = speed,
		dirX = sx / dist,
		dirY = sy / dist,
	}
	self.state, self.result = "done", flick
	return flick
end

-- One relative-movement sample. Returns the finished Flick when this sample closes the segment.
function FlickGesture.add(self: Detector, t: number, tPrev: number, dx: number, dy: number): Flick?
	if self.state == "done" or self.state == "invalid" then
		return nil
	end
	local P = self.P
	if not (finite(t) and finite(tPrev) and finite(dx) and finite(dy)) then
		return nil -- a malformed event is dropped
	end
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 then
		return nil
	end
	local elapsed = math.max(t - tPrev, P.MinElapsed)
	if len / elapsed > P.MaxSpeed then
		self.state, self.reason = "invalid", "sample faster than MaxSpeed"
		return nil
	end
	local samples = self.samples
	table.insert(samples, { t = t, tPrev = math.min(tPrev, t), dx = dx, dy = dy, len = len })
	self.lastMoveT = t
	local st0 = self.stats
	st0.events += 1
	st0.pathTotal += len
	if len < P.JitterPixels then
		st0.jitterEvents += 1
	end
	st0.maxMove = math.max(st0.maxMove, len)

	if self.state == "idle" then
		-- drop samples older than the onset window (keeps the list short while the player holds still)
		while #samples > 0 and samples[1].t < t - P.OnsetWindow do
			table.remove(samples, 1)
		end
		-- the window's moving samples (jitter-sized moves do not count toward a start)
		local first = nil
		for k = 1, #samples do
			if samples[k].len >= P.JitterPixels then
				first = k
				break
			end
		end
		if not first then
			return nil
		end
		local sx, sy, path = sum(samples, first, #samples)
		local net = math.sqrt(sx * sx + sy * sy)
		local speed = net / span(samples, first, #samples, P.MinElapsed)
		local coherent = path > 0 and net / path >= P.Coherence
		local st = self.stats
		if speed > st.maxSpeed then
			st.maxSpeed = speed
		end
		if net > st.maxNet then
			st.maxNet = net
			st.coherenceAtMax = if path > 0 then net / path else 0
		end
		if net >= P.OnsetDistance and speed >= P.OnsetSpeed and coherent then
			self.state = "segment"
			self.segStart = first
			self.detectT = t
			self.peak = speed
			-- (MeasureTime) a slow frame can already cover the whole measurement: finalise now
			if P.MeasureTime and t - samples[first].tPrev >= P.MeasureTime then
				return self:finish(t, "measured")
			end
		end
		return nil
	end

	-- measuring: does this sample continue the flick?
	local i = self.segStart
	local sx, sy = sum(samples, i, #samples - 1)
	local segLen = math.sqrt(sx * sx + sy * sy)
	local instSpeed = len / elapsed
	local turnCos = if segLen > 0 then (dx * sx + dy * sy) / (len * segLen) else 1
	local slow = instSpeed < P.SegmentEndFraction * self.peak
	if slow or turnCos < math.cos(math.rad(P.SegmentMaxTurnDeg)) then
		table.remove(samples) -- this sample is the hand slowing / turning back: not part of the flick
		return self:finish(t, if slow then "slow" else "turn")
	end
	self.peak = math.max(self.peak, instSpeed)
	if P.MeasureTime and t - samples[i].tPrev >= P.MeasureTime then
		return self:finish(t, "measured") -- the short bounded measurement is complete
	end
	if t - self.detectT >= P.SegmentMax then
		return self:finish(t, "timeout")
	end
	return nil
end

-- Per frame: closes a segment that paused or timed out. Returns the Flick when it does.
function FlickGesture.update(self: Detector, t: number): Flick?
	if self.state ~= "segment" then
		return nil
	end
	local P = self.P
	local s = self.samples[self.segStart]
	if t - self.lastMoveT >= P.SegmentGap then
		return self:finish(t, "gap")
	elseif P.MeasureTime and s and t - s.tPrev >= P.MeasureTime then
		return self:finish(t, "measured")
	elseif t - self.detectT >= P.SegmentMax then
		return self:finish(t, "timeout")
	end
	return nil
end

return FlickGesture
