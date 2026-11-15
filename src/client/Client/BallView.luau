-- BallView (client): renders the cosmetic ball (BallTemplate.Ball.BallVisual, whatever it looks like in Studio).
-- The server owns the ball; it sends snapshots (position, velocity, spin, server time) on every serve, hit, contact
-- and periodically. Between snapshots this client advances the SAME deterministic BallPhysics over the same
-- TableWorld, so the ball moves smoothly at the local frame rate instead of at network rate. Visual only: nothing
-- here affects gameplay. The visual also rotates with the simulated spin (useful for patterned/skinned balls).
-- CHARGE SLOW MOTION: a "slow" snapshot advances at its server-provided time scale; a local prediction applies the
-- same scale on the press frame, before the server's verdict arrives.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BallPhysics = require(Shared:WaitForChild("BallPhysics"))
local FrameDriver = require(script.Parent:WaitForChild("FrameDriver"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))

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
	return info.mode == "held" or (localTimeScale ~= nil and localTimeScale <= 0)
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

	snapshotRemote.OnClientEvent:Connect(function(snap)
		local s = BallPhysics.newState(snap.p, snap.v, snap.w)
		s.resting = snap.mode == "held"
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
		info.received = os.clock()
	end)
	snapshotRemote:FireServer() -- ask for the current state

	FrameDriver.bind("NotPongBallView", Enum.RenderPriority.Camera.Value - 10, function(dt)
		local s = state
		if not s then
			return
		end
		local timeScale = localTimeScale or info.timeScale
		local simDt = if info.mode == "held" then 0 else dt * timeScale
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
