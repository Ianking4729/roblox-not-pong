--!strict
-- GameStates: names and legal transitions for the match state machine.
-- Pure data + tiny helpers, shared so the server (authority) and client (display) agree on the vocabulary.

export type State = "WaitingForPlayer" | "ReadyToServe" | "Serving" | "Rally" | "PointScored" | "MatchOver"
export type Side = "Player" | "Bot"

local GameStates = {}

GameStates.State = table.freeze({
	WaitingForPlayer = "WaitingForPlayer" :: State, -- no player seated or bot not ready
	ReadyToServe = "ReadyToServe" :: State, -- ball placed for the server; waiting for a serve to begin
	Serving = "Serving" :: State, -- serve in progress, ball not yet in a rally
	Rally = "Rally" :: State, -- ball in play
	PointScored = "PointScored" :: State, -- brief pause showing who scored
	MatchOver = "MatchOver" :: State,
})

GameStates.Side = table.freeze({
	Player = "Player" :: Side,
	Bot = "Bot" :: Side,
})

-- Attribute names the server replicates on the arena folder. The client reads these.
GameStates.Attributes = table.freeze({
	State = "State",
	Server = "Server",
	ScorePlayer = "ScorePlayer",
	ScoreBot = "ScoreBot",
	RallyHits = "RallyHits",
	LastHitter = "LastHitter",
})

local S = GameStates.State
local allowed: { [string]: { [string]: boolean } } = {
	[S.WaitingForPlayer] = { [S.ReadyToServe] = true },
	[S.ReadyToServe] = { [S.Serving] = true, [S.WaitingForPlayer] = true },
	[S.Serving] = { [S.Rally] = true, [S.PointScored] = true, [S.WaitingForPlayer] = true },
	[S.Rally] = { [S.PointScored] = true, [S.WaitingForPlayer] = true },
	[S.PointScored] = { [S.ReadyToServe] = true, [S.MatchOver] = true, [S.WaitingForPlayer] = true },
	[S.MatchOver] = { [S.ReadyToServe] = true, [S.WaitingForPlayer] = true },
}

function GameStates.canTransition(from: string, to: string): boolean
	local row = allowed[from]
	return row ~= nil and row[to] == true
end

function GameStates.opponentOf(side: Side): Side
	return if side == "Player" then "Bot" else "Player"
end

return GameStates
