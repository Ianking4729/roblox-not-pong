-- MatchState: server-authoritative match state machine, score and serve rotation.
-- No Instances other than an optional `replica` (attributes are written onto it so clients can read state
-- without remotes; late joiners get the current values for free). Constructed via MatchState.new() so a test
-- can create throwaway instances without touching the live match.
--
-- Flow:  WaitingForPlayer -> ReadyToServe -> Serving -> Rally -> PointScored -> (ReadyToServe | MatchOver)
-- RallyService calls startServe(), enterRally(), registerHit(side), awardPoint(side), replayServe() (let), nextPoint().

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GameStates = require(Shared:WaitForChild("GameStates"))

local State, Side, Attr = GameStates.State, GameStates.Side, GameStates.Attributes

local MatchState = {}
MatchState.__index = MatchState

function MatchState.new(replica: Instance?)
	local changed = Instance.new("BindableEvent")
	local self = setmetatable({
		state = State.WaitingForPlayer,
		server = Config.Match.FirstServer,
		scorePlayer = 0,
		scoreBot = 0,
		rallyHits = 0,
		lastHitter = nil :: string?,
		replica = replica,
		_changed = changed,
		Changed = changed.Event, -- fires (newState, oldState, reason)
	}, MatchState)
	self:_replicate()
	return self
end

function MatchState:destroy()
	self._changed:Destroy()
end

function MatchState:getState(): string
	return self.state
end

function MatchState:snapshot()
	return {
		state = self.state,
		server = self.server,
		scorePlayer = self.scorePlayer,
		scoreBot = self.scoreBot,
		rallyHits = self.rallyHits,
		lastHitter = self.lastHitter,
	}
end

function MatchState:_replicate()
	local r = self.replica
	if not r then
		return
	end
	r:SetAttribute(Attr.State, self.state)
	r:SetAttribute(Attr.Server, self.server)
	r:SetAttribute(Attr.ScorePlayer, self.scorePlayer)
	r:SetAttribute(Attr.ScoreBot, self.scoreBot)
	r:SetAttribute(Attr.RallyHits, self.rallyHits)
	r:SetAttribute(Attr.LastHitter, self.lastHitter or "")
end

-- Validated transition. Returns true, or false plus a reason. Illegal transitions never change state.
function MatchState:transition(to: string, reason: string?): (boolean, string?)
	local from = self.state
	if not GameStates.canTransition(from, to) then
		return false, ("illegal transition %s -> %s"):format(from, to)
	end
	self.state = to
	self:_replicate()
	self._changed:Fire(to, from, reason)
	return true, nil
end

-- Who serves, from the number of points played. Alternates every ServesPerTurn points, and every point at deuce.
function MatchState:_computeServer(): string
	local M = Config.Match
	local first = M.FirstServer
	local other = GameStates.opponentOf(first)
	local total = self.scorePlayer + self.scoreBot
	local deuceStart = (M.PointsToWin - 1) * 2
	local turn
	if self.scorePlayer >= M.PointsToWin - 1 and self.scoreBot >= M.PointsToWin - 1 then
		turn = math.floor(deuceStart / M.ServesPerTurn) + (total - deuceStart)
	else
		turn = math.floor(total / M.ServesPerTurn)
	end
	return if turn % 2 == 0 then first else other
end

function MatchState:isGameOver(): boolean
	local M = Config.Match
	local hi, lo = math.max(self.scorePlayer, self.scoreBot), math.min(self.scorePlayer, self.scoreBot)
	return hi >= M.PointsToWin and hi - lo >= M.WinBy
end

function MatchState:winner(): string?
	if not self:isGameOver() then
		return nil
	end
	return if self.scorePlayer > self.scoreBot then Side.Player else Side.Bot
end

-- WaitingForPlayer -> ReadyToServe (both competitors present).
function MatchState:markReady(): (boolean, string?)
	return self:transition(State.ReadyToServe, "competitors ready")
end

-- ReadyToServe -> Serving
function MatchState:startServe(): (boolean, string?)
	local ok, err = self:transition(State.Serving, "serve started")
	if ok then
		self.rallyHits = 0
		self.lastHitter = nil
		self:_replicate()
	end
	return ok, err
end

-- Serving -> Rally
function MatchState:enterRally(): (boolean, string?)
	return self:transition(State.Rally, "serve completed")
end

-- Record a legal paddle hit (only meaningful while Serving or Rally).
function MatchState:registerHit(side: string): boolean
	if self.state ~= State.Serving and self.state ~= State.Rally then
		return false
	end
	self.rallyHits += 1
	self.lastHitter = side
	self:_replicate()
	return true
end

-- Serving -> ReadyToServe without scoring: a let (the serve touched the net but was otherwise good).
function MatchState:replayServe(): (boolean, string?)
	if self.state ~= State.Serving then
		return false, ("replayServe called in state %s"):format(self.state)
	end
	self.rallyHits = 0
	self.lastHitter = nil
	return self:transition(State.ReadyToServe, "let")
end

-- Serving | Rally -> PointScored, increments the winner's score.
function MatchState:awardPoint(side: string, reason: string?): (boolean, string?)
	if side ~= Side.Player and side ~= Side.Bot then
		return false, "unknown side " .. tostring(side)
	end
	if self.state ~= State.Serving and self.state ~= State.Rally then
		return false, ("cannot award a point in state %s"):format(self.state)
	end
	if side == Side.Player then
		self.scorePlayer += 1
	else
		self.scoreBot += 1
	end
	return self:transition(State.PointScored, reason or (side .. " scored"))
end

-- PointScored -> MatchOver, or rotate server and -> ReadyToServe.
function MatchState:nextPoint(): (boolean, string?)
	if self.state ~= State.PointScored then
		return false, ("nextPoint called in state %s"):format(self.state)
	end
	if self:isGameOver() then
		return self:transition(State.MatchOver, (self:winner() :: string) .. " won the match")
	end
	self.server = self:_computeServer()
	self.rallyHits = 0
	self.lastHitter = nil
	return self:transition(State.ReadyToServe, "next point")
end

-- MatchOver -> ReadyToServe with scores cleared.
function MatchState:rematch(): (boolean, string?)
	if self.state ~= State.MatchOver then
		return false, ("rematch called in state %s"):format(self.state)
	end
	self.scorePlayer, self.scoreBot = 0, 0
	self.server = Config.Match.FirstServer
	self.rallyHits = 0
	self.lastHitter = nil
	return self:transition(State.ReadyToServe, "rematch")
end

-- Any state -> WaitingForPlayer (a competitor left). Keeps the score.
function MatchState:suspend(reason: string?): (boolean, string?)
	if self.state == State.WaitingForPlayer then
		return true, nil
	end
	self.rallyHits = 0
	self.lastHitter = nil
	return self:transition(State.WaitingForPlayer, reason or "suspended")
end

return MatchState
