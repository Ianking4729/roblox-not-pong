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

-- PLAYING PLATFORM: a flat court under the table and both players (2026-11-21: a turf disc on the raised pier, see Pier).
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
-- (2026-11-21 coastal pier) The platform is now the CIRCULAR TURF COURT: a flat disc (a Cylinder part, axis vertical)
-- whose top is still the playing floor (FloorY unchanged). Radius 56 = the old slab's half-length along the table axis
-- (55.6), chosen from a measured sweep of 400 simulated returns: the ball falls to 8 studs above the floor at a median
-- 36.9 / p98 48.4 studs from the table centre, and to 3 studs (save height) at p98 54.2. The disc is wider than the old
-- slab sideways (56 vs 33.25). Size = the disc's footprint bounds (2R x Thickness x 2R). The old rectangle is kept as
-- LegacyRectSize (the bot's lateral limit still uses it, so the bot moves exactly as before).
local PLATFORM_RADIUS = 56
local Platform = {
	Thickness = 1,
	Shape = "Disc", -- "Disc" (circular court) | "Rect" (the pre-2026-11-21 slab)
	Radius = PLATFORM_RADIUS,
	Material = Enum.Material.SmoothPlastic,
	Color = Color3.fromRGB(92, 168, 72), -- (the Disc part is invisible collision; the visible turf is Pier.Colors.Turf)
	Size = Vector3.new(2 * PLATFORM_RADIUS, 1, 2 * PLATFORM_RADIUS),
	LegacyRectSize = Vector3.new(
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
	-- LEGAL SERVING REGION (2026-11-19 Pass 12; ServeRules.region): ANYWHERE ON THE PLATFORM behind the server's end
	-- line, beyond either side line included: the ball must leave the hand behind the end line (by at least the ball's
	-- radius) and inside the platform's footprint, with the character's root on the platform and the feet on the ground.
	-- Derived from Config.Platform / Layout at runtime (no radius, lateral or depth limits). Checked by the server at the
	-- toss. (The walls / guard limit where the character can actually stand: Layout.PlayerArea.)
	CornerAllowance = 3, -- (legacy, unused since Pass 12: the old region's studs beyond each side line)
	RegionDepth = 22, -- (legacy, unused since Pass 12: the old region's depth behind the end line)
	ShowRegionDebug = false, -- DEVELOPER ONLY: outline the legal release region on the floor (the player never sees it)
	-- SERVE LANDING GUIDE (Client/ServeGuide; Pass 12, reworked Pass 13). From the ball resting in your hand on your serve
	-- until contact:
	--   PROVISIONAL (preparation and toss, before the flick): a REPRESENTATIVE serve (Representative below: power 0.5,
	--     no spin, clean, at the toss's typical contact point, your current aim) solved by the same ShotLaunch.serve as the
	--     server. It is a typical serve, not your final one, so it is drawn fainter (dashes, ring and arrow).
	--   FINAL (flick -> contact): the predicted serve from your real inputs, full strength.
	-- The guide hides at contact (it is not drawn over the struck ball). White dashed line FLAT ON THE TABLE along the
	-- predicted flight's ground track, through the first bounce to the RECEIVER-SIDE landing (second bounce), hollow ring there, short downward arrow filling tail -> tip on a loop
	-- whose clock never restarts for a moving target.
	Guide = {
		DashWidth = nil :: number?, -- studs; nil = the measured BallVisual diameter x DashWidthScale (1.5 studs today)
		DashWidthScale = 0.45, -- (Pass 13: 1.0 = the ball's diameter read as too thick; ~0.7 studs)
		DashThickness = 0.06, -- studs (the dashes lie flat on the table)
		FlatLift = 0.04, -- studs above the table surface
		DashLength = 1.6, -- studs
		DashGap = 1.1, -- studs
		MaxDashes = 40,
		DashTransparency = 0.25, -- final path
		ProvisionalTransparency = 0.45, -- representative path before the flick
		EndTrim = 1.6, -- studs: the dashes stop this far before the landing (the ring / arrow tip stay clean)
		RingRadius = 2.0, -- studs (Pass 13: was 1.6; seen at a grazing angle from the serve camera)
		RingThickness = 14, -- px on a 128 px canvas
		RingTransparency = 0.05,
		ProvisionalRingTransparency = 0.3,
		ArrowHeight = 2.4, -- studs, tail to tip (the tip touches the ring's centre)
		ArrowWidth = 1.1, -- studs, the head's width
		ArrowMinHeightPx = 40, -- + these pixels, so it stays readable from the serve camera (measured 23 px studs-only)
		ArrowMinWidthPx = 20,
		ArrowTrackTransparency = 0.8, -- the empty arrow (faint, like the contact ring's track)
		ProvisionalArrowStrength = 0.75, -- the fill's opacity before the flick (x the final's)
		MarkerOnTop = false, -- (tested true: the AlwaysOnTop arrow did not appear in Studio captures at all; false renders)
		FillTime = 0.45, -- s, tail -> tip
		HoldTime = 0.35, -- s, the full arrow before the next fill
		SnapDistance = 6, -- studs: a provisional landing that jumps further than this snaps instead of sliding
		Smoothing = 14, -- 1/s: the ring / arrow ease toward a new landing
		FadeTime = 0.3, -- s (fault / reset / mode change)
		ContactFadeTime = 0.12, -- s: the fade at contact
		Color = Color3.fromRGB(255, 255, 255),
		-- the representative serve shown before the flick (documented, not a prediction of your final inputs)
		Representative = { Power = 0.5, Topspin = 0, Sidespin = 0, Quality = "clean" },
		ResolveInterval = 0.12, -- s: at most this often the representative serve is re-solved ...
		ResolveAim = 0.03, -- ... and only if the aim moved this much
		ResolveMove = 0.75, -- ... or the hand this many studs
	},
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
	WideSolveBudgetExtra = 0.02, -- (Pass 12) extra seconds for contacts outside the table's width (the widest serving spots)
	-- (Pass 12) last-resort spin-free launch grid for the widest spots close to the end line (ShotLaunch.serve step 5)
	WideScanFirstBeyond = 4, -- studs outside a side line from which the scan runs before the centre fallback
	WideScan = { Speeds = { 40, 55, 70, 90 }, MaxYaw = 40, YawStep = 5, MinPitch = -25, MaxPitch = 15, PitchStep = 5 },
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

-- COASTAL PIER (2026-11-21, structural blockout; cleanup pass 2026-11-21b). Server/PierBuilder SYNCS Workspace.NotPongCoast
-- in Edit mode from these values (it updates its own structural parts in place; see PierBuilder for what it owns).
-- From the centre outward, every band directly adjoining the next:
--   turf court (visual turf + the invisible Platform collision disc) -> white rim -> walkable GLASS -> dark inner border
--   -> turquoise band -> dark outer border -> warm promenade -> railing.
-- All bands share ONE radial height function (PierBuilder.heightAt == TableWorld ground): flat at the playing floor
-- across the court and rim, then rising RiseSlope studs per stud outward (a shallow upturned cone; no steps). Below:
-- open air down to the lower beach (BeachTopY), with minimal pier columns. Layout.FloorY is unchanged.
-- Every circular edge is generated from the same centre (Layout.PlatformCenter) and radii with the same Segments
-- divisions, so neighbouring bands share their vertices exactly (no gaps, no overlaps, no z-fighting).
local Pier = {
	Folder = "NotPongCoast",
	Segments = 128, -- divisions around the circle (a 128-gon is within 0.017 studs of the true circle at the court edge)
	GlassPanelSegments = 2, -- segments merged into one glass panel (64 visible panels; joints every other division)
	RimWidth = 1.5,
	RimLift = 0, -- the rim's top above the turf (0 = flush; the turf and rim now share their edge exactly)
	GlassWidth = 24,
	-- turquoise trim with a dark border either side (distinct architectural bands, flush and walkable)
	InnerBorderWidth = 0.35,
	TrimWidth = 1.8,
	OuterBorderWidth = 0.35,
	PromenadeWidth = 16,
	RiseSlope = 0.06, -- studs of rise per stud outward from the rim's outer edge (~3.4 degrees)
	TurfThickness = 0.3, -- the visual turf layer (its top is the playing floor)
	TurfEdgeWidth = 2.5, -- the exact 128-gon ring that meets the rim; the rest of the turf is one plain disc (fewest edges)
	GlassThickness = 0.6,
	TrimThickness = 1.4, -- (the borders use the same depth)
	PromenadeThickness = 1.6,
	RimDepth = 2.5, -- the rim's white fascia reaches down to the deck slab's underside
	DeckThickness = 2.2, -- structural slab under the turf layer (its underside is FloorY - TurfThickness - DeckThickness)
	BeachTopY = -12, -- the lower beach's surface (the old Baseplate top was 0)
	RailHeight = 9.5, -- (about hip height on the 17.5-stud avatars)
	RailPostEvery = 2, -- a railing post every N divisions (64 posts at Segments 128)
	ColumnDiameter = 1.6,
	-- Column rings. Radius = a fixed radius, or Band = the middle of that band ("Rim", "Trim" = inner border..outer
	-- border), or Band = "PromenadeOuter" with Inset = studs in from the promenade's outer edge.
	ColumnRings = {
		{ Radius = 30, Count = 8 },
		{ Band = "Rim", Count = 24 },
		{ Band = "Trim", Count = 24 },
		{ Band = "PromenadeOuter", Inset = 1.1, Count = 32 },
	},
	StairAngle = 0, -- degrees around the court centre (0 = +X) where a plain ramp leads from the promenade down to the beach
	StairWidth = 10,
	StairRun = 46,
	ShoreX = -150, -- the beach meets the water at this world X (the ocean is on the -X side)
	-- Default looks, applied ONLY when PierBuilder first creates a part (afterwards colours / materials are yours).
	Colors = {
		Turf = Color3.fromRGB(92, 168, 72),
		Deck = Color3.fromRGB(190, 190, 185),
		Rim = Color3.fromRGB(245, 245, 240),
		Glass = Color3.fromRGB(190, 225, 240),
		Frame = Color3.fromRGB(150, 160, 170),
		Border = Color3.fromRGB(58, 62, 68), -- dark grey, not black
		Trim = Color3.fromRGB(46, 184, 184), -- restrained turquoise (SmoothPlastic, not Neon)
		Promenade = Color3.fromRGB(198, 122, 74),
		Rail = Color3.fromRGB(70, 76, 84),
		Column = Color3.fromRGB(150, 150, 148),
		Sand = Color3.fromRGB(228, 208, 160),
		Shallow = Color3.fromRGB(70, 200, 205),
		Deep = Color3.fromRGB(30, 105, 175),
	},
	GlassTransparency = 0.6,
	-- BALL GROUND (Shared/TableWorld world.ground, used by every ball simulation and prediction): the court and rim at
	-- FloorY, the deck bands on the same slope, the beach below. Beyond the pier the point still ends where the old
	-- floor plane was (the ball crossing FloorY + radius), so no point lasts longer than before; the ball then keeps
	-- falling to the beach for the eye only.
	BallGround = true,
}

local Config = {
	Pier = Pier,
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
	-- RALLY PACE EXPERIMENT (2026-11-19; DISABLED by default: compare with the baseline first). Return n of a point (the
	-- serve is not a return; the count restarts with every serve, replayed serves included): returns 1..FreeReturns at the
	-- baseline speed, then +StepPercent per return up to +MaxPercent, computed from the rally count (never by compounding the
	-- incoming ball). Applied to the SPEED INPUT of ordinary shots before their trajectory is solved (the player's
	-- ShotLaunch.compute speedFactor, the bot's ShotSolver speed), so every shot is still calibrated / legal and the
	-- client's prediction uses the same factor (ShotLaunch.rallyPaceFactor). Never applied to serves, smashes (their own
	-- SmashSpeed), emergency lobs or the bot's pop-ups; backspin keeps its slower launch (the factor multiplies it).
	-- MaxSpeed caps the escalated launch speed overall (a shot already faster than it is left at its baseline).
	-- (2026-11-19 Pass 12) ON, cap raised to +20% (the step and the opening exchanges unchanged: +2% per return from return
	-- 5, the cap reached at return 14). The trail's rally colours follow this schedule (Feedback.Trail.RallyColors).
	RallyPace = {
		Enabled = true, -- (false = the baseline: no escalation, white trail throughout)
		FreeReturns = 4,
		StepPercent = 2,
		MaxPercent = 20, -- (was 10)
		MaxSpeed = 130, -- studs/s, horizontal launch speed
	},
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

	-- Player shot controls: CLICK-AND-FLICK (2026-11-17): PREPARE (cursor position: stroke, base aim, drive/arc) -> COMMIT
	-- (hold left-click) -> FLICK (speed = power, direction = spin). Flick / Prep / Emergency below hold the new settings.
	-- The client only REQUESTS a swing (flick time + raw measurements, the locked choices); the server re-derives and
	-- validates everything.
	ShotControl = {
		Enabled = true,
		-- timing (seconds): the CONTACT moment (flick start + Flick.ContactDelay) against the incoming ball's window
		ContactWindowDuration = 0.25, -- clean-contact window centred on the moment the ball is closest to the paddle
		-- (2026-11-17 playtest value. MEASURED over 21 real rally windows from the server's own contact model: the valid
		-- contact range is [max(window opens, ideal - 0.225), min(ball leaves reach, ideal + 0.225)] with the old 0.1 / 0.1.
		-- The window OPENS (the bounced ball is falling and inside the reach) at ideal -0.16 s on average, i.e. inside the
		-- early tolerance in 19 of 21 windows, so the EARLY side is gated by that opening, never by the tolerance (widening
		-- it changes nothing); the ball LEAVES reach at ideal +0.25 s on average, which is before the old late limit in 9 of
		-- 21 windows (fast balls). So the LATE tolerance is the only lever that helps, and only for balls that stay in
		-- reach longer: mean valid range 0.372 s -> 0.412 s (+11%); more than that needs a change to the hitting range /
		-- legal contact rule, which is held fixed. Was Late 0.1.)
		-- (2026-11-17 Stage 1: that legal-contact rule is now RequireFallingBall below, OFF: the window opens as soon as the
		-- bounced ball is inside the reach, rising or falling, so the early side is no longer gated by the ball's apex.)
		-- LEGAL CONTACT: the ball must have bounced once on the player's half and be inside the reach (radius + height
		-- band). true = ALSO falling (or already past the player's end line): the old rule, which removed ~0.2 s from the
		-- front of the window. The emergency-save ring always keeps the falling rule (its rules are unchanged). The bot
		-- (Striker) and the serve toss have their own rules and are not affected. Revert = set true.
		RequireFallingBall = false,
		EarlyReleaseTolerance = 0.1, -- beyond the clean window: a contact this much earlier is still WEAK (capped by the window opening)
		LateReleaseTolerance = 0.22, -- ... and this much later (capped by the ball leaving reach)
		-- reach (studs). Contact availability comes from the ball's simulated distance to this anchor, not a timer.
		PaddleReach = 9, -- (overwritten at the end of this file: ArmReach + BladeContactRadius, 9.48 at BladeScale 1.3)
		ArmReach = 7.4, -- studs: the reach without the blade (the previous total 9 minus its blade radius 1.6)
		BladeContactRadius = 1.6, -- (overwritten at the end: BaseBladeRadius x BladeScale)
		AnchorRight = 4, -- anchor: this far to the player's right ... (FOREHAND)
		AnchorForward = 3, -- ... and this far in front of the root (same rule as the bot)
		-- BACKHAND reach (confirmed 2026-11-15: reach follows the stroke locked at the press). The anchor is mirrored to
		-- the player's LEFT; same radius and forward offset. The server uses the stroke recorded with the press.
		BackhandAnchorRight = -4,
		-- (hold-to-charge ChargeTime / ChargeExponent and the drag-spin Spin* / DragOvershootPixels settings were removed
		-- on 2026-11-17: power and spin come from the flick, Config.Flick)
		MaxSpin = 90, -- rad/s cap on the total spin (~19 rev/s; the bot plays 80)
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
		-- FOREHAND / BACKHAND SELECTION (2026-11-18): "Q" = the Q key toggles the rally stroke (the cursor only prepares
		-- placement / height); "Cursor" = the previous rule (left of the screen centre = backhand, right = forehand, with
		-- StrokeDeadZone hysteresis). Q during your own serve (ball in hand) still switches the SERVING POSTURE only.
		StrokeSelect = "Q",
		StrokeDeadZone = 0.03, -- ("Cursor" selection only)
		ShowDiagnostics = true, -- development-only debug bridges (Player.NotPongShotDebug / NotPongArrowDebug) used by Studio test scripts
		ShowInputDebug = true, -- TEMPORARY developer indicator (bottom left): stroke (selected / queued), PREPARING / COMMITTED / SWING / RECOVERING, last miss reason. Set false to hide.
		-- (The 2026-11-17 button-free "MouseOnly" rally prototype was superseded on 2026-11-18: rallies use hold-left-click
		-- + flick only. Shared/MouseSwing is no longer loaded.)
		-- RESPONSE (2026-11-18): the paddle stroke starts at the flick's ONSET (timed to reach the ball at the contact
		-- moment); the ball's new flight is shown locally at the contact moment from the client's prediction of the
		-- server's launch (the server's snapshot then corrects it; a refused / missed swing reverts it). false = the
		-- previous behaviour (stroke at recognition, ball response after the server round trip).
		StrokeAtOnset = true,
		PredictBallResponse = true,
		-- CONTACT ZONE MODEL (2026-11-18): "Body" = Config.ContactZone (one symmetric zone around the torso, the same for
		-- forehand and backhand); "Anchor" = the previous model (a PaddleReach circle around a point AnchorRight to the
		-- side of the selected stroke and AnchorForward in front). Serves always use the Anchor rule (ServeRules).
		ContactModel = "Body",
	},

	-- ===== CLICK-AND-FLICK SHOTS (2026-11-17; replaces hold-to-charge / drag / release-to-strike) =====================
	-- PREPARE (cursor position) -> COMMIT (hold left-click) -> FLICK (a quick mouse flick while holding) = the swing.
	-- Shared/FlickGesture recognises one coherent flick from timestamped relative mouse movement; Shared/ShotInput turns it
	-- into power (flick speed) and spin (flick direction). Holding longer never adds power; releasing without a flick
	-- cancels; one swing per click. The server recomputes power / spin from the raw gesture measurements (Flick limits).
	--
	-- Speeds and distances are in REFERENCE PIXELS: screen pixels x (ReferenceHeight / viewport height), so the same hand
	-- movement means the same thing at any resolution. While committed the mouse is held in place
	-- (MouseBehavior.LockCurrentPosition): the cursor does not drift, screen edges never stop a flick, and preparation is
	-- untouched; the relative movement comes from InputObject.Delta.
	--
	-- WHY THESE INITIAL VALUES (to be tuned with a real mouse): ordinary aiming / resting hand movement is slow and short
	-- (measured guides: a few px per frame, under ~600 ref px/s, and it wanders), while a deliberate flick moves ~40-300 ref
	-- px in 30-80 ms in one direction (~1500-6000 ref px/s). A flick STARTS when, within the last OnsetWindow seconds, the
	-- movement adds up to at least OnsetDistance px, its average speed (displacement / elapsed time, not per frame) is at
	-- least OnsetSpeed, and it is coherent (|sum of moves| / path length >= Coherence: jitter back and forth cancels out).
	-- Movements under JitterPixels per event are ignored for the onset. The flick's SEGMENT then runs from the first
	-- moving sample of that window until the movement slows below SegmentEndFraction of its peak speed, turns more than
	-- SegmentMaxTurnDeg, pauses for SegmentGap, or SegmentMax seconds pass: its average speed = power, its direction = spin.
	-- So the swing is finalised at most OnsetWindow + SegmentMax after the hand started moving (processing delay, bounded);
	-- the CONTACT TIME is the flick's start + ContactDelay (the paddle travelling to the ball), on client and server alike.
	Flick = {
		ReferenceHeight = 1080, -- px: thresholds are defined at this viewport height
		JitterPixels = 1.5, -- ref px per input event: smaller moves never start a flick
		OnsetWindow = 0.05, -- s: sliding window tested for a flick start
		OnsetDistance = 36, -- ref px of net movement inside the window
		OnsetSpeed = 1100, -- ref px/s average speed inside the window
		Coherence = 0.8, -- net displacement / path length inside the window (1 = perfectly straight)
		SegmentMax = 0.06, -- s after the start was detected: the measurement ends at the latest here
		SegmentEndFraction = 0.35, -- ... or when a frame's speed falls below this fraction of the segment's peak
		SegmentMaxTurnDeg = 60, -- ... or a frame's movement turns this far from the segment's direction
		SegmentGap = 0.03, -- ... or no movement for this long
		-- SHORT BOUNDED MEASUREMENT (2026-11-18): the flick is finalised once its segment has measured this many seconds
		-- from the flick's start (or earlier when it slows / turns / pauses), instead of waiting up to SegmentMax after the
		-- onset was detected. Holding the button already arms the stroke, so there is nothing to wait for. nil = the old rule.
		MeasureTime = 0.04,
		MinElapsed = 1 / 240, -- s: elapsed-time floor for one sample (no division by ~0 at high event rates)
		MaxSpeed = 20000, -- ref px/s: faster = an invalid sample (rejected, never clamped into a shot)
		-- power from the segment's average speed
		MinPower = 0.15, -- power of a flick right at OnsetSpeed
		FullPowerSpeed = 5000, -- ref px/s for full power
		PowerExponent = 1, -- 1 = linear between OnsetSpeed and FullPowerSpeed
		-- spin from the flick's direction (screen: up = topspin, down = backspin, right = curve to the screen-right, left =
		-- curve left; diagonals split). Strength grows with the flick's power from SpinAtMinPower to SpinAtFullPower rad/s.
		SpinAtMinPower = 25,
		SpinAtFullPower = 90, -- (= ShotControl.MaxSpin)
		ContactDelay = 0.07, -- s from the flick's start to the paddle meeting the ball (the same as Serve.HitDelay)
		-- the server accepts a flick timestamp this much older than its arrival on top of MaxLatencyCompensation
		-- (the recognition interval: OnsetWindow + SegmentMax)
		RecognitionAllowance = 0.11,
	},

	-- (RETIRED 2026-11-18, kept for reference only: nothing loads Shared/MouseSwing any more.)
	-- MOUSE-ONLY RALLY PROTOTYPE (ShotControl.RallyInput = "MouseOnly"; Shared/MouseSwing + Client/ShotController).
	-- The flick is measured with the same Config.Flick thresholds as click-to-lock; these only separate a flick from
	-- moving the paddle into position, and say when a flick may count as a swing.
	MouseOnlyRally = {
		-- WHEN: a flick counts only if its contact moment (flick start + Flick.ContactDelay) falls in the ATTEMPT ZONE around
		-- the incoming ball's best contact moment (the window's ideal; the earlier pass's ideal for a high bounce; for a
		-- ball out of every reach, its closest approach within NearReach). Outside it every movement is preparation.
		-- The zone is wider than the valid window (ideal -0.225 .. +0.345 s) so early / late attempts still MISS.
		AttemptLead = 0.5, -- s before the ideal moment
		AttemptTrail = 0.45, -- s after it
		NearReach = 20, -- studs: "is the ball coming near me at all" for out-of-reach attempts (zone only, never reach)
		-- WHAT: short vs sustained (MouseSwing rule 2)
		SweepCheck = 0.03, -- s after a measurement that ran out of time while still moving
		SweepFraction = 0.5, -- keeps moving the same way at >= this fraction of the flick's speed -> a sweep (reposition)
		MaxFlickDistance = 400, -- ref px: a movement longer than this is a reposition however it ends (flicks: ~40-300)
		-- settling after a sweep / flick / warp (MouseSwing rule 3)
		QuietGap = 0.04, -- s without movement
		QuietSpeed = 700, -- ref px/s: or a movement event slower than this
		QuietTurnDeg = 60, -- or a turn of more than this from the previous movement
		WarpPixels = 400, -- ref px in ONE movement event = a cursor warp / reset, never movement
		PrepHistory = 0.5, -- s of preparation kept to snapshot the one from just before the flick
	},

	-- PREPARATION (cursor position, before committing). Screen fractions from UserInputService:GetMouseLocation() over
	-- Camera.ViewportSize (both include the top-bar inset area, so the two agree; recomputed every frame, so a resized
	-- window is handled). Horizontal: left of the dead zone = backhand, right = forehand (StrokeDeadZone keeps the current
	-- stroke near the middle), and the base aim across the opponent's half (-1 = their left as you see it .. +1 = right).
	-- Vertical: higher on the screen = a higher arc, lower = a low drive. Locked at the click.
	Prep = {
		AimHalfSpan = 0.42, -- screen fraction from the centre to full aim (-1 / +1)
		AimMaxX = 1, -- |aim| cap
		ProfileTop = 0.25, -- screen Y fraction (0 = top) giving profile 1 (highest arc) ...
		ProfileBottom = 0.85, -- ... and profile 0 (lowest drive); clamped outside
		-- the base aim on the opponent's half: aim -1..1 -> lateral target up to AimLateral of the half-width (minus
		-- ShotControl.LateralMargin); the profile sets the launch speed factor and depth
		AimLateral = 1,
		DriveSpeedFactor = 1.0, -- profile 0: launch speed x this (a flat, fast drive)
		ArcSpeedFactor = 0.72, -- profile 1: launch speed x this (slower = a higher arc for the same landing)
		DriveDepthBonus = 0, -- profile 0: + this to the landing depth (0..1 of the half)
		ArcDepthBonus = 0.08, -- profile 1: lands a little deeper
		ArcClearance = 3.5, -- profile 1: net clearance (studs) the calibration asks for; profile 0 uses Rally.NetClearance
	},

	-- BODY-CENTRED CONTACT ZONE (2026-11-18; ShotControl.ContactModel = "Body"; Shared/ShotInput.bodyZone). One
	-- symmetric volume around the player's root, the SAME for forehand and backhand, oriented along the table (forward =
	-- toward the opponent). Horizontally two half-ellipses (Forward ahead, Back behind, Side to either side), vertically
	-- LowAboveFloor .. HighAboveFloor. A ball centre inside it at the judged contact moment can be hit; nothing else (no
	-- body part, accessory or paddle collision) ever makes contact. Assisted reach, sized to the avatar (block rig x3.37:
	-- root ~10.1 above the floor, head top ~17.4, shoulder top ~13.3 and 5.0 right of the root, arm + blade ~10).
	-- PREVIOUS (Anchor model, per stroke): a 9.48-stud circle centred 4 studs to the stroke's side and 3 ahead, 4..20
	-- above the floor: forehand covered 5.5 left .. 13.5 right, 6.5 behind .. 12.5 ahead (282 sq studs); the other side
	-- needed the other stroke. NOW: 13.5 either side, 3.5 behind .. 13 ahead (350 sq studs), 4..22 above the floor, both
	-- strokes. EMERGENCY: the same shape 4.5 studs bigger to the sides and ahead, limited behind (was: the anchor circle
	-- + 4.5). Being inside never hits by itself: you still commit and flick at a valid time.
	ContactZone = {
		Normal = { Side = 13.5, Forward = 13, Back = 3.5, LowAboveFloor = 4, HighAboveFloor = 22 },
		Emergency = { Side = 18, Forward = 17.5, Back = 5, LowAboveFloor = 3, HighAboveFloor = 24 },
		SweetForward = 4.5, -- studs ahead of the root: the ideal-contact point (the ball closest to it = the ideal moment)
		Visualize = false, -- DEVELOPER ONLY (Pass 12: off for players): outline of both zones + the sweet-point post around you (also NotPongShotDebug "zones")
	},

	-- EMERGENCY SAVE (2026-11-17; replaces the F dive and its automatic return). Two reach zones around the stroke's anchor:
	-- the normal reach (ShotControl.PaddleReach) and an OUTER ring up to PaddleReach + ReachExtra. A ball whose path never
	-- enters the normal reach but passes through the ring can be SAVED: you still move yourself, hold left-click and time
	-- the flick (the same timing rules, against the ring's own contact window). A successful save is a slow, high
	-- defensive lob (power and spin capped: a fast flick never makes it an attack). The body and paddle reach toward the
	-- contact (animation only: the root is never moved), land, then a StandUpTime get-up during which your WalkSpeed is
	-- x RecoverySpeedFactor; preparing, flicking and hitting stay available; no cooldown, no stamina cost, no random roll.
	Emergency = {
		Enabled = true,
		ReachExtra = 4.5, -- studs beyond PaddleReach
		LandDelay = 0.25, -- s from the contact to landing (the reach animation's lunge)
		StandUpTime = 0.5, -- s get-up after landing
		RecoverySpeedFactor = 0.8, -- WalkSpeed multiplier during the get-up
		-- the flick's POWER plays no part in a save (the lob's own slow speeds below decide its pace: never an attack)
		SpinFactor = 0.3, -- the flick's spin x this ...
		MaxSpin = 20, -- ... capped at this (rad/s)
		-- the lob: the slowest of Speeds (studs/s, horizontal) that lands legally and peaks at most MaxApex above the table
		Speeds = { 46, 52, 58, 64, 72, 80 },
		MaxApex = 18,
		Depth = 0.7, -- landing depth on the opponent's half
		AimFollow = 0.5, -- the landing follows the locked base aim by this fraction (safe, not a placement winner)
		SolveBudget = 0.015,
	},

	-- RALLY TELEMETRY (2026-11-17, diagnosis only; changes no gameplay). Client/Telemetry logs every incoming ball and
	-- every attempt (no gesture, committed-but-no-flick with how close the hand came to a flick, early, late, out of
	-- reach, contact and where the shot was predicted to land); RallyService logs its verdicts, the falling-ball rule's
	-- effect, missed incoming balls and point endings. Lines start with "[Tel]" in the Output window; a summary prints
	-- every SummaryEvery attempts and on request (Player.NotPongTelemetry:Invoke("summary")).
	Telemetry = {
		Enabled = true,
		Print = true, -- one Output line per attempt / ball / point
		SummaryEvery = 10,
	},

	-- CHARGE SLOW MOTION (server-authoritative; Server/RallyService + Client/ShotController). When the incoming ball is
	-- close to contact, the ball, bot and player move at TimeScale while you charge and curve.
	-- (2026-11-17) OFF for rallies: its trigger (pressing to charge near contact) no longer exists with click-and-flick;
	-- you chose to leave rally slow motion off until a new trigger is decided. The slow-motion plumbing (time scale,
	-- bot/player slowing, client tint) is kept; nothing starts it.
	ChargeFreeze = {
		Enabled = false,
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
		-- ORDINARY JUMP (2026-11-19 Pass 12). Measured before: the default jump scaled with the 3.37x avatar (JumpPower 91.8)
		-- rose ~21.5 studs and stayed ~0.94 s in the air (floaty). Now a moderate, quicker jump: Height studs at the apex
		-- and AirTime seconds off the ground, from the CHARACTER's own extra gravity while airborne (a VectorForce on the
		-- local character's root, Client/JumpController; workspace.Gravity and the ball physics are untouched) plus the
		-- matching JumpPower (MovementService). Space jumps in rallies and free roaming; on your serve Space only tosses.
		-- While airborne the stance / footwork tracks yield to Roblox's jump / fall animations (StancePose), blending back
		-- over StanceFadeIn after landing; the visual smash hop never starts in the air (no double lift).
		Jump = {
			Enabled = true,
			Height = 6, -- studs at the apex (the avatar is 17.5 tall)
			AirTime = 0.42, -- seconds from take-off to landing on flat ground
			AirGrace = 0.12, -- s of Freefall (not a jump) before the stance yields (stepping off a small ledge)
			StanceFadeOut = 0.1, -- s
			StanceFadeIn = 0.18, -- s
			YieldStance = true,
			-- measured 2026-11-19: the engine's take-off speed was ~1.05x JumpPower and the first airborne frame adds ~0.8
			-- studs (apex 7.3 for Height 6); this scale brings the measured apex to ~Height
			TakeoffScale = 0.9,
			CutJumpHold = true, -- end the Humanoid's Jumping state (which holds the take-off speed ~0.12 s) after one frame
			-- (Pass 15) ONE JUMP PER GROUNDED CYCLE (Client/JumpController): grounded = a raycast finds the floor within
			-- GroundTolerance studs of the rest height (hip + half the root) and the root rises slower than MaxRiseGrounded
			-- studs/s. The Humanoid's own floor state is not trusted (it reports a floor through the whole jump on this rig).
			GroundTolerance = 0.8,
			MaxRiseGrounded = 12,
			GroundReach = 8, -- studs of ray beyond the rest height
			HeldGrace = 0.08, -- s a jump input counts as still held (a fresh press needs this long released)
		},
		-- (The F dive, its lunge, 1.3 s recovery, stamina cost and AUTOMATIC return were retired on 2026-11-17: the
		-- EMERGENCY SAVE in the click-and-flick shot replaces them, Config.Emergency.)
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

	-- PADDLE ARM LAYER (click-and-flick, 2026-11-17; StancePose + Shared/PaddleArm; client, visual only). The local
	-- player's paddle arm (shoulder, elbow, wrist) follows the shot controller: the PREPARED pose from the cursor
	-- (PaddleArm's solved grid, blended), then on a flick a stroke to the CONTACT pose (solved per swing so the blade
	-- meets the predicted ball, timed to the contact moment), a follow-through, and back to preparation. It is written
	-- after the Animator each frame, over the stance track's arm only: legs / footwork, hips, root and facing are never
	-- touched. Your serve's hold / toss / strike clips own the arm, so the layer fades out during your serve; the
	-- emergency save's body clip leaves the paddle arm to this layer (the arm reaches for the ball over the lunge).
	ArmLayer = {
		Enabled = true,
		BlendRate = 12, -- 1/s: the layer's weight in / out
		PrepSmoothing = 18, -- 1/s: the pose eases toward the cursor's prepared pose (no snaps when the cursor jumps)
		MinStrikeTime = 0.06, -- s: the quickest stroke from preparation to contact (a flick recognised late)
		FollowTime = 0.16, -- s: contact -> follow-through
		-- SMASH HOP (2026-11-19; visual only: no jump velocity, reach, root displacement, slowdown or lock): on a credible smash
		-- attempt (the predicted contact is smash-eligible, ShotInput.smashEligible, the flick's onset is fast enough, and not an
		-- emergency save) the body dips at the flick onset, rises to its peak just after the contact and lands with a knee
		-- absorb, by offsetting the LowerTorso root joint + flexing the legs (the physics root never moves). The dip is
		-- squeezed into the time left before the contact (never delaying it); Total is the whole action in seconds.
		-- Heights are fractions of the avatar's leg length (upper + lower leg), so they follow the avatar's scale.
		SmashHop = {
			Enabled = true,
			Total = 0.36, -- s, whole action from the onset
			DipTime = 0.06, -- s, at most (shorter when the contact is nearer)
			DipFraction = 0.2, -- crouch depth (of leg length)
			RiseFraction = 0.3, -- peak rise (of leg length)
			PeakAfterContact = 0.04, -- s: the peak comes this long after the contact (the paddle meets the ball on the way up)
			LandFraction = 0.62, -- of Total: the feet are back on the floor
			AbsorbFraction = 0.6, -- landing knee absorb depth (of the dip)
			OnsetSpeed = 1800, -- ref px/s: the onset must be at least this fast (a soft flick at a high ball is not a smash attempt)
			HipSign = 1, -- direction of the hip / knee flexion (R15 joint axes; verified by measuring the feet)
			KneeSign = -1,
			LegFlex = 0.84, -- multiplier on the computed leg flexion, tuned by measuring the feet against the floor during the dip (1.0 floated them 0.45 studs, 0.85 -> 0.03)
			FadeOut = 0.08, -- s: the hop eases out when the swing turns out not to be a smash
			FreezeAt = nil, -- REVIEW ONLY: a time (s from the onset) holds the hop at that pose; nil in play
			TimeScale = 1, -- REVIEW ONLY: > 1 stretches the identical motion (e.g. to capture stills); keep 1 in play
		},
		-- (2026-11-18) with ShotControl.StrokeAtOnset the stroke starts at the flick's ONSET and may be this quick (the
		-- onset is recognised ~1-2 frames after the hand starts; contact is Flick.ContactDelay after the start)
		OnsetMinStrikeTime = 0.025,
		-- WIND-UP = the COMMITTED (cocked) paddle while left-click is held (2026-11-18: shown from the press, eased back on
		-- release / cancel; a swing starts from it). Extra joint angles (same layout as Follow), reached in Time. Max is
		-- unused while committed (the hold can be as long as you like).
		Windup = {
			Enabled = true,
			Time = 0.08,
			Max = 0.25,
			Forehand = { -9, -2, 10, 7, 0, 0, 0, 0 }, -- back and open (about -0.4 x the follow-through)
			Backhand = { -5, 15, 0, 8, 0, 0, 0, 0 },
		},
		ReturnTime = 0.3, -- s: follow-through -> preparation
		-- STROKE PROFILES (2026-11-19; reference: docs/Not pong obsidian vault/drive-swing-animations.png). The follow-through is
		-- SOLVED like the contact (Shared/PaddleArm.solveContact) toward a blade target in the upper torso's frame, given as
		-- { right, up, forward } in units of ArmReach (Face = the striking face's direction there, same frame), plus an extra
		-- torso turn Waist = { lean, twist, side bend } degrees (measured on the avatar: + twist turns LEFT, + lean tilts BACK,
		-- + bend tilts LEFT). INTENSITY 0..1 comes from the shot's actual power (SoftPower .. StrongPower): a soft return only
		-- travels Reach.x of the way from the contact to the target with a little of the torso turn; a strong one all of it.
		-- Smash = the server's smash rule (any stroke): cocked above / behind the playing shoulder while committed (Cock), high
		-- contact (the ball's legal height), then DOWN and across to the opposite hip. Scoop = an emergency save: the blade
		-- goes UNDER the ball with an open face (ScoopUp of the way from the outgoing direction to straight up), then lifts
		-- forward (Follow in WORLD terms: right = 0, up, forward = along the shot). false = the previous fixed offsets (Follow).
		Strokes = {
			Enabled = true,
			SoftPower = 0.35,
			StrongPower = 0.85,
			Forehand = { Follow = { -0.55, 0.25, 0.55 }, Face = { -1, 0.2, 0.4 }, Waist = { -6, 18, 0 }, Reach = { 0.35, 1 }, FollowTime = { 0.12, 0.2 } },
			Backhand = { Follow = { 0.8, 0.1, 0.7 }, Face = { 0.7, 0.1, 0.7 }, Waist = { 0, -14, 0 }, Reach = { 0.4, 1 }, FollowTime = { 0.1, 0.16 } },
			Smash = {
				Follow = { -0.45, -0.55, 0.55 }, Face = { -0.2, -0.8, 0.5 }, Waist = { -14, 16, 0 }, Reach = { 1, 1 }, FollowTime = { 0.22, 0.22 },
				Cock = { 0.5, 1.0, -0.3 }, CockFace = { 0, 0.5, 1 }, -- above / behind the playing shoulder (committed, smash-height ball)
			},
			Scoop = { Follow = { 0, 0.4, 0.25 }, ScoopUp = 0.75, Waist = { 8, 0, 0 }, Reach = { 1, 1 }, FollowTime = { 0.24, 0.24 } },
			HoldTime = 0.04, -- s at the end of the follow-through before returning to the ready pose
			-- REVIEW ONLY: hold the paddle arm at contact + this many seconds of the current stroke (nil in play)
			FreezeAt = nil,
		},
		-- extra joint angles at the follow-through ({ shoulder x, y, z, elbow x, y, wrist x, y, z }, degrees)
		Follow = {
			Forehand = { 22, 6, -26, -18, 0, 0, 0, 0 }, -- up and across the body
			Backhand = { 12, -38, 0, -20, 0, 0, 0, 0 }, -- out to the right
		},
		FaceOffset = 0.95, -- studs: blade centre behind the ball along the striking face (ball radius + half the paddle)
		MissReach = 3, -- studs: a swing with no ball goes this far forward from the prepared blade
		-- contact solve (Shared/PaddleArm.solveContact)
		SolveIterations = 28, -- (measured ~8 ms at 40 passes, once per swing; fewer passes trade a little accuracy for time)
		SolveStep = 14, -- degrees, halved when stuck (stops below 0.5)
		FaceWeight = 6, -- striking face along the outgoing direction
		StayWeight = 0.0004, -- stay near the prepared pose (no wild solutions)
		ClearanceWeight = 10, -- no blade / hand / forearm through the torso, head, upper arm or table top
		-- UPPER-BODY SUPPORT for far contacts: an extra waist rotation (lean x, twist y, side bend z) on top of the stance,
		-- used only when the arm alone cannot reach (it costs WaistWeight per degree squared); capped at WaistLimit.
		WaistWeight = 0.004,
		WaistLimit = Vector3.new(18, 40, 22), -- degrees: lean, twist, side bend
	},

	-- (DivePose, the F dive's clip blending, was retired on 2026-11-17 with the F dive; the emergency save's body clip
	-- NP_SaveRight / NP_SaveLeft is played by the stance controller, see StancePose controller:playSave.)

	-- Client-side visual feedback (never authoritative). Colours are cosmetic and independent of gameplay.
	Feedback = {
		-- 3D trajectory arrow (Client/TrajectoryArrow): the predicted flight of the charged shot, from the predicted
		-- paddle contact to the first predicted landing, simulated with the shared BallPhysics. Shown while charging.
		Arrow = {
			-- (Pass 13) BLUE: the shot preview must not share a colour with the ball's own trail (white / yellow / red / purple
			-- rally stages, orange vulnerable ball); it was purple, the same as the capped rally trail
			Color = Color3.fromRGB(170, 215, 255), -- bright core (additive glow)
			GlowColor = Color3.fromRGB(40, 110, 255), -- wider blue halo (not additive, so it stays blue on any table colour)
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
			RiskyColor = Color3.fromRGB(150, 235, 255), -- (Pass 13: was amber, read as the orange vulnerable-ball cue)
			EndRingRadius = 1.5, -- studs: highlight on the predicted landing spot
			-- PROGRESSIVE REVEAL (2026-11-18 Pass 1): after the flick is finalised the predicted path DRAWS from the contact
			-- point to the predicted landing in RevealTime (well inside any flight time, so its leading edge stays ahead of
			-- the real ball), stays HoldTime, then fades over FadeTime. The landing ring and NET / OUT label appear when the
			-- reveal reaches them. When the server's verdict arrives the path is recomputed from the server's own launch
			-- (velocity + spin); a miss / refusal removes it. false = the previous always-full arrow.
			Reveal = true,
			RevealTime = 0.15, -- (Pass 13: was 0.22)
			HoldTime = 0, -- (Pass 13: was 0.45; the preview no longer lingers over the real, already resolved flight)
			FadeTime = 0.15, -- (Pass 13: was 0.3; measured, it still covered the real ball's early flight)
		},
		-- CURSOR TRACE (2026-11-18 Pass 1; replaces the Curve bar and the flick dial's spin arrow): while left-click is held,
		-- the ACTUAL relative mouse movement the flick detector receives is drawn as a short screen-space trace around the
		-- held cursor (a virtual trace: the real cursor is never moved, the trace never feeds back into the shot). Scale
		-- converts reference px to screen px; the whole trace shrinks uniformly to stay inside MaxRadius. Thickness and
		-- brightness follow each sample's speed (OnsetSpeed .. FullPowerSpeed of Config.Flick); the part the detector
		-- measured is bright, the hold drift before it and the hand's tail after it faint. Fades FadeTime after the stroke.
		CursorTrace = {
			Enabled = true,
			-- VISUAL SIZE (2026-11-19): one multiplier on Scale, MaxRadius, the thicknesses and the end marker (1 = the Pass 1
			-- size; 1.24 = 24% larger). Uniform, so the trace's direction is never distorted; the gesture itself (sensitivity,
			-- thresholds, power, spin) is not touched.
			Size = 1.24,
			Scale = 0.5,
			MaxRadius = 110, -- px
			Window = 0.35, -- s of movement before the flick that stay drawn
			TailTime = 0.12, -- s of movement after the flick was finalised still drawn (display only)
			MinThickness = 2,
			MaxThickness = 6,
			Color = Color3.fromRGB(120, 230, 255), -- cyan: distinct from the purple world-space arrow
			FaintTransparency = 0.7,
			FadeTime = 0.45,
			MaxSegments = 40,
		},
		-- ATTACKABLE HIGH BALL TRAIL (2026-11-18 Pass 1): when the server classifies a hit as giving the receiver a smash
		-- opportunity (ShotInput.highBallWindow: after its legal bounce the ball passes through smash height, inside the
		-- reachable height band, not too far behind the receiver's end line), the ball's normal trail blends into a thin
		-- orange wavy line (+ a wider faint companion) following the rendered ball, and back when the opportunity ends.
		-- The wave is a sum of three slow sines in distance travelled (wavelengths below, phases seeded per ball) under a
		-- slow amplitude envelope: smooth, varied, never per-frame random.
		HighBallTrail = {
			Enabled = true,
			-- (Pass 12) WHO GETS ORANGE (server, RallyService.strike, the same for both competitors, decided at the hit):
			--   * every defensive LOB: a player's emergency save, the bot's pop-up (always, smash window or not);
			--   * every other HIGH return that opens a smash: its predicted post-bounce flight passes through the receiver's
			--     legal smash band (ShotInput.highBallWindow) for at least MinWindow AND it flies high (pre-bounce apex >=
			--     MinFlightApex above the table) or sits up after its bounce (post-bounce apex >= MinApex).
			-- Measured 2026-11-19 (scripted rallies, normal arcs): ordinary drives window 0-0.30 s, apex 7.6-9.7, flight
			-- apex 11.6-15.3 (no orange); saves 0.27-0.36 s / 9.0-9.3 / 17.1-17.4; high returns 0.40-0.77 s / 10.8-14.9 /
			-- 17.4-29.7 (orange). The old filter (window >= 0.4 s and apex >= 9.5) missed saves and some high returns.
			-- NOTE: by the smash rule alone (centre >= 7.5 above the table) most drives that bounce up are technically
			-- smashable with tight timing; orange marks the clearly high / vulnerable ones only.
			MinWindow = 0.05, -- s
			MinApex = 10, -- studs above the table after the bounce ("sits up")
			MinFlightApex = 16, -- studs above the table before the bounce ("lob height")
			Color = Color3.fromRGB(255, 150, 50),
			Width = 0.32, -- studs, the line
			HaloWidth = 1.0, -- studs, the companion
			CoreTransparency = 0.15,
			HaloTransparency = 0.8,
			Lifetime = 0.5,
			Amplitude = 0.22, -- studs (restrained)
			WaveLengths = { 2.7, 4.9, 8.3 }, -- studs travelled per wave
			EnvelopeLength = 11, -- studs: the slow amplitude modulation
			FadeIn = 0.15, -- s
			FadeOut = 0.35, -- s (the smash window ran out)
			FadeOutOnHit = 0.08, -- s (the receiver hit it: the opportunity is over at once)
			LeadIn = 0, -- s before the opportunity window the orange may start (0 = from the hit that created it)
		},
		-- CONTACT RING (Client/ContactRing; replaced the accuracy bar, 2026-11-17): a hollow ring round the incoming ball;
		-- its arc (clockwise from 12 o'clock) completes and turns green while a flick right now would register.
		ContactRing = {
			Segments = 72, -- bars the arc is drawn with
			Thickness = 4, -- px, the arc
			TrackThickness = 2, -- px, the faint full circle
			TrackTransparency = 0.78,
			ArcTransparency = 0.05,
			FarRadius = 78, -- px, the ring's radius when far (it tightens toward the ball, never below ball radius + NearGap)
			NearGap = 9, -- px between the ball's edge and the ring when tight
			LeadTime = 0.9, -- s before a flick becomes valid at which the arc starts to grow
			BeforeValidMax = 0.97, -- the arc never reads as complete until contact is actually possible
			ApproachStuds = 40, -- with no reachable window: the arc follows the distance to the contact area over this span ...
			UnreachableMax = 0.8, -- ... and never goes past this fraction (never complete, never green)
			Smoothing = 16, -- 1/s on the approach only (the green signal is never smoothed)
			FadeTime = 0.18, -- s to fade out after the opportunity (the arc is not unwound)
			ArcColor = Color3.fromRGB(235, 240, 255),
			TrackColor = Color3.fromRGB(235, 240, 255),
			GreenColor = Color3.fromRGB(90, 235, 120),
		},
		-- Aim marker (click-and-flick): the BASE aim on the opponent's half while preparing (cursor) and committed (locked):
		-- a ring where the base aim points and a post whose height shows the drive (PostMin) .. arc (PostMax) profile.
		AimMarker = {
			RingRadius = 1.6,
			PostMin = 0.6, -- studs: profile 0 (low drive)
			PostMax = 5, -- studs: profile 1 (high arc)
			Color = Color3.fromRGB(235, 235, 245), -- following the cursor
			LockedColor = Color3.fromRGB(200, 110, 255), -- locked at the click
		},
		-- Power / curve meter (bottom right): shown after a flick only: Power = what the flick's speed gave; Curve = the
		-- spin strength. (Holding the button never fills anything.)
		PowerMeter = {
			Width = 220,
			Segments = 5,
			PowerColor = Color3.fromRGB(200, 110, 255),
			FullColor = Color3.fromRGB(255, 120, 230), -- the power bar at full charge
			CurveColor = Color3.fromRGB(170, 120, 255),
			ShowCurve = false, -- (2026-11-18) the Curve bar is replaced by the cursor trace (Feedback.CursorTrace); true = show it
			ShowAfterRelease = 0.7, -- seconds the meter stays after the swing
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
			SaveColor = Color3.fromRGB(255, 150, 60), -- the emergency-save window and verdict
			ResultShowTime = 0.9,
		},
		-- Ball trail (follows the rendered ball; drawn from its real position every frame, so it shows the real curve).
		Trail = {
			Enabled = true,
			Lifetime = 0.55, -- (Pass 13: was 0.4; the trail read as missing from the gameplay camera)
			Width = 2.4, -- studs (2026-11-20: 2.4 with the comet texture, whose edges are soft; Pass 13 1.5 plain, was 1.0)
			TailWidth = 0.35, -- width at the trail's end, as a fraction (was 0.15: the tail vanished)
			LightEmission = 0.8, -- (was 0.55)
			ColorLightEmission = 0.12, -- (2026-11-20) emission once a stage colour has taken over (additive glow washed purple to pink)
			-- (Pass 15) TAPER: widest right behind the ball, narrowing smoothly to the oldest end (WidthScale key 0 = newest point at the ball,
			-- 1 = oldest). Pass 14's narrow-head shape read as a tail growing away from the ball. (position along the trail, width fraction); the end is TailWidth.
			Taper = { { 0, 1 }, { 0.2, 0.9 }, { 0.5, 0.58 }, { 0.8, 0.3 } },
			SlowColor = Color3.fromRGB(190, 200, 215),
			FastColor = Color3.fromRGB(255, 255, 255),
			TopspinColor = Color3.fromRGB(255, 150, 70), -- tint by dominant spin axis (kept subtle)
			BackspinColor = Color3.fromRGB(110, 180, 255),
			SidespinColor = Color3.fromRGB(190, 120, 255),
			TintStrength = 0, -- (Pass 13) spin tint OFF: its orange topspin tint competed with the orange vulnerable-ball cue (spin physics unchanged)
			FullSpeed = 126, -- studs/s at which the trail is at full brightness / width
			MinTransparency = 0.25, -- most opaque the trail gets (fast ball)
			MaxTransparency = 0.7, -- slow ball
			WidthScaleSpinned = 1.35, -- width multiplier at maximum spin
			SpinFullAt = 100, -- rad/s treated as "full spin" for the visuals
			-- RALLY COLOURS (Pass 15): the base trail's colour follows the number of accepted RETURNS this rally (the server's
			-- referee hit counter minus the serve, which is hit 1: counted once per legal paddle hit by either side, never from
			-- ticks, bounces, predictions or duplicate messages; it restarts at 0 with every serve). Stage = floor(returns /
			-- ReturnInterval): 0-9 white, 10-19 yellow, 20-29 red, 30+ purple. Independent of the pace percentage (RallyPace,
			-- unchanged). The colour switches HARD at the boundary (a blend yellow -> red would pass through the orange of the
			-- vulnerable-ball cue). The orange HighBallTrail overrides it while active; the stage colour is back when it ends.
			RallyColors = {
				Enabled = true,
				ReturnInterval = 10,
				Colors = {
					Color3.fromRGB(255, 255, 255),
					Color3.fromRGB(255, 226, 90),
					Color3.fromRGB(225, 20, 60), -- (2026-11-20 deeper crimson: visible over the orange table)
					Color3.fromRGB(176, 96, 255),
				},
				BlendTime = 0.15, -- s: the comet layers' fade-in / glow ease to a new stage (the colour itself switches at once)
			},
			-- (2026-11-20) the main ribbon's texture: the streaky comet body cut from the user's Trails sheet
			-- (sprites/Trails/9251.jpg, top-right comet; tools/trail_textures.py -> assets/vfx/comet_body.png). nil = plain ribbon.
			Texture = "rbxassetid://72980472869758",
			-- COMET LAYERS (2026-11-20; replaces the single Pass 12/13 SpeedStreaks strand, whose texture was also drawn sideways:
			-- Roblox Trails run the texture's height along the length). Textured Trails on the ball's follower, cut from the
			-- user's SyphoDev Trails sheets (9251.jpg comets; 9247.jpg is the colour reference: white-hot head, stage-coloured
			-- body). Each layer fades in from FromStage to FullStage (the return-count colour stage, 0 white .. 3 purple; Pass 15):
			-- opening = body + core + light strands; yellow adds sparkle dust; red adds smoky wisps; purple = everything at full.
			-- Opacity also scales with ball speed (SlowFactor at rest .. 1 at FullSpeed) and yields to the orange high-ball line.
			-- Whiten mixes white into the stage colour. HeadClear = fraction nearest the ball left clear (never over the ball).
			Comet = {
				Enabled = true,
				Layers = {
					{ Name = "Core", Texture = "rbxassetid://100596374827505", -- comet_core.png (9251 slim bottom-right comet)
						Width = 1.1, TailWidth = 0.4, Lifetime = 0.2, LightEmission = 1, ColorLightEmission = 1, Whiten = 0.75, HeadClear = 0.04,
						FromStage = 0, FullStage = 3, MinOpacity = 0.7, MaxOpacity = 0.95, SlowFactor = 0.5 },
					{ Name = "Strands", Texture = "rbxassetid://94684561859469", -- comet_strands.png (9251 centre-right comet)
						Width = 3.6, TailWidth = 0.7, Lifetime = 0.35, LightEmission = 0.8, ColorLightEmission = 0.3, Whiten = 0.3, HeadClear = 0.06,
						FromStage = 0, FullStage = 3, MinOpacity = 0.45, MaxOpacity = 0.8, SlowFactor = 0.5 },
					{ Name = "Dust", Texture = "rbxassetid://123517828766864", -- comet_dust.png (9251 centre-left comet)
						Width = 4.2, TailWidth = 1.0, Lifetime = 0.5, LightEmission = 1, ColorLightEmission = 0.8, Whiten = 0.5, HeadClear = 0.08,
						FromStage = 1, FullStage = 3, MinOpacity = 0.4, MaxOpacity = 0.85, SlowFactor = 0.6 },
					{ Name = "Wisps", Texture = "rbxassetid://84393863768285", -- comet_wisps.png (9251 smoky bottom-left comet)
						Width = 4.0, TailWidth = 1.1, Lifetime = 0.6, LightEmission = 0.6, ColorLightEmission = 0.15, Whiten = 0.15, HeadClear = 0.1,
						FromStage = 2, FullStage = 3, MinOpacity = 0.3, MaxOpacity = 0.6, SlowFactor = 0.6 },
				},
			},
		},
		-- SHOT VFX (2026-11-19; Client/ShotVfx; textures from the SyphoDev pack, assets/vfx/MANIFEST.md). One accent per swing
		-- at the predicted contact (cancelled on a server miss, shown late at the server's contact if only the server says
		-- hit), a paddle trail on strong strokes and smashes. Replaces the old ImpactFx burst while enabled. false = ImpactFx.
		ShotVfx = {
			Enabled = true,
			StrongPower = 0.6, -- power from which a return counts as STRONG (burst + trail), scaled up to full power
			Textures = {
				Glint = "rbxassetid://87790381341943", -- sprites/impacts/hit_cross_glow_01
				Burst = "rbxassetid://72862746379191", -- sprites/impacts/starburst_soft_02
				SmashBurst = "rbxassetid://90799407633776", -- sprites/impacts/comic_burst_glow_03
				SmashLines = "rbxassetid://133061155758744", -- sprites/impacts/speed_lines_glow_02
				ScoopRing = "rbxassetid://139930241889632", -- sprites/rings/ring_soft_08
				Trail = "rbxassetid://115112933165849", -- beams/energy_soft_01
			},
			Colors = {
				Soft = Color3.fromRGB(255, 245, 225),
				Strong = Color3.fromRGB(255, 170, 70),
				Smash = Color3.fromRGB(255, 205, 60),
				Scoop = Color3.fromRGB(120, 220, 255),
			},
			TrailLifetime = 0.16, -- s the ribbon lingers behind the paddle
			TrailAfterContact = { strong = 0.16, smash = 0.22 }, -- s after the contact the trail stays on (the follow-through)
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
