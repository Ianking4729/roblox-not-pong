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
-- CANONICAL vs PRESENTATION (read this before changing sizes)
--   Config.Real           canonical ITTF metres. Never edited for presentation reasons.
--   StudsPerMeter (10)    the unit conversion: 1 stud = 0.1 m. Unchanged by anything below.
--   ArenaScale (1.15)     presentation multiplier on the TABLE + NET assembly: every table/net stud value is
--                         metres * 10 * ArenaScale. Layout, serve points and BallPhysics surfaces derive from those,
--                         so they stay coherent automatically. With ArenaScale = 1 the arena is true 1 stud = 0.1 m;
--                         at 1.15 the table is 1.15x bigger relative to the avatar, ball and paddle, i.e. effectively
--                         1 stud = 0.0870 m for the table (0.1 / 1.15). Table proportions are unchanged.
--                         NOT scaled by ArenaScale: the ball's gameplay radius, gravity (98.1 studs/s^2 is a physical
--                         constant of the ball simulation, not of the table), the avatar height and the stand-back
--                         distance behind the end line (those are in true stud units).
--   TableWidthStuds (23)  the table's playing width, in studs, set DIRECTLY and independently of ArenaScale and of the
--                         canonical 1.525 m (which would give 17.5). Intended tuning range 22-24 (clamped to 20-26).
--                         This deliberately breaks the official aspect ratio for readability; the table length
--                         (31.51) and height (8.74) are untouched. Net length, lines, posts, playable bounds,
--                         BallPhysics surfaces and the play area all derive from it.
--   BallVisualScale(1.25) multiplier on the RENDERED ball only. The gameplay radius (Ball.Radius, 0.2 studs) is
--                         unchanged; physics never reads the visual size. At contact the 1.25x shell sinks 0.05 studs
--                         (5 mm) into the table; that is the deliberate, documented visual error.
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

-- Presentation-only multipliers (see the header). Edit these, never the Real table.
local Presentation = {
	ArenaScale = 1.15, -- table + net assembly (and everything derived from them)
	BallVisualScale = 1.25, -- rendered ball only
	TableWidthStuds = 23, -- table playing width; tune 22-24
}

-- Metres -> studs for the table/net assembly: the unit conversion times ArenaScale.
local function toArenaStuds(meters: number): number
	return meters * STUDS_PER_METER * Presentation.ArenaScale
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

-- All values below are at ArenaScale (27.4 / 15.25 / 7.6 at 1.0; 31.51 / 17.54 / 8.74 at 1.15).
local Table = {
	Length = toArenaStuds(Real.TableLength),
	Width = math.clamp(Presentation.TableWidthStuds, 20, 26), -- independent of ArenaScale (see header)
	Height = toArenaStuds(Real.TableHeight), -- to playing surface
	TopThickness = toArenaStuds(Real.TableTopThickness), -- visual slab only; the collision block is full height
	LineWidth = toArenaStuds(Real.LineWidth),
	CenterLineWidth = toArenaStuds(Real.CenterLineWidth),
	LegWidth = 0.6 * Presentation.ArenaScale,
	LegInsetX = 1.5 * Presentation.ArenaScale,
	LegInsetZ = 2.5 * Presentation.ArenaScale,
	Style = "Default", -- key into Config.TableStyles (cosmetic only)
}

local Net = {
	Height = toArenaStuds(Real.NetHeight),
	Overhang = toArenaStuds(Real.NetOverhang),
	Thickness = toArenaStuds(Real.NetThickness),
	Length = Table.Width + 2 * toArenaStuds(Real.NetOverhang),
	PostWidth = toArenaStuds(Real.NetPostWidth),
	TapeHeight = 0.15 * Presentation.ArenaScale,
}

-- GAMEPLAY ball: Radius is the canonical collision radius BallPhysics uses. Not affected by ArenaScale.
-- VISUAL ball: only the rendered part uses VisualDiameter.
local Ball = {
	Diameter = toStuds(Real.BallDiameter), -- 0.4
	Radius = toStuds(Real.BallDiameter) / 2, -- 0.2
	VisualDiameter = toStuds(Real.BallDiameter) * Presentation.BallVisualScale, -- 0.5
	Style = "Default", -- key into Config.BallStyles (cosmetic only)
}

