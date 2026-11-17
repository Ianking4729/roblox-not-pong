-- Main (server): bootstraps the NOT PONG foundation. Order matters:
--   collision groups -> arena (loaded, not rebuilt) -> match state -> avatar service -> bot
-- The match is event-driven: it moves between WaitingForPlayer and ReadyToServe as the player seat
-- and the bot become available. There is no polling loop.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GameStates = require(Shared:WaitForChild("GameStates"))

local Server = script.Parent
local CollisionSetup = require(Server:WaitForChild("CollisionSetup"))
local ArenaBuilder = require(Server:WaitForChild("ArenaBuilder"))
local MatchState = require(Server:WaitForChild("MatchState"))
local AvatarService = require(Server:WaitForChild("AvatarService"))
local BotService = require(Server:WaitForChild("BotService"))
local RallyService = require(Server:WaitForChild("RallyService"))
local MovementService = require(Server:WaitForChild("MovementService"))
local TableGuard = require(Server:WaitForChild("TableGuard"))

local function log(...)
	if Config.Debug.Verbose then
		print("[NotPong]", ...)
	end
end

-- Animation retargeting off (Config.Animation): our avatars are scaled with Model:ScaleTo, and retargeting scaled the
-- default animations' hip motion a second time (the shaky walk). The bot animates here; each client sets it too.
workspace.Retargeting = Config.Animation.Retargeting

CollisionSetup.setup()
local arena = ArenaBuilder.load() -- finds the static arena saved in the place; only the ball is created here
TableGuard.build(arena.Folder) -- invisible block on the table footprint: characters cannot climb onto the table
local match = MatchState.new(arena.Folder)
local botReady = false

-- Recompute readiness whenever the seat or bot changes.
local function refreshReadiness()
	local seated = AvatarService.getSeatedPlayer()
	if seated and botReady then
		if match:getState() == GameStates.State.WaitingForPlayer then
			match:markReady()
		end
	else
		match:suspend(if seated then "bot not ready" else "no player seated")
	end
	arena.Folder:SetAttribute(Config.Names.SeatedPlayerAttribute, seated and seated.UserId or 0)
end

match.Changed:Connect(function(newState, oldState, reason)
	log(("state %s -> %s (%s)"):format(oldState, newState, tostring(reason)))
end)

MovementService.start() -- Shift boost remote + validation (before players arrive)
AvatarService.setPlayerStand(arena.PlayerStand)
AvatarService.start({ onSeatChanged = refreshReadiness })

local bot = BotService.spawn(arena.Folder, arena.BotStand)
botReady = bot ~= nil
if not bot then
	warn("[NotPong] bot failed to spawn; match will stay in WaitingForPlayer")
end
-- Ball, serving, rallies and scoring (holds the ball at the serve point on every ReadyToServe).
RallyService.start(arena, match, AvatarService, bot)
refreshReadiness()

log("foundation ready. table", Config.Table.Length, "x", Config.Table.Width, "x", Config.Table.Height, "studs")
