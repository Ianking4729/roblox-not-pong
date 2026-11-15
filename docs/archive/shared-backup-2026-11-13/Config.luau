--!strict
-- Config: single source of truth for NOT PONG tunables.
--
-- UNITS
--   Distance : studs.            1 stud = 0.1 m  (StudsPerMeter = 10)
--   Time     : seconds
--   Speed    : studs / second    (1 m/s = 10 studs/s)
--   Accel    : studs / second^2  (9.81 m/s^2 = 98.1 studs/s^2)
-- Real-world measurements live in `Config.Real` in METERS and are converted exactly once, below.
-- Everything else in the codebase consumes the stud values. Never hard-code a stud number elsewhere.
--
-- AXES (fixed, so the table is axis-aligned and BallPhysics surfaces stay valid)
--   Table length runs along Z. The player stands on the +Z side facing -Z. The bot stands on the -Z side.
--   Table width runs along X. Y is up.
--
-- NOTE ON THE AVATAR: Roblox R15 hands are ~1.7x larger than real hands relative to body height, so the
-- paddle's *visual* is scaled up (Config.Paddle.VisualScale) while gameplay uses the real dimensions.

local STUDS_PER_METER = 10

local function toStuds(meters: number): number
	return meters * STUDS_PER_METER
end

-- ITTF / real-world measurements, in METERS.
local Real = table.freeze({
	TableLength = 2.74,
	TableWidth = 1.525,
	TableHeight = 0.76, -- floor to playing surface
	TableTopThickness = 0.025,
	LineWidth = 0.02,
	CenterLineWidth = 0.003,
	NetHeight = 0.1525, -- above the playing surface
	NetOverhang = 0.1525, -- net extends this far past each side edge
	NetThickness = 0.005,
	NetPostWidth = 0.03,
	BallDiameter = 0.04,
	AvatarHeight = 1.75,
	AvatarStandBack = 1.0, -- distance behind the end line
	PaddleBladeWidth = 0.15,
	PaddleBladeHeight = 0.16,
	PaddleBladeThickness = 0.008,
	PaddleHandleLength = 0.10,
	PaddleHandleWidth = 0.03,
	PaddleHandleThickness = 0.025,
	Gravity = 9.81, -- m/s^2
})

local Table = {
	Length = toStuds(Real.TableLength), -- 27.4
	Width = toStuds(Real.TableWidth), -- 15.25
	Height = toStuds(Real.TableHeight), -- 7.6 (to playing surface)
	TopThickness = toStuds(Real.TableTopThickness),
	LineWidth = toStuds(Real.LineWidth),
	CenterLineWidth = toStuds(Real.CenterLineWidth),
	LegWidth = 0.6,
	LegInsetX = 1.5,
	LegInsetZ = 2.5,
}

local Net = {
	Height = toStuds(Real.NetHeight), -- 1.525
	Overhang = toStuds(Real.NetOverhang),
	Thickness = toStuds(Real.NetThickness),
	Length = Table.Width + 2 * toStuds(Real.NetOverhang), -- 18.3
	PostWidth = toStuds(Real.NetPostWidth),
	TapeHeight = 0.15,
}

local Ball = {
	Diameter = toStuds(Real.BallDiameter), -- 0.4
	Radius = toStuds(Real.BallDiameter) / 2, -- 0.2
}

local Arena = {
	-- Center of the table footprint at floor level. Offset on Z to stay clear of the pre-existing Workspace.Rig.
	Origin = Vector3.new(0, 0, 60),
	FloorY = 0, -- top of the Baseplate
}

local Avatar = {
	-- Every competitor is scaled so feet-to-top-of-head (accessories ignored) equals this. There is deliberately
	-- no fixed scale factor: avatars differ a lot (default R15 is 5.46 studs tall at scale 1, a tested custom
	-- avatar only 2.77), so AvatarService measures each body and computes the factor.
	Height = toStuds(Real.AvatarHeight), -- 17.5
	StandBack = toStuds(Real.AvatarStandBack), -- 10
	WalkSpeed = 16,
}

