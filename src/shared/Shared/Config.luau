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
--   ArenaScale (1.725)    presentation multiplier on the table LENGTH + NET assembly: those stud values are
--                         metres * 10 * ArenaScale (length 47.27, net height 2.63). Layout, serve points and BallPhysics
--                         surfaces derive from them, so they stay coherent automatically.
--                         NOT scaled by ArenaScale: the table height (TableHeightStuds), the ball (BallDiameterStuds),
--                         gravity (98.1 studs/s^2), the avatar height and the stand-back distance behind the end line.
--   TableHeightStuds(8.74) floor to playing surface, set directly (tuned to the 17.5-stud avatar).
--   TableWidthStuds (34.5) the table's playing width, set DIRECTLY (clamped 20-40). Deliberately wider than the official
--                         aspect ratio for readability. Net length, lines, posts, playable bounds, BallPhysics surfaces
--                         and the play area all derive from it.
--   BallDiameterStuds(1.5) the gameplay ball (collision radius 0.75); BallVisualScale (1) = rendered / gameplay, so the
--                         visible ball is the simulated ball. Spin coupling at bounces keeps the real ball's lever arm
--                         (BallPhysics.spinRadius 0.2), so spin behaves as before.
--   The VISUAL table is the uploaded TableAsset model, fitted to these numbers by ArenaBuilder.fitTableAsset().
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
-- 2026-11-15 ENLARGED TABLE (confirmed: x1.5 of the previous 31.51 x 23 plan, wide shape kept, height kept):
--   ArenaScale 1.15 -> 1.725 (length 47.27, net height 2.63), TableWidthStuds 23 -> 34.5, the HEIGHT is set on its own
--   (TableHeightStuds, unchanged 8.74: it is tuned to the 17.5-stud avatar, paddle reach and the smash height), and the
--   ball is 1.5 studs for BOTH physics and rendering (was 0.4 physics / 1.0 visual).
-- To resize the table: change these, run ArenaBuilder.syncGeometry() then ArenaBuilder.fitTableAsset() in Edit mode
-- (docs/current-state.md, "Table asset and editing workflow").
local Presentation = {
	ArenaScale = 1.725, -- table LENGTH + net assembly (and everything derived from them); not the table height
	TableHeightStuds = 8.74, -- floor to playing surface (was toArenaStuds(0.76) at ArenaScale 1.15)
	TableWidthStuds = 34.5, -- table playing width
	BallDiameterStuds = 1.5, -- the GAMEPLAY ball diameter (physics, contacts, bounces)
	BallVisualScale = 1, -- rendered ball / gameplay ball. 1 = the visible ball is exactly the simulated one
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

-- All values below are at ArenaScale (27.4 / 15.25 at 1.0; 47.27 long at 1.725). Height is set directly.
local Table = {
	Length = toArenaStuds(Real.TableLength),
	Width = math.clamp(Presentation.TableWidthStuds, 20, 40), -- independent of ArenaScale (see header)
	Height = Presentation.TableHeightStuds, -- to playing surface (independent of ArenaScale)
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

-- GAMEPLAY ball: Radius is the collision radius BallPhysics uses (table, net, floor contacts, paddle reach heights).
-- VISUAL ball: the rendered BallVisual is VisualDiameter (= Diameter at BallVisualScale 1, so what you see is what
-- bounces). The spin lever arm at bounces stays the real ball's (BallPhysics.spinRadius) so spin behaves as tuned.
local Ball = {
	Diameter = Presentation.BallDiameterStuds, -- 1.5
	Radius = Presentation.BallDiameterStuds / 2, -- 0.75
	VisualDiameter = Presentation.BallDiameterStuds * Presentation.BallVisualScale, -- 1.5
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
	SecondBounceDepth = 13.5, -- desired second bounce, studs past the net on the receiver's half (x1.5 with the table; was 9)
	-- Speeds x1.15 with the enlarged table (confirmed 2026-11-15: partial speed-up, flights take longer than before)
	Speed = 80, -- initial horizontal speed guess, studs/s; the solver bisects within Min..Max (was 70)
	MinSpeed = 29, -- (was 25)
	MaxSpeed = 126, -- (was 110)
	Topspin = 20, -- rad/s (~3 rev/s)
	Sidespin = 0,
	TargetSpreadX = 4.5, -- random +/- studs on the bounce targets so serves are not identical (x1.5; was 3)
	BotDelay = 1.5, -- seconds the bot waits in ReadyToServe before serving
	PlayerReach = 16, -- (legacy fixed-spot check; the player serve now uses the legal region below)
	RequestCooldown = 0.3, -- seconds between accepted serve requests from a client

	-- PLAYER SERVE (2026-11-16 pass 3: natural toss, no slow motion, contact-based and forgiving). The ball rests in the
	-- free (left) hand; Space plays the toss clip and the ball leaves the hand at its Release marker, rises, slows near the
	-- apex and falls under the normal shared physics (no time dilation anywhere in the serve). A fresh left-click locks the
	-- aim (cursor X) and charges, drag = spin, release = swing. When the paddle meets the FALLING ball inside its contact
	-- phase (height band + reach, judged on the server's own simulation of the toss), the serve is LEGAL: Shared/ShotLaunch
	-- .serve solves a launch with the shared physics so it bounces on the server's half, then the receiver's; power sets
	-- the pace (how deep it lands), aim the placement across the table, spin the flight and the kick (in full when it can
	-- be made legal, else the same spin direction scaled down). Real misses: still rising (early), dropped below the band
	-- (late), out of reach, or never struck (the toss falls). The bot keeps its own automatic serve.
	-- Hand positions are the /animate clip NP_ServeToss's left-hand centre (block-rig studs from the root, x the avatar's
	-- scale in game): frame 0 (held) and the "Release" marker frame (the ball leaves the hand).
	HandHold = Vector3.new(-0.68, -0.52, -1.70),
	HandRelease = Vector3.new(-0.97, 1.16, -1.58),
	HandTop = 0.15, -- block-rig studs from the hand's centre to its palm (the ball rests on it)
	-- SERVING POSTURE (2026-11-17): before the toss, Q switches between two moderately side-on postures; Space locks the
	-- one selected for that serve. "LeftLead" = the left hip leads toward the table (the body turned right); "RightLead" =
	-- the right hip leads (turned left). The hips turn HipYaw degrees (the legs turn with them, feet stay on the floor),
	-- the chest keeps ChestFollow of that turn, the neck turns the rest back, so the head stays on the table / opponent.
	-- The stroke follows the POSTURE, never the cursor: LeftLead = forehand serve, RightLead = backhand serve (the cursor
	-- is only the aim). The posture blends in/out over BlendTime and fades while walking (pre-toss repositioning).
	-- The server applies the same chest turn to the hand's release point, so the toss leaves the visible hand.
	Posture = {
		Default = "LeftLead",
		HipYaw = 25,
		ChestFollow = 0.4,
		BlendTime = 0.25,
		FollowThroughHold = 0.6, -- seconds the posture is kept after the strike before blending back to the ready stance
	},
	-- TOSS TIMING. The clip plays at TossAnimSpeed (a slower, readable lift; the hand path is the authored one), so the ball
	-- leaves the hand TossReleaseMarker / TossAnimSpeed seconds after Space (TossReleaseDelay, derived below: the server
	-- releases the ball at the same moment the client's hand reaches the marker).
	TossAnimSpeed = 0.75,
	TossReleaseMarker = 0.25, -- seconds into NP_ServeToss at speed 1 (its "Release" marker; keep in sync with the clip)
	TossReleaseDelay = 0.25 / 0.75, -- (derived: TossReleaseMarker / TossAnimSpeed; recomputed after this table)
	-- Measured on the 3.37x avatar (2026-11-16, shared physics with drag): the ball leaves the hand 6.55 above the table
	-- (about the head top). Apex / time after release: 28 -> 10.3 / 0.28 s, 32 -> 11.35 / 0.31 s, 36 -> 12.5 / 0.35 s,
	-- 40 -> 13.8 / 0.38 s. A LOWER toss gives LESS time; a higher one more time but a faster ball lower down.
	PlayerTossSpeed = 36, -- studs/s straight up from the hand (rises ~6 studs, ~a head and a half above the hand)
	-- CONTACT PHASE (where the paddle can meet the toss): the ball FALLING, its centre between ContactMinHeight and
	-- ContactMaxHeight above the table, and within the locked stroke's normal reach. The paddle meets the ball HitDelay
	-- after the release (the strike clip's Hit marker), so the server judges the ball where it is at release + HitDelay.
	-- The middle (1 - 2 * WeakEdge) of the phase is a clean contact, the WeakEdge fraction at each end a weak one (less spin
	-- and pace); both are legal serves. Before the phase = too early (still rising / too high), after = too late.
	-- Why the band starts at 6: measured 2026-11-16, on this table (net 2.63 high, 47.3 long, air drag) a legal serve
	-- (own half, then theirs) exists for only ~1-50% of contacts at 1-2.5 studs above the table and ~35-75% at 4-5.5,
	-- but for (nearly) every aim / power / spin from ~7 up. So the phase is the falling toss from its apex (~12.5) down to
	-- 6 (about the head top): ~0.35 s at normal speed.
	ContactMinHeight = 6.0,
	ContactMaxHeight = 13.0,
	WeakEdge = 0.2,
	HitDelay = 0.07, -- seconds (NP_ServeStrike's Hit marker is 0.067 s)
	-- LEGAL SERVING REGION (derived from the table and the platform at runtime): the ball must leave the hand behind the
	-- server's end line (by at least the ball's radius), across the table's width plus CornerAllowance beyond either side
	-- line, with the character on the platform. Checked by the server at the toss; shown on the floor by the client.
	CornerAllowance = 3, -- studs beyond each side line
	RegionDepth = 22, -- studs behind the end line the region extends (the platform edge limits it too)
	-- LEGAL-SERVE SOLVE (ShotLaunch.serve; shared physics, decided once at contact, nothing steered afterwards). The
	-- second bounce (on the receiver's half) is placed by the inputs: across the table by the AIM (-1 = the receiver's
	-- left as you look at it .. +1 = right, staying LateralMargin inside the side lines), along it by the POWER (from
	-- SecondDepthMin to SecondDepthMax studs past the net: more power = a deeper, faster serve). The first bounce is on the
	-- server's half FirstBounceDepth from the net (0 = net, 1 = end line) on the line toward that point. The solver bisects
	-- the speed (PlayerMinSpeed..PlayerMaxSpeed) and simulates the whole serve (table, net) with the requested spin; if the
	-- full spin cannot be made legal it retries the same spin direction at SpinLadder fractions, then shallower/deeper
	-- targets. A weak contact serves with WeakDepthFactor of the depth (and WeakSpinFactor of the spin).
	LateralMargin = 4.5,
	SecondDepthMin = 8,
	SecondDepthMax = 18,
	FirstBounceDepth = 0.6,
	PlayerMinSpeed = 30,
	PlayerMaxSpeed = 140,
	WeakDepthFactor = 0.85,
	-- SAFE SERVE ENVELOPE (2026-11-17; ShotLaunch.serveEnvelope). Measured before: 785 of 1458 legal test serves (54%)
	-- left over the receiver's side line after their receiver-side bounce (sideways : forward speed up to 8.6 : 1), even
	-- 36 spin-free ones from wide spots aimed wide. Every serve's whole flight must now satisfy (ball-centre values):
	Envelope = {
		BounceMargin = 1.5, -- the receiver-side bounce lands at least this far inside the side lines (2 ball radii)
		SideMargin = 0.75, -- then, until the end-line plane, the centre stays this far inside the side lines (1 radius)
		MaxLateralRatio = 0.6, -- right after that bounce: sideways speed <= this x the speed toward the end line (~31 deg)
		MaxReceiveSpeed = 85, -- horizontal studs/s after that bounce (playable, not a missile across the end line)
		EndLineMaxHeight = 19, -- studs above the floor where it crosses the end-line plane (inside the reach band, 20)
		Horizon = 3, -- seconds simulated
	},
	-- How a serve outside the envelope is brought inside BEFORE contact: the aimed second bounce is shifted against the
	-- predicted post-bounce drift (CompensationSteps tries, CompensationGain x the drift), then the sidespin is reduced
	-- along SideSpinLadder (topspin / backspin kept), then the aim is eased toward the centre, then a spin-free centre serve.
	CompensationSteps = 2,
	CompensationGain = 0.9,
	SideSpinLadder = { 1, 0.7, 0.45, 0.2 },
	-- When the bisection finds nothing (speed vs depth is not monotonic for some contacts), a coarse scan of these
	-- first-bounce depths x speeds picks the safe launch closest to the aimed depth. SolveFlightTime bounds each inner
	-- flight; SolveCost bounds each inner solve; past SolveBudget seconds the solve goes straight to the spin-free centre
	-- serve (bounded server cost per serve; was up to 0.12 s). Measured 2026-11-17 (432 strong-spin serves): a 12 ms
	-- budget sent 113 of them to the spin-free fallback, 50 ms none (max 32 ms, mean 8 ms); 35 ms keeps nearly all
	-- choices with a bounded worst case.
	ScanFirstDepths = { 0.6, 0.8 },
	ScanSpeeds = { 45, 65, 90, 120 },
	SolveFlightTime = 1.2,
	SolveCost = { MaxIterations = 14, MaxFactors = 2, Tolerance = 0.15, BisectSteps = 10 },
	SolveBudget = 0.035,
	AimDeadZone = 0.05, -- fraction of the half-screen around the centre that aims straight
	-- AIM INDICATOR (client): a line from the hand over the table to a ring on the receiver's half where the serve's
	-- second bounce is aimed (its depth follows the power while charging: a placement cue, not a predicted path).
	AimLineLength = 36, -- (legacy; the line now ends at the target ring)
	AimRingRadius = 2.2,
	AimColor = Color3.fromRGB(120, 220, 255),
	AimLockedColor = Color3.fromRGB(255, 215, 90),
	RegionColor = Color3.fromRGB(120, 220, 255),
	RegionBadColor = Color3.fromRGB(255, 110, 120),
}

Serve.TossReleaseDelay = Serve.TossReleaseMarker / Serve.TossAnimSpeed

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
		-- (2026-11-17) the visible blade relative to the previous 3.2-stud paddle, and that paddle's blade radius; the
		-- contact radius follows them (see the end of this file)
		BladeScale = 1.3,
		BaseBladeRadius = 1.6,
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
		-- Lever arm for spin <-> speed coupling at bounces: the REAL ball's radius (0.2), so enlarging the collision ball does
		-- not make spin kick 3.75x harder (contact slip = v + spin x r). Collision geometry uses `radius`.
		spinRadius = toStuds(Real.BallDiameter) / 2,
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
		magnusSideSpeedRef = 86, -- studs/s (x1.15 with the shot speeds; was 75)
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
		NetClearance = 1.2, -- studs: solved shots must clear the net top by at least this much (x1.5 with the net; was 0.8)
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
		ReturnSpeed = 71, -- horizontal launch speed, studs/s (x1.15 with the enlarged table; was 62)
		ReturnSpeedVariation = 7, -- +/- studs/s (was 6)
		Topspin = 80, -- rad/s (~13 rev/s)
		TargetDepthMin = 0.45, -- landing depth on the opponent's half (fraction from the net)
		TargetDepthMax = 0.75,
		TargetSpreadX = 7.5, -- +/- studs across the table (x1.5; was 5)
		AimError = 0.9, -- +/- studs of random error added to the target (x1.5; was 0.6)
		MaxStepBack = 14, -- furthest behind its end line the bot will move to (studs)
		MinStepBack = 4, -- closest to its end line
		HomeStepBack = 10, -- where it waits
		-- POP-UPS (confirmed: pressure pop-ups + a small random rate), the source of smashable balls. Pressure 0..1 at the
		-- bot's contact = max of: how far out of its reach it hits (ramp from PressureReachFrom of Reach to the edge), how
		-- fast the ball arrives (PressureSpeedFrom..PressureSpeedTo studs/s horizontal) and how much sidespin it carries
		-- (PressureSpinFull rad/s). Lob chance = PopupRandomChance + PopupPressureChance * pressure.
		PopupPressureChance = 0.3,
		PopupRandomChance = 0.05,
		PressureReachFrom = 0.6,
		PressureSpeedFrom = 86, -- (x1.15; was 75)
		PressureSpeedTo = 126, -- (was 110)
		PressureSpinFull = 80,
		-- The lob (measured: 30 studs/s + topspin 60 to 0.65 depth bounces 10.1-12.4 studs above the table on the
		-- player's half, 0/40 solver failures; a solver failure falls back to the normal return).
		-- ENLARGED TABLE (measured 2026-11-15): with air drag a 30-35 studs/s lob cannot carry the longer table (ShotSolver
		-- keeps the horizontal speed and only raises the arc: 0/120 lobs solved at 34.5). 52 +/- 3 to depth 0.6 solves
		-- ~100% and bounces 11-16 studs above the table (was 30 / 0.65 on the small table).
		PopupSpeed = 52,
		PopupSpeedVariation = 3,
		PopupTopspin = 60,
		PopupDepth = 0.6,
		PopupSpreadX = 6, -- (x1.5; was 4)
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
		-- CURSOR-SIDE HOLDING LEAN (2026-11-17): the paddle wrist in the forehand ready pose. Measured on the 3.37x avatar
		-- from the rally camera: without it the blade read ~5 deg from vertical on screen (the "straight up" hold);
		-- Y -40 leans the tip ~34 deg toward the right, face still square to the table (0.99). Y turns the blade sideways
		-- here; X tips it forward/back, Z rolls the face. The backhand's own value is Backhand.RightWrist.
		RightWrist = Vector3.new(0, -40, 0),
		LeftShoulder = Vector3.new(30, 0, -18),
		LeftElbow = Vector3.new(45, 0, 0),
		FootSink = 0.05, -- (StancePose.groundFeet, legacy) studs the soles sit into the floor
		-- FOOTWORK (StancePose.start, rewritten 2026-11-15 pass 2). The legs are one locomotion layer whose weights always
		-- sum to 1: the NP_Ready loop (standing), 4 shuffles (normal speed) and 4 Shift runs, blended by speed and by the
		-- travel direction in the body's frame, all driven by one shared cycle clock. HipHeight is never changed.
		Locomotion = {
			MoveThreshold = 1.5, -- horizontal studs/s above which the footwork replaces the ready legs
			StartRate = 18, -- 1/s blend into footwork when a move starts (~0.1 s: no input delay)
			StopRate = 11, -- 1/s settle back into the ready legs when stopping
			DirectionRate = 15, -- 1/s: how fast each direction clip's share follows a change of direction (was 12)
			RestartAfterIdle = 0.25, -- seconds standing still after which the next move starts its cycle on the lead foot
			RunFrom = 30, -- studs/s: below this, shuffle (normal speed is 24) ...
			RunTo = 44, -- ... above this, the Shift run (boost is 54); blended in between
			RunBlendRate = 8, -- 1/s
			-- HYBRID FOOTWORK (2026-11-17). Diagnosed: the old shuffle clips moved the body 1.5 block-rig studs per cycle
			-- (5.1 on the 3.37x avatar), so at the unchanged 24 studs/s the legs cycled ~4.75x a second (~9.5 foot moves/s):
			-- the micro-step "crab walk". The clips now cover more ground per cycle (STRIDE, block-rig studs per cycle, x
			-- the avatar's scale in game) and the cycle clock runs at real speed / the blended stride, so planted feet do
			-- not skate and longer strides mean fewer, slower steps. Exaggerate / calm the footwork with these (and the
			-- clip recipe anims/_notpong.py in the /animate kit for the shapes).
			Stride = {
				Shuffle = 1.7, -- NP_ShuffleRight/Left: step out + close (feet never cross)
				Cross = 3.0, -- NP_CrossRight/Left: trail leg crosses in front, lead steps out behind
				Forward = 2.6, -- NP_ShuffleForward: controlled walking steps (two per cycle)
				Back = 2.6, -- NP_ShuffleBack: backward steps (was 2.2: cadence too quick)
				RunSide = 2.5, RunForward = 4.0, RunBack = 2.6, -- the Shift run clips (unchanged)
			},
			PlaybackScale = 1, -- x the cadence the stride implies (< 1 = slower steps; feet then skate slightly)
			MinCycleRate = 0.6, -- clamps on cycles per second
			MaxCycleRate = 4.5,
			-- shuffle -> crossover: sideways movement in ONE direction for CrossoverAfter seconds above CrossoverMinSpeed
			-- (sideways studs/s) turns into crossover strides (blended in at CrossBlendIn 1/s); it stays until the sideways
			-- speed drops below CrossoverExitSpeed (hysteresis) and blends out at CrossBlendOut. A reversal ends it at once
			-- (capped to ReversalCrossCap) so a quick A <-> D plays as a direction-change shuffle step. Short taps never
			-- reach the threshold, so they stay shuffles.
			CrossoverAfter = 0.22,
			CrossoverMinSpeed = 16,
			CrossoverExitSpeed = 8,
			CrossBlendIn = 9,
			CrossBlendOut = 12,
			ReversalCrossCap = 0.2,
			-- (ClipSpeed / MinPlaySpeed / MaxPlaySpeed were replaced by Stride / Min/MaxCycleRate on 2026-11-17)
		},
		-- Additive upper-body layer (written after the Animator each frame; never touches the legs).
		Layer = {
			WaistCounter = 0.55, -- the chest turns back against the hips' yaw by this fraction (shoulder counter-motion)
			NeckCounter = 0.35, -- the head turns back a further fraction: eyes stay on play (sideways run: hips 25 -> head ~2.5)
			FreeArmSwing = 1.0, -- free (left) arm swings forward/back by this x the hips' yaw: balance
			BreathDegrees = 0.8, -- slow chest rise and fall
			BreathPeriod = 3.6, -- seconds
		},
		-- BACKHAND ready pose (upper body only; the forehand pose is the Right/Left values above). MEASURED on the scaled
		-- R15 avatar in Play: on this rig RightShoulder.Y (+) is what brings the paddle arm ACROSS the body (Z barely
		-- moves it once the arm is raised). These values put the blade ~3.5 studs LEFT of the root, 5.3 up, 6.5 forward,
		-- face toward the table (the forehand blade sits 6.2 right, 6.7 up, 7.4 forward). TorsoTwist turns the chest
		-- (degrees about the vertical, + = toward the player's left); the head counter-turns.
		-- FACE FLIP (2026-11-16): the backhand shows the OPPOSITE rubber to the player. On this rig the grip puts the blade's
		-- face normal roughly along the forearm (forehand: forearm pointing forward, front/red face to the table, the
		-- camera sees the back/black face). So the backhand turns the whole arm: elbow up in front of the right chest,
		-- forearm across the body pronated (elbow Y -83), wrist cocked; the black face points at the table (0.86) and the
		-- red face back at the camera; tip leans ~30 deg left; blade ~3.2 left, 4.9 up, 6.1 forward of the root (the
		-- backhand reach anchor is 4 left). Solved with forward kinematics on the avatar's joints with clearance checks
		-- (blade, hand, forearm vs torso / head / upper arm, also through the forehand <-> backhand cross-fade).
		-- (Old values, red face still to the table: shoulder (65, 70, 0), elbow (40, 0, 0), wrist (0, -20, 0), twist 15.)
		Backhand = {
			RightShoulder = Vector3.new(50, 71, 2),
			RightElbow = Vector3.new(71, -83, 0), -- Y = forearm pronation
			RightWrist = Vector3.new(-17, 19, -39),
			LeftShoulder = Vector3.new(22, 0, -12),
			LeftElbow = Vector3.new(40, 0, 0),
			TorsoTwist = 36,
		},
		StrokeBlendTime = 0.2, -- seconds to cross-fade between the forehand and backhand ready poses (0.12 before the flip)
		-- Wide base (reference sheet "Ready stance & footwork"): each hip opens this far outward, feet stay flat.
		LegSpreadDegrees = 10, -- (legacy Config-built legs track only; the live legs are the NP_Ready clip)
		ActivationBlendTime = 0.25, -- seconds to fade the stance out / back in when leaving / returning to the platform
	},

	-- ANIMATION RETARGETING (Workspace.Retargeting), applied by the server and every client at start.
	-- Measured 2026-11-15: with Roblox's retargeting on (Default), the default walk/idle/run translations were scaled to the
	-- avatar's HipHeight ON TOP of Model:ScaleTo's own scaling, so on our 3.37x avatars the hips bobbed ~3x too far
	-- (walk: 2.55 studs, with 0.93-stud jumps in one frame: the shaky off-platform walk). Disabled: 0.84 studs, 0.30 per
	-- frame, the same proportion as an unscaled avatar. Our own runtime clips are unaffected either way.
	Animation = {
		Retargeting = Enum.AnimatorRetargetingMode.Disabled,
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
		-- BALANCED LATERAL FRAMING (2026-11-16 pass 3). Was ShoulderOffset 8 / CameraXFollow 0.7 / LateralFollow 0.4: a
		-- fixed right-shoulder view that, at the left side wall, left the avatar ~15 studs left of the camera (its backhand
		-- side at the screen edge) while at the right wall it sat centred. Now the camera follows the player's X closely
		-- with only a small right offset, and the aim point follows partly so the table and the opponent stay framed.
		ShoulderOffset = 3, -- studs to the player's right (+): a slight over-the-paddle-shoulder bias, constant (never flips)
		DistancePerBackStud = 0.2,
		HeightPerBackStud = 0.2,
		AimPerBackStud = 0.6, -- aim point moves toward the player (+Z) by this per stud walked back
		CameraXFollow = 0.88, -- camera X = table X + (player X offset) * this
		LateralFollow = 0.45, -- aim X = table X + (player X offset) * this
		LookAtHeightOffset = 0, -- added to table surface height for the aim point
		LookAheadStuds = 3, -- shifts the aim point toward the opponent (-Z); negative = toward the player
		-- FOLLOW (frame-rate independent). The camera follows a STABLE target: the HumanoidRootPart's position (physics,
		-- never the animated head / feet), plus a bounded look-ahead. Each axis is a critically damped spring (no
		-- overshoot on reversals): LateralSmoothTime for X, DepthSmoothTime for Z (seconds to close most of a gap).
		LateralSmoothTime = 0.14,
		DepthSmoothTime = 0.14,
		-- Look-ahead: the target leads the player by velocity * LeadTime, clamped to MaxLead studs, and the lead itself
		-- eases at LeadRate (1/s), so starts, stops and reversals never jump the camera (the old raw velocity lead of
		-- 0.125 s flipped the target by ~6 studs in one frame at every shuffle reversal). Off during dives.
		LeadTime = 0.1,
		MaxLead = 3,
		LeadRate = 6,
		Smoothing = 8, -- (legacy exponential follow rate; the springs above replace it)
		VelocityLead = 0.125, -- (legacy; replaced by LeadTime / MaxLead / LeadRate)
		-- final output easing (1/s) that only absorbs discontinuities (respawn, side flip); fast enough to add no lag
		OutputSmoothing = 30,
		-- SERVE FRAMING (2026-11-16 pass 3; the reference's lower serve view). While the player prepares and tosses their
		-- own serve, the camera lowers to about head height and looks more horizontally down the table, at the same
		-- follow distance (horizontal distance behind the player is unchanged). After a successful strike it blends back up
		-- into the rally framing; a missed swing keeps the serve view until the point resolves; bot serves use the rally
		-- framing. FOV never changes. Blends are eased (smootherstep) over EnterTime / ExitTime seconds.
		Serve = {
			Height = 17, -- camera height above the floor (the avatar's head top is ~18.5)
			LookHeight = 2.5, -- aim point height above the table surface
			LookAheadStuds = 0, -- aim point Z: the table centre (+ toward the opponent)
			-- LATERAL OFFSET FROM COURT POSITION (2026-11-17; replaces the fixed right offset 10). The camera's sideways
			-- offset depends on WHERE the server stands across the court (court-relative, so it works from either end),
			-- never on the Q posture: on the right side it sits over the player's right, on the left side over their left,
			-- centred in the middle. offset = LateralOffset x f(courtX / CenterBlend), f(u) = u(3 - u^2)/2 clamped to
			-- +-1: continuous and smooth through the centre (no shoulder swap), full strength CenterBlend studs out.
			-- The offset follows through a critically damped spring (OffsetSmoothTime) on top of the root follow.
			LateralOffset = 10,
			CenterBlend = 12,
			OffsetSmoothTime = 0.3,
			EnterTime = 0.8,
			ExitTime = 1.25,
		},
		-- DISTANCE (2026-11-15, enlarged table): the camera is pulled back along its own line of sight to the aim point by
		-- this factor, so the over-the-shoulder ANGLE and composition are unchanged and only the view widens. 1 = the
		-- previous distance. (FieldOfView is left alone on purpose.)
		DistanceMultiplier = 1.25,
		-- Returning to the platform from the default Roblox camera: the table camera starts from wherever the default
		-- camera was and eases in at this rate (1/s) instead of Smoothing, so there is no snap.
		ReturnSmoothing = 4,
		-- Leaving the platform: the camera glides over HandoffTime to a follow pose OffPlatformDistance behind the avatar's
		-- head (pitched OffPlatformPitch down, along the current view direction), then Roblox's default camera takes over
		-- from exactly that pose.
		HandoffTime = 0.4,
		OffPlatformDistance = 28,
		OffPlatformPitch = 18,
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
		TableAsset = "TableAsset", -- Model under NotPongArena/Table/Visual: the uploaded table (the visual table)
		PaddleTemplate = "PaddleTemplate", -- Model under NotPongArena: the uploaded paddle, cloned onto every competitor
		PaddleGripAttachment = "Grip", -- Attachment on the template's Handle: where the fist closes (+Y toward the blade tip, blade faces +/-Z)
		ArenaVersionAttribute = "NotPongArenaVersion",
		SeatedPlayerAttribute = "SeatedUserId",
		BoostStaminaAttribute = "NotPongBoostStamina",
		BoostExhaustedAttribute = "NotPongBoostExhausted",
		DiveStateAttribute = "NotPongDive", -- on the character (server-set): "" | "lunge" | "recover"
		DiveDirAttribute = "NotPongDiveDir", -- on the character: the dive's horizontal direction (Vector3)
		DiveRefusedAttribute = "NotPongDiveRefused", -- on the player: bumped when a dive is refused for stamina
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
		PaddleReach = 9, -- (overwritten at the end of this file: ArmReach + BladeContactRadius, 9.48 at BladeScale 1.3)
		ArmReach = 7.4, -- studs: the reach without the blade (the previous total 9 minus its blade radius 1.6)
		BladeContactRadius = 1.6, -- (overwritten at the end: BaseBladeRadius x BladeScale)
		AnchorRight = 4, -- anchor: this far to the player's right ... (FOREHAND)
		AnchorForward = 3, -- ... and this far in front of the root (same rule as the bot)
		-- BACKHAND reach (confirmed 2026-11-15: reach follows the stroke locked at the press). The anchor is mirrored to
		-- the player's LEFT; same radius and forward offset. The server uses the stroke recorded with the press.
		BackhandAnchorRight = -4,
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
		MinShotSpeed = 55, -- horizontal launch speed at zero charge, studs/s (x1.15 with the enlarged table; was 48)
		MaxShotSpeed = 115, -- ... at full charge (was 100; the bot plays 71)
		TopspinSpeedBonus = 0.12, -- full topspin launches this much faster (a driven shot); scales with the topspin
		BackspinSpeedPenalty = 0.15, -- full backspin launches this much slower (a floated push)
		MinShotDepth = 0.4, -- spin-free landing depth on the opponent's half at zero charge (0 = net, 1 = end line)
		MaxShotDepth = 0.82, -- ... at full charge
		FollowLateral = 0.45, -- default direction: 0 = always toward the centre line, 1 = straight down the table from the contact point
		LateralMargin = 3.75, -- the default direction stays this far inside the opponent's side lines (studs; x1.5, was 2.5)
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
		WeakAimError = 0, -- (legacy random error, studs; replaced by the deterministic timing error below. 0 = off)
		-- TIMING ERROR (confirmed: forgiving ordinary returns, risk in aggressive / stretched shots; no hidden randomness).
		-- Applied in ShotLaunch AFTER the calibration, so server and arrow compute the same shot from the same release time.
		--   timing  t = (release - ideal) / (ContactWindowDuration / 2): -1..+1 inside the clean window; weak contacts
		--           continue linearly to -2/+2 at the edge of the weak band.
		--   risk    r = ErrorBase + ErrorPowerWeight * ramp(power from ErrorPowerFrom to 1)
		--                         + ErrorStretchWeight * ramp(stretch from ErrorStretchFrom to 1)
		--           (stretch = contact distance from the paddle anchor / PaddleReach), times SmashTimingMultiplier on a smash.
		--   error   yaw = t * r * TimingYawDegrees: EARLY pulls the ball across the body (forehand: to the player's left,
		--                 backhand: to the right), LATE pushes it the other way;
		--           pitch = -t * r * TimingPitchDegrees: EARLY launches higher (long), LATE lower (net).
		ErrorBase = 0.2,
		ErrorPowerFrom = 0.5,
		ErrorPowerWeight = 0.8,
		ErrorStretchFrom = 0.6,
		ErrorStretchWeight = 0.8,
		TimingYawDegrees = 6,
		TimingPitchDegrees = 1.2,
		-- CLEAN-WINDOW PENALTY (2026-11-16 pass 3): inside the green window only this fraction of the timing value counts
		-- (ShotLaunch.effectiveTiming), ramping continuously to the full value at the weak band's edge. Was effectively 1:
		-- a green release at the window's edge turned a full-power shot ~6 deg (a smash ~18 deg) and could miss the table.
		CleanTimingScale = 0.35,
		-- SMASH (confirmed 2026-11-15). Server-checked at release: ball centre >= SmashMinHeight above the table, no more than
		-- SmashMaxBehindEndLine behind the player's end line, power >= SmashMinPower, clean or weak contact.
		SmashMinHeight = 7.5,
		SmashMaxBehindEndLine = 6,
		SmashMinPower = 0.75,
		SmashSpeed = 155, -- horizontal launch speed, studs/s (normal max 115; x1.15, was 135)
		SmashDepth = 0.85, -- calibration depth on the opponent's half
		SmashSpinFactor = 0.5, -- the drag spin is halved on a smash (a flat kill)
		SmashTimingMultiplier = 3, -- x the full-power timing risk
		SmashColor = Color3.fromRGB(255, 200, 60), -- the arrow while a smash is lined up
		-- networking / anti-spam
		MaxLatencyCompensation = 0.2, -- seconds the server will rewind to judge a release (caps "lag reach")
		-- the client reports its root with each press / release; the server uses it for the reach anchor only within this
		-- many studs (horizontal) of its own, ~0.1 s late, view of the root (boost speed 54 x 0.1 s = 5.4)
		MaxRootMismatch = 6,
		SwingCooldown = 0.3, -- seconds between swing requests
		ResultTimeout = 1, -- client: seconds to wait for the server's verdict
		RecoveryTime = 0.35, -- client: seconds in RECOVERY before aiming again
		-- FOREHAND / BACKHAND: the mouse's horizontal SCREEN position picks the stroke (left half = backhand, right half =
		-- forehand). Followed while idle; locked from the moment charging starts until the stroke's recovery ends.
		-- StrokeDeadZone: fraction of the screen width either side of the centre where the current stroke is kept
		-- (hysteresis, so the pose does not flicker when the cursor rests near the middle).
		StrokeDeadZone = 0.03,
		ShowDiagnostics = true, -- development-only debug bridges (Player.NotPongShotDebug / NotPongArrowDebug) used by Studio test scripts
		ShowInputDebug = true, -- TEMPORARY on-screen overlay (top left) tracing the input pipeline: button, mouse events, drag, spin, meter, arrow. Set false once verified.
	},

	-- CHARGE SLOW MOTION (server-authoritative; Server/RallyService + Client/ShotController). When the incoming ball is
	-- close to contact, the ball, bot and player move at TimeScale while you charge and curve.
	ChargeFreeze = {
		Enabled = true,
		-- Match modes that may use it. Solo (vs the bot) only: slow motion must not affect another human's game.
		Modes = { Solo = true, PvP = false },
		-- seconds before ideal contact when a press can start slow motion. Must be <= MaxDuration * TimeScale (0.14 s) or
		-- the slowed contact cannot be reached before the cap (measured 2026-11-15; was 0.45 = always an early miss).
		LeadTime = 0.13,
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
		-- DIVE (F; backward dives, 1.3 s recovery; 2026-11-16 pass 3: AUTOMATIC return, see DiveReturn* below). Server-owned:
		-- the client only sends "dive" + a direction; MovementService validates stamina/cooldown/state and drives the lunge
		-- with a server-created LinearVelocity (no teleport; the table guard still blocks it). No charge, drag or release:
		-- RallyService attempts the return itself during the dive's contact window.
		-- Direction (relative to the court-facing direction, i.e. the avatar's facing; WASD is camera-relative and the camera
		-- is behind the player): holding S (alone or with A/D) = a BACKWARD dive along the held direction (back diagonals keep
		-- their sideways component and play the backward animation); A/D = a dive to that side; no keys (or W alone) = toward
		-- the locked stroke's side. ShotInput.diveKind classifies it the same way on every machine.
		DiveEnabled = true,
		DiveKey = Enum.KeyCode.F, -- (was E; E is no longer bound)
		DiveStaminaCost = 50,
		DiveDuration = 0.35, -- seconds of lunge
		DiveDistance = 10, -- studs covered by the lunge (speed = distance / duration, independent of Shift boost)
		DiveRecovery = 1.3, -- seconds after the lunge with no walking, no jumping, no new charge (was 1.0)
		DiveCooldown = 1.5, -- seconds from one dive's start to the next (shorter than a whole dive, so in practice a dive
		-- can only start once the previous one, including its recovery, is over)
		DiveBackwardThreshold = 0.35, -- a direction whose backward share (dot with -facing) is at least this is a backward dive
		-- DIVE CONTACT WINDOW: from the dive's start until DiveContactWindow seconds (the lunge + the landing), the reach
		-- anchor moves DiveAnchorAhead studs along the dive direction from wherever the server sees the root, and the radius
		-- grows by DiveReachBonus. After that (the get-up) no contact is possible.
		DiveContactWindow = 0.45,
		DiveReachBonus = 5,
		DiveAnchorAhead = 3,
		-- AUTOMATIC DIVE RETURN (2026-11-16 pass 3: supersedes the manual dive contact above). Pressing F commits: any
		-- charge is cancelled and no manual swing can follow at that ball. During the contact window, the FIRST physics tick
		-- at which the incoming ball is legally playable (bounced once on the player's half, the player's turn) and inside
		-- the dive-extended reach (the anchor DiveAnchorAhead along the dive, radius PaddleReach + DiveReachBonus; never under
		-- the table) is the contact. The outcome is rolled ONCE there on the server: DiveReturnChance -> a defensive return
		-- solved to land legally (DiveReturnSpeed, a little topspin, DiveReturnDepth toward the middle); otherwise a
		-- coherent physical mishit (long / wide / net). One contact per dive and per incoming ball.
		DiveReturnChance = 0.9,
		-- DEFENSIVE (2026-11-17): a slower, higher ball that buys recovery time and gives the opponent a chance to attack
		-- (was 60 studs/s with topspin 25: a flat, firm return). The SLOWEST of DiveReturnSpeeds (horizontal studs/s,
		-- tried slow to fast) that lands legally and peaks at most DiveReturnMaxApex above the table is used. Measured:
		-- one fixed 46 studs/s speed had to arc 25-50 studs high to carry the long table against drag (moon balls) and
		-- cost up to 0.68 s to solve; never pick a speed list whose fastest entry cannot carry from a deep, wide contact.
		DiveReturnSpeed = 46, -- (the slowest speed; kept for the fallback guess)
		DiveReturnSpeeds = { 46, 52, 58, 64, 72, 80 },
		DiveReturnMaxApex = 18, -- studs above the table (the rally camera sits ~21 above it; a smash needs >= 7.5)
		DiveReturnTopspin = 5, -- rad/s (almost flat: it floats)
		DiveReturnDepth = 0.7, -- landing depth on the opponent's half (0 = net, 1 = end line): deep, so it is not a winner
		DiveReturnLateral = 0.2, -- the landing follows the contact's sideways offset by this fraction
		DiveSolveBudget = 0.015, -- seconds; past it the remaining (faster) speeds aim at the centre
		DiveMishitSpeed = 62,
		DiveMishitLongSpeed = 100, -- (measured: with drag, 62 studs/s cannot carry past the far end line)
		DiveMishitKinds = { "long", "wide", "net" },
	},

	-- ON / OFF THE PLATFORM (client presentation, Client/PlatformZone). Off the platform the game hands the player back to
	-- standard Roblox behaviour: the default follow camera with normal controls, the default idle/walk/run/jump animations
	-- and facing the movement direction. Back on the platform the table-tennis camera, facing, ready stance and footwork
	-- return. Bounds = the Platform part with the CharacterFade margins below (hysteresis), plus DwellTime.
	PlatformZone = {
		DwellTime = 0.2, -- seconds the new state must hold before anything switches (no flicker along the edge)
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
		-- Backhand swing: offsets added to Config.Stance.Backhand (re-solved 2026-11-16 for the face-flip pose; the wrist
		-- stays at the backhand ready value through the swing). Back = wound further left, strike = in front with the
		-- black face to the table, follow = up and out to the right. FK blade path (root frame): ready (-3.2 r, 4.9 up,
		-- 6.1 fwd) -> back (-4.4, 4.4, 4.3) -> strike (-1.3, 5.4, 8.0, black face toward the table 0.72) -> follow
		-- (2.8, 6.4, 8.3); no blade/hand/forearm contact with the torso, head or upper arm at the keys or between them.
		Backhand = {
			BackShoulder = Vector3.new(-1, 10, 0),
			StrikeShoulder = Vector3.new(-3, -22, 2),
			FollowShoulder = Vector3.new(11, -41, 3),
			BackElbow = Vector3.new(-5, 6, 0),
			StrikeElbow = Vector3.new(11, -8, 0),
			FollowElbow = Vector3.new(14, -12, 0),
			BackTorso = Vector3.new(0, 9, 0),
			StrikeTorso = Vector3.new(0, 3, 0),
			FollowTorso = Vector3.new(0, -8, 0),
		},
		-- Overhead smash: offsets added to the FOREHAND ready pose. Back = arm raised high (+X lifts it forward/up),
		-- strike = chopped down in front, follow = low across the body; the chest leans in (-X) through the strike.
		Smash = {
			BackShoulder = Vector3.new(105, 0, 10),
			StrikeShoulder = Vector3.new(40, 0, -10),
			FollowShoulder = Vector3.new(-10, 25, -15),
			BackElbow = Vector3.new(20, 0, 0),
			StrikeElbow = Vector3.new(-40, 0, 0),
			FollowElbow = Vector3.new(-20, 0, 0),
			BackTorso = Vector3.new(8, 10, 0),
			StrikeTorso = Vector3.new(-14, -12, 0),
			FollowTorso = Vector3.new(-18, -18, 0),
		},
	},

	-- Dive + get-up animation (client, visual; 2026-11-15 replaced the procedural lean with the /animate clips
	-- NP_DiveRight / NP_DiveLeft: push-off, airborne reach, floor landing in the 0.35 s lunge, then a 1.0 s get-up
	-- (brace, kneel, rise) that ends in the ready stance). Action4: nothing standing shows through while on the floor.
	DivePose = {
		BlendIn = 0.06, -- seconds to blend from the current pose into the push-off
		BlendOut = 0.18, -- seconds over which the clip's last frames blend into the live ready stance
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
			RecomputeInterval = 0.02, -- seconds between predictions (power, spin and the release-now timing change continuously)
			Smoothing = 35, -- 1/s: the drawn path eases toward each new prediction (snaps when the verdict changes)
			-- HONEST PREVIEW (2026-11-16 pass 3): amber + "RISKY" when the shot released TimingLookahead seconds later would
			-- fail, or the predicted landing is within EdgeMargin studs of a side line, the end line or the net line.
			TimingLookahead = 0.05,
			EdgeMargin = 1.5,
			RiskyColor = Color3.fromRGB(255, 190, 70),
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
			Width = 1.0, -- studs (ball is 1.5 now; was 0.55)
			SlowColor = Color3.fromRGB(190, 200, 215),
			FastColor = Color3.fromRGB(255, 255, 255),
			TopspinColor = Color3.fromRGB(255, 150, 70), -- tint by dominant spin axis (kept subtle)
			BackspinColor = Color3.fromRGB(110, 180, 255),
			SidespinColor = Color3.fromRGB(190, 120, 255),
			TintStrength = 0.75, -- 0 = no spin tint; 1 = full tint at maximum spin
			FullSpeed = 126, -- studs/s at which the trail is at full brightness / width
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

-- PADDLE BLADE SCALE <-> CONTACT AREA (2026-11-17). Hit detection is a horizontal radius around the stroke's reach
-- anchor (ShotInput.inReach), not paddle-part collision. That radius is split into the ARM's reach (fixed) plus the
-- BLADE's radius (scales with the visible blade), so a bigger blade enlarges the contact area by exactly the blade's
-- growth and never multiplies the arm's reach. Measured: the previous template's blade was 3.2 studs across (radius
-- 1.6); the v2-v4 templates (now assets/paddle/NotPongPaddle_v4.blend) are built at BladeScale 1.3 (4.16 x 4.30 studs).
-- To retune: change BladeScale here AND resize the template's blade zones (FrontRubber, BackRubber, WoodBlade, EdgeBand;
-- not the Handle/EndCap) in Studio by the same factor, or change HW/HH in tools/build_paddle_v4.py and rebuild;
-- PaddleFactory warns at Play if the template's blade width (WoodBlade) disagrees with BladeScale.
-- (BladeScale / BaseBladeRadius live in Config.Paddle, ArmReach in Config.ShotControl)
Config.ShotControl.BladeContactRadius = Config.Paddle.BaseBladeRadius * Config.Paddle.BladeScale
Config.ShotControl.PaddleReach = Config.ShotControl.ArmReach + Config.ShotControl.BladeContactRadius -- 9.48
-- the bot holds the same paddle: its reach grows by the same blade growth (was 8)
Config.BotPlay.Reach = 8 + Config.Paddle.BaseBladeRadius * (Config.Paddle.BladeScale - 1)

return Config