-- PLAYING PLATFORM: a flat slab under the table and both players, sitting on the Baseplate (whose top is Y = 0).
-- Its top surface IS the playing floor, so Arena.FloorY = Platform.Thickness. Size is derived from the table and the
-- play area so it always supports them; Margin is the extra slab beyond the walkable area.
local PlayArea = {
	SideMargin = 8, -- studs the player may walk beyond each table side line
	FrontGap = 3, -- closest the player may stand to the end line (studs behind it)
	BackLimit = 24, -- furthest the player may stand behind the end line
	-- The area bounds the character's ROOT centre; the boundary walls' inner faces sit this much further out so the
	-- body (about 3.4 studs half-width, 1.7 half-depth, for a scaled R15) does not poke past the platform.
	BodyMarginX = 3.5,
	BodyMarginZ = 2,
}
local Platform = {
	Thickness = 1,
	Material = Enum.Material.SmoothPlastic,
	Color = Color3.fromRGB(88, 92, 100),
	Size = Vector3.new(
		Table.Width + 2 * (PlayArea.SideMargin + 8),
		1,
		Table.Length + 2 * (PlayArea.BackLimit + 8)
	),
}

local Arena = {
	-- Center of the table footprint at floor level. Offset on Z to stay clear of the pre-existing Workspace.Rig.
	Origin = Vector3.new(0, 0, 60),
	FloorY = Platform.Thickness, -- top of the playing platform (Baseplate top is 0)
}

local Avatar = {
	-- Every competitor is scaled so feet-to-top-of-head (accessories ignored) equals this. There is deliberately
	-- no fixed scale factor: avatars differ a lot (default R15 is 5.46 studs tall at scale 1, a tested custom
	-- avatar only 2.77), so AvatarService measures each body and computes the factor.
	Height = toStuds(Real.AvatarHeight), -- 17.5
	StandBack = toStuds(Real.AvatarStandBack), -- 10
	WalkSpeed = 24, -- studs/s, applied AFTER the avatar is scaled (ScaleTo would otherwise multiply it)
}