local Serve = {
	RestFromEndLine = 3, -- studs in from the end line where the ball rests before a serve
	-- Sideways offset toward the server's paddle hand (measured: scaled R15 hands hang 4.7 studs from centre).
	-- Keeps the resting ball out from behind the player's own body as seen from the camera.
	-- The player's right is +X; the bot faces the other way, so its right is -X.
	RestSideOffset = 4.7,
}

local originX, originZ = Arena.Origin.X, Arena.Origin.Z
local surfaceY = Arena.FloorY + Table.Height
local halfL, halfW = Table.Length / 2, Table.Width / 2

-- Derived world-space layout. Built from the values above; do not edit by hand.
local Layout = {
	FloorY = Arena.FloorY,
	SurfaceY = surfaceY,
	TableSurfaceCenter = Vector3.new(originX, surfaceY, originZ),
	TableTopCenter = Vector3.new(originX, surfaceY - Table.TopThickness / 2, originZ),
	NetCenter = Vector3.new(originX, surfaceY + Net.Height / 2, originZ),
	PlayerStand = Vector3.new(originX, Arena.FloorY, originZ + halfL + Avatar.StandBack),
	BotStand = Vector3.new(originX, Arena.FloorY, originZ - (halfL + Avatar.StandBack)),
	PlayerFacing = Vector3.new(0, 0, -1),
	BotFacing = Vector3.new(0, 0, 1),
	ServeBall = {
		Player = Vector3.new(originX + Serve.RestSideOffset, surfaceY + Ball.Radius, originZ + halfL - Serve.RestFromEndLine),
		Bot = Vector3.new(originX - Serve.RestSideOffset, surfaceY + Ball.Radius, originZ - halfL + Serve.RestFromEndLine),
	},
	-- Surfaces in the shape BallPhysics expects (axis-aligned, split at the net).
	PlayerHalf = {
		topY = surfaceY,
		minX = originX - halfW,
		maxX = originX + halfW,
		minZ = originZ,
		maxZ = originZ + halfL,
	},
	BotHalf = {
		topY = surfaceY,
		minX = originX - halfW,
		maxX = originX + halfW,
		minZ = originZ - halfL,
		maxZ = originZ,
	},
}

