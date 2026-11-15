-- BotController: moves the bot to where it can intercept the incoming ball (server).
-- After the opponent hits, the bot waits its reaction time, PREDICTS the ball with the real physics
-- (BallPhysics.predict over TableWorld), picks the first reachable contact point after the bounce on its half,
-- and walks (Humanoid:MoveTo, no teleporting) so its paddle anchor arrives there. Whether it actually hits is decided
-- per physics tick by RallyService with the same Striker reach rules, so a ball it cannot get to is simply missed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BallPhysics = require(Shared:WaitForChild("BallPhysics"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))

local BotController = {}
BotController.__index = BotController

function BotController.new(bot: Model, striker)
	local self = setmetatable({ bot = bot, striker = striker, plan = 0, target = nil :: Vector3? }, BotController)
	return self
end

local function humanoidOf(bot: Model): Humanoid?
	return bot:FindFirstChildOfClass("Humanoid")
end

-- Clamp a root target to the bot's own end, between Min/MaxStepBack behind the end line and within the platform.
local function clampTarget(p: Vector3): Vector3
	local B = Config.BotPlay
	local endZ = TableWorld.endLineZ("Bot") -- bot faces +Z; "behind" is -Z
	local z = math.clamp(p.Z, endZ - B.MaxStepBack, endZ - B.MinStepBack)
	local halfX = Config.Platform.Size.X / 2 - 3
	local x = math.clamp(p.X, TableWorld.center.X - halfX, TableWorld.center.X + halfX)
	return Vector3.new(x, Config.Layout.FloorY, z)
end

function BotController:moveTo(p: Vector3)
	local h = humanoidOf(self.bot)
	if h then
		self.target = clampTarget(p)
		h:MoveTo(self.target)
	end
end

function BotController:goHome()
	self.plan += 1
	local B = Config.BotPlay
	self:moveTo(Vector3.new(TableWorld.center.X, 0, TableWorld.endLineZ("Bot") - B.HomeStepBack))
end

-- Predicts the contact point for a ball in `state` (a snapshot; not mutated). Returns the point and seconds from now.
function BotController.predictContact(state, striker): (Vector3?, number?)
	local samples, events = BallPhysics.predict(state, TableWorld.physics, TableWorld.world, 2.5, function(_, e)
		return e ~= nil and (e.kind == "floor" or e.kind == "side")
	end)
	local bounceTime: number? = nil
	for _, e in events do
		if e.kind == "table" and e.surface == "Bot" then
			bounceTime = e.time
			break
		end
	end
	if not bounceTime then
		return nil, nil
	end
	local R = Config.Rally
	local floor = Config.Layout.FloorY
	local endZ = TableWorld.endLineZ("Bot")
	local t0 = state.time
	for _, s in samples do
		if s.time > bounceTime then
			local p = s.position
			local okHeight = p.Y >= floor + R.ContactMinAboveFloor and p.Y <= floor + R.ContactMaxAboveFloor
			if okHeight and (s.velocity.Y <= 0 or p.Z < endZ) then
				return p, s.time - t0
			end
		end
	end
	return nil, nil
end

-- The opponent just hit. `state` is the authoritative ball state at the hit.
function BotController:onOpponentHit(state)
	self.plan += 1
	local myPlan = self.plan
	local snapshot = BallPhysics.copyState(state)
	task.delay(Config.BotPlay.ReactionTime, function()
		if self.plan ~= myPlan then
			return
		end
		local contact = BotController.predictContact(snapshot, self.striker)
		if not contact then
			return -- ball is not coming to our half: stay put
		end
		-- Root target so the paddle anchor (right + forward of the root, in the bot's facing frame) meets the ball.
		local root = self.bot:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return
		end
		local cf = root.CFrame
		local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z).Unit
		local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z).Unit
		local B = Config.BotPlay
		self:moveTo(contact - right * B.AnchorRight - fwd * B.AnchorForward)
	end)
end

return BotController
