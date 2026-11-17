-- BallView (client): renders the cosmetic ball (BallTemplate.Ball.BallVisual, whatever it looks like in Studio).
-- The server owns the ball; it sends snapshots (position, velocity, spin, server time) on every serve, hit, contact
-- and periodically. Between snapshots this client advances the SAME deterministic BallPhysics over the same
-- TableWorld, so the ball moves smoothly at the local frame rate instead of at network rate. Visual only: nothing
-- here affects gameplay. The visual also rotates with the simulated spin (useful for patterned/skinned balls).
-- CHARGE SLOW MOTION: a "slow" snapshot advances at its server-provided time scale; a local prediction applies the
-- same scale on the press frame, before the server's verdict arrives.
-- PLAYER SERVE: mode "hand" = the ball rests on the serving player's free (left) hand: the visual is drawn on that
-- character's real LeftHand every frame (the same single ball; the server keeps its gameplay part at the same spot) until
-- the server's snapshot says the toss left the hand, then the normal simulation takes over from the server's state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BallPhysics = require(Shared:WaitForChild("BallPhysics"))
local FrameDriver = require(script.Parent:WaitForChild("FrameDriver"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))
local ServeRules = require(Shared:WaitForChild("ServeRules"))

local BallView = {}

local MAX_CATCHUP = 0.5 -- seconds of latency we simulate forward when a snapshot arrives

local current: BallPhysics.State? = nil
local lastSnapshot: { state: BallPhysics.State, t: number, b: number }? = nil -- exact server state at server time t
-- From the latest snapshot: is the ball on its way to the local player, bounces on the player's half, hit counter, mode.
local info = {
	incoming = false,
	bounces = 0,
	hits = 0,
	mode = "held",
	timeScale = 1,
	received = 0,
	freeze = nil :: any,
	pressAck = 0,
	serve = false, -- the local player's serve toss is in the air and may be struck
}
local localTimeScale: number? = nil -- predicted slow motion (until the server answers)

-- The locally simulated ball (read-only for other client modules) and the latest server flags.
function BallView.getState(): BallPhysics.State?
	return current
end
function BallView.getInfo()
	return info
end
-- The latest snapshot exactly as the server sent it (before any local catch-up), with its server timestamp.
-- Gameplay timing on the client (ShotController) predicts from this, not from the rendered ball, so it matches the
-- server's own prediction even if local frames are slow.
function BallView.getSnapshot()
	return lastSnapshot
end

-- Predicted charge slow motion: apply the configured scale until the server confirms or denies it.
function BallView.setLocalTimeScale(scale: number?)
	localTimeScale = scale
end
function BallView.isHeld(): boolean
	return info.mode == "held" or info.mode == "hand" or (localTimeScale ~= nil and localTimeScale <= 0)
end

-- Cosmetic layers (trail, effects) subscribe here to be called after the visual ball has been moved each frame:
-- fn(state, visual). They draw FROM the rendered ball; they never move it.
local frameListeners: { (BallPhysics.State, BasePart) -> () } = {}
function BallView.onFrame(fn: (BallPhysics.State, BasePart) -> ())
	table.insert(frameListeners, fn)
end

function BallView.start()
	local remotes = ReplicatedStorage:WaitForChild(Config.Names.Remotes)
	local snapshotRemote = remotes:WaitForChild("BallSnapshot") :: RemoteEvent
	local arena = workspace:WaitForChild(Config.Names.Arena)
	local visual = arena:WaitForChild("BallTemplate"):WaitForChild("Ball"):WaitForChild("BallVisual") :: BasePart

	local cfg, world = TableWorld.physics, TableWorld.world
	local state: BallPhysics.State? = nil
	local rotation = visual.CFrame.Rotation
	local Players = game:GetService("Players")

	-- The serving player's character and free hand (the seated player: Names.SeatedPlayerAttribute on the arena).
	local function servingCharacter(): Model?
		local id = arena:GetAttribute(Config.Names.SeatedPlayerAttribute)
		local p = typeof(id) == "number" and id ~= 0 and Players:GetPlayerByUserId(id) or nil
		return p and p.Character or nil
	end
	local function servingHand(): BasePart?
		local character = servingCharacter()
		return character and character:FindFirstChild("LeftHand") :: BasePart? or nil
	end

	snapshotRemote.OnClientEvent:Connect(function(snap)
		local s = BallPhysics.newState(snap.p, snap.v, snap.w)
		s.resting = snap.mode == "held" or snap.mode == "hand"
		lastSnapshot = { state = BallPhysics.copyState(s), t = snap.t, b = snap.b or 0 }
		local lag = math.clamp(workspace:GetServerTimeNow() - snap.t, 0, MAX_CATCHUP)
		local lagScale = if snap.mode == "slow" then (snap.ts or 1) else 1
		while lag > 0 do -- step() caps work per call; loop to cover the whole latency
			local chunk = math.min(lag, cfg.fixedStep * cfg.maxStepsPerUpdate * 0.9)
			BallPhysics.step(s, cfg, world, chunk * lagScale)
			lag -= chunk
		end
		state = s
		current = s
		info.incoming, info.bounces, info.hits, info.mode = snap.i == true, snap.b or 0, snap.h or 0, snap.mode
		info.timeScale = snap.ts or 1
		info.freeze, info.pressAck = snap.f, snap.pa or 0
		info.serve = snap.sv == true
		info.received = os.clock()
	end)
	snapshotRemote:FireServer() -- ask for the current state

	FrameDriver.bind("NotPongBallView", Enum.RenderPriority.Camera.Value - 10, function(dt)
		local s = state
		if not s then
			return
		end
		if info.mode == "hand" then
			local hand = servingHand()
			local p: Vector3? = nil
			if hand then
				-- resting on the palm (above the hand's centre by its half height + the ball's radius)
				p = hand.Position + Vector3.new(0, hand.Size.Y / 2 + Config.Ball.Radius, 0)
			else
				-- no hand part (yet): the authored hold point from the server's rules, so the ball still follows the body
				-- (with no character at all, the server's periodic hand snapshots move it)
				local character = hand == nil and servingCharacter() or nil
				local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root and character then
					p = ServeRules.handPoint(root.CFrame, character:GetScale(), "hold")
				end
			end
			if p then
				s.position = p
				visual.CFrame = CFrame.new(p) * rotation
				for _, fn in frameListeners do
					fn(s, visual)
				end
				return
			end
		end
		local timeScale = localTimeScale or info.timeScale
		local simDt = if info.mode == "held" or info.mode == "hand" then 0 else dt * timeScale
		BallPhysics.step(s, cfg, world, simDt)
		local w = s.spin
		if w.Magnitude > 1e-3 and simDt > 0 then
			rotation = CFrame.fromAxisAngle(w.Unit, w.Magnitude * simDt) * rotation
		end
		visual.CFrame = CFrame.new(s.position) * rotation
		for _, fn in frameListeners do
			fn(s, visual)
		end
	end)
end

return BallView
