-- Striker: "can this competitor reach the ball, and what shot do they play?" Shared by the bot (Config.BotPlay) and
-- the TEMPORARY player auto-return (Config.AutoReturn), so both use identical reach rules and the same physically
-- solved shots (ShotSolver over BallPhysics). Server-only; reads the character's replicated root (never trusts a
-- client-reported hit). Gameplay reach is a configurable anchor near the paddle hand, independent of paddle visuals.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ShotSolver = require(Shared:WaitForChild("ShotSolver"))
local TableWorld = require(Shared:WaitForChild("TableWorld"))

local Striker = {}
Striker.__index = Striker

export type Settings = {
	Reach: number,
	AnchorRight: number,
	AnchorForward: number,
	ReturnSpeed: number,
	ReturnSpeedVariation: number,
	Topspin: number,
	TargetDepthMin: number,
	TargetDepthMax: number,
	TargetSpreadX: number,
	AimError: number,
}

function Striker.new(side: string, settings: Settings, getCharacter: () -> Model?)
	return setmetatable({ side = side, settings = settings, getCharacter = getCharacter }, Striker)
end

-- World position of the paddle anchor (horizontal), or nil when there is no character.
function Striker:anchor(): Vector3?
	local character = self.getCharacter()
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local cf = root.CFrame
	local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
	local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if right.Magnitude < 1e-3 or fwd.Magnitude < 1e-3 then
		return nil
	end
	local S = self.settings
	return root.Position + right.Unit * S.AnchorRight + fwd.Unit * S.AnchorForward
end

function Striker:inReach(position: Vector3): boolean
	local a = self:anchor()
	if not a then
		return false
	end
	local R = Config.Rally
	local floor = Config.Layout.FloorY
	if position.Y < floor + R.ContactMinAboveFloor or position.Y > floor + R.ContactMaxAboveFloor then
		return false
	end
	return Vector2.new(position.X - a.X, position.Z - a.Z).Magnitude <= self.settings.Reach
end

-- Strike now? In reach, and the ball is either falling (past its post-bounce apex) or already past our end line.
function Striker:shouldStrike(position: Vector3, velocity: Vector3): boolean
	if not self:inReach(position) then
		return false
	end
	local pastEnd = (position.Z - TableWorld.endLineZ(self.side)) * TableWorld.towardSide(self.side) > 0
	return velocity.Y <= 0 or pastEnd
end

-- How hard the incoming ball pressed this striker (0..1): out at the edge of its reach, fast, or curving
-- (Config.BotPlay.Pressure*). `state` = the ball at contact. 0 when the settings have no pop-up values.
function Striker:pressure(state): number
	local S = self.settings :: any
	if not S.PopupPressureChance or not state then
		return 0
	end
	local a = self:anchor()
	local reachTerm = 0
	if a then
		local d = Vector2.new(state.position.X - a.X, state.position.Z - a.Z).Magnitude / S.Reach
		reachTerm = math.clamp((d - S.PressureReachFrom) / math.max(1 - S.PressureReachFrom, 1e-3), 0, 1)
	end
	local v = state.velocity
	local speed = Vector2.new(v.X, v.Z).Magnitude
	local speedTerm = math.clamp((speed - S.PressureSpeedFrom) / math.max(S.PressureSpeedTo - S.PressureSpeedFrom, 1e-3), 0, 1)
	local spinTerm = math.clamp(math.abs(state.spin.Y) / math.max(S.PressureSpinFull, 1e-3), 0, 1)
	return math.max(reachTerm, speedTerm, spinTerm)
end

-- Choose a target on the opponent's half (with placement variety and aim error) and solve the launch from `from`.
-- `state` (optional): the ball at contact. With Config.BotPlay pop-up settings, a pressed striker sometimes plays a
-- high defensive LOB instead (chance = PopupRandomChance + PopupPressureChance * pressure): the smash opportunity.
-- Returns shot, target, and "lob" | nil.
function Striker:shot(from: Vector3, rng: Random, state: any?)
	local S = self.settings
	local P = S :: any
	if P.PopupPressureChance and state then
		local chance = (P.PopupRandomChance or 0) + P.PopupPressureChance * self:pressure(state)
		if rng:NextNumber() < chance then
			local target = TableWorld.pointOnHalf(
				if self.side == "Player" then "Bot" else "Player",
				P.PopupDepth,
				rng:NextNumber(-P.PopupSpreadX, P.PopupSpreadX)
			)
			local lob = ShotSolver.solve(TableWorld.physics, from, target, {
				speed = P.PopupSpeed + rng:NextNumber(-P.PopupSpeedVariation, P.PopupSpeedVariation),
				topspin = P.PopupTopspin,
				netZ = TableWorld.netZ,
				netTopY = TableWorld.netTopY,
				clearance = Config.Rally.NetClearance,
				maxTime = 4,
			})
			if lob.ok then
				return lob, target, "lob"
			end -- no legal lob from here: play the normal return
		end
	end
	local target = TableWorld.pointOnHalf(
		if self.side == "Player" then "Bot" else "Player",
		rng:NextNumber(S.TargetDepthMin, S.TargetDepthMax),
		rng:NextNumber(-S.TargetSpreadX, S.TargetSpreadX)
	) + Vector3.new(rng:NextNumber(-S.AimError, S.AimError), 0, rng:NextNumber(-S.AimError, S.AimError))
	local speed = S.ReturnSpeed + rng:NextNumber(-S.ReturnSpeedVariation, S.ReturnSpeedVariation)
	local shot = ShotSolver.solve(TableWorld.physics, from, target, {
		speed = speed,
		topspin = S.Topspin,
		netZ = TableWorld.netZ,
		netTopY = TableWorld.netTopY,
		clearance = Config.Rally.NetClearance,
	})
	return shot, target
end

return Striker
