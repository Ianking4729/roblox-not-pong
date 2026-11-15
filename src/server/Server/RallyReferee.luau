-- RallyReferee: the table-tennis rules for ONE point, as a pure state machine (no Instances, no timing).
-- RallyService feeds it what the physics reports (paddle hits, table bounces by half, net touches, dead balls,
-- timeouts) and acts on the outcome. Keeping the rules here means they can be unit-tested and replaced.
--
-- Phases:  serveToss -> serveFlight -> rally -> over
--   serveToss   : ball tossed; only the server may strike it.
--   serveFlight : struck serve; must bounce on the server's half, then the receiver's half (net touch + good = let).
--   rally       : after each hit, the ball must bounce once on the opponent's half; the opponent must then return it
--                 before a second bounce. Hitting your own half, out (floor/table side), a volley or a double hit loses.
-- Outcomes returned: nil (nothing decided), {serveGood=true}, {hit=true}, {let=true}, {winner=side, reason=string}.

local RallyReferee = {}
RallyReferee.__index = RallyReferee

local function opp(side: string): string
	return if side == "Player" then "Bot" else "Player"
end
RallyReferee.opponentOf = opp

function RallyReferee.new()
	return setmetatable({
		phase = "idle",
		server = nil :: string?,
		lastHitter = nil :: string?,
		bounces = { Player = 0, Bot = 0 }, -- table bounces per half since the last hit
		netSinceHit = false,
		serveTouchedNet = false,
		hits = 0,
	}, RallyReferee)
end

function RallyReferee:startServe(server: string)
	self.phase = "serveToss"
	self.server = server
	self.lastHitter = nil
	self.bounces = { Player = 0, Bot = 0 }
	self.netSinceHit = false
	self.serveTouchedNet = false
	self.hits = 0
end

function RallyReferee:_end(winner: string, reason: string)
	self.phase = "over"
	return { winner = winner, reason = reason }
end

-- Who must hit next (nil when nobody can).
function RallyReferee:expecting(): string?
	if self.phase == "serveToss" then
		return self.server
	elseif self.phase == "rally" then
		return opp(self.lastHitter)
	end
	return nil
end

-- May `side` legally strike the ball right now? (Rally: exactly one bounce on their half since the opponent's hit.)
function RallyReferee:canHit(side: string): boolean
	if self.phase == "serveToss" then
		return side == self.server
	elseif self.phase == "rally" then
		return side == opp(self.lastHitter) and self.bounces[side] == 1
	end
	return false
end

function RallyReferee:onHit(side: string)
	if self.phase == "serveToss" then
		if side ~= self.server then
			return self:_end(opp(side), "hit the ball before the serve")
		end
		self.phase = "serveFlight"
	elseif self.phase == "serveFlight" then
		return self:_end(opp(side), if side == self.server then "double hit on the serve" else "volleyed the serve")
	elseif self.phase == "rally" then
		if side == self.lastHitter then
			return self:_end(opp(side), "double hit")
		end
		if self.bounces[side] == 0 then
			return self:_end(opp(side), "volley (hit before the bounce)")
		end
	else
		return nil
	end
	self.lastHitter = side
	self.bounces = { Player = 0, Bot = 0 }
	self.netSinceHit = false
	self.hits += 1
	return { hit = true }
end

-- A table bounce on `half` ("Player" / "Bot").
function RallyReferee:onBounce(half: string)
	if self.phase == "serveFlight" then
		local server, receiver = self.server, opp(self.server)
		if self.bounces[server] == 0 then
			if half ~= server then
				return self:_end(receiver, "serve must bounce on the server's side first")
			end
			self.bounces[server] = 1
			return nil
		end
		if half == server then
			return self:_end(receiver, "serve bounced twice on the server's side")
		end
		if self.serveTouchedNet then
			self.phase = "over"
			return { let = true }
		end
		self.phase = "rally"
		self.bounces = { Player = 0, Bot = 0 }
		self.bounces[receiver] = 1
		return { serveGood = true }
	elseif self.phase == "rally" then
		local receiver = opp(self.lastHitter)
		if half == self.lastHitter then
			return self:_end(receiver, if self.netSinceHit then "into the net" else "bounced on own side")
		end
		self.bounces[receiver] += 1
		if self.bounces[receiver] >= 2 then
			return self:_end(self.lastHitter, "not returned (second bounce)")
		end
	end
	return nil
end

function RallyReferee:onNet()
	self.netSinceHit = true
	if self.phase == "serveFlight" then
		self.serveTouchedNet = true
	end
end

-- The ball is dead: it hit the floor or a side of the table (`kind`).
function RallyReferee:onDead(kind: string)
	if self.phase == "serveToss" then
		return self:_end(opp(self.server), "dropped the serve toss")
	elseif self.phase == "serveFlight" then
		return self:_end(opp(self.server), if self.serveTouchedNet then "serve into the net" else "serve out")
	elseif self.phase == "rally" then
		local receiver = opp(self.lastHitter)
		if self.bounces[receiver] >= 1 then
			return self:_end(self.lastHitter, "not returned")
		end
		local why = if self.netSinceHit then "into the net" elseif kind == "side" then "hit the table edge" else "out"
		return self:_end(receiver, why)
	end
	return nil
end

-- Nobody hit for too long: the side that was expected to act loses.
function RallyReferee:onTimeout()
	local who = self:expecting() or (if self.lastHitter then self.lastHitter else self.server)
	if self.phase == "rally" and self.bounces[opp(self.lastHitter)] == 0 then
		who = self.lastHitter -- the ball never reached the opponent
	end
	return self:_end(opp(who), "rally timed out")
end

return RallyReferee