local Serve = {
	RestFromEndLine = 3, -- studs in from the end line where the ball rests before a serve
	-- Sideways offset toward the server's paddle hand (measured: scaled R15 hands hang 4.7 studs from centre).
	-- Keeps the resting ball out from behind the player's own body as seen from the camera.
	-- The player's right is +X; the bot faces the other way, so its right is -X.
	RestSideOffset = 4.7,
	-- PHASE 2 serve (placeholder: the ball is held, tossed straight up, and struck on the way down).
	HoldBehindEndLine = 1.5, -- studs behind the server's end line where the ball is held (rules: behind the end line)
	HoldAboveTable = 4, -- studs above the table surface (the ball is struck when it falls back to this height).
	-- Tested: at 2.5 serves had to be 8-11 m/s and ~5% found no legal trajectory; at 4 every test serve was legal at 6-9 m/s.
	TossSpeed = 20, -- studs/s straight up (rises ~2 studs)
	FirstBounceDepth = 0.65, -- first bounce, as a fraction of the server's half from the net (0 net .. 1 end line)
	SecondBounceDepth = 9, -- desired second bounce, studs past the net on the receiver's half
	Speed = 70, -- initial horizontal speed guess, studs/s (7 m/s); the solver bisects within Min..Max
	MinSpeed = 25,
	MaxSpeed = 110,
	Topspin = 20, -- rad/s (~3 rev/s)
	Sidespin = 0,
	TargetSpreadX = 3, -- random +/- studs on the bounce targets so serves are not identical
	BotDelay = 1.5, -- seconds the bot waits in ReadyToServe before serving
	PlayerReach = 16, -- server validation: the player's root must be within this many studs (horizontal) of the held ball
	RequestCooldown = 0.3, -- seconds between accepted serve requests from a client
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
	-- Where the ball is HELD before a serve: behind the server's end line, on their paddle side, above table height.
	ServeBall = {
		Player = Vector3.new(originX + Serve.RestSideOffset, surfaceY + Serve.HoldAboveTable, originZ + halfL + Serve.HoldBehindEndLine),
		Bot = Vector3.new(originX - Serve.RestSideOffset, surfaceY + Serve.HoldAboveTable, originZ - halfL - Serve.HoldBehindEndLine),
	},
	-- Walkable rectangles (studs), per side. Used by the boundary walls, the server guard and the camera.
	PlayerArea = {
		minX = originX - halfW - PlayArea.SideMargin,
		maxX = originX + halfW + PlayArea.SideMargin,
		minZ = originZ + halfL + PlayArea.FrontGap,
		maxZ = originZ + halfL + PlayArea.BackLimit,
	},
	BotArea = {
		minX = originX - halfW - PlayArea.SideMargin,
		maxX = originX + halfW + PlayArea.SideMargin,
		minZ = originZ - halfL - PlayArea.BackLimit,
		maxZ = originZ - halfL - PlayArea.FrontGap,
	},
	PlatformCenter = Vector3.new(originX, Arena.FloorY - Platform.Thickness / 2, originZ),
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
		toArenaStuds = toArenaStuds,
	},
	Presentation = Presentation,
	Real = Real,
	Table = Table,
	Net = Net,
	Ball = Ball,
	Arena = Arena,
	Platform = Platform,
	PlayArea = PlayArea,
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
		VisualScale = 2.0, -- R15 fists are ~3.3 studs; at 1.6 the blade was mostly hidden inside the fist
		-- GRIP (visual only; hit detection never reads it). The paddle is held by a Motor6D on the hand's standard
		-- RightGripAttachment. In the ready stance that attachment's +Y points up and its -Z (LookVector) points the way
		-- the carrier faces. The paddle's own frame: +Y toward the blade tip, broad face along +/-Z.
		--   Offset          : studs in the grip attachment's frame (+Z = back toward the wrist, +Y = up).
		--   RotationDegrees : rotation in that frame after the offset (X: -tips the blade forward; Z: -tips it outward).
		--   HandlePoint     : where the fist closes on the handle, as a fraction of the handle length from its centre.
		-- Change these (or swap Grip for a per-animation table later) without touching gameplay.
		Grip = {
			Offset = Vector3.new(0, 0.25, 0.5), -- handle top just above the fist, blade fully clear of it
			RotationDegrees = Vector3.new(-10, 0, -8),
			HandlePoint = -0.25,
		},
	},

	-- Ball physics in the exact shape BallPhysics expects (all studs / seconds / radians; see the UNITS header).
	-- Derivations for a real 40 mm, 2.7 g ball: drag = 0.5*rho*Cd*A/m = 0.14 /m = 0.014 /stud; Magnus coefficient
	-- ~0.0056 (same in m or studs); table e ~0.9 (ITTF rebound test) and table friction ~0.25.
	BallPhysics = {
		radius = Ball.Radius,
		gravity = toStuds(Real.Gravity), -- 98.1 studs/s^2
		restitution = 0.9, -- table, normal direction
		tableFriction = 0.25, -- table Coulomb friction (spin <-> speed coupling at the bounce)
		restSpeed = 1, -- studs/s; below this the ball settles instead of bouncing
		fixedStep = 1 / 240, -- 240 Hz: a 150 studs/s ball moves 0.6 studs per tick (contacts are swept anyway)
		maxStepsPerUpdate = 40,
		drag = 0.014, -- 1/stud, quadratic air drag. 0 = vacuum
		magnus = 0.0056, -- a = magnus * (spin x velocity). 0 = spin never curves the ball
		-- PHASE 4 curvature tuning (NOT PONG exaggerates spin, but stays controllable). Effective coefficient =
		-- magnus * MagnusGain / (1 + |spin| / MagnusSaturation). Raise MagnusGain for more bend at every spin level;
		-- lower MagnusSaturation for stronger diminishing returns (0 = linear). 1 / 0 reproduces Phase 3 exactly.
		magnusGain = 3.2,
		magnusSaturation = 200, -- rad/s
		-- SIDESPIN curvature (refinement pass). Only the spin about the vertical axis, whose Magnus push is purely
		-- sideways, is exaggerated further, so top/backspin lift and dip are unchanged (bot shots and serves carry no
		-- sidespin and are unaffected). magnusSideSpeedRef makes that push scale with horizontal speed / ref, so the
		-- ball turns by the same angle per stud at any speed: soft and hard shots curve with the same SHAPE.
		-- Presets tested (full sidespin, full power, ~33-stud flight): moderate 2.0 (bend 5.0 studs, turns ~68 deg),
		-- strong 2.6 (6.8, ~91 deg), very strong 3.2 (8.6, ~120 deg). 1 / 0 = the previous behaviour.
		magnusSideGain = 2,
		magnusSideSpeedRef = 75, -- studs/s
		-- Table bounce: extra impulse = -BounceSpinKick * (spin's contact-point velocity, spin * radius). Topspin kicks
		-- forward, backspin checks, sidespin kicks sideways. 0 = Phase 3 (friction only).
		bounceSpinKick = 0.5,
		spinDecay = 0.2, -- 1/s
		netRestitution = 0.15,
		netFriction = 0.4,
		netCordKeep = 0.7, -- fraction of speed kept when the ball clips the top of the net
		floorRestitution = 0.55,
		floorFriction = 0.5,
		sideRestitution = 0.4,
		maxSpeed = 400, -- studs/s (40 m/s, faster than any real shot)
		maxSpin = 1000, -- rad/s (~160 rev/s)
	},

	Physics = {
		PaddleRestitution = 0.85, -- FUTURE (Phase 3): BallPhysics.paddleHit for player swings
		PaddleFriction = 0.6,
	},

	-- RALLY (server). Shots shared by the bot and the temporary auto-return.
	Rally = {
		NetClearance = 0.8, -- studs: solved shots must clear the net top by at least this much
		HitCooldown = 0.25, -- seconds before the same side may be credited with another hit (no double contacts)
		ContactMinAboveFloor = 4, -- studs: ball-centre height window in which a paddle can reach it
		ContactMaxAboveFloor = 20,
		SnapshotInterval = 0.5, -- seconds between periodic ball snapshots to clients (also sent on every contact)
	},

	-- BOT opponent (server). Reach and anchor are in studs, relative to the bot's root, in its own facing frame.
	BotPlay = {
		Reach = 8, -- horizontal studs from the paddle anchor within which the bot can hit
		AnchorRight = 4, -- paddle anchor: this far to the bot's right ...
		AnchorForward = 3, -- ... and this far in front of its root
		ReactionTime = 0.25, -- seconds after the opponent's hit before the bot starts moving
		ReturnSpeed = 62, -- horizontal launch speed, studs/s (6.2 m/s)
		ReturnSpeedVariation = 6, -- +/- studs/s
		Topspin = 80, -- rad/s (~13 rev/s)
		TargetDepthMin = 0.45, -- landing depth on the opponent's half (fraction from the net)
		TargetDepthMax = 0.75,
		TargetSpreadX = 5, -- +/- studs across the table
		AimError = 0.6, -- +/- studs of random error added to the target (accuracy)
		MaxStepBack = 14, -- furthest behind its end line the bot will move to (studs)
		MinStepBack = 4, -- closest to its end line
		HomeStepBack = 10, -- where it waits
	},

	-- TEMPORARY automatic player returns (Phase 2 only; Phase 3 replaces this with mouse aiming/timing).
	AutoReturn = {
		Enabled = false, -- superseded by ShotControl (Phase 3); set true (and ShotControl.Enabled false) to test physics hands-free
		Reach = 11, -- generous so a standing player sustains rallies while the physics is evaluated
		AnchorRight = 4,
		AnchorForward = 3,
		ReturnSpeed = 62,
		ReturnSpeedVariation = 6,
		Topspin = 80,
		TargetDepthMin = 0.45,
		TargetDepthMax = 0.75,
		TargetSpreadX = 5,
		AimError = 0.6,
	},

	Timing = {
		ServeReadyDelay = 1.0, -- seconds from ReadyToServe before a serve may begin
		PointResetDelay = 1.5, -- seconds shown on PointScored before the next point
		RallyTimeout = 10, -- seconds without a hit before the rally is ended (the side that should have hit loses)
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

	-- Ready stance (placeholder pose). Applied as additive Motor6D C0 rotations in degrees, so Roblox's own
	-- idle/walk animation layers on top. Signs follow R15 joint axes: +X swings a hanging limb forward.
	-- Knee bend lowers the body, so HipHeight is reduced by the computed drop to keep the feet on the floor.
	Stance = {
		KneeBendDegrees = 20, -- hip flexion; the knee bends twice this (feet stay planted)
		LeanDegrees = 12, -- forward lean at the waist
		HeadCounterDegrees = 8, -- tips the head back up so the eyes stay on the table
		RightShoulder = Vector3.new(45, 0, 18), -- x: raise forward, z: out from body (degrees)
		RightElbow = Vector3.new(60, 0, 0),
		LeftShoulder = Vector3.new(30, 0, -18),
		LeftElbow = Vector3.new(45, 0, 0),
		-- Grounding / locomotion (StancePose.start). HipHeight is MEASURED per avatar, these only shape the blend.
		FootSink = 0.05, -- studs the soles sit into the floor (hides float from rounding; 0 = exactly on it)
		MoveSpeedThreshold = 2, -- horizontal studs/s above which the bent-knee legs fade out and the walk cycle shows
		LegBlendRate = 10, -- 1/s, how fast the legs blend between stance and walking
		-- While walking, HipHeight follows a peak of the lowest foot point: instant when a stride reaches lower, relaxing
		-- at WalkGroundingDecay (1/s) toward the deepest point of the last WalkGroundingWindow seconds (~one stride).
		-- Works for any avatar and walk/run animation (StancePose.start).
		WalkGroundingWindow = 0.7,
		WalkGroundingDecay = 1.5,
	},

	-- Keeps the player's avatar facing the table during play. Client-side, via an AlignOrientation constraint (a
	-- torque-driven rotation of the root part, not teleporting) with Humanoid.AutoRotate turned off.
	Facing = {
		Enabled = true,
		-- Aim point: the centre of the opponent's end line, blended toward the player's own X by AimFollowX.
		--   0 = always face the centre of the opponent's end line (turns inward as you sidestep: about 26 degrees at the
		--       side walls),
		--   1 = always face straight down the table (never turns while you sidestep).
		-- 0.5 turns about 13 degrees at the side walls, which reads naturally and keeps the paddle side stable.
		AimFollowX = 0.5,
		Responsiveness = 30, -- AlignOrientation responsiveness; higher turns faster
		MaxTorque = 1e7,
	},

	Bot = {
		Name = "NotPongBot",
		WalkSpeed = 24, -- studs/s, applied AFTER scaling
		ShirtColor = Color3.fromRGB(167, 167, 167),
		SkinColor = Color3.fromRGB(167, 167, 167),
		PantsColor = Color3.fromRGB(167, 167, 167),
	},

	-- CAMERA (refinement pass): a LOW third-person view behind the player, like the concept art: the avatar's upper body
	-- and paddle in the foreground, the table stretching away to the opponent, the curve arrow rising above it.
	-- Reference spot (the player StandBack behind the end line, centred): camera Height above the floor, DistanceBehind
	-- behind the root and ShoulderOffset to the side, aimed at the table centre + LookAtHeightOffset, LookAheadStuds toward the opponent.
	-- When the player moves:
	--   back/forward: per stud further back, the camera moves back DistancePerBackStud, up HeightPerBackStud, and the aim
	--                 point slides toward the player AimPerBackStud (the table stays framed as the avatar walks away).
	--   sideways:     the camera follows the player's X by CameraXFollow and the aim point by LateralFollow.
	-- (Previous high overview: FieldOfView 58, Height 42, DistanceBehind 15, LookAtHeightOffset -3.74, LookAheadStuds -1.)
	Camera = {
		FieldOfView = 58,
		Height = 26, -- studs above the floor (the avatar is 17.5 tall: the camera looks over its shoulder)
		DistanceBehind = 19, -- studs behind the player's root at the reference position
		ShoulderOffset = 8, -- studs to the player's right (+) / left (-): over the paddle shoulder, so the avatar sits
		-- lower-left and the paddle and the arrow's start are in clear view (tuned from Studio screenshots)
		DistancePerBackStud = 0.2,
		HeightPerBackStud = 0.2,
		AimPerBackStud = 0.6, -- aim point moves toward the player (+Z) by this per stud walked back
		CameraXFollow = 0.7, -- camera X = table X + (player X offset) * this
		LateralFollow = 0.4, -- aim X = table X + (player X offset) * this
		LookAtHeightOffset = 0, -- added to table surface height for the aim point
		LookAheadStuds = 3, -- shifts the aim point toward the opponent (-Z); negative = toward the player
		Smoothing = 8, -- exponential follow rate (1/s); lower = softer, slower camera
		-- Feed-forward: the follow target is the player's position plus their horizontal velocity times this. An
		-- exponential follow trails a walking target by speed/Smoothing; 1/Smoothing cancels that lag exactly, so the
		-- avatar does not slide toward the bottom edge while walking back at full speed.
		VelocityLead = 0.125,
		-- (The avatar fade moved to Config.CharacterFade / Client/CharacterFade.)
	},

	CollisionGroups = {
		Table = "NP_Table",
		Boundary = "NP_Boundary", -- invisible walls that keep characters on the platform
		Ball = "NP_Ball",
		Paddle = "NP_Paddle",
		Character = "NP_Character",
	},

	Names = {
		Arena = "NotPongArena",
		PlayerSpawn = "PlayerSpawn", -- SpawnLocation in the arena: its X/Z is where the player stands
		BotSpawn = "BotSpawn", -- marker Part in the arena: its X/Z is where the bot stands
		Boundary = "Boundary",
		PlatformPart = "Platform",
		ArenaVersionAttribute = "NotPongArenaVersion",
		SeatedPlayerAttribute = "SeatedUserId",
		BoostStaminaAttribute = "NotPongBoostStamina",
		BoostExhaustedAttribute = "NotPongBoostExhausted",
		Remotes = "NotPongRemotes", -- ReplicatedStorage folder created at runtime (BallSnapshot, ServeRequest)
	},

	-- COSMETICS. Purely visual; nothing in gameplay or physics reads these. A style is applied by
	-- ArenaBuilder.applyBallStyle / applyTableStyle without touching geometry or collision.
	BallStyles = {
		Default = {
			Color = Color3.fromRGB(255, 150, 20),
			Material = Enum.Material.SmoothPlastic,
			Reflectance = 0,
			TextureId = "", -- FUTURE: pattern/texture (applied to the visual shell only)
			Trail = { Enabled = false, Color = Color3.fromRGB(255, 200, 120), Lifetime = 0.25, Width = 0.3 },
		},
	},
	TableStyles = {
		Default = {
			SurfaceColor = Color3.fromRGB(22, 78, 150),
			Material = Enum.Material.SmoothPlastic,
			TextureId = "", -- FUTURE: surface pattern
			LineColor = Color3.fromRGB(245, 245, 245),
		},
	},

	Colors = {
		Line = Color3.fromRGB(245, 245, 245),
		Leg = Color3.fromRGB(45, 45, 50),
		Net = Color3.fromRGB(235, 235, 235),
		PaddleBlade = Color3.fromRGB(190, 35, 35),
		PaddleHandle = Color3.fromRGB(205, 160, 110),
	},

	-- Phase 3 player shot controls: PRE-AIM (mouse) -> LOCK (hold left button) -> DRAG FOR SPIN -> RELEASE TO SWING.
	-- The client only REQUESTS a swing (target, drag, release time); the server re-derives and validates everything.
	ShotControl = {
		Enabled = true,
		-- timing (seconds)
		ContactWindowDuration = 0.25, -- clean-contact window centred on the moment the ball is closest to the paddle
		EarlyReleaseTolerance = 0.1, -- beyond the clean window: this much earlier still gives a WEAK contact
		LateReleaseTolerance = 0.1, -- ... and this much later
		AutoReleaseAtWindowEnd = false, -- true: holding past the window swings automatically at its last moment
		-- reach (studs). Contact availability comes from the ball's simulated distance to this anchor, not a timer.
		PaddleReach = 9, -- horizontal radius around the anchor (0.9 m)
		AnchorRight = 4, -- anchor: this far to the player's right ...
		AnchorForward = 3, -- ... and this far in front of the root (same rule as the bot)
		-- CHARGE -> CURVE -> RELEASE. Holding left-click charges POWER (hold time only); dragging the mouse while holding
		-- sets SPIN (accumulated relative mouse movement). The cursor position never chooses where the ball goes.
		-- power from hold time (the server measures the hold itself from the press/release times, see RallyService)
		ChargeTime = .4, -- seconds of holding for full power (a normal rally gives ~0.7 s from the bot's hit to contact; press earlier to reach full)
		ChargeExponent = 1, -- power = (hold / ChargeTime) ^ exponent. 1 = linear; >1 = slow start, fast finish
		-- spin from the drag (pixels of mouse movement accumulated while holding; dragging back reduces / reverses it)
		SpinSensitivity = 1, -- multiplies the drag distance
		SpinDragPixels = 180, -- drag (pixels, at sensitivity 1) for full spin
		SpinDeadzonePixels = 6, -- smaller drags give no spin
		SpinCurveExponent = 1.1, -- >1 = finer control at small drags (was 1.4: a half drag gave only 38% spin, so medium curves were faint)
		MaxSpin = 90, -- rad/s cap on the total spin (~19 rev/s; the bot plays 80)
		DragOvershootPixels = 30, -- the accumulated drag is clamped this far past full spin, so reversing is quick
		-- launch (Shared/ShotLaunch). Power sets the launch speed AND how deep a spin-free shot of that power would land;
		-- the launch elevation is calibrated to that depth, then the full spin is applied and bends the real flight.
		MinShotSpeed = 48, -- horizontal launch speed at zero charge, studs/s (was 44)
		MaxShotSpeed = 100, -- ... at full charge (was 80; the bot plays 62)
		TopspinSpeedBonus = 0.12, -- full topspin launches this much faster (a driven shot); scales with the topspin
		BackspinSpeedPenalty = 0.15, -- full backspin launches this much slower (a floated push)
		MinShotDepth = 0.4, -- spin-free landing depth on the opponent's half at zero charge (0 = net, 1 = end line)
		MaxShotDepth = 0.82, -- ... at full charge
		FollowLateral = 0.45, -- default direction: 0 = always toward the centre line, 1 = straight down the table from the contact point
		LateralMargin = 2.5, -- the default direction stays this far inside the opponent's side lines (studs)
		-- How much of the spin's effect the launch angle anticipates (0 = none: spin moves the landing fully;
		-- 1 = fully: the curve shows but always ends at the default point). Low = more skill and more risk.
		TopspinCompensation = 0.55,
		BackspinCompensation = 0.88, -- backspin lifts much more than topspin dips: anticipated more, or it always floats long
		-- Sidespin is anticipated a lot now because the curve itself is huge: the ball still bends 5-9 studs off its chord,
		-- but full sidespin moves the LANDING by ~5-8 studs (enough to reach a corner, or miss from a wide contact).
		SidespinCompensation = 0.66,
		-- weak (early/late) contacts
		WeakSpeedFactor = 0.8,
		WeakSpinFactor = 0.4,
		WeakAimError = 4, -- +/- studs of random error in the default direction / depth
		-- networking / anti-spam
		MaxLatencyCompensation = 0.2, -- seconds the server will rewind to judge a release (caps "lag reach")
		SwingCooldown = 0.3, -- seconds between swing requests
		ResultTimeout = 1, -- client: seconds to wait for the server's verdict
		RecoveryTime = 0.35, -- client: seconds in RECOVERY before aiming again
		ShowDiagnostics = true, -- development-only debug bridges (Player.NotPongShotDebug / NotPongArrowDebug) used by Studio test scripts
		ShowInputDebug = true, -- TEMPORARY on-screen overlay (top left) tracing the input pipeline: button, mouse events, drag, spin, meter, arrow. Set false once verified.
	},

	-- CHARGE SLOW MOTION (server-authoritative; Server/RallyService + Client/ShotController). When the incoming ball is
	-- close to contact, the ball, bot and player move at TimeScale while you charge and curve.
	ChargeFreeze = {
		Enabled = true,
		-- Match modes that may use it. Solo (vs the bot) only: slow motion must not affect another human's game.
		Modes = { Solo = true, PvP = false },
		LeadTime = 0.45, -- seconds before ideal contact when a press can start slow motion
		MaxDuration = .4, -- maximum real-time duration; if it expires, the swing is lost
		TimeScale = 0.35, -- ball simulation, character movement and animations run at this fraction of normal speed
		SlowBotAnimations = true,
		-- client visuals
		TintSaturation = -0.35, -- ColorCorrection while slowed (subtle; 0 = none)
		TintColor = Color3.fromRGB(236, 228, 255),
		TintFadeTime = 0.12,
		TimerColor = Color3.fromRGB(200, 140, 255),
		TimerLowColor = Color3.fromRGB(255, 110, 120), -- last 30% of the slow-motion window
	},

	-- ===== PHASE 4 =====================================================================================================

	-- Keeps characters off the table (Server/TableGuard): an invisible block on the table's own footprint only, from the
	-- playing surface up to Height. Collides with characters only (never the ball). No walls around the table.
	TableGuard = {
		Enabled = true,
		Height = 36, -- studs above the playing surface (about two avatar heights; the avatar's jump apex is ~21)
		Margin = 0, -- studs added around the table footprint (0 = exactly the table)
		Name = "TableGuard",
	},

	-- Movement (server-applied; see Server/MovementService). Shift = boost.
	Movement = {
		BoostEnabled = true,
		BoostMultiplier = 2.25, -- Shift: WalkSpeed = Avatar.WalkSpeed * this; releasing Shift restores the base speed
		BoostRequestInterval = 0.04, -- server: minimum seconds between boost-on requests (anti-spam; releases are never throttled)
		MaxStamina = 100, -- displayed as a percentage in the HUD
		BoostDuration = .8, -- seconds of continuous boost from full stamina
		StaminaRegenerationDelay = 1, -- seconds after boost ends before recovery begins
		StaminaRegenerationDuration = 3, -- seconds to refill an empty stamina bar
		-- Optional jump cap (studs). nil = leave the Roblox jump alone. Not needed to keep players off the table
		-- (TableGuard does that); set a number only if you want lower jumps.
		MaxJumpHeight = nil :: number?,
	},

	-- The local player's own avatar is translucent ON the platform (so it never blocks the table) and fully visible off it.
	-- Every part of the character (head, body, hair, hats, face accessories, decals) uses the same value; the paddle never fades.
	CharacterFade = {
		Transparency = 0.6, -- 0 = opaque, 1 = invisible (on the platform)
		TransitionTime = 0.25, -- seconds to fade between the two states
		EnterMargin = 0.5, -- studs INSIDE the platform edge the root must be before fading in
		ExitMargin = 1.5, -- studs OUTSIDE the platform edge before restoring (hysteresis: no flicker on the edge)
	},

	-- Procedural paddle-arm swing (an Action2 animation layered over the ready stance). Visual only.
	Swing = {
		Duration = 0.34, -- seconds, whole swing
		CleanStrength = 1, -- 1 = full amplitude
		WeakStrength = 0.55,
		MissStrength = 0.7,
		-- Rotation offsets (degrees) added to Config.Stance.RightShoulder / RightElbow at each key.
		BackShoulder = Vector3.new(-32, 0, 8),
		StrikeShoulder = Vector3.new(38, 0, -16),
		FollowShoulder = Vector3.new(52, 0, -22),
		BackElbow = Vector3.new(20, 0, 0),
		StrikeElbow = Vector3.new(-30, 0, 0),
		FollowElbow = Vector3.new(-18, 0, 0),
		BackTorso = Vector3.new(0, 10, 0), -- waist twist (degrees about the vertical axis)
		StrikeTorso = Vector3.new(0, -12, 0),
		FollowTorso = Vector3.new(0, -16, 0),
	},

	-- Client-side visual feedback (never authoritative). Colours are cosmetic and independent of gameplay.
	Feedback = {
		-- 3D trajectory arrow (Client/TrajectoryArrow): the predicted flight of the charged shot, from the predicted
		-- paddle contact to the first predicted landing, simulated with the shared BallPhysics. Shown while charging.
		Arrow = {
			Color = Color3.fromRGB(236, 170, 255), -- bright core (additive glow)
			GlowColor = Color3.fromRGB(176, 60, 255), -- wider purple halo (not additive, so it stays purple on any table colour)
			BadColor = Color3.fromRGB(255, 70, 90), -- predicted to hit the net / miss the table
			Width = 0.45, -- studs, core
			GlowWidth = 1.3, -- studs, halo
			HeadLength = 3.2, -- studs
			HeadWidth = 2.4, -- studs
			Segments = 28, -- beam segments along the path (pooled; nothing is created per frame)
			CoreTransparency = 0.05,
			GlowTransparency = 0.55,
			StartFade = 0.3, -- fraction of the path over which the start fades in (keeps the paddle readable)
			WeakTransparency = 0.45, -- extra transparency while a release right now would only be a WEAK contact
			RecomputeInterval = 0.04, -- seconds between predictions (power and spin change continuously)
			Smoothing = 22, -- 1/s: the drawn path eases toward each new prediction
			EndRingRadius = 1.5, -- studs: highlight on the predicted landing spot
		},
		-- Power / curve meter (bottom right): Power fills with hold time ONLY; Curve shows the spin strength.
		PowerMeter = {
			Width = 220,
			Segments = 5,
			PowerColor = Color3.fromRGB(200, 110, 255),
			FullColor = Color3.fromRGB(255, 120, 230), -- the power bar at full charge
			CurveColor = Color3.fromRGB(170, 120, 255),
			ShowAfterRelease = 0.7, -- seconds the meter stays after the swing
		},
		-- Spin dial: appears where you press the button; the arrow is your charged spin.
		SpinDial = {
			RadiusPixels = 62,
			IdleColor = Color3.fromRGB(235, 235, 245),
			LowColor = Color3.fromRGB(255, 255, 255),
			HighColor = Color3.fromRGB(255, 120, 40), -- full spin
		},
		-- Contact timing bar (bottom centre): the predicted clean / weak release window and a moving "now" needle.
		Timing = {
			SecondsBefore = 0.55, -- bar spans this long before the ideal moment ...
			SecondsAfter = 0.2, -- ... and this long after
			Width = 300,
			Offset = 120, -- pixels above the bottom edge
			CleanColor = Color3.fromRGB(90, 230, 120),
			WeakColor = Color3.fromRGB(255, 205, 70),
			MissColor = Color3.fromRGB(255, 80, 80),
			ResultShowTime = 0.9,
		},
		-- Ball trail (follows the rendered ball; drawn from its real position every frame, so it shows the real curve).
		Trail = {
			Enabled = true,
			Lifetime = 0.4,
			Width = 0.55, -- studs
			SlowColor = Color3.fromRGB(190, 200, 215),
			FastColor = Color3.fromRGB(255, 255, 255),
			TopspinColor = Color3.fromRGB(255, 150, 70), -- tint by dominant spin axis (kept subtle)
			BackspinColor = Color3.fromRGB(110, 180, 255),
			SidespinColor = Color3.fromRGB(190, 120, 255),
			TintStrength = 0.75, -- 0 = no spin tint; 1 = full tint at maximum spin
			FullSpeed = 110, -- studs/s at which the trail is at full brightness / width
			MinTransparency = 0.25, -- most opaque the trail gets (fast ball)
			MaxTransparency = 0.7, -- slow ball
			WidthScaleSpinned = 1.35, -- width multiplier at maximum spin
			SpinFullAt = 100, -- rad/s treated as "full spin" for the visuals
		},
		-- Impact burst when the server confirms a hit.
		Impact = {
			CleanColor = Color3.fromRGB(120, 255, 150),
			WeakColor = Color3.fromRGB(255, 215, 110),
			CleanParticles = 16,
			WeakParticles = 5,
			RingSize = 4.5, -- studs, clean hit ring
		},
		-- Receiver outline: the character about to receive the ball gets a green outline.
		Outline = {
			Enabled = true,
			ReceiverColor = Color3.fromRGB(70, 255, 110),
			NeutralColor = Color3.fromRGB(255, 255, 255),
			NeutralTransparency = 0.78, -- unobtrusive for the non-receiver
			ReceiverTransparency = 0.05,
			FadeTime = 0.12,
		},
	},

	Debug = {
		ShowStateLabel = true,
		Verbose = true,
	},
}

return Config
