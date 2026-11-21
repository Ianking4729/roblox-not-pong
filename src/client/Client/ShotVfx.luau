-- ShotVfx (client, cosmetic; Config.Feedback.ShotVfx, 2026-11-19): contact accents and a paddle swing trail for the
-- local player's strokes, from the SyphoDev texture pack (assets/vfx/MANIFEST.md lists the six textures used).
--   soft return    a small, brief glint
--   strong return  the glint + a soft starburst, sized / brightened by the shot's power; a short paddle trail
--   smash          a bold burst + radial lines and a gold trail following the paddle's real downward swing
--   emergency save a soft cyan ring (the scoop)
-- Timing and placement: ONE accent per swing (keyed by its request seq), shown at the predicted contact moment and point
-- (the paddle and the predicted ball response arrive then); cancelled if the server's verdict is a miss before it shows;
-- shown at the SERVER's contact point if only the server's reply says it was a hit. No duplicate predicted + confirmed
-- bursts. The trail is a Trail between two attachments on the paddle blade, enabled only from the stroke's onset / swing
-- to the end of its follow-through, so it draws the actual arm motion.
-- Efficiency: one pooled holder part with five rate-0 emitters (Emit() per hit, nothing created per hit), one Trail per
-- character, no lights, no per-frame searches (the blade is found once per character).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ShotVfx = {}

local function seq(...: any): NumberSequence
	local args = { ... }
	local kps = {}
	for i = 1, #args, 2 do
		table.insert(kps, NumberSequenceKeypoint.new(args[i], args[i + 1]))
	end
	return NumberSequence.new(kps)
end