local Config = {
	Scale = {
		StudsPerMeter = STUDS_PER_METER,
		MetersPerStud = 1 / STUDS_PER_METER,
		toStuds = toStuds,
	},
	Real = Real,
	Table = Table,
	Net = Net,
	Ball = Ball,
	Arena = Arena,
	Avatar = Avatar,
	Serve = Serve,
	Layout = Layout,

	Paddle = {
		-- Gameplay dimensions (real, in studs). Hit detection will use these, not the visual size.
		BladeWidth = toStuds(Real.PaddleBladeWidth),
		BladeHeight = toStuds(Real.PaddleBladeHeight),
		BladeThickness = toStuds(Real.PaddleBladeThickness),
		HandleLength = toStuds(Real.PaddleHandleLength),
		HandleWidth = toStuds(Real.PaddleHandleWidth),
		HandleThickness = toStuds(Real.PaddleHandleThickness),
		ContactRadius = toStuds(0.08), -- FUTURE: distance within which a swing can strike the ball
		-- Placeholder visual only. Replaceable without touching gameplay.
		VisualScale = 1.6,
		-- Where the paddle is carried, in CHARACTER space relative to the right hand's centre (studs): +Right is
		-- the carrier's right, +Up, +Forward is the way they face. Arms hang at the sides (no custom animation yet),
		-- so the paddle is held just outboard of the fist with the blade tilted outward; straight up would sit
		-- inside the forearm and straight forward is hidden behind it from the camera. Replace with a proper
		-- ready-stance animation later.
		Hold = {
			Clearance = 0.46, -- sideways gap beyond the hand's outer face (hand width is measured per avatar)
			Up = 0.73,
			Forward = 0,
			TiltDegrees = 25, -- blade leans outward (away from the body) by this much
		},
	},

	-- Ball physics in the exact shape BallPhysics.step/tick expects.
	BallPhysics = {
		radius = Ball.Radius,
		gravity = toStuds(Real.Gravity), -- 98.1 studs/s^2
		restitution = 0.9, -- ITTF ball: ~24.5 cm rebound from a 30.5 cm drop => e ~ 0.9
		friction = 0.98, -- horizontal speed kept per table bounce
		restSpeed = 1, -- studs/s; below this the ball settles instead of bouncing
		fixedStep = 1 / 120,
		maxStepsPerUpdate = 12,
	},

	-- Other physics constants (FUTURE: not yet consumed).
	Physics = {
		PaddleRestitution = 0.85,
		AirDragPerSecond = 0.0, -- placeholder; BallPhysics has no drag yet
		-- Per tick the ball moves up to ~2 studs at max speed while the net is 0.05 studs thick,
		-- so net crossing MUST use a swept (continuous) test, not a per-tick overlap test.
	},

	Timing = {
		ServeReadyDelay = 1.0, -- seconds from ReadyToServe before a serve may begin
		PointResetDelay = 1.5, -- seconds shown on PointScored before the next point
		RallyTimeout = 10, -- FUTURE: seconds without a hit before the rally is ended
		BotReactionTime = 0.25, -- FUTURE
		AppearanceLoadTimeout = 8, -- seconds to wait for a player's avatar appearance
	},

	Match = {
		PointsToWin = 11,
		WinBy = 2,
		ServesPerTurn = 2,
		FirstServer = "Player", -- "Player" | "Bot"
	},

	-- FUTURE shot parameters (placeholders; nothing reads these yet). Speeds in metres/second.
	Shot = {
		MinSpeedMps = 3,
		MaxSpeedMps = 22,
		ChargeTimeSeconds = 0.8,
		AimMaxYawDegrees = 35,
		AimMaxPitchDegrees = 25,
		SpinMaxRevsPerSecond = 100,
		HitWindowSeconds = 0.15,
	},

	Bot = {
		Name = "NotPongBot",
		WalkSpeed = 16,
		ShirtColor = Color3.fromRGB(200, 55, 55),
		SkinColor = Color3.fromRGB(226, 180, 140),
		PantsColor = Color3.fromRGB(40, 40, 50),
	},

	Camera = {
		FieldOfView = 62,
		Height = 34, -- studs above the floor
		DistanceBehind = 22, -- studs behind the player's root part (along +Z)
		ShoulderOffset = 8, -- studs to the player's right (+X, since the player faces -Z); moves the avatar off-centre
		LookAtHeightOffset = 0, -- added to table surface height for the aim point
		LookAheadStuds = 0, -- shifts the aim point toward the opponent (-Z)
		LateralFollow = 0.5, -- 0 = aim at table center, 1 = follow the player sideways
		Smoothing = 10, -- exponential follow rate (1/s)
		-- Local-only fade of the player's own avatar (0 = opaque, paddle excluded). Needed because avatars vary:
		-- a tested custom avatar (big head + a guitar accessory) is 36 studs tall in total and blocked every
		-- sampled point of the table from any reasonable camera position.
		AvatarTransparency = 0.7,
	},

	CollisionGroups = {
		Table = "NP_Table",
		Ball = "NP_Ball",
		Paddle = "NP_Paddle",
		Character = "NP_Character",
	},

	Names = {
		Arena = "NotPongArena",
		SeatedPlayerAttribute = "SeatedUserId",
	},

	Colors = {
		TableTop = Color3.fromRGB(22, 78, 150),
		Line = Color3.fromRGB(245, 245, 245),
		Leg = Color3.fromRGB(45, 45, 50),
		Net = Color3.fromRGB(235, 235, 235),
		Ball = Color3.fromRGB(255, 150, 20),
		PaddleBlade = Color3.fromRGB(190, 35, 35),
		PaddleHandle = Color3.fromRGB(205, 160, 110),
	},

	Debug = {
		ShowStateLabel = true,
		Verbose = true,
	},
}

return Config
