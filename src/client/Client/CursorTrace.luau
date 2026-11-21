-- CursorTrace (client, cosmetic; Config.Feedback.CursorTrace, 2026-11-18): draws what the hand ACTUALLY did during a
-- committed flick, as a short screen-space trace around the held cursor. Replaces the Curve bar and the flick dial's
-- idealised spin arrow.
--
-- Input: the shot controller's `traceSamples` (the very relative-movement samples its flick detector received, plus a
-- short display-only tail after the flick), read every frame. The real cursor is held in place while committed, so the
-- trace is VIRTUAL: cumulative movement x Scale from the held point, shrunk uniformly to stay inside MaxRadius. It never
-- moves the cursor and never feeds anything back into the shot.
-- Look: one pooled frame per sample segment; thickness / brightness from each sample's speed (Flick.OnsetSpeed ..
-- FullPowerSpeed); the measured flick bright, the hold drift before it and the tail after it faint; a small arrowhead at
-- the end; everything fades FadeTime after the stroke. Cyan, so it never reads as the purple world-space arrow.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local CursorTrace = {}

local C = Config.Feedback.CursorTrace
local SIZE = C.Size or 1 -- visual size multiplier (Config.Feedback.CursorTrace.Size)
local F = Config.Flick

function CursorTrace.new(screen: ScreenGui, controller: any)
	local root = Instance.new("Frame")
	root.Name = "CursorTrace"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(0, 0)
	root.Visible = false
	root.Parent = screen
	local segs: { Frame } = {}
	for i = 1, C.MaxSegments do
		local f = Instance.new("Frame")
		f.Name = "S" .. i
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = C.Color
		f.Visible = false
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = f
		f.Parent = root
		segs[i] = f
	end
	local headBox = Instance.new("Frame") -- arrowhead: a rotated square centred on the trace's end
	headBox.Name = "HeadBox"
	headBox.AnchorPoint = Vector2.new(0.5, 0.5)
	headBox.Size = UDim2.fromOffset(math.floor(9 * SIZE + 0.5), math.floor(9 * SIZE + 0.5))
	headBox.BorderSizePixel = 0
	headBox.BackgroundColor3 = C.Color
	headBox.Visible = false
	headBox.Parent = root

	local self = {}
	local origin = Vector2.zero
	local fadeFrom = -math.huge -- os.clock() the stroke ended (fade start); -huge = live
	local active = false

	function self.begin(at: Vector2)
		origin = at
		fadeFrom = -math.huge
		active = C.Enabled == true
	end
	function self.finish()
		if active and fadeFrom == -math.huge then
			fadeFrom = os.clock() + (C.TailTime or 0)
		end
	end
	function self.cancel()
		active = false
		root.Visible = false
	end
	-- a commitment that ended without a flick for any reason (respawn, point reset...): drop a trace still being drawn live
	function self.dropIfLive()
		if active and fadeFrom == -math.huge then
			self.cancel()
		end
	end
	function self.isActive(): boolean
		return active
	end

	local lastInfo: any = nil
	function self.debug(): any
		return lastInfo
	end

	function self.step()
		if not active then
			root.Visible = false
			return
		end
		local now = os.clock()
		local alpha = 1
		if fadeFrom ~= -math.huge then
			alpha = 1 - math.clamp((now - fadeFrom) / math.max(C.FadeTime, 1e-3), 0, 1)
			if alpha <= 0 then
				active = false
				root.Visible = false
				return
			end
		end
		local samples = controller.traceSamples or {}
		local flick = controller.flick
		local fStart = flick and flick.startT or math.huge
		local fEnd = flick and flick.endT or math.huge
		-- which samples to draw: the last Window seconds before the flick (or before now) through the tail
		local anchorT = if flick then fStart else now
		local first = 1
		for i = #samples, 1, -1 do
			if samples[i].t < anchorT - C.Window then
				first = i + 1
				break
			end
		end
		local count = #samples - first + 1
		if count > C.MaxSegments then
			first = #samples - C.MaxSegments + 1
			count = C.MaxSegments
		end
		-- cumulative positions (screen px) from the held point, then shrink uniformly into MaxRadius
		local camera = workspace.CurrentCamera
		local h = camera and camera.ViewportSize.Y or 1080
		local k = C.Scale * SIZE * h / F.ReferenceHeight -- ref px -> screen px
		local pts: { Vector2 } = { Vector2.zero }
		local maxR = 0
		local acc = Vector2.zero
		for i = first, #samples do
			local s = samples[i]
			acc += Vector2.new(s.dx, s.dy) * k
			table.insert(pts, acc)
			maxR = math.max(maxR, acc.Magnitude)
		end
		local maxRadius = C.MaxRadius * SIZE
		local shrink = if maxR > maxRadius then maxRadius / maxR else 1
		root.Visible = true
		root.Position = UDim2.fromOffset(origin.X, origin.Y)
		for i = 1, C.MaxSegments do
			local seg = segs[i]
			local si = first + i - 1
			if i <= count and pts[i + 1] then
				local a, b = pts[i] * shrink, pts[i + 1] * shrink
				local d = b - a
				local len = d.Magnitude
				local s = samples[si]
				local speed = s.speed or 0
				local n = math.clamp((speed - F.OnsetSpeed) / math.max(F.FullPowerSpeed - F.OnsetSpeed, 1), 0, 1)
				local measured = s.t >= fStart - 1e-4 and s.t <= fEnd + 1e-4
				local thickness = (C.MinThickness + (C.MaxThickness - C.MinThickness) * (if measured then n else n * 0.4)) * SIZE
				local base = if measured then 0.05 + 0.35 * (1 - n) else C.FaintTransparency
				seg.Visible = len > 0.3
				seg.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
				seg.Size = UDim2.fromOffset(len + thickness * 0.6, thickness)
				seg.Rotation = math.deg(math.atan2(d.Y, d.X))
				seg.BackgroundTransparency = 1 - (1 - base) * alpha
			else
				seg.Visible = false
			end
		end
		-- arrowhead at the end of the drawn trace, pointing along its last movement
		local endP = pts[#pts] * shrink
		local prevP = pts[math.max(#pts - 1, 1)] * shrink
		local d = endP - prevP
		local showHead = #pts >= 3 and d.Magnitude > 0.5 and (endP.Magnitude > 6 * SIZE)
		headBox.Visible = showHead
		if showHead then
			headBox.Position = UDim2.fromOffset(endP.X, endP.Y)
			headBox.Rotation = math.deg(math.atan2(d.Y, d.X)) + 45
			headBox.BackgroundTransparency = 1 - 0.95 * alpha
		end
		lastInfo = { points = #pts - 1, endX = endP.X, endY = endP.Y, shrink = shrink, alpha = alpha, rawEnd = acc }
	end

	return self
end

return CursorTrace