function ShotVfx.start(player: Player, controller: any)
	local V = Config.Feedback.ShotVfx
	if not V or not V.Enabled then
		return nil
	end
	local T = V.Textures

	-- ---------- pooled contact emitters ----------
	local holder = Instance.new("Part")
	holder.Name = "NotPongShotVfx"
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Transparency = 1
	holder.Anchored, holder.CanCollide, holder.CanQuery, holder.CanTouch, holder.CastShadow = true, false, false, false, false
	holder.Parent = workspace.CurrentCamera
	local function emitter(name: string, texture: string, lifetime: number, size: NumberSequence, transparency: NumberSequence): ParticleEmitter
		local e = Instance.new("ParticleEmitter")
		e.Name = name
		e.Texture = texture
		e.Rate = 0
		e.Speed = NumberRange.new(0)
		e.Lifetime = NumberRange.new(lifetime)
		e.Size = size
		e.Transparency = transparency
		e.LightEmission = 1
		e.LightInfluence = 0
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-40, 40)
		e.ZOffset = -1 -- (drawn a little behind the ball / ring)
		e.Parent = holder
		return e
	end
	local glint = emitter("Glint", T.Glint, 0.12, seq(0, 1.6, 1, 3.2), seq(0, 0.1, 1, 1))
	local burst = emitter("Burst", T.Burst, 0.16, seq(0, 2, 1, 5), seq(0, 0.25, 1, 1))
	local smash = emitter("Smash", T.SmashBurst, 0.2, seq(0, 3, 1, 7.5), seq(0, 0.1, 0.6, 0.5, 1, 1))
	local lines = emitter("Lines", T.SmashLines, 0.18, seq(0, 4, 1, 9.5), seq(0, 0.3, 1, 1))
	lines.Rotation = NumberRange.new(0)
	lines.RotSpeed = NumberRange.new(0)
	local ring = emitter("Ring", T.ScoopRing, 0.26, seq(0, 2.5, 1, 6), seq(0, 0.35, 1, 1))
	ring.Rotation = NumberRange.new(0)

	local stats = { played = 0, cancelled = 0, late = 0, lastClass = nil :: string?, lastAt = nil :: Vector3?, trails = 0 }

	local function classify(data: any): (string, number)
		if data.kind == "emergency" then
			return "scoop", 1
		elseif data.smash then
			return "smash", 1
		end
		local power = if typeof(data.power) == "number" then data.power else 0.5
		local k = math.clamp((power - V.StrongPower) / math.max(1 - V.StrongPower, 1e-3), 0, 1)
		return if power >= V.StrongPower then "strong" else "soft", k
	end

	local baseLife = { [glint] = 0.12, [burst] = 0.16, [smash] = 0.2, [lines] = 0.18, [ring] = 0.26 }
	local function play(pos: Vector3, class: string, k: number)
		holder.CFrame = CFrame.new(pos)
		local scale = V.ReviewScale or 1 -- REVIEW ONLY (> 1 stretches the effects to capture stills)
		for e, life in baseLife do
			e.Lifetime = NumberRange.new(life * scale)
		end
		if trail then
			trail.Lifetime = V.TrailLifetime * scale
		end
		stats.played += 1
		stats.lastClass, stats.lastAt = class, pos
		local C = V.Colors
		if class == "scoop" then
			ring.Color = ColorSequence.new(C.Scoop)
			ring:Emit(1)
		elseif class == "smash" then
			smash.Color = ColorSequence.new(C.Smash)
			lines.Color = ColorSequence.new(C.Smash)
			smash:Emit(1)
			lines:Emit(1)
			glint.Color = ColorSequence.new(Color3.new(1, 1, 1))
			glint:Emit(1)
		elseif class == "strong" then
			burst.Color = ColorSequence.new(C.Soft:Lerp(C.Strong, k))
			burst.Size = seq(0, 2 + 1.2 * k, 1, 4 + 2 * k)
			burst:Emit(1)
			glint.Color = ColorSequence.new(C.Soft)
			glint:Emit(1)
		else
			glint.Color = ColorSequence.new(C.Soft)
			glint:Emit(1)
		end
	end

	-- ---------- paddle trail ----------
	local trail: Trail? = nil
	local trailUntil = -math.huge
	local function ensureTrail(): Trail?
		if trail and trail.Parent then
			return trail
		end
		local character = player.Character
		local paddle = character and character:FindFirstChild("Paddle", true)
		if not paddle then
			return nil
		end
		local blade: BasePart? = nil
		for _, name in { "WoodBlade", "Blade", "FrontRubber" } do
			local b = paddle:FindFirstChild(name, true)
			if b and b:IsA("BasePart") then
				blade = b
				break
			end
		end
		if not blade then
			local best = 0
			for _, d in paddle:GetDescendants() do
				if d:IsA("BasePart") and d.Size.Magnitude > best then
					blade, best = d, d.Size.Magnitude
				end
			end
		end
		if not blade then
			return nil
		end
		-- attachments across the blade's longest face axis: the ribbon is as wide as the blade
		local s = blade.Size
		local axis = if s.X >= s.Y and s.X >= s.Z then Vector3.xAxis elseif s.Y >= s.Z then Vector3.yAxis else Vector3.zAxis
		local half = math.max(s.X, s.Y, s.Z) / 2 * 0.9
		local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
		a0.Name, a1.Name = "NotPongTrailA", "NotPongTrailB"
		a0.Position, a1.Position = axis * half, -axis * half
		a0.Parent, a1.Parent = blade, blade
		local t = Instance.new("Trail")
		t.Name = "NotPongSwingTrail"
		t.Attachment0, t.Attachment1 = a0, a1
		t.Texture = T.Trail
		t.TextureMode = Enum.TextureMode.Stretch
		t.LightEmission = 0.8
		t.LightInfluence = 0
		t.Lifetime = V.TrailLifetime
		t.MinLength = 0.05
		t.FaceCamera = true -- (reads as a streak from the gameplay camera behind the player)
		t.Enabled = false
		t.Parent = blade
		trail = t
		return t
	end
	local function startTrail(class: string, k: number, untilServer: number)
		if class ~= "smash" and class ~= "strong" then
			return
		end
		local t = ensureTrail()
		if not t then
			return
		end
		local C = V.Colors
		local color = if class == "smash" then C.Smash else C.Soft:Lerp(C.Strong, k)
		local base = if class == "smash" then 0.15 else 0.55 - 0.25 * k
		t.Color = ColorSequence.new(color)
		t.Transparency = seq(0, base, 1, 1)
		t.Lifetime = V.TrailLifetime * (V.ReviewScale or 1) -- (ReviewScale: review only)
		if not t.Enabled then
			t:Clear()
			t.Enabled = true
			stats.trails += 1
		end
		trailUntil = math.max(trailUntil, untilServer)
	end
	local function stopTrail()
		if trail then
			trail.Enabled = false
		end
		trailUntil = -math.huge
	end

	-- ---------- events ----------
	local pending: any = nil -- { seq, t (server time), pos, class, k }
	local done: { [number]: boolean } = {}
	controller.on(function(event: string, data: any)
		if event == "onset" and data and data.smash then
			-- the smash's trail starts with the stroke itself (the onset), so it covers the whole downward swing
			startTrail("smash", 1, (data.contactT or workspace:GetServerTimeNow()) + V.TrailAfterContact.smash)
		elseif event == "swing" and data and not data.serve then
			local class, k = classify(data)
			local seqId = data.seq
			if data.quality ~= "miss" and typeof(data.contact) == "Vector3" and typeof(data.contactT) == "number" and seqId and not done[seqId] then
				pending = { seq = seqId, t = data.contactT, pos = data.contact, class = class, k = k }
			end
			startTrail(class, k, (data.contactT or workspace:GetServerTimeNow()) + (V.TrailAfterContact[class] or 0.15))
		elseif event == "result" and data and not (data.msg and data.msg.serve) then -- (serves get no accent)
			local msg = data.msg
			local seqId = msg and msg.seq
			local hit = data.result == "clean" or data.result == "weak"
			if pending and pending.seq == seqId and not hit then
				pending = nil -- the server says it was not a hit: no accent
				stats.cancelled += 1
			elseif hit and seqId and not done[seqId] and not (pending and pending.seq == seqId) and typeof(msg.contact) == "Vector3" then
				-- the client did not expect a hit but the server confirms one: show it now at the server's contact
				done[seqId] = true
				stats.late += 1
				local class, k = classify({ kind = msg.kind, smash = msg.smash, power = msg.power })
				play(msg.contact, class, k)
			end
		elseif event == "reset" or event == "cancel" then
			if controller.state == "IDLE" and pending and workspace:GetServerTimeNow() > pending.t + 0.5 then
				pending = nil
			end
		end
	end)
	RunService.RenderStepped:Connect(function()
		local now = workspace:GetServerTimeNow()
		local p = pending
		if p and now >= p.t then
			pending = nil
			if not done[p.seq] then
				done[p.seq] = true
				play(p.pos, p.class, p.k)
			end
		end
		if trail and trail.Enabled and now > trailUntil then
			trail.Enabled = false
		end
	end)
	player.CharacterAdded:Connect(function()
		pending = nil
		stopTrail()
		trail = nil -- (the old blade went with the old character)
	end)

	local self = {}
	function self.stats()
		return table.clone(stats)
	end
	function self.clear()
		pending = nil
		stopTrail()
	end
	if Config.ShotControl.ShowDiagnostics then
		local bridge = Instance.new("BindableFunction")
		bridge.Name = "NotPongVfxDebug"
		bridge.OnInvoke = function(cmd: string?, key: string?, value: any)
			if cmd == "cfg" and key then
				V[key] = value -- DEV / REVIEW: set a Config.Feedback.ShotVfx value in the game's config instance
			end
			local s = self.stats()
			s.trailEnabled = trail ~= nil and trail.Enabled
			s.emitters = #holder:GetChildren()
			s.pending = pending ~= nil
			return s
		end
		bridge.Parent = player
	end
	return self
end

return ShotVfx
