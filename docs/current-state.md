# Current State

_Last updated: 2026-11-17 (Pass 8), latest change: **mouse-only rally input prototype (no click: the cursor prepares, a deliberate flick while the ball is coming is the swing), switchable back with `Config.ShotControl.RallyInput = "ClickLock"`**; see "Pass 8" at the end. Before it (Pass 7 Stage 1): **legal rising-ball returns (the falling-ball requirement is now `Config.ShotControl.RequireFallingBall = false`; save ring unchanged) and brief HUD miss reasons (NO FLICK / TOO EARLY / TOO LATE / OUT OF REACH / CONTACT • OUT)**; see "Pass 7 Stage 1" at the end (it supersedes the falling-ball rule described in Pass 6 / 6c / 6d). Before it (Pass 6): **click-and-flick rally (cursor-prepared paddle and base aim, click to commit, flick = swing: speed -> power, direction -> spin), serves by flick, the emergency save replacing the F dive, rally slow motion off, a procedural paddle arm that meets the ball**; see "Pass 6" at the end (it supersedes every earlier section on hold-to-charge, drag spin, release-to-strike, the charge slow motion, the F dive and its automatic return). Before it, 2026-11-16 (Pass 5c): **paddle v4 (flat-bottom rubbers exposing the wooden shoulder, narrow black edge band, plain colours, textures removed) and a genuine backhand face flip (the opposite rubber faces the player)**; see "Pass 5c" at the end (it supersedes Pass 5b's zones/textures and Pass 5's backhand pose). Before it: **paddle v3 from the build guide: same blade size and hit area, shorter flared handle, thicker 5-ply blade with sponge and separate rubber sheets, fine 1024 px rubber/wood/grip textures**; see "Pass 5b" at the end (it supersedes Pass 5's paddle description). Pass before it: **hybrid footwork (longer shuffles + crossover strides), a detailed larger paddle with independently styled zones and a matching contact radius, and the cursor-side paddle holding lean**; see "Pass 5" at the end (it supersedes the old shuffle clips/cadence settings and the old paddle template). Before it: **safe serve envelope (no serves escaping over the receiver's side line), Q serving posture, serve camera offset from court position, defensive dive lobs, bounded serve-solver cost, and a new concept-based table + large-square net**; see "Pass 4" at the end; it supersedes Pass 3's fixed serve-camera offset, its serve-stroke-from-cursor rule, its dive-return speed and its serve-solver budget, and the table asset description in "Uploaded assets". Before it, 2026-11-16: **balanced camera follow + lower serve view, natural toss with NO serve slow motion, contact-based legal serves, automatic dive returns (~90% legal), honest clean-shot preview, reversal flicker in the footwork**; see "Pass 3" at the end; it supersedes Pass 2's serve (apex slow motion, fixed-height timer, unforgiving fixed launch) and dive (manual contact) sections. Before it, 2026-11-15: **fluid athletic movement (stiffness/shake diagnosed and fixed), manual dive contact with F + backward dives and a 1.3 s get-up, and the player's manual toss-and-strike serve**; see "Pass 2: movement, manual dives, manual serve" at the end; it supersedes older sections on the dive (key E, automatic return), the serve (automatic strike, fixed spot) and the footwork/grounding. Before it the same day: **uploaded table + paddle, table enlarged x1.5, Edit-mode persistence fixed, new dive/get-up and shuffle footwork animations, wider camera and off-platform behaviour**; see "Uploaded assets, x1.5 table, persistence, dive/footwork animations, off-platform camera" near the end. Where this file's older sections disagree with that section (table size, ball size, editing rules, dive pose), that section wins. Earlier the same day: forehand/backhand by mouse screen side, and runtime checks of slow motion and stamina; see "Forehand / backhand + runtime checks" near the end. Before it, 2026-11-14: gameplay refinement awaiting review: much stronger sidespin curves, faster shots, a low over-the-shoulder camera, and server-authoritative charge slow motion; see "Refinement" below. Before it: the Charge -> Curve -> Release core rework, Phase 4 feedback/movement, Phase 2-3 physics, rallies and shot controls)._

## Architecture: static arena in Studio, dynamic gameplay at runtime

**STATIC: saved in the place, visible and editable in Edit mode.** `Workspace.NotPongArena`:

| Object | Role | Edit it? |
|---|---|---|
| `Table/Collision/TableTop` | Invisible solid block, floor to playing surface. THE gameplay table (collision, future targeting bounds) | **No** (geometry is re-enforced) |
| `Table/Visual/TableSurface` | The visible playing surface | **Yes**: colour, material, patterns |
| `Table/Visual/SideLine*, EndLine*, CenterLine` | Painted lines | Colour/material yes; size/position no |
| `Table/Visual/Leg1-4` | Legs (non-colliding) | Colour/material yes |
| `Net/NetMesh, NetTape, PostLeft, PostRight` | The net | Colour/transparency yes; size/position no |
| `Platform` | The playing slab (top surface = the playing floor) | Colour/material yes; size/position no |
| `BallTemplate/Ball` (+ `BallVisual`) | The ONE ball. `Ball` is the invisible canonical gameplay part (0.4), moved by the server; `BallVisual` is the cosmetic shell, drawn by each client from server snapshots | `BallVisual`: colour, material, textures, trail, and (it turns out) size: yours is currently 1.0 and is kept. Edit-mode position is only a preview |
| `PlayerSpawn` (SpawnLocation), `BotSpawn` (Part) | Markers: their X/Z is where each competitor stands | **Yes**: move them (keep them inside the play area) |

**DYNAMIC: created at Play, never saved:** the player's character, the bot, paddles, match state, camera, facing and stance controllers.

**How Play finds the arena.** `ArenaBuilder.load()` looks up the existing `NotPongArena`, never rebuilds it, warns about duplicates, compares it with `Config` and corrects any difference in memory for that session (with a warning), then adds the ball. It creates an arena only if none exists (fallback, with a warning). Spawn markers are hidden during Play and shown in Edit.

**Create-or-update by name.** `ArenaBuilder.syncGeometry()` creates or updates every static part by name from `Config`. **Geometry properties are always enforced** (size, position, anchoring, collision flags, collision group). **Cosmetic properties are written only when a part is first created**, so your edits are never overwritten. Run it after changing a geometry value in `Config` (table width, ArenaScale, platform, play area...). In Studio's Command Bar (Edit mode): `require(game.ServerScriptService.Server.ArenaBuilder).syncGeometry()`. Save the place afterwards.

**Gameplay vs cosmetic separation (unchanged principle).** Collision is only `Table/Collision/TableTop`, the net parts and the platform (the ball itself never uses Roblox collision: `TableWorld` mirrors these from Config). Anything under `Table/Visual` is cosmetic: restyling cannot change the playable surface. The ball's gameplay part is canonical (0.4 studs, invisible); skins touch only `BallVisual`. Move the ball only via `ArenaBuilder.moveBall`.

**Old implementation, kept until the static arena is verified (it is): ** `docs/archive/ArenaBuilder.runtime-build.luau.txt` (the runtime builder), `docs/archive/Config.before-static-arena.luau.txt`, `docs/archive/CameraController.before-dynamic.luau.txt`. Delete them when you are happy.

## How to change the table's colour, material and pattern in Studio

1. Open **Explorer > Workspace > NotPongArena > Table > Visual > TableSurface**.
2. **Colour:** Properties > `Color`. **Material:** Properties > `Material` (or set `MaterialVariant` to use a custom variant).
3. **Pattern:** right-click `TableSurface` > Insert Object > **Texture** (or Decal). Set `Face` = Top, `Texture` = your image id, `StudsPerTileU/V` to size the repeat, `Transparency` to blend. (Insert a `SurfaceGui` for UI-style patterns.) Several overlays can coexist.
4. **Line colour:** select `SideLineLeft`, `SideLineRight`, `EndLinePlayer`, `EndLineBot`, `CenterLine` and set `Color`.
5. **Platform:** select `Platform` > `Color` / `Material`. **Net:** `NetMesh`/`NetTape`/posts > `Color`, `Transparency`.
6. **Save the place (Cmd+S).** Edits survive Play because Play never touches cosmetics (verified).

**Safe to edit:** `Color`, `Material`, `MaterialVariant`, `Reflectance`, `Transparency` of visual parts, and any Texture/Decal/SurfaceGui/SurfaceAppearance/Highlight children; positions of `PlayerSpawn` and `BotSpawn`.
**Do not edit (they are re-enforced from Config at Play and by `syncGeometry`):** `Size`, `Position`/`CFrame`, `Anchored`, `CanCollide`, `CollisionGroup` of any static part, and anything in `Collision`. To resize, change `Config` and run `syncGeometry()`.
Default look comes from `Config.TableStyles.Default` and is applied once, at creation. `ArenaBuilder.applyTableStyle(arena, name)` re-applies a Config style on demand (it will overwrite your colours/material/pattern).

## Round 4: persistence, ball template, no barriers

**Why Studio edits could be lost.** Play never re-styled the table, net or platform, but (1) `ensure()` destroyed and recreated any static part whose class differed from `Part` (a MeshPart/Union swapped in for looks was deleted), and (2) `load()` re-wrote every static part's properties and re-applied the ball style at every Play, and the ball only existed at runtime. Fixes: `ensure()` now keeps any BasePart; `load()` writes **nothing** to the static arena unless gameplay geometry (TableTop, NetMesh, Platform) is out of date with Config or the ball template is missing (and even then never touches cosmetics); the ball style is applied only when the ball is first created.

**Ball.** `Workspace.NotPongArena.BallTemplate.Ball/BallVisual` exists in Edit mode (preview position at the serve point). At Play it is the one active ball: its sizes are enforced (canonical 0.4 collision, 0.5 visual), it is moved to the serve point, any other part named Ball/BallVisual under the arena is removed, and its appearance is left exactly as you set it. Gameplay and physics read `Config`, never the part's look, so future skins only touch `BallVisual`.

**Barriers.** Removed: the 8 `Boundary` walls (Studio folder deleted, creation code removed), `PlayAreaGuard` (file, call), nothing replaces them. Platform and table collisions are unchanged.

**Facing and camera for walking around.** Facing aims at a point that slides smoothly along the table with the player (far end line when behind an end, table centre alongside, near end line behind the other end), so there are no jumps. Camera: framing is mirrored when the player is on the bot's half (flip with 6-stud hysteresis), and alongside the table it is held at the closest standing framing so the whole table stays in view.

**Tested (Play):** table, platform, net, decorative object and ball colour/material edits all persisted; exactly 1 ball and 1 visual; ball at the serve point with canonical sizes; no Boundary/guard; table 23 x 31.51 collision intact; `moveBall` keeps the shell centred; console clean; sync delivered the deletion of `PlayAreaGuard`. Walked right-rear, right-mid, right-front, behind the bot, left-front, left-mid, left-rear and home: reached every stop, facing error 0.0 degrees to the aim point (at least 0.88 toward the table), player always on screen, whole table on screen at every stop (min margin 6%). **Test colours and the test decor object were restored/removed.**
**Known gaps:** the bot's head can graze the screen edge when you stand alongside on the mirrored side, and the camera swings across when you cross the net plane (by design, smoothed). Walking behind the bot places the camera behind you looking at the table with the bot in front of it. Not tested: real keyboard input, other avatars, real server.

## Scale and units

**1 stud = 0.1 m** (`StudsPerMeter = 10`). Canonical ITTF measurements stay in `Config.Real`. Presentation multipliers in `Config.Presentation`:

| Value | Setting | Notes |
|---|---|---|
| `ArenaScale` | 1.15 | table length/height, net height, lines, legs; NOT ball radius, gravity, avatar |
| `TableWidthStuds` | **23** | the playing width, set directly; tune 22-24 (clamped 20-26); independent of ArenaScale |
| `BallVisualScale` | 1.25 | rendered ball only |

Table: **31.51 long x 23 wide x 8.74 high** (the aspect ratio is deliberately not official; readability first). Net 26.51 long x 1.754 high. Ball: 0.4 collision diameter, 0.5 visual, gravity 98.1 studs/s^2.

**Platform:** 55 x 1 x 95.51, sits on the Baseplate (its top is Y = 0), so the playing floor is `Config.Arena.FloorY = 1`. Size derives from the table and play area (`Config.Platform`, `Config.PlayArea`). Colour/material in `Config.Platform`.

**No movement barriers.** The invisible `Boundary` walls and the server `PlayAreaGuard` clamp were removed; the player can walk anywhere on the platform, including around both sides of the table. (`Config.PlayArea` now only sizes the platform; `Layout.PlayerArea/BotArea` are unused data.)

Axes: table length along Z; player on +Z facing -Z; bot on -Z. Arena origin `(0, 0, 60)`.

## Facing, movement and camera

- **Facing:** `FacingController` (client) sets `Humanoid.AutoRotate = false` and drives an `AlignOrientation` constraint on the root toward an aim point on the opponent's end line, blended by `Config.Facing.AimFollowX` (0.5 = about 13 degrees of turn at the side walls; 0 = about 26; 1 = never turns). No teleporting; the paddle (welded to the hand), stance and camera are unaffected. Smooth: under 1 degree per 50 ms measured.
- **Walk speed:** `Config.Avatar.WalkSpeed = 18`, applied after scaling. (`ScaleTo` multiplies WalkSpeed: the avatar was walking at 52 studs/s before this fix.)
- **Camera (`Config.Camera`):** reference view centred behind the player (Height 42, Behind 15, FOV 58). Walking back moves the camera back 0.26 studs per stud and slides the aim point toward the player 0.75 per stud; sidestepping makes the camera follow by 0.35 (aim by 0.45); the target leads by the player's velocity (`VelocityLead 0.125`) so smoothing (8/s) does not lag a walking player. Parameters were found by a numeric search over the real key points, then verified live. Height does not change.
- **Fade:** body 0.6, paddle opaque, **head opaque** (this avatar's head disappears at any fade above 0).

## Phase 2: physics, serving, rallies, scoring

### Part 1: character grounding and paddle (investigated first)

**Why the characters looked like they were levitating (measured, not guessed).**
1. **No contact shadow.** The foot parts were geometrically on the floor (the bot's at exactly Y = 1.000), but neither character casts a visible shadow while the big table does. A 3 x 10 stud probe block cast none either, so this place's lighting only draws soft shadows for large objects, and the feet have no shadow under them. **This is a Lighting setting you own:** in Studio set `Lighting > Technology` to **ShadowMap** or **Future** and characters get sharp contact shadows. I could not change or even read it from the MCP tool (it is a protected property), so I left it.
2. **Hip bob.** The idle animation moved the hips up and down, so the feet dipped up to 0.37 studs into the floor and back.
3. **Gliding.** The stance track also held the legs while walking, so a walking avatar slid without stepping.

**Fixes (`Shared/StancePose.start`, run by the client for the player and by the server for the bot).**
- The stance is two tracks: **upper body** (always on, the paddle arm keeps its pose) and **legs**, which also holds the hips still at the avatar's *own measured average idle hip pose*. Holding them at the rig's rest pose instead (first attempt) put the hips 2 studs lower than the walk cycle, so starting to walk would have lifted the body 3 studs. Note: keyframe translations are multiplied by the character's scale, so the measured offset is divided by it.
- While moving, the legs track fades out (`MoveSpeedThreshold`, `LegBlendRate`) and the walk cycle drives the legs; the bot, which has no running Animate script, gets the R15 walk animation played by the server.
- HipHeight is **measured per avatar**, not formula-based: one value for the bent-knee stance and, while walking, a value grounded on the lowest foot point of the recent stride (`WalkGroundingWindow`, `WalkGroundingDecay`). The player is never anchored.
- Bot: walk speed now set after scaling (was being multiplied like the player's had been), `AutoRotate` off plus an `AlignOrientation` so it side-steps facing the table.

**Paddle grip (`PaddleFactory`).** The paddle is now held by a **Motor6D named `PaddleGrip` on the hand's `RightGripAttachment`** (the standard Roblox grip point), defined in the hand's own frame. It no longer depends on what pose the hand was in when the paddle was attached, and follows the hand through every animation. `Config.Paddle.Grip` (`Offset`, `RotationDegrees`, `HandlePoint`) is the configurable grip for future custom animations. `VisualScale` raised 1.6 -> 2.0 and the grip raised so the blade clears the 3.3-stud R15 fist (at 1.6 it was mostly hidden inside it). Visual only: hit detection uses the reach anchor in `Config.BotPlay` / `Config.AutoReturn`, never the paddle parts.

### Part 2: ball physics (`Shared/BallPhysics`, extended, same API)

Fixed 240 Hz step with an accumulator (frame-rate independent), semi-implicit Euler. Gravity 98.1 studs/s^2; quadratic **air drag** (0.014 /stud, derived from a real 40 mm 2.7 g ball); **Magnus** force `magnus * (spin x velocity)` (0.0056) so topspin dips, backspin floats, sidespin curves, any combination; spin decay. **Swept** contacts per tick (earliest wins), so nothing tunnels: table top (restitution 0.9 + Coulomb friction 0.25 with spin coupling for a hollow sphere, so topspin kicks forward and backspin checks up), table sides, net body (reflected, heavily damped), net cord (slowed and popped up), floor. `BallPhysics.paddleHit` is a physical paddle impulse for Phase 3. `BallPhysics.predict` simulates a copy for AI and solvers. `Shared/TableWorld` builds the one collision world from Config, so server, client and bot use identical geometry. `Shared/ShotSolver` finds launch velocities by **simulating the real flight** (drag + spin included) and correcting: every shot is a coherent trajectory that lands on its target and clears the net (`Rally.NetClearance`); nothing is forced mid-air.

**Authority.** `Server/RallyService` owns the only ball state (position, velocity, spin) and rally state, simulates it in Heartbeat, and moves the invisible gameplay `Ball`. Clients (`Client/BallView`) draw the cosmetic `BallVisual` by running the same deterministic simulation from server snapshots (sent on every serve, hit and contact, and every 0.5 s), so the ball is smooth at any frame rate and its look is never touched. The visual also spins with the simulated spin (useful for patterned skins).

### Part 3: serving
`ReadyToServe` holds the ball behind the server's end line on their paddle side, 4 studs above the table. **Player: press Space** (a request; the server checks seat, state, turn, distance <= `Serve.PlayerReach` from the ball, 1 s ready delay, rate limit; when it is not your serve Space still jumps). **Bot:** serves `Serve.BotDelay` s after the ball is ready. Toss straight up, struck on the way down; `ShotSolver.solveServe` picks a speed so the ball bounces on the server's half then the receiver's (retries other targets if needed). Lets (net touch, otherwise good) replay the serve.

### Part 4: bot rallies (`Server/BotController` + `Server/Striker`)
After your hit the bot waits `ReactionTime`, predicts the ball with the real physics, picks the first reachable contact point after the bounce on its half and walks there (`Humanoid:MoveTo`, never teleported). The hit is checked every physics tick with the same reach rules: within `Reach` of its paddle anchor and the ball falling or past its end line. Return: random target depth/width + aim error, speed 62 +/- 6 studs/s with topspin, solved physically. Balls it cannot reach in time are missed (fast, wide shots to its backhand: computed below). After hitting it recovers toward the centre.

### Part 5: TEMPORARY player auto-return (`Config.AutoReturn`, same `Striker` code)
Reach 11 studs from an anchor at your right-front; returns any legal ball in reach with the same solved shots. You do not swing. Turn it off with `AutoReturn.Enabled = false`. Phase 3 replaces it.

### Part 6: rules and scoring (`Server/RallyReferee`, pure)
Serve must bounce server's half then receiver's; after each hit the ball must bounce once on the opponent's half and be returned before a second bounce. Points for: serve faults, bouncing on your own side, out (floor or table side without bouncing on the opponent's half), into the net, not returned (second bounce or dead after a good bounce), double hit, volley, 10 s timeout. Hits only count when `canHit` (alternating sides, after exactly one bounce) plus a 0.25 s cooldown, so double contacts cannot register. Outcomes drive the existing `MatchState` (score, serve every 2 points, deuce, match over); a let uses a new `Serving -> ReadyToServe` transition. The HUD shows the last event and point reason (`LastEvent` attribute).

## Stabilization pass (2026-11-14), paused on Script Sync
- **Script Sync is stalled.** Studio still records all three folders as "Syncing" (in `~/Library/Preferences/com.roblox.RobloxStudio.plist`, keys `File_Sync_Persistence_Record_V1:103864112438456:*`). But probe edits moved in neither direction: disk edits did not reach Studio, and Studio edits did not reach disk. The drive (APFS, USB) did not remount, and the Studio log shows no sync errors. The Studio process has run since 2026-11-13 15:10 with three place reopens. Reopening the place does not restart the sync; a full quit (Cmd+Q) and relaunch is the next step. Disk and Studio were left identical. No code changes were made, so a reconnect is conflict-free.
- **Real Space key serving verified.** The key was sent to the client by Studio's input tool: ReadyToServe, then Serving, then Rally. Rallies of 14 and 32 hits followed. Both ended "not returned": the bot's placement went outside the standing player's auto-return reach.
- **Reach check.** The bot has 8 studs (0.8 m) horizontally from an anchor 0.5 m to its right, with contact between 0.4 m and 2.0 m above the floor. It walks at 2 m/s after a 0.25 s reaction. This is plausible, not superhuman. Auto-return's 11 studs is generous on purpose and temporary.
- **Not started (need working sync to test):** matching the ball visual to the 0.5-stud collision size, the bot's standing/walking height jump, and the paddle grip.

## Phase 3: player shot controls (2026-11-14, awaiting approval)
Sequence: PRE-AIM, then LOCK TARGET (press and hold the left button), then DRAG FOR SPIN, then RELEASE TO SWING, then contact (judged by the server). The ball keeps flying normally throughout. AutoReturn is now off (`AutoReturn.Enabled = false`). The bot, serving, physics and scoring are unchanged.

**How it works**
- `Shared/ShotInput` (new, pure, used by client and server):
  - Aim: the mouse ray meets the table-top plane and is clamped to the bot's half (edge and net margins).
  - Spin from drag: up = topspin, down = backspin, left/right = sidespin curving that way. Strength follows `(distance × SpinSensitivity / SpinDragPixels) ^ SpinCurveExponent × MaxSpin`, capped at MaxSpin.
  - Contact window: simulated with the real BallPhysics. It opens when the ball has bounced on the player's half and is within `PaddleReach` of the paddle point (same rule as the bot). Ideal = closest approach.
  - Release grading: within ±ContactWindowDuration/2 of ideal = clean; up to Early/LateReleaseTolerance beyond that = weak; otherwise, or ball out of reach = miss.
- `Client/ShotController` (new): state machine IDLE, AIMING, SPIN_CHARGING, SWING_RELEASED, CONTACT_RESOLVED, RECOVERY.
  - Shows a yellow aim marker that turns orange when locked, a blue predicted-landing dot, and a diagnostics panel (bottom left).
  - The client predicts the window from the latest server snapshot, in server time, so it matches the server's judgement (checked within 1 ms).
  - Holding past the window is a miss, or an automatic release if `AutoReleaseAtWindowEnd`.
  - Resets on point reset, an interrupted rally or respawn. Only one swing per incoming ball.
- `Server/RallyService` checks each `SwingRequest`:
  - seat, an incoming ball, one swing per ball, a 0.3 s rate limit, finite numbers;
  - the release time is clamped to at most `MaxLatencyCompensation` (0.2 s) in the past;
  - the window is recomputed from the ball state right after the bot's hit and the player's current paddle point;
  - target and spin are recomputed and clamped.

  On contact it rewinds to the ball's recorded state at the release moment, solves the shot with ShotSolver (same physics) and re-simulates up to now. The ball is never steered afterwards. Infeasible shots fall back to no-spin, then a plain guess, and may fail.
- `ShotSolver` has a new optional own-end-line clearance (`edgeZ` / `edgeTopY`), used for player shots struck below table height. Without it, clean low contacts hit our own table edge.
- `BallView` now exposes the latest snapshot. Snapshots carry `i` (ball incoming to the player), `b` (bounces on the player's half) and `h` (hit count).
- Dev-only `PlayerGui.NotPongShotDebug` BindableFunction (exists only while `ShowDiagnostics` is on): used by Studio test scripts.

**Verified in Studio** (scripted through the debug bridge; release timing taken from the controller's own window):
- Unit tests 28/30. The 2 failures were test bugs: a 32-bit float equality check, and an unfair bounce comparison.
- Edge fix: 23/30 low contacts land legally, against 8/30 before.
- On-time releases, all clean. Every one of these pressed early and held (scenario 8).

  | Shot | Spin (rad/s) | Measured on the server ball |
  |---|---|---|
  | Left drag | +86 sidespin | curve +0.75 to +1.03 |
  | Right drag | −86 sidespin | curve −0.58 to −1.06 |
  | Up drag | topspin | apex 6.22 vs 5.35 flat |
  | Down drag | backspin | apex 5.22 |
  | Diagonal | 63 / 63 | both effects |

  Landings were within about 0.3 studs of the target.
- Too early: server miss (−347 / −413 ms). Last-moment late release: weak. Hold past window: client miss, then the ball goes unreturned.
- Rapid clicks: 1 swing sent. Spammed remotes: rejected. A NaN target: rejected.
- Reset while charging: back to IDLE. Respawn while charging: reset, then the next shot was clean.
- No console errors.

**Not verified:** real mouse aiming and dragging (the Studio viewport was 1×1 because the window wasn't drawn), real latency, sustained rallies by a human, other avatars.

**Known issues**
- Bounce kick: at these spin and friction values, bounces stay in sliding friction. Spin mainly changes the arc and curve, not the bounce speed.
- Some very low contacts close behind the end line still can't clear our own edge.
- The weak-late band is often cut short because the ball leaves reach soon after the ideal moment.
- Script Sync is still stalled (Studio never fully quit). All files were pushed by MCP and verified byte-identical.

## Phase 4: visual feedback, spin tuning and refinements (2026-11-14, awaiting review)

> **Superseded parts:** the target marker, target locking and the predicted-landing marker described below were REMOVED by the core rework (next section), as was the diagnostics panel. Everything else in Phase 4 is unchanged.

**Migration:** the project now lives at `/Users/ianking/Documents/RobloxProjects/roblox-not-pong`. No old SSD paths remain in the project; Studio's Script Sync was reconnected to the three new folders (`src/server/Server`, `src/client/Client`, `src/shared/Shared`) and verified in both directions (also re-checked at the end of Phase 4; new files created on disk appear in Studio). Studio's plist still holds one stale, "Errored" AutoRecovery record that points at the SSD; it is harmless.

### 1. Curvature and bounce (`Shared/BallPhysics`, `Config.BallPhysics`)
- Magnus coefficient is now `magnus * magnusGain / (1 + |spin| / magnusSaturation)`: **gain 3.2, saturation 200 rad/s** (linear Phase 3 = 1 / 0). Medium spin bends clearly, maximum spin cannot run away. `ShotSolver`, bot, server and client all call the same `BallPhysics.tick`, so predictions match the real flight.
- **Table bounce spin kick** (`bounceSpinKick = 0.5`): the bounce adds `-kick * (spin x r)`, so topspin kicks forward, backspin checks, sidespin kicks sideways (capped at 2/3 so spin cannot reverse). Phase 3 spin barely changed the bounce because friction was capped.
- **Spin fallback** (`ShotSolver.solveWithSpinFallback`, used by the server swing and the client prediction): if a spin is infeasible (heavy backspin from a contact below table height cannot clear the net) it retries at 75/50/30/0% of the same spin before giving up. Decided once, before contact; nothing is steered afterwards. The swing reply says "spin eased to N%".
- **Measured** (solver shots from y=10, 62 studs/s, target 12 studs past the net; offline): sidespin 40/80/120 rad/s bends the flight 1.1 / 2.0 / 2.7 studs from the straight line (4 studs at 45 studs/s, longer flights), left and right identical (also at off-centre targets); post-bounce forward speed x0.92 none, x1.22 topspin 120, x0.61 backspin 120; backspin floats longer (0.80 s vs 0.57 s). Phase 3 bent about half as much.
- **Live** (real server ball, shots through the controller bridge, release at the ideal moment): none, left, right, top, back, diagonal and off-centre (+8) targets all landed within 0.6 studs of the aim point; the bot returned every shot. 100 of 100 serves legal under the new physics.

### 2-6. Shot feedback (client, cosmetic, non-authoritative; `Client/ShotFeedback`, `ImpactFx`, `BallTrail`, `FrameDriver`)
- **Target marker:** dark outline + coloured ring on the opponent's half, follows the mouse with smoothing (`Feedback.Target.FollowRate`), yellow while aiming, orange with a fill and a pulse when locked.
- **Predicted landing:** a second marker from `ShotSolver.solveWithSpinFallback` + `BallPhysics` using the window's ideal contact point, the locked target and current spin. Cyan = lands on the opponent's half, amber = your spin had to be eased, red "NET"/"OUT" = predicted miss. It is translucent and its ring widens while a release right now would only be weak. Recomputed only when target/spin/contact changes, throttled to 0.12 s and adaptively slower if a solve is slow (typical solve 0.4-1.2 ms; rare worst case about 28 ms).
- **Spin dial:** appears under the cursor while charging; the arrow points in the drag direction (up = top, down = back, left/right = side) with length/colour = actual capped spin; zero spin is a dim ring and a dot only.
- **Contact timing bar:** bottom centre; green clean window, amber weak bands (both clipped to the predicted in-reach window), a moving needle; after release a tick and the SERVER's verdict: CLEAN / WEAK . EARLY / WEAK . LATE / EARLY / LATE / MISS.
- **Ball trail:** one Trail on a follower part driven from the rendered ball every frame (so it shows the real curve); brightness, opacity and width follow speed, a subtle tint follows the dominant spin axis. Cleared and disabled when the ball is held or placed. Style is plain data (`Config.Feedback.Trail`, `BallTrail.setStyle`) so skins can replace it.
- **Swing + impact:** `StancePose.playSwing` plays a generated Action2 keyframe layer on the paddle arm (back, strike, follow-through, waist twist) the instant you release (strength from the client's estimate: clean 1.0 / weak 0.55 / miss 0.7); after a SERVER-confirmed hit `ImpactFx` shows a burst (clean = bright burst + ring, weak = dull puff). The paddle stays on its Motor6D grip.

### 7. Shift boost (`Client/MovementInput`, `Server/MovementService`)
Shift (either) sends a boolean `BoostRequest`; the server sets `WalkSpeed = Avatar.WalkSpeed * Movement.BoostMultiplier` while boosting and restores base speed on release. `BoostRequestInterval` only throttles repeated boost-on requests; it is not a duration cap, and boost-off requests always stop movement. The server now owns stamina: a full bar provides 3 seconds of boost, recovery starts 1 second after boost ends and takes 5 seconds from empty to full. Exhaustion stops boost and requires the player to release and press Shift again. A bottom-right bar shows stamina and prompts `RELEASE SHIFT` when exhausted. The client never sends speed or stamina values. The key is sunk at high priority so Roblox Shift Lock cannot toggle, and `StarterPlayer.EnableMouseLockOption` is turned off. The boost is a keyboard input and does not touch the mouse, so aiming, dragging and releasing are unaffected.

**Stamina update (2026-11-14): not yet verified in Studio.** Playtest by holding Shift until the bar empties, confirming boost ends, releasing Shift, confirming the 1-second delay and refill, then holding Shift through exhaustion and confirming it does not resume until Shift is released and pressed again.

### 8. Keeping players off the table (`Server/TableGuard`)
**Cause (measured):** the avatar is scaled 3.37x, so its hip height (9.18) is taller than the table (8.74): the Humanoid simply *steps up onto it*. Walking in was enough; jumping was not needed. A jump cap alone cannot fix that (a jump cap of 5 did not stop it, so it is not used).
**Fix:** one invisible solid block on the table's own footprint only, from the playing surface up 36 studs, in the existing `NP_Boundary` collision group (collides with characters only; never the ball or paddles). Table + block is far too tall to step or jump onto. No walls around the table: players walk right up to every edge. Built at Play from `TableWorld`, never saved, so resizing the table resizes it. The bot stands outside the footprint. Jump height is unchanged (`Movement.MaxJumpHeight = nil`; set a number for a cap).

### 9. Avatar fade (`Client/CharacterFade`)
One value (`Config.CharacterFade.Transparency = 0.6`) for the whole local character: head, body, accessory handles, and Decals/Textures (original decal values restored exactly). The paddle never fades. On the platform = faded, off the platform = fully visible, eased over 0.25 s, with 0.5/1.5-stud hysteresis. Inside/outside comes from the real `Platform` part (its CFrame and Size). Roblox's default camera script rewrites `LocalTransparencyModifier` every frame, so the value is enforced after the camera each frame, but only written when it differs. Other characters are never touched. The old fade code and `Camera.BodyTransparency/HeadTransparency` were removed from `CameraController` / `Config`.

### 10. Receiver outlines (`Client/ReceiverOutline`)
One `Highlight` (outline only) per competitor: white, faint; **green for whoever receives**. Receiver = non-server during ReadyToServe/Serving, ball direction during Rally, nobody otherwise; eased over 0.12 s.

### Testing done in Studio (honest split)
Automated and measured (Studio had no render loop, see below; per-frame code was stepped through `FrameDriver`'s dev bridge, real remotes and the real server were used):
- Physics: sweep above; solver vs actual bounce within 0.6 studs (live, 7 cases); serves 100/100.
- Boost: normal 18.00, boosted 22.50 in six directions (sideways both ways, back, forward, diagonal), 18.00 on release.
- Table guard: 20 of 20 runs (10 start points x walk / continuous jump, boosted: both ends, both sides, four corners, beside the net) never entered the table footprint; jump apex about 24 vs a 45.7-stud column.
- Fade: head = torso = arm = foot at 0.60 on the platform, 0.00 off it, 0.40 / 0.20 mid-transition, paddle 0, zero flicker over 60 edge hovers, synthetic hat + face decal + texture faded and restored exactly, bot untouched, correct after respawn.
- Feedback UI read back live: target marker position exact, landing marker 0.2 studs from the target, dial arrow angle and length match the drag (-135 deg for up-left), timing zones and needle, CLEAN / EARLY / LATE verdict labels, swing track playing, impact ring animating; outlines green on the right side; trail enabled in flight with lifetime 0.40.
- Client/server release timing agree within 3-11 ms. No console errors or warnings through all of the above.

**NOT verified (needs a real window, mouse and keyboard):** how anything LOOKS (marker contrast on your table colour, trail look, dial readability, impact burst, swing pose and paddle clipping, head at 0.6 fade, outline thickness); real mouse aiming/dragging; real Shift and Space key presses (the boost request and shot input were sent through their remotes/bridge, not by keys); feel and latency of real-network play; other avatars. The WEAK . EARLY / WEAK . LATE labels were not seen live: the weak bands are often shorter than a frame or two (see Known issues), only the code path and CLEAN / EARLY / LATE were exercised.

### How to tune (all in `Shared/Config.luau`)
| What | Where |
|---|---|
| Curvature strength / diminishing returns | `BallPhysics.magnusGain` (3.2), `magnusSaturation` (200; 0 = linear) |
| Bounce kick / check | `BallPhysics.bounceSpinKick` (0.5; 0 = Phase 3; max 0.67 used) |
| Max player spin | `ShotControl.MaxSpin` (120), `SpinCurveExponent`, `SpinDragPixels` |
| Boost | `Movement.BoostMultiplier`, `BoostEnabled`, `BoostRequestInterval`, `MaxStamina`, `BoostDuration`, `StaminaRegenerationDelay`, `StaminaRegenerationDuration` |
| Jump cap (off) | `Movement.MaxJumpHeight` |
| Table guard | `TableGuard.Height` (36), `Margin`, `Enabled` |
| Avatar fade | `CharacterFade.Transparency` (0.6), `TransitionTime`, `EnterMargin`, `ExitMargin` |
| Swing | `Swing.*` (duration, strengths, joint offsets) |
| Markers, dial, timing bar, trail, impact, outline | `Feedback.Target / Landing / SpinDial / Timing / Trail / Impact / Outline` |
| Diagnostics | `ShotControl.ShowDiagnostics` (dev bridges), `ShowDiagnosticsPanel` (text panel, off) |

### Known issues and limitations (Phase 4)
- **Spin can be eased at low contacts:** heavy backspin (and fast topspin) from a contact near or below table height cannot clear the net, so the solver uses a smaller fraction of the spin (shown by the amber landing marker); at very low contacts it can drop to 0.
- **Weak bands are short:** the ball is in reach for only a short stretch around the ideal moment (about 60-180 ms), so the early/late weak bands are often partly or fully clipped; most mistimed releases are EARLY/LATE misses.
- **Prediction cost:** a rare worst case (low backspin) costs about 28 ms per solve; it is throttled adaptively so it cannot stall frames, but the landing marker then updates slowly.
- **Swing is local:** the swing layer is played by the local client and replicates through the Animator; the pose angles are hand-set and may need adjusting by eye.
- **Fade vs this avatar's head:** Phase 2 notes found this avatar's head vanishes at any LocalTransparencyModifier above 0. Phase 4 follows your request (head = body = 0.6); if the head looks wrong, check it first.
- **`PointsToWin` is cached by `MatchState`:** changing it at runtime does nothing (affected only a test attempt).
- `TableGuard` is invisible and runtime-only; the table's Studio collision part is unchanged.

### Phase 4 files
| File | Change |
|---|---|
| `shared/Shared/BallPhysics.luau` | gain + saturated Magnus, bounce spin kick, optional `spinKick` in `contact` |
| `shared/Shared/ShotSolver.luau` | `solveWithSpinFallback` |
| `shared/Shared/StancePose.luau` | `buildSwing`, `playSwing` |
| `shared/Shared/Config.luau` | curvature values; `TableGuard`, `Movement`, `CharacterFade`, `Swing`, `Feedback`; `ShowDiagnosticsPanel`; fade values removed from `Camera` |
| `server/Server/MovementService.luau`, `TableGuard.luau` | **New** |
| `server/Server/AvatarService.luau`, `Main.legacy.luau`, `RallyService.luau` | MovementService hook; TableGuard + MovementService start; swing uses the spin fallback |
| `client/Client/ShotFeedback.luau`, `ImpactFx.luau`, `BallTrail.luau`, `CharacterFade.luau`, `ReceiverOutline.luau`, `MovementInput.luau`, `FrameDriver.luau` | **New** |
| `client/Client/ShotController.luau`, `BallView.luau`, `CameraController.luau`, `Main.local.luau` | event hook, own marker/diagnostic drawing removed; frame hook and FrameDriver; fade removed; wiring |

### Manual playtest checklist
1. Play; serve with Space. As the ball comes back: the yellow target ring follows the mouse over the bot's half, a cyan landing ring sits near it.
2. Hold left-click: the ring turns orange and pulses and stays put; a dial appears under the cursor. Drag up / down / left / right / diagonal: the arrow points that way and grows to a cap; the landing ring slides with the spin (watch for amber / red).
3. Watch the bottom bar: the needle moves toward the green zone; release inside it: CLEAN, swing, burst. Release far too early / hold too long: EARLY / LATE.
4. Hit with strong left and right sidespin: the trail bends visibly, the ball still lands on your target. Compare topspin (dips, kicks) and backspin (floats, dies).
5. The opponent's / your outline turns green when it is their / your turn to receive.
6. Hold Shift while walking in all directions: faster; release: normal. Try Shift while dragging a shot.
7. Walk and jump at every side and corner of the table: you cannot get on it, you can still walk right up to its edges.
8. Walk off the platform edge and back: the avatar fades in/out smoothly, the head with the body, the paddle always visible. Reset your character and check again.
9. Console: no errors. Edit any script on disk: it appears in Studio within seconds.

## Core rework: Charge -> Curve -> Release (2026-11-14, awaiting review)

Replaces Phase 3's PRE-AIM -> LOCK TARGET -> DRAG SPIN -> RELEASE. Reference: `docs/not-pong-curve-concept.png` (the brief named `docs/references/...`; the file is in `docs/`).

### Controls
- **Hold left-click = power.** Power = `(hold / ChargeTime) ^ ChargeExponent`, capped at 1 (`ShotControl.ChargeTime` 0.8 s). Mouse movement never changes it.
- **Drag while holding = spin.** Relative mouse deltas (`InputChanged.Delta`) are accumulated from the press: right / left = sidespin (ball curves that way), up = topspin, down = backspin, diagonal = both. Same dead zone / curve / `MaxSpin` 120 cap as before. The accumulated drag is clamped just past full spin (`DragOvershootPixels`), so dragging back reduces or reverses spin at once. Works while walking or boosting.
- **Release = swing.** Judged by the server exactly as before (reach, contact window, CLEAN / WEAK / EARLY / LATE / MISS, one swing per ball). Holding past the window = miss; full charge never guarantees a hit.
- **No target.** The cursor position plays no part. Mouse ray aiming, `ShotInput.aimFromRay/clampTarget`, `AimSensitivity`, `TargetEdgeMargin/NetMargin`, the target marker and its lock are gone; the swing request no longer carries a target.
- **When you can charge:** any time a rally is live and you have not swung at this ball, including while your own shot is still flying to the bot (pre-charge). A press during the short post-swing recovery or between points is remembered and starts charging when it becomes possible, if the button is still down (power counts from then).
- States: `IDLE -> CHARGING -> SWING_RELEASED -> CONTACT_RESOLVED -> RECOVERY -> IDLE`. Charge and spin reset on a hit/miss, point reset, respawn, window focus loss and input cancel. Releasing when no ball is coming sends nothing.

### The shot model (`Shared/ShotLaunch`, used by the server AND the arrow)
1. Power -> horizontal launch speed `MinShotSpeed..MaxShotSpeed` (44..80 studs/s) and a calibration depth `MinShotDepth..MaxShotDepth` (0.40..0.82 of the opponent's half).
2. Default direction: toward a point at that depth, laterally `FollowLateral` (0.45) of the contact point's offset from the centre line (so a shot from the right goes right-ish), kept `LateralMargin` inside the lines. Built from `TableWorld` (no hard-coded coordinates).
3. Launch elevation and yaw are solved (ShotSolver, real physics) so that a ball with only PART of the spin (`TopspinCompensation` 0.55, `BackspinCompensation` 0.85, `SidespinCompensation` 0.35) would land at that point and clear the net.
4. The ball is launched with ALL of its spin and flies by the real physics. So spin really moves the landing (topspin lands shorter, backspin longer, sidespin curves off to the side) and shots can miss (e.g. full power + full backspin floats long). Nothing steers the ball after contact.
Weak contacts: speed x0.8, spin x0.4, +/-4 studs random error in the calibration point (server-side random, so the arrow cannot show it; it turns translucent instead).

### Server authority (`Server/RallyService`)
- New `ChargeStart` RemoteEvent: one message per press `{t}`. The server stores the press time clamped to `[arrival - MaxLatencyCompensation, arrival]`.
- `SwingRequest {seq, dx, dy, t, pressT}`: release time clamped the same way; **hold = release - stored press**, so the server measures the charge itself (no press on record = zero power). `pressT` is informational only. Press records are cleared after each swing and at every point reset. Spin is re-derived and clamped from the drag. Malformed, duplicate, too-frequent or no-ball requests are rejected as before.
- Most a lying client can gain: 0.2 s of extra charge (the latency allowance), still capped at full power.

### The 3D trajectory arrow (`Client/TrajectoryArrow`, driven by `Client/ShotFeedback`)
- **Prediction:** while CHARGING at a reachable incoming ball, `ShotLaunch.compute(contact, power, spin)` + `ShotLaunch.predictPath` simulate the shot through the real `TableWorld` (gravity, drag, Magnus with gain/saturation, net, table body, floor) from the predicted paddle contact (the contact window's ideal point) to the first contact. Recomputed when power (0.5% steps), spin or the contact point change, at most every `Arrow.RecomputeInterval` (0.04 s), adaptively slower if slow. Measured cost 0.3-1.3 ms.
- **Rendering:** a pooled chain of `Arrow.Segments` (28) world-space Beams (bright additive core + wider purple halo) between attachments moved along the path, resampled to equal arc-length steps; a tapered Beam arrowhead whose tip is the predicted end point; a ring on the table at the landing spot. Nothing is created per frame. The drawn path eases toward each new prediction (`Smoothing`), fades in near the paddle (`StartFade`).
- **Failure:** first contact on the net -> red arrow + "NET"; floor / table side -> red + "OUT"; own half -> red + "OWN SIDE". The arrow ends at that first contact.
- **Weak timing:** while a release right now would only be WEAK, the arrow is more transparent (`WeakTransparency`).
- Hidden on release (the real ball and its trail take over), on cancel and on reset. Not shown while pre-charging before the return is struck (no contact point yet); it appears as soon as the incoming ball is reachable.
- **Power / Curve meter** (`Client/PowerMeter`, bottom right): segmented Power bar (hold time only, turns pink at full) and Curve bar (spin strength); stays `ShowAfterRelease` 0.7 s after the swing. The Phase 4 spin dial, timing bar, swing animation and impact burst are kept.

### Tests in Studio (automated: test scripts drove the controller's debug bridge; NOT real mouse/keyboard)
- **Launch model sweep (server, 63 shots: 3 contacts x 3 powers x 7 spins):** 62 land on the opponent's half; the 1 miss is full power + full backspin from a normal contact (floats past the end line). Sidespin moves the landing about +/-5.6 to +/-7.3 studs and bends the flight 2.2-3.1 studs; left/right exactly mirrored. Topspin lands 0.14-0.25 of the half shorter; backspin longer. More power = deeper and flatter (apex 8.0 -> 4.8 studs above the table).
- **Live shots (real server ball, character walking to the ball, release at the ideal moment):** none / right / left / top / back / diagonal / tap (0.07 s) / pre-charged: all CLEAN; the arrow's predicted landing vs the real landing: **0.13-0.54 studs** (the remainder comes from the real release being a frame off the ideal contact). Client power = server-measured power in every shot (e.g. 0.9837 vs 0.98). Spin reached the server unchanged.
- **Power independence:** holds of 0.383 s with no drag and 0.382 s with full right drag both gave power 0.48.
- **Drag:** +400 px clamps to 256 px / 120 rad/s; back 60 px -> 97.7; back 200 more -> 0 (dead zone); left 300 more -> reversed +120; diagonal mixes. Done through the same accumulation code real mouse deltas use.
- **Arrow:** visible in 39/43 frames of a charge (the first frames before the first prediction); tip moved from 5.8 to 10.7 studs past the net as power rose 0.13 -> 0.78 while the bend stayed ~2.2 studs; arc above the table (start 11.8, apex 3.9-6.4 above the surface). Invalid shot: arrow predicted OUT ending on the floor; the real ball hit the floor 0.17 studs from the arrow tip and the point was scored "out".
- **Timing:** release 146 ms early -> miss (ball not yet in reach; the early weak band is often clipped, as in Phase 4); 204 ms late -> WEAK; holding past the window -> MISS at power 1.00.
- **Reaching charge:** bot hit -> ideal contact took ~0.71 s in a normal rally (so `ChargeTime` was lowered from 0.9 to 0.8 s: ~89% if you press on the bot's hit). A press during recovery started charging 0.27 s later and reached full power; the server measured 1.05 s.
- **Resets:** point ended while charging -> IDLE, power and drag 0. Respawn while charging -> IDLE, spin 0, a later stray release did nothing; the avatar was re-seated.
- **Regression:** bot returned shots and rallies continued; serving and scoring worked through a full match (bot won 11-x because test rallies end after one shot); Shift boost 18 -> 22.5 -> 18; console clean (no errors or warnings).
- **Looked at it:** one screen capture with the Studio window in front showed the arrow above the table, rising, bending right, arrowhead and landing ring readable from the default camera. The halo looked blue on the blue table and the head small; colours/head/ring were then retuned, and **the retuned look has not been seen** (Studio went to the background: no rendering).

### Not verified
- Real mouse drag and left-click feel, real latency, readability during fast rallies, the retuned arrow colours / arrowhead / ring, the power meter's look.

### How to tune (`Shared/Config.luau`)
| What | Setting |
|---|---|
| Charge speed / curve | `ShotControl.ChargeTime` (0.8), `ChargeExponent` (1) |
| Shot speed by power | `MinShotSpeed` 44, `MaxShotSpeed` 80 |
| Depth by power | `MinShotDepth` 0.40, `MaxShotDepth` 0.82 |
| Default direction | `FollowLateral` 0.45, `LateralMargin` 2.5 |
| How much spin moves the landing (risk) | `TopspinCompensation` 0.55, `BackspinCompensation` 0.85, `SidespinCompensation` 0.35 (lower = more movement, more misses) |
| Spin feel | `SpinDragPixels` 220, `SpinSensitivity`, `SpinDeadzonePixels` 6, `SpinCurveExponent` 1.4, `MaxSpin` 120, `DragOvershootPixels` 30 |
| Curve strength (physics, affects everyone) | `BallPhysics.magnusGain` 3.2, `magnusSaturation` 200 |
| Arrow look | `Feedback.Arrow` (colours, widths, head, segments, fade, smoothing, recompute interval) |
| Meter | `Feedback.PowerMeter` |

### Known issues / limitations
- The arrow appears only once the incoming ball is reachable from where you stand (~0.6 s before contact while moving to it); the meter shows charge before that.
- The server judges reach from where you stand when the release arrives (Phase 3 rule, unchanged). If you keep moving after the ball enters reach, a swing the client showed as reachable can be rejected "ball never in reach" (seen once in testing while the test walked the character late).
- Weak contacts get a random error the arrow cannot predict (it turns translucent instead).
- A cheating client can gain up to 0.2 s of charge (latency allowance), capped at full power.
- `ShotSolver.solveWithSpinFallback` (Phase 4) is now unused; left in place.

### Files
| File | Change |
|---|---|
| `src/shared/Shared/ShotLaunch.luau` | **new**: power curve, default direction, launch calibration, path prediction (server + client) |
| `src/client/Client/TrajectoryArrow.luau` | **new**: pooled 3D Beam arrow, arrowhead, landing ring, NET/OUT label |
| `src/client/Client/PowerMeter.luau` | **new**: Power / Curve bars |
| `src/client/Client/ShotController.luau` | rewritten: charge/curve/release states, relative drag, ChargeStart, pending press; target, aim, diag panel removed; debug bridge moved to `Player` |
| `src/client/Client/ShotFeedback.luau` | target + landing markers removed; drives arrow and meter; dial/timing/swing/impact kept; `NotPongArrowDebug` bridge |
| `src/shared/Shared/ShotInput.luau` | `aimFromRay`/`clampTarget` removed, `clampDrag` added |
| `src/server/Server/RallyService.luau` | `ChargeStart` remote, server-measured charge, ShotLaunch launches, no target |
| `src/shared/Shared/Config.luau` | `ShotControl` charge/launch settings (aim/target/speed settings removed), `Feedback.Arrow`, `Feedback.PowerMeter` (`Target`/`Landing` removed), `ShowDiagnosticsPanel` removed |

### Script Sync
Working from `/Users/ianking/Documents/RobloxProjects/roblox-not-pong`: the three new modules appeared in Studio at `ReplicatedStorage.Shared.ShotLaunch`, `StarterPlayerScripts.Client.TrajectoryArrow` / `PowerMeter`, and every edit was picked up on each Play restart. Nothing was saved or published.

### Manual playtest checklist
1. Serve (Space). As the bot's return comes, hold left-click: the Power bar fills over 0.8 s; a purple arrow appears from your paddle over the net.
2. Keep holding without moving the mouse: the arrow reaches deeper as power grows. Release at the green timing zone: CLEAN, and the ball should follow the arrow and land on its ring.
3. While holding, drag right / left: the arrow bends that way. Drag back: it straightens. Up: lands shorter (topspin); down: floats longer (backspin). Diagonal: both.
4. Full charge + full backspin: the arrow should turn red "OUT". Release anyway: the ball goes long.
5. Short tap at the last moment: weak-power shot that still lands. Hold too long: MISS.
6. Press during your own shot's flight and keep holding: charge builds; the arrow appears when the return is reachable.
7. Walk / Shift while charging and dragging; check the arrow stays readable and the camera is unchanged.
8. Let a point end while holding, and reset your character while holding: everything clears.

## Input fix: real mouse drag did not register (2026-11-14, awaiting your manual check)

- **Symptom:** holding left-click charged power, but moving the mouse did not change spin or the Curve meter.
- **Root cause (measured in Studio):** `ShotController` accumulated `input.Delta` from `MouseMovement`. With the normal (unlocked) mouse, the movement events DO arrive (cursor position changes) but `Delta` is (0, 0) on every one, so the drag stayed at zero. The earlier automated tests fed the drag straight into the controller's debug bridge, so they never exercised this path. Not the cause: the camera is Scriptable and consumes nothing; movement events arrive with `gameProcessed = false`; `dragToSpin`, the meter and the arrow were all correct once they received a drag.
- **Fix:** `ShotInput.movementOf(delta, pos, lastPos)`: use `Delta` when it is non-zero (a locked / relative mouse), else the change in cursor position since the previous movement event. `ShotController` tracks the previous position on every movement event (so the first event after a press is already valid) and feeds the result into the same clamped accumulation as before. No mouse lock is used (a lock made the injected test moves stop registering, and it is not needed); if your real mouse hits the viewport edge during a drag, a lock-while-charging option would be the next step.
- **Temporary diagnostics:** `Config.ShotControl.ShowInputDebug` (true) shows a small overlay (top left, ~8 updates/s): button held, state, mouse events (total / this charge), last move and its source (`delta` / `position`), accumulated drag, spin, meter power / curve, and the spin the arrow last predicted with. Set it to false once verified.
- **Verified with Studio's mouse tool (it injects real engine input events, though absolute positions only):** hold + drag right gave sidespin and a rising Curve meter while Power depended only on hold time; up gave topspin, dragging back reduced then reversed it to backspin; diagonal combined both; the arrow's spin and landing tip followed (spin -15 -> -58, tip X 0.8 -> 4.3). `movementOf` was unit tested (delta, position fallback, first event, no movement, NaN).
- **Not verified:** a physical mouse (the tool cannot produce relative `Delta`), trackpads, and edge-of-viewport behaviour.
- **Files:** `src/shared/Shared/ShotInput.luau`, `src/client/Client/ShotController.luau`, `src/client/Client/ShotFeedback.luau` (overlay), `src/shared/Shared/Config.luau` (flag).

## Refinement: stronger curves, low camera, charge slow motion (2026-11-14, awaiting review)

Builds on the Charge -> Curve -> Release rework (controls unchanged: hold = power from hold time only, drag = spin, release = strike; no target, the cursor never chooses a landing).

### 1. Why curves looked weak (measured before changing anything)
Bend = how far the flight bows away from the straight line between contact and landing (the "sag"). Baseline, contact (4, 14, 80), full sidespin: **2.8-3.1 studs** over a ~32-stud flight; a half drag only **1.4-1.5 studs**. Causes, in order:
- **Effective Magnus too small for an arcade game.** At full spin the coefficient is `magnus * magnusGain / (1 + |spin| / magnusSaturation)` = 0.0179 / 1.6: saturation alone removed 38% of the bend at max spin. Lateral acceleration ~1.1 g for a ~0.5 s flight.
- **Drag curve.** `SpinCurveExponent` 1.4: half the drag gave 38% of the spin, so "medium" curves were faint.
- **Speed vs bend.** bend ~ spin x distance^2 / speed: faster shots curve LESS at the same coefficient, so simply raising speed would have made curves weaker.
- **Not the cause:** the partial spin compensation in ShotLaunch. It only rotates the launch direction; it never reduces the bend. It decides where the curve ENDS (with low compensation a strong curve flies off the table, which is what kept the curve small). The arrow rendering was faithful (tip within ~0.5 studs of the real landing).
- **Why not just raise `magnusGain`:** backspin lift at max spin was already ~1 g (that is why full backspin floats long); a global gain would make top/backspin unplayable.

### 2. What changed (physics, shared by server, arrow and bot)
- `BallPhysics`: **`magnusSideGain`** multiplies only the spin component about the vertical axis, whose Magnus push is purely sideways, so top/backspin dip and lift are unchanged; bot shots and serves carry no sidespin and are unaffected. **`magnusSideSpeedRef`** scales that push with horizontal speed / ref, so the ball turns by the same angle per stud at any power (without it, slow shots hooked 120+ deg and the solver failed to calibrate them).
- `ShotSolver.solve`: the yaw now uses a secant update (and 24 iterations instead of 16); a strongly curving ball does not respond 1:1 to yaw. Converged results are unchanged for straight shots.
- `ShotLaunch`: topspin launches up to 12% faster (`TopspinSpeedBonus`), backspin up to 15% slower (`BackspinSpeedPenalty`).
- Presets tested (full sidespin, contact (4,14,80)):

| preset | `magnusSideGain` | bend at power 0 / 0.5 / 1 | total turn (power 1) | landing shift at full sidespin |
|---|---|---|---|---|
| before | (1) | 3.1 / 2.9 / 2.8 | ~45 deg | 5.6-6.4 |
| moderate | 2.0 | 3.1 / 4.0 / 5.0 | 68 deg | 3.4-5.6 |
| strong | 2.6 | 4.1 / 5.3 / 6.8 | 91 deg | 3.5-5.7 |
| **very strong (selected)** | **3.2** | **5.1 / 6.7 / 8.6** | **117 deg** | **4.8-8.1** |

  Selected because it still calibrates every tested shot (898/900 solved), the arrow stays exact, and the bot still returns most shots (below). A medium (half) drag now bends 2.8-4.6 studs (was 1.4-1.5).
- Speeds: 48-100 studs/s horizontal (was 44-80); topspin up to 112. Flight time to the first bounce 0.68 / 0.50 / 0.42 s at power 0 / 0.5 / 1 (was 0.75 / 0.60 / 0.53); full topspin 0.32 s.
- Topspin: lands 2.5-4.2 studs shorter than a flat shot and KICKS forward at the bounce (horizontal speed x1.09-1.30). Backspin: floats a little longer, CHECKS at the bounce (x0.58-0.72).
- Landing rate over a 900-shot grid of clean contacts (5 x-positions, 3 heights, 2 depths, 3 powers, 10 spin inputs): **884/900 (98%)**. The 16 misses are real player errors: full power + full backspin floats long (10), and full sidespin toward the near side line from a wide contact (6). Timing, reach and weak contacts add further misses in play. Nothing steers the ball after contact.

### 3. Camera (`Client/CameraController`, `Config.Camera`)
Low over-the-shoulder view tuned from Studio screenshots against the concept image: **FieldOfView 58, Height 26 above the floor, DistanceBehind 19, ShoulderOffset +8 (to the player's right, the paddle side), aim at the table surface 3 studs past the centre**. The translucent avatar sits lower-left, the paddle in front of the near table, the table runs to the bot; the curve arrow rises over the table. Smoothing, velocity lead, back/sideways follow and the side flip are unchanged (follow values: CameraXFollow 0.7, LateralFollow 0.4, DistancePerBackStud 0.2, HeightPerBackStud 0.2, AimPerBackStud 0.6). The avatar fade (whole body incl. head on the platform) is unchanged.

### 4. Charge slow motion (`Config.ChargeFreeze`; Server/RallyService, MovementService, Client/ShotController, BallView, ShotFeedback)
- **When:** pressing left-click while the incoming ball is within `LeadTime` of its ideal contact and not past the contact window can activate slow motion in solo matches, once per incoming ball. An earlier press charges at normal speed.
- **During charge:** server ball simulation, player walk speed, bot walk speed and bot/player animations run at `TimeScale` (currently 0.35). The player and ball continue moving; the player is not anchored. The client's ball prediction uses the same scale.
- **Release:** charge power remains based on real elapsed time; spin still comes from drag. The server maps the clamped release time onto the slowed simulation timeline, checks the contact window from the player's current position, and launches from the server's historical ball state at release. A miss does not become a free hit.
- **Timers:** `MaxDuration` is a real-time cap; the server allows `MaxLatencyCompensation` for an already-sent release to arrive. Rally timeout and hit cooldowns compensate for the time dilation. If the cap expires, normal speed resumes and the swing is lost.
- **Cancel:** focus loss, input cancellation, respawn or leaving returns movement and animation speeds to normal. Slow motion remains used for that incoming ball.
- **Client:** predicts slow motion on the press frame; the server snapshot confirms or denies it. A draining SLOW MO timer (red "RELEASE!" in the last 30%), subtle desaturating tint, and contact arrow provide feedback.
- **PvP:** `ChargeFreeze.Modes = { Solo = true, PvP = false }`; slow motion is still solo-only to avoid unilaterally slowing another player's match.

### Tests in Studio
- Curvature, speed, landing: the sweep above (pure, Edit context, the live modules).
- The freeze implementation was replaced with slow motion after those earlier tests. The new slow-motion timing, movement scaling, release judging, timeout, and cancel/respawn paths have **not yet been verified in Studio**.
- Camera: screenshots at the serve spot, far left + back, far right + near.

### Not verified
- Slow-motion feel and real network latency (Studio has ~0 ms: client prediction/correction has not been exercised with lag).
- PvP: no PvP mode exists to run; the disable rule was checked by reading the code and the `MatchMode = Solo` attribute only.
- Walking off the platform with the new camera (only on-platform positions were screenshotted).

### Known issues
- **Reach while moving:** the server decides slow-motion eligibility from the replicated position; it can disagree with the client just after movement, in which case the press continues at normal speed.
- At the far right near the table the camera cuts off the table's near-left corner (net, bot and ball stay visible).
- "Very strong" curves leave the table's footprint mid-air (they bow up to ~8.6 studs and hook back). If that reads as too wild, `magnusSideGain` 2.6 (strong) keeps the same landing control with ~20% less bow.
- The bot misses some full-power, strong-curve shots (3/13 in the test); intended as the reward for a hard curve, tunable via `BotPlay.ReactionTime` / `Bot.WalkSpeed`.
- Unused `ShotSolver.solveWithSpinFallback` still present (from Phase 4).

### Files
- Modified: `src/shared/Shared/BallPhysics.luau` (side gain + speed reference), `ShotSolver.luau` (yaw secant), `ShotLaunch.luau` (top/backspin speed), `Config.luau` (ShotControl, BallPhysics, Camera, ChargeFreeze slow-motion settings), `src/server/Server/RallyService.luau` (authoritative slow motion and release judging), `MovementService.luau` (player movement scaling), `src/client/Client/BallView.luau` (scaled prediction), `ShotController.luau` (slow-motion prediction / confirmation / release / cancel), `ShotFeedback.luau` (slow-motion timer and tint), `CameraController.luau` (shoulder offset); `docs/current-state.md`.
- No new files.

### Script Sync
Working from the Mac folder: every edit appeared in Studio (server RallyService with `trySlowMotion`, `ChargeFreeze` attribute = true, `MatchMode` = Solo). Nothing saved, published or committed.

### Manual playtest checklist
1. Serve and rally; on the return, press and hold near contact: the ball, bot and player should move at 0.35× speed; the SLOW MO timer drains and Power fills in real time.
2. Move during slow motion to confirm walk speed is reduced; drag to curve and release to swing at the server-judged slowed-time contact.
3. Hold past the timer: the swing is lost and normal speed resumes.
4. Press very early (as the bot hits): no slow motion; time the release as usual.
5. Press late (as the ball reaches you): expect a weak contact or miss based on the slowed-time window.
6. Alt-tab or respawn during slow motion: normal movement and animation speeds return; no state remains stuck.
7. Walk to the far sides and back: the camera keeps the table, net, bot and ball in view.
8. Try full power + full sidespin toward the near side line from a wide position (should sometimes go out), and full power + full backspin (floats long).

## Configuration values (all in `src/shared/Shared/Config.luau`)

| Group | Values |
|---|---|
| `BallPhysics` | radius 0.2, gravity 98.1, table restitution 0.9 / friction 0.25, drag 0.014, magnus 0.0056 (Phase 4: x gain 3.2, saturation 200, bounce spin kick 0.5), spinDecay 0.2, fixedStep 1/240, net restitution 0.15 / friction 0.4 / cord keep 0.7, floor 0.55 / 0.5, side 0.4, maxSpeed 400, maxSpin 1000 |
| `Serve` | hold 1.5 behind the end line, 4 above the table, side offset 4.7; toss 20; first bounce depth 0.65 of the server's half; second bounce 9 studs past the net (+/-2); speed guess 70 (bisected 25..110); topspin 20; spread +/-3; bot delay 1.5 s; player reach 16; request cooldown 0.3 s |
| `Rally` | net clearance 0.8, hit cooldown 0.25 s, contact height 4..20 above the floor, snapshot interval 0.5 s |
| `BotPlay` | reach 8, anchor 4 right / 3 forward, reaction 0.25 s, return speed 62 +/- 6, topspin 80, target depth 0.45..0.75, spread +/-5, aim error +/-0.6, step-back 4..14 (home 10); walk speed 20 (`Bot.WalkSpeed`) |
| `AutoReturn` | enabled, reach 11, same shot values as the bot |
| `Stance` | FootSink 0.05, MoveSpeedThreshold 2, LegBlendRate 10, WalkGroundingWindow 0.7, WalkGroundingDecay 1.5 |
| `Paddle.Grip` | Offset (0, 0.25, 0.5), RotationDegrees (-10, 0, -8), HandlePoint -0.25; VisualScale 2.0 |
| `Timing` | ServeReadyDelay 1, PointResetDelay 1.5, RallyTimeout 10 |

## Files (under `src/`)

| File | Change |
|---|---|
| `shared/Shared/BallPhysics.luau` | **Extended**: spin, drag, Magnus, swept table/side/net/floor contacts, events, `contact`, `paddleHit`, `predict` (old calls still work) |
| `shared/Shared/ShotSolver.luau`, `TableWorld.luau` | **New** |
| `shared/Shared/StancePose.luau` | **Rewritten**: two-track stance controller with measured grounding |
| `shared/Shared/Config.luau`, `GameStates.luau` | **Changed**: values above; `LastEvent` attribute; let transition |
| `server/Server/RallyService.luau`, `RallyReferee.luau`, `Striker.luau`, `BotController.luau` | **New** |
| `server/Server/PaddleFactory.luau` | **Changed**: Motor6D grip |
| `server/Server/Stance.luau`, `AvatarService.luau`, `BotService.luau`, `MatchState.luau`, `Main.legacy.luau` | **Changed**: stance controller; bot facing and walk speed; `replayServe`; starts RallyService |
| `client/Client/BallView.luau`, `ServeInput.luau` | **New** |
| `client/Client/StanceController.luau`, `DebugHud.luau`, `Main.local.luau` | **Changed** |

`ReplicatedStorage.NotPongRemotes` (`BallSnapshot`, `ServeRequest`) is created at Play and not saved.

## Bugs found and fixed this phase

- Feet bobbed into the floor (idle hip bob); walking glided (stance held the legs). See Part 1.
- `FootSink` sign was inverted (feet 0.05 above instead of into the floor).
- Holding the hips at the rest pose made a 3-stud stance/walk height difference; fixed by holding the measured idle pose, then found and fixed the keyframe scale multiplication (body hung 9 studs below the root).
- A fixed walking offset (first attempt) left this avatar's run cycle 1 stud above the floor and the bot's walk 1.2 studs into it; replaced by measured stride grounding.
- Bot walk speed was multiplied by the scale (set before scaling).
- Paddle buried in the fist; weld depended on the pose at attach time.
- First serve target (half depth, 2.5 above the table) produced no legal serve; retuned from a 50-serve sweep.
- `Main.legacy.luau` lost its `local function refreshReadiness()` line to a find-replace on my side; caught by a byte-count check and restored before it ran.

## Tested (Studio Play, measured)

- **Unit tests, 21/21 pass (server):** identical results at 30/60/144/240 fps and jittery frame times (0 difference); 390 studs/s straight down bounces off the table; 390 studs/s into the net is stopped and reflected; net-cord clip; table-side hit reflected; topspin lands shorter and kicks faster than backspin, sidespin curves 1.6 studs; ITTF drop test 3.05 -> 2.23 studs; `paddleHit`; ShotSolver 40/40 random returns on target (worst 0.04 studs) clearing the net; 10 referee rule scenarios (good serve, serve faults, let, net, double bounce, out, own side, double hit, volley, bounce-before-hit).
- **Serves:** 50 random serves per side after retuning: 100% legal at 6-9 m/s. Live: player serve via the server remote and bot serves both worked.
- **Rallies:** live automated rallies of 16, 42 and 41+ hits; points ended correctly ("not returned" when the ball went outside the standing player's auto-return reach), score and serve rotation updated (to the bot after 2 points), ball reset to the right server each point, `Serving -> Rally -> PointScored -> ReadyToServe` in the log, console clean (no errors or warnings from game scripts).
- **Bot reach:** at the bot's backhand corner, 90-120 studs/s shots are computed misses; 62 studs/s (the current return speed) is reachable, so rallies last.
- **Grounding:** idle feet of both characters at 0.95 (floor 1.0, 0.05 sink) with zero bob; player walking at full speed 18, lowest foot within about 0.3 studs of the floor per stride; bot moving at 20 studs/s, walking animation on, feet median 1.00 (worst frames about 0.5 into the floor while starting/stopping), always facing the table, paddle stayed in hand.
- **Ball:** exactly 1 gameplay ball and 1 visual; your `BallVisual` colour/material/size untouched.

## Not verified

- **Real keyboard input** (walking was driven with `MoveTo`; the Space key path was tested by firing the same remote the key fires, not by pressing Space).
- Other avatars, a second player, real server latency. Feel and readability by eye during a full rally (screenshots of moving play were unreliable: captures often drop character meshes when the Studio window is not in front).
- The bot actually missing in live play (computed only; it never missed in the live rallies because of the consistent-return tuning).

## Known issues and limitations

- **(Resolved in Phase 4: Script Sync was reconnected to the new local folders and verified.)** Script Sync stopped delivering during an earlier session (even after you reconnected). Every changed file was copied into Studio through the MCP tool and verified byte-for-byte against disk, so Studio and disk match now. Please check Script Sync is really connected before the next session (a test edit to any file should appear in Studio within seconds).
- No contact shadows until `Lighting.Technology` is ShadowMap/Future (see Part 1).
- Your `BallVisual` is 1.0 studs (2.5x the 0.4 gameplay ball) so at a bounce it visually sinks 0.3 studs into the table; set it back to 0.5 for exact contact.
- Bot start/stop transitions can sink its feet ~0.5 studs for a few frames; its body rises ~1.5 studs between stance and walking because its rest-pose stance is lower than its walk.
- No swing animation: hits happen when the ball reaches the reach anchor; the paddle does not move toward the ball. The auto-return makes the player return everything within 11 studs without input.
- Serves are a placeholder toss; serve speeds are chosen by the solver (6-9 m/s), not by the player.
- `Shared` still carries the harmless attribute `ManualStopgapCopy`. Archive files in `docs/archive/` are kept until you say to delete them.

## Tooling notes

- Script Sync (disk -> Studio), when connected: use in-place writes, never `sed -i`. Suffixes: `.luau` ModuleScript, `.legacy.luau` Script, `.local.luau` LocalScript.
- `Humanoid:Move` from a test script is overridden every frame by the default control script; use `MoveTo` for scripted walking.
- Keyframe translations are scaled by the character's scale.
- `screen_capture` times out or drops meshes when the Studio window is not visible.

## How to test the rally system yourself

1. Press **Play**. The HUD (top left) shows `ReadyToServe | Serve: Player` and "Your serve: press Space". The ball hangs behind your end line to your right.
2. **Press Space** (stand near your end; if you walked away the HUD says "Serve refused: walk back..."). The ball is tossed and served; the bot moves and returns it; your auto-return hits back anything within reach. Watch `Rally:` count up.
3. Walk sideways to see the legs step and stop to see the stance. Walk far from the ball's path to let it go past you and lose the point; the HUD shows the reason.
4. After two points the bot serves by itself.
5. Tuning: `Config.BotPlay` (reach, reaction, speed, spread, aim error), `Config.AutoReturn`, `Config.Serve`, `Config.BallPhysics`. To make the bot beatable, lower `BotPlay.Reach`/`Bot.WalkSpeed` or raise `AutoReturn.ReturnSpeed` and `TargetSpreadX`.
6. Optional: `Lighting.Technology` = ShadowMap/Future for contact shadows. Save the place (Cmd+S) if you want your Studio changes kept; I did not save or publish.

## Forehand / backhand + runtime checks (2026-11-15, Windows, awaiting your review)

Project now at `F:\roblox games\roblox-not-pong` (Windows). **Script Sync verified both ways today:** all 40 scripts in Studio were byte-identical to disk (CRLF-normalised checksums); a probe comment written on disk appeared in Studio within 0.5 s, and removing it in Studio rewrote the disk file. Nothing saved or published.

**Config drift:** the tables earlier in this file are partly out of date. Current values include `ChargeTime` 0.4, `MaxSpin` 90, `magnusSideGain` 2, `SidespinCompensation` 0.66, `BackspinCompensation` 0.88, `Movement.BoostDuration` 0.8, `StaminaRegenerationDuration` 3, `Avatar.WalkSpeed` 24, `ChargeFreeze.MaxDuration` 0.4. `Config.luau` is the truth.

### Runtime checks of the unverified slow-motion and stamina paths (Studio Play, scripted through remotes / the debug bridge)
- **Stamina:** boost 24 -> 54 walk speed; full bar empties in ~0.8 s, then speed returns to 24 and `exhausted` is set; a new boost request while exhausted is refused; releasing clears `exhausted`; refill to 100 takes ~3 s; a second boost works. **Discrepancy:** the 1 s regeneration delay counts from the moment stamina ran out, not from releasing Shift, so stamina also refills while Shift is still held after exhaustion (regen started 0.27 s after release in the test). Not changed.
- **Slow motion:** a press 0.10 s before ideal contact slowed the rally (player walk speed 8.4 = 24 x 0.35, ball mode `slow`) and a release at the strike gave CLEAN; normal speed came back. Holding past the cap gave "held too long (slow motion ran out)" and normal speed. **Conflict found:** with `LeadTime` 0.45, `TimeScale` 0.35 and `MaxDuration` 0.4, a press more than ~0.14 s (0.4 x 0.35) before ideal enters slow motion but contact is then further away in real time than the cap allows (press at 0.29 s -> 0.73-0.85 s of real time to contact vs 0.35-0.4 s left), so it always ends as an early miss or a run-out. Either `LeadTime` <= `MaxDuration * TimeScale` or `MaxDuration` >= `LeadTime / TimeScale` (~1.3 s) is needed. **Resolved in the next section: `LeadTime` 0.13.**
- Not verified: a normal-speed press before `LeadTime` under the current code (the harness did not get a window in time), real keys, real latency.

### Forehand / backhand (implemented)
- **Rule:** mouse on the LEFT half of the screen = backhand, RIGHT half = forehand, from the screen X coordinate only (`ShotController.pointerStroke`, viewport centre, dead zone `ShotControl.StrokeDeadZone` 0.03 of the width keeps the current stroke near the middle).
- **Locking:** follows the pointer while IDLE; locks when charging actually starts (a queued press locks the pointer side at that later moment); stays locked through SWING_RELEASED, CONTACT_RESOLVED and RECOVERY; every return to IDLE (end of recovery, cancel, focus loss, point reset, respawn, release with no ball) unlocks and re-reads the pointer at once. Drag accumulation, spin, power and the arrow are untouched.
- **Pose:** `StancePose` builds one upper-body ready track per stroke (`Config.Stance.Backhand`) and the stance controller cross-fades them (`StrokeBlendTime` 0.12 s); the same tracks are reused, only one plays at full weight, the legs/grounding track is unchanged, the paddle stays on its `PaddleGrip` Motor6D (no teleport). The backhand angles were MEASURED on the avatar (on this rig shoulder Y, not Z, brings the arm across): blade 3.5 studs left / 5.3 up / 6.5 forward of the root vs the forehand's 6.2 right / 6.7 up / 7.4 forward. `StanceController` remembers the requested stroke so it survives the ~3 s stance measurement and respawns (the new character starts directly in it).
- **Swing:** `StancePose.playSwing(character, strength, stroke)`; backhand swing (`Config.Swing.Backhand`) measured blade path: back (-3.8 right, 2.8 fwd) -> strike (3.9 right, 10.5 fwd) -> follow (7.4 right, 9.5 fwd). It starts and ends at the locked stroke's ready pose.
- **Server:** `ChargeStart` now carries `stroke`; RallyService stores it per press (only "Forehand"/"Backhand", cleared with the press, at point reset and on cancel) and reports it in the swing reply and the event text ("You hit (backhand clean, ...)"). (Reach was made stroke-dependent in the next section.)
- **Reach anchor vs backhand (explained, not changed):** gameplay reach is a 9-stud circle around a point 4 studs right / 3 forward of the root (`ShotInput.anchor`), so it covers roughly x = -5..+13 relative to the body whatever the pose. A backhand pose shows the blade ~3.5 left, so a ball 6 studs to the left is unreachable next to a visible backhand paddle, while a ball 12 studs right is hittable while posed for a backhand. Stance-specific reach is an open decision.

**Tests (Studio Play, scripted via `Player.NotPongShotDebug`: new `pointer`, `cancel`, `blur` commands; not real mouse):** idle pointer 0.2/0.49/0.52/0.8/0.51/0.45 -> B/B/B/F/F/B (dead zone works), exactly one upper track at weight 1 after each switch; live rally: backhand charge stayed backhand while the pointer crossed to 0.92 with -90 sidespin from the drag, through release, CLEAN verdict and recovery, then unlocked to forehand; cancel, focus loss, point reset (held through the point) and respawn all returned to IDLE unlocked and followed the pointer; queued press between points locked the pointer side at the moment charging began; after respawn only the backhand pose ever appeared; both camera orientations (player on the bot's half with the mirrored camera): pointer-left = blade on the screen-left of the body; three live returns forehand/backhand/forehand all CLEAN with the right stroke in the server log; console clean. Screenshot: backhand blade reads front-left (seen through the 0.6-faded head).
**Not verified:** a physical mouse/trackpad, feel, how the poses look from other angles, paddle clipping during the backhand swing, real latency.

### Measured for the open smash question
Bot returns (200 solved shots with the bot's own rules) peak only **3.5-8.2 studs above the table** after bouncing on the player's half (median 5.8); they cross the player's end line 3.7-5.6 above it. The reach band tops out at 20 above the floor = 10.3 above the table.

### Files
`src/shared/Shared/Config.luau` (Stance.Backhand, StrokeBlendTime, Swing.Backhand, ShotControl.StrokeDeadZone), `src/shared/Shared/StancePose.luau` (stroke poses, setStroke, backhand swing, start in a stroke), `src/client/Client/StanceController.luau` (setStroke/getStroke), `src/client/Client/ShotController.luau` (stroke selection/lock, stroke on ChargeStart and release, debug commands), `src/client/Client/ShotFeedback.luau` (swing uses the stroke), `src/client/Client/Main.local.luau` (wiring), `src/server/Server/RallyService.luau` (press stroke record/report).

### Manual playtest checklist (stroke)
1. Idle: move the mouse across the screen centre: the arm switches between forehand (paddle right) and backhand (paddle across, front-left) with a short blend; resting near the centre does not flicker.
2. Hold left-click on the left half, drag right across the centre for spin: the backhand stays; release: a backhand swing; the next stroke follows the mouse after recovery.
3. Alt-tab, let a point end, or reset the character while holding: the pose follows the mouse again.
4. Walk round to the bot's half: left of the screen is still backhand.

## Stroke reach, timing errors, smash, dive, slow-motion fix (2026-11-15, awaiting your review)

Decisions confirmed in chat: reach follows the stroke (mirrored anchor); forgiving ordinary returns with risk in aggressive/stretched shots; smash thresholds as proposed; high balls from bot pressure pop-ups + a small random rate; slow-motion `LeadTime` 0.13; dive by movement input with an automatic weak return, costlier preset (50 stamina, 1.0 s recovery).

### What changed
- **Reach follows the stroke.** `ShotInput.anchor(root, settings, stroke)`: backhand anchor = `ShotControl.BackhandAnchorRight` (-4, mirrored), same 9-stud radius. Server: the stroke recorded with the press (`ChargeStart.stroke`) is used for the contact window, slow-motion eligibility and stretch. Client: the window/timing bar/arrow use the current stroke (locked while charging); a stroke change while idle clears the window so it is recomputed from the other anchor.
- **Deterministic timing error** (`ShotLaunch.compute` opts `timing`, `stretch`, `stroke`; `ShotInput.timingValue`). After the calibration the launch is turned by `yaw = t * risk * TimingYawDegrees` (early = across the body: forehand to the left, backhand to the right) and `pitch = -t * risk * TimingPitchDegrees` (early = higher/long, late = lower/net), where `t` = release offset in half clean-windows (-1..1 clean, up to +/-2 at the weak band's edge) and `risk = ErrorBase 0.2 + ErrorPowerWeight 0.8 * ramp(power 0.5..1) + ErrorStretchWeight 0.8 * ramp(stretch 0.6..1)`. The old random +/-4 stud weak error is off (`WeakAimError` 0); weak contacts keep x0.8 speed / x0.4 spin. Nothing is steered after contact.
  - Offline sweep (60 contacts x spins per cell, landed % / mean landing shift): power 0.3-0.6 near the body: 100% at every timing (shift <= 2.3 studs at the weak edge); power 1.0: 89-98% at the clean edge, 68-82% at the weak edge; power 1.0 + stretch 0.9: 77-96% at the clean edge, 30-36% at the weak edge.
- **Arrow = "release now".** `ShotFeedback` predicts with the ball's position at this moment inside the window (incoming flight cached once per snapshot), the timing error of this moment, the stretch, the weak penalty and the smash rule, so the arrow sweeps through the error as the ball arrives and is straightest at the ideal moment. Recompute interval 0.02 s (`Feedback.Arrow.RecomputeInterval`), prediction cost measured 0.2-0.3 ms.
- **Smash.** `ShotInput.smashEligible`: ball centre >= `SmashMinHeight` 7.5 above the table, <= `SmashMaxBehindEndLine` 6 behind the player's end line, power >= `SmashMinPower` 0.75; with a clean or weak contact the server plays `ShotLaunch` opts.smash: `SmashSpeed` 135, `SmashDepth` 0.85, spin x0.5, risk x3 of full power. Offline: lands 92-100% within +/-1/4 of the clean window (~+/-30 ms), 56-93% at +/-1/2, 13-26% at the edge. Arrow gold (`ShotControl.SmashColor`) with "SMASH" (red "SMASH OUT/NET" when it would miss); release plays `StancePose.playSwing(..., "Smash")` (`Config.Swing.Smash`, hand-set, not measured).
- **Bot pop-ups** (`Striker:shot(from, rng, state)`, `Config.BotPlay.Popup*`/`Pressure*`): pressure = max(edge-of-reach, incoming speed 75..110, sidespin /80); lob chance = 0.05 + 0.3 x pressure; the lob is 30 +/- 2 studs/s, topspin 60, to 0.65 depth (offline: bounces 10.1-12.4 above the table; live tests saw 8.0-10.6 depending on the bot's contact height). Event text "Bot pops up a high ball: smash it!".
- **Contact window horizon 1.5 -> 3 s** (`ShotInput.contactWindow`): the server predicts from the bot's hit and a lob takes longer than 1.5 s to come back into reach; before this every lob was "ball never in reach" on the server while the client showed a window (found in testing).
- **Slow motion:** `ChargeFreeze.LeadTime` 0.45 -> 0.13 (<= MaxDuration x TimeScale).
- **Dive** (`Config.Movement.Dive*`, key E). Client (`MovementInput`): direction = `Humanoid.MoveDirection`, or the locked stroke's side when no keys are held; sends `DiveRequest(dir)`. Server (`MovementService.requestDive`): character alive/placed, not diving, 1.5 s cooldown, stamina >= 50 (else the player's `NotPongDiveRefused` counter bumps -> HUD flashes NO STAMINA), then RallyService's gate (live rally, one dive per incoming ball; cancels the charge and any slow motion). Lunge = a server-created horizontal `LinearVelocity` for 0.35 s covering 10 studs (not affected by Shift boost; physics, so the table guard blocks it), WalkSpeed 0 through the lunge and the 1.0 s recovery, character attribute `NotPongDive` = lunge / recover / "". No boost drain or regeneration during a dive. RallyService `tryDiveReturn` (per physics tick during the lunge): referee/one-swing/cooldown rules, root within `DivePositionTolerance` 6 of where the lunge can be (anti-teleport), ball in reach of `root + dir*3` with radius 9 + 6, falling or past the end line -> `ShotLaunch` opts.dive: 40 studs/s, spinless, depth 0.55, stretch error up to 5 deg toward the dive side. Client: charging is refused while diving; a dive cancels a charge; dive pose `StancePose.playDive` (Action3); stamina bar has a dive-cost tick.

### Tests (Studio Play, scripted through remotes and `Player.NotPongShotDebug`/`NotPongArrowDebug`; not real keys/mouse)
- Reach: ball 6 studs LEFT -> backhand CLEAN, forehand "ball never in reach"; ball 12 studs RIGHT -> forehand CLEAN, backhand "never in reach". Client window agreed with the server in all four.
- Timing error: forehand early (-80 ms) yaw +3.8 deg / pitch +0.8, late (+83 ms) yaw -4.0 / -0.8, backhand ideal ~0; the arrow's own yaw matches the formula for its timing exactly (e.g. -0.061 s -> +2.92 deg) and the real bounce was 0.8-2.9 studs from the arrow tip. **The arrow lagged the server by up to ~66 ms in these tests because Studio in the background renders at 15 fps (RenderStepped 15/s, Heartbeat 60/s); a focused window renders every frame.**
- Smash (bot forced to lob for this test only, then restored to 0.05): on time -> "forehand SMASH clean", contact 7.8 above the table, landed; early (-67 ms) -> smash with yaw +9.7, landed; a natural pop-up during the final regression was smashed from slow motion (clean, power 92%).
- Dive: refused between points (stamina unchanged); in a rally a charge was cancelled ("dive"), lunge 0.33 s / 9.6 studs, WalkSpeed 0 during, recovery ~1.0 s, dive pose played; refused at 38 stamina with the NO STAMINA counter bumped; ball passing 14 studs to the left (out of normal reach) -> "You dived and returned it (stretch 74%)", landed on the bot's half; diving at the table from 5.2 studs off its edge stopped 5.0 off it.
- Slow motion: press 0.112 s before ideal -> slowed (WalkSpeed 8.4), clean at the strike, power charged in real time.
- Regression: ordinary returns at power 0.62-0.71 clean and landed (yaw <= 0.5 deg); serving, scoring, stroke reporting; console clean throughout.

### Not verified
- Physical mouse/keyboard (E, Shift, drag), feel, latency; how the smash swing and dive pose LOOK (hand-set keyframes; only the forehand/backhand poses were measured); the one-dive-per-ball refusal (source only; the 1.5 s cooldown makes it rare); the anti-teleport tolerance path; the pressure pop-up rate in real rallies; the arrow's sweep readability at 60 fps.

### Known issues / tuning notes
- Live lobs peaked 8.0-10.6 above the table (offline 10.1-12.4): the smashable stretch of the fall is short when the bot hits low. Lower `PopupSpeed` or raise `PopupDepth` for higher lobs, or lower `SmashMinHeight`.
- Stamina regeneration resumes 1 s after the dive STARTS, i.e. right after the 1.35 s dive ends; and (unchanged) after boost exhaustion it counts from exhaustion, not from releasing Shift.
- The arrow cannot know your release frame: at 60 fps its "release now" prediction is at most a frame or two old.
- `ShowInputDebug` is still true in Config (its overlay code is commented out in ShotFeedback).

### Files (this pass)
`src/shared/Shared/Config.luau`, `ShotInput.luau` (stroke anchor, timingValue, smashEligible, 3 s horizon), `ShotLaunch.luau` (risk, timing/stretch/smash/dive launches), `StancePose.luau` (smash swing, dive pose); `src/server/Server/RallyService.luau` (stroke reach, playerLaunch, dive gate + return, pop-up event), `Striker.luau` (pressure, lob), `MovementService.luau` (dive); `src/client/Client/ShotController.luau` (stroke anchor, dive lockout/cancel, dive result), `ShotFeedback.luau` (release-now arrow, smash, cached incoming flight), `TrajectoryArrow.luau` (smash look), `MovementInput.luau` (E, NO STAMINA, dive pose), `Main.local.luau` (wiring).

### Manual playtest checklist
1. Rally normally at medium power: almost everything lands; watch the arrow swing slightly as the ball arrives and straighten at the green zone.
2. Full power: release a little early/late and watch shots go across/long or wide/into the net; the arrow shows it before you release.
3. Stand so the ball comes to your left: with the mouse on the right (forehand) it is out of reach; switch the mouse left (backhand) and it is hittable.
4. Hit hard, wide, curving shots until the bot pops up ("smash it!"): hold to >= 75% power, the arrow turns gold SMASH; release on time.
5. Let a ball go wide, press E toward it (with A/D held, or none: your stroke side): you lunge, the ball comes back as a soft lob if you reached it; you are stuck ~1 s after. Try E at under 50% stamina: NO STAMINA.
6. Press very late on an incoming ball: slow motion; release at the strike.

## Uploaded assets, x1.5 table, persistence, dive/footwork animations, off-platform camera (2026-11-15, awaiting your review)

Decisions confirmed in chat: table **x1.5 of the old plan keeping the wide shape** (47.27 long x 34.5 wide), height kept at 8.74; ball enlarged in proportion (1.5 studs, gameplay = visual); the incomplete import fixed by **re-exporting from Blender and importing in Studio** (done by you); shot speeds **x1.15** (partial, flights take longer than before); dive/footwork animated for **standard R15**.

### 1. The assets (what is where now)

| Object | Role | Edit it? |
|---|---|---|
| `NotPongArena/Table/Visual/TableAsset` | **The visible table**: your uploaded meshes. `Top`, `Lines` (from your first import; lines are a separate layer so they can have their own colour), `Legs`, `NetPart1-4`, `NetBorder`, `NetHolder`, `Clamp` (from `assets/table/NotPongTable.fbx`). Anchored, no collision/query/touch | **Appearance: freely** (colour, material, MaterialVariant, textures, decals, SurfaceAppearance, Highlights, new child parts). Size/position: see "Editing workflow" |
| `NotPongArena/Table/Collision/TableTop` | Invisible gameplay table block (unchanged role) | No (Config-enforced) |
| `NotPongArena/Net/*` | **Collision only now** (Transparency 1: the asset's net is the visible one). Blocks characters; the ball uses `TableWorld` | No |
| `NotPongArena/PaddleTemplate` | **The paddle**: your uploaded paddle (Handle, Red, Blue unions), scaled x2.51 (blade 3.2 studs, the placeholder's visual size). `Handle/Grip` attachment = where the fist closes (+Y toward the blade tip, blade faces +/-Z, red face toward the table in the ready stance). At Play it moves to ServerStorage and `PaddleFactory` clones it onto the player and the bot (named `Paddle`, welded, unanchored, massless, no collision). Visible in Edit mode next to the player spawn | **Freely**: appearance, scale (Scale tool / `Model:ScaleTo`), extra parts. Move/rotate `Grip` to change how it is held |
| `NotPongArena/BallTemplate/Ball/BallVisual` | The visible ball, now **1.5 studs = the gameplay ball** | Appearance freely; size is gameplay (Config) |
| `ServerStorage/NotPongBackup_2026-11-15` | Reversible copies: `PrimitiveVisuals` (the old table surface, lines and legs), `UploadedOriginals` (your Scene, NotPongTable and Paddle exactly as imported, and the old 1.0-stud BallVisual). README inside | Delete when you are happy |

The uploaded table came in incomplete (only 1 of 4 leg quarters, 1 of 4 net quarters, 1 of 2 net holders, no materials): the Blender file's Mirror/Array modifiers had not been applied on export. `assets/table/NotPongTable.fbx` was exported from `tableTennisTable.blend` with modifiers applied (the .blend was not modified or saved); the net is split into 4 quarters because the full net is 49,600 triangles (over the per-mesh limit). The net mesh is one-sided, so `DoubleSided` is on for the net parts. Colours/materials were set once from the Blender materials (navy top, white lines/net, dark metal frame).

### 2. Why Edit-mode changes did not stick, and the fix
Measured (representative edits, then Play):
- **The uploaded paddle and table were never used.** `PaddleFactory` built a primitive paddle (two Parts) for every character; `Workspace.Paddle` and `Workspace.Scene` were just sitting in Workspace, so editing them changed nothing in the game.
- **One gameplay mismatch reset unrelated visuals.** When any gameplay part (TableTop, NetMesh, Platform) differed from Config, `ArenaBuilder.load()` ran the full `syncGeometry()`, which re-enforced Size/CFrame of EVERY static part, including the visual legs/lines and the BallVisual (your 1.0-stud ball went back to 0.5). Reproduced: resizing TableTop also reset a resized leg and the ball.
- Plain appearance edits on the arena did persist (verified), so this was not Play overwriting cosmetics.

Fix:
- `PaddleFactory.create()` clones `PaddleTemplate` (falls back to the primitive paddle with a warning only if the template is missing). The template's look, scale and part layout are kept exactly.
- `ArenaBuilder.syncGeometry(folder, gameplayOnly)`: Play passes `gameplayOnly`, so only gameplay geometry (collision table, net collision, platform, ball sizes) is corrected; visual parts, the table asset and spawn markers are never touched. With a `TableAsset` present the primitive visuals are neither created nor updated.
- The visible table may not disagree with the simulation: at Play, only the asset's **structural** parts (Top, Lines, NetPart1-4, NetBorder; attribute `FitStructural`) are compared with Config and, if they drifted, re-fitted **in memory for that session with a warning** (Size/CFrame only; appearance untouched). Cosmetic geometry (Legs, NetHolder, Clamp) is never touched at Play, so resizing them sticks.

### Editing workflow
- **Appearance of anything** (table asset, paddle template, ball visual): edit in Studio and save; nothing at Play rewrites it.
- **Legs / net holders / clamp size or position**: edit directly (cosmetic geometry).
- **Paddle**: edit `PaddleTemplate` (look, scale) and its `Handle/Grip` attachment (grip).
- **Table size (structural)**: change `Config.Presentation` (`ArenaScale` = length/net, `TableWidthStuds`, `TableHeightStuds`, `BallDiameterStuds`), then in the Command Bar (Edit mode):
  `local AB = require(game.ServerScriptService.Server.ArenaBuilder); AB.syncGeometry(); AB.fitTableAsset()` and save. `syncGeometry` updates the collision table, net, platform and ball; `fitTableAsset` rescales every fitted asset part from its recorded native size (idempotent; attributes `Native*` on the model and `FitZone`/`FitStructural`/`FitSource*` on the parts). Move the spawn markers if the table length changed. Do not resize the Top/Lines/net parts by hand: Play would put them back (with a warning).
- Adding your own parts to `TableAsset` is fine: parts without `FitZone` are never moved by code.

### 3. Scale (Config.Presentation)
| Value | Old | New |
|---|---|---|
| Table (L x W x H) | 31.51 x 23 x 8.74 | **47.27 x 34.5 x 8.74** (`ArenaScale` 1.725, `TableWidthStuds` 34.5, `TableHeightStuds` 8.74) |
| Net height / length | 1.754 / 26.51 | **2.63 / 39.76** |
| Ball (gameplay / visual) | 0.4 / 1.0 | **1.5 / 1.5** |
| Platform | 55 x 95.51 | 66.5 x 111.27 |
| Spawns | z 85.75 / 34.24 | z 93.63 / 26.37 (10 behind each end line, as before) |

Not multiplied blindly: height, gravity, avatar, reach (9 + dive 6), timing windows, smash height unchanged.
- **Ball radius vs spin**: collisions use the 0.75 radius, but the bounce's spin <-> speed coupling uses the real ball's lever arm (`BallPhysics.spinRadius` 0.2); otherwise every bounce would kick spin 3.75x harder.
- **Speeds x1.15**: player 55-115 (was 48-100), smash 155, bot 71 +/- 7, serve 80 (29-126), `magnusSideSpeedRef` 86. Lateral spreads x1.5 (bot spread 7.5, aim error 0.9, serve spread 4.5, second bounce 13.5, lateral margin 3.75); net clearance 1.2.
- **Not x1.15, because measured necessary**: bot lob `PopupSpeed` 52 +/- 3 to depth 0.6 (at 34.5 the solver found **0/120** lobs: with drag a slow lob cannot carry the longer table; at 52: ~100% solved, bouncing 11-16 above the table); `DiveReturnSpeed` 55 (46 solved 9/15 dive returns from contacts wide of the table; 55: 15/15).
- **Camera**: `Camera.DistanceMultiplier` 1.25 pulls the camera back along its own line of sight (same angle and composition, wider view; FOV unchanged).

### 4. Dive + get-up and footwork animations (made with /animate)
`/animate` (the fwjelaa kit) was used with the Blender MCP: recipe `anims/_notpong.py` in the kit (`C:\Users\Yan\.claude\skills\animate\pack`), clips `NP_DiveRight`, `NP_DiveLeft`, `NP_ShuffleRight/Left/Forward/Back`, built on the kit's block R15 rig with its IK, exported, converted by `tools/anim_to_luau.py` into `src/shared/Shared/NotPongAnimData.luau` (generated; do not edit) and built into KeyframeSequences at runtime by `Shared/NotPongAnims` (registered like the generated stance; **nothing uploaded or published**). Built in a temporary scene of your open Blender file, removed afterwards; your .blend was not saved.
- **Dive (one clip per side, 1.35 s = the 0.35 s lunge + the 1.0 s recovery, Action4, every joint):** push-off (4 f) -> airborne reach with the paddle stretched beyond the head (10, marker Reach) -> floor landing lying on the dive side (19, Land) -> squash (21, Recover = start of the server's recovery) -> still down while the free hand plants (30) -> brace (36) -> kneel (51 = 0.5 s into the recovery) -> rising (66) -> ready (81). The paddle stays in the right hand: a left dive reaches across (backhand side). The clip never moves the HumanoidRootPart (the server's LinearVelocity does), so no double root motion.
- **Sync with gameplay** (`MovementInput` watcher -> `StancePose.dive`): "lunge" starts it, "recover" re-syncs to the get-up, "" lets it finish (blends out over its last 0.18 s into the live stance) or blends it out if the dive was cut short (respawn). HipHeight is held during the whole dive (the stance grounding pauses); jumping is disabled during the dive and re-enabled after; charging stays refused (existing). Slow motion scales the clip.
- **Per-avatar fit** (`NotPongAnims.rootOffset`): every LowerTorso translation is shifted down by (root height / scale - 3) units. The stance measures each avatar's own hip pose, so its root sits higher than the block rig's. Exact for block-proportioned avatars; your test avatar is the block rig x3.37. (A multiplicative fit and a per-frame HipHeight servo were tried first and failed: the body floated 2-3 studs, then legs went through the floor.)
- **Ready stance**: feet wider than the hips (`Stance.LegSpreadDegrees` 10), as in your reference.
- **Shuffle footwork** (players): moving on the platform up to `Stance.ShuffleMaxSpeed` 32 studs/s, the legs shuffle instead of walking: the foot nearest the movement direction steps first, the other follows, never crossing. The four directions are blended by the move direction in the body's frame and the playback speed follows the ground speed. Faster than that (Shift boost) the regular run shows. While shuffling, the grounding uses a short window (one foot is always planted).
- The old procedural dive lean (`Config.DivePose` angles) is replaced; `Config.DivePose` now only holds the blend times.

### 5. Camera distance and off the platform
- New `Client/PlatformZone`: one on/off-platform state from the real `Platform` part with the fade's margins (0.5 in / 1.5 out) plus `PlatformZone.DwellTime` 0.2 s, shared by the camera, facing, stance and fade (all switch together; no edge flicker).
- **Off**: the camera glides for 0.4 s to a follow pose 28 studs behind the head along the current view (`Camera.HandoffTime`/`OffPlatformDistance`/`OffPlatformPitch`), then Roblox's default camera takes over from exactly that pose (zoom pinned to that distance for a moment, then normal zoom/orbit). `AutoRotate` on and the facing constraint removed (the avatar faces its movement). The stance, shuffle and swing-base tracks stop and the avatar's own HipHeight returns, so the default idle/walk/run/jump show. The fade turns off (unchanged behaviour).
- **Back on**: the table camera starts from the current view and eases in (`Camera.ReturnSmoothing` 4), the facing constraint and the stance/footwork fade back in (0.25 s), and the fade returns.

### Tests (Studio Play; scripted through remotes, `Player.NotPongShotDebug`, `Humanoid:MoveTo` and teleports in the test harness only; not real keys/mouse)
- **Assets active / no duplicates**: one TableAsset (10 parts), one BallVisual, two paddles (player + bot), both clones of the template; template moved to ServerStorage at Play and back in the arena after Stop. Console clean.
- **Geometry**: TableTop 34.5 x 8.74 x 47.27, platform 66.5 x 111.27, net collision 39.76 x 2.63, ball 1.5/1.5; `validate` and `validateTableAsset` 0 problems; visual top surface at 9.74 = gameplay surface; net border top 2.63 above it.
- **Persistence, 2 Play/Stop cycles, on the new assets**: table top colour + material + a Texture, legs colour + 10% resize, paddle template colour + a Highlight child, ball colour + Neon all present on server and client in both cycles (the paddle edit appears on the character's clone); a hand-resized Top was re-fitted in memory with a warning while its colour/material/texture stayed. Test edits reverted afterwards (validators 0 problems).
- **Offline shot sweep (5,300 launches on the new table)**: clean timing: power 0.5 lands 99%, power 1.0 96%, power 0 75% (fails are zero-power full-backspin shots: the solver cannot calibrate them and they fall short); timing extremes 81-89%; smash on time 100%, +/-1 half-window 33-67%; bot returns 120/120, bouncing 6.2-15.1 above the table (median 9.9); lobs ~100% solved at the new speed.
- **Live rallies**: a 19-hit rally (13 forehand + 6 backhand, all clean, with spin drags; the bot returned every shot on the wider table, one pop-up); a 13-hit full-power rally including **a smash of a bot pop-up** ("forehand SMASH clean") that the bot returned; player and bot serves; scoring and points.
- **Dive**: both sides played in sync with the server phases (lunge -> recover at 0.35 s -> stance at ~1.45 s), body moved 10.6 studs, jump disabled during and restored after. After the fit, the body lies on the floor at landing (torso 4.8 studs above the floor on its side). Screenshots from the game camera: lying on the floor beside the table after a right dive; kneeling at 0.82 s of a left dive.
- **Footwork**: moving right / left / diagonal / back blends the matching shuffle (e.g. right 0.53 + forward 0.02 while still blending in); feet never crossed (closest 3.95 studs); on a 32-stud side-step the lowest foot sat at a median 0.09 above the floor.
- **Off-platform**: off -> camera Custom, AutoRotate on, facing removed, avatar turned to its movement (+Z), only default animations playing, HipHeight 6.75 (natural), fade 0; back on -> everything restored. Camera hand-off: largest single-frame step 6.6 studs (was a 24.9-stud snap before the glide) in this background Studio window running at ~15 fps (about 1.6 per frame at 60 fps); return 3.3.

### Not verified
- Anything with your real mouse/keyboard, and the feel.
- How the dive and shuffle look to the eye at full frame rate. The dive was checked from two screenshots and key-pose renders; the shuffle was not screenshot in motion.
- Avatars that are not block-proportioned (the per-avatar fit is exact only for block proportions).
- Network latency; another player; the bot's own dive (it has none).

### Known issues
- **Dive clip clipping** (kit checks): arms pass 0.25-0.5 studs (block-rig units; x3.37 on your avatar) into the head or chest during the overhead reach and the floor catch. In the left dive the paddle arm sinks up to 0.4 units into the floor while lying on it (the rig's shoulder joint touches the floor; the body may rise only 0.3 units onto the arm). The two legs overlap 0.25 in the airborne frames.
- **Shuffle start**: during the first ~0.5 s of a move (blending in) the feet float ~0.3 studs; settled shuffling is within ~0.1.
- **"Rally timed out" once** in ~60 rally shots: after a full-power rally, 10 s passed with no hit and no floor contact (the ball came to rest without being scored). Cause not identified.
- Zero-power full-backspin shots fall short (75% landing at power 0). This may predate the resize; it was not compared with the old table.
- Flights are ~30% longer than before (x1.5 table, x1.15 speeds), as chosen; raise the speeds further if rallies feel slow.
- The camera clipping at the near-left table corner (old note) was not re-checked.

### Files (this pass)
- Shared: `Config.luau` (Presentation, scale-driven values, camera, PlatformZone, Stance footwork, DivePose, Names), `BallPhysics.luau` (`spinRadius`), `StancePose.luau` (wider legs, shuffle, dive clip, off-platform suspend, time scale), **new** `NotPongAnims.luau`, **new (generated)** `NotPongAnimData.luau`.
- Server: `ArenaBuilder.luau` (gameplay-only sync, table-asset fit/validate, paddle template parking), `PaddleFactory.luau` (template clone, Grip attachment).
- Client: **new** `PlatformZone.luau`, `CameraController.luau` (distance, hand-off, return), `FacingController.luau`, `CharacterFade.luau`, `StanceController.luau`, `MovementInput.luau` (dive clip sync, jump lock), `ShotController.luau` (slow-motion time scale), `Main.local.luau`.
- **New** `tools/anim_to_luau.py`, `assets/table/NotPongTable.fbx`.
- Studio (unsaved until you save the place): `TableAsset`, `PaddleTemplate`, resized arena, moved spawns, backup folder.
- /animate kit: `anims/_notpong.py` and `anims/NP_*.py`.

### Manual playtest checklist
1. **Save the place first** (the new assets live in the Edit data model).
2. Look at the table, net, paddle and ball from the game camera; recolour the table top and the paddle in Edit mode, press Play twice: the changes stay.
3. Rally: is the wider view comfortable? Do rallies feel too slow (flights are ~30% longer)?
4. Move left/right/forward/back in a rally: the feet should side-step without crossing; Shift shows the run.
5. Dive (E) both ways: commit, land on the floor, get up in about 1 s; is the paddle visible at the reach?
6. Walk off the platform: the camera becomes the normal follow camera and you walk/run/jump normally; walk back: the table camera, stance and footwork return without a snap.


## Pass 2: movement, manual dives, manual serve (2026-11-15, awaiting your review)

Requested in chat: fluid athletic movement (diagnose the robotic on-platform movement and the shaky off-platform walk first), dives on **F** with manual contact (no automatic return), a **backward dive** (S + F), recovery **1.3 s**, and a **player-controlled toss-and-strike serve** (ball in the free hand, Space to toss, cursor aim before charging, apex slow motion, real faults). Bot serving, scoring, rotation, the uploaded assets, persistence and the camera are unchanged.

### 1. Diagnosis (measured in Studio on your avatar before any change)
| Symptom | Cause found | Fix |
|---|---|---|
| Off-platform walk shaky / choppy | Roblox's **animation retargeting** (`Workspace.Retargeting = Default`) scaled the default walk/idle translations to the avatar's HipHeight **on top of** `Model:ScaleTo`'s own scaling: on the 3.37x avatar the hips bobbed **2.55 studs** per stride with **0.93-stud jumps in one frame** (the asset itself moves 0.28 units). The root itself was perfectly steady, so it was not physics or the camera | `Config.Animation.Retargeting = Disabled`, set by the server and every client at start. Measured after: bob **0.86**, max **0.31** per frame (the same proportion as an unscaled avatar) |
| On-platform movement robotic | (a) the leg tracks' weights dipped to **~0.75** at every start/stop/reversal, so the (over-scaled) default walk leaked into the legs; (b) the per-frame HipHeight grounding saw those feet and **popped the body up ~0.47 studs** each start; (c) the shuffle clips keyed the **whole body** (arms at rest), averaging the paddle arm and the lean down by half while moving (shoulder **45 -> 22 deg**, lean **12 -> 6**); (d) a single frozen upper-body pose | New footwork controller (below): leg weights always sum to 1, HipHeight never touched, legs-only clips, additive upper-body layer |

### 2. Movement (Shared/StancePose.start, rewritten)
- **Legs** = one locomotion layer whose weights always sum to 1: `NP_Ready` (standing) + 4 shuffles + 4 Shift runs, blended by speed (shuffle below 30 studs/s, run above 44, Shift boost is 54) and by the travel direction in the body's frame. One shared cycle clock drives every footwork track (no track restarts on input changes); a move started after standing still begins on the lead foot (the foot nearest the direction). Cadence = real speed / the blended clips' authored travel speed (so no extra slow-motion factor is needed: slow motion lowers the real speed).
- **HipHeight is never changed** (on or off the platform). The clips fit the avatar's own HipHeight with no vertical shift (`NotPongAnims.rootOffset` is now 0; the old shift was for the old raised HipHeight and sank the bot's feet 0.69 studs).
- **Upper body** = the stroke's ready pose (Config.Stance) + an **additive layer** written after the Animator each frame (`RunService.PreSimulation`): waist and neck counter-rotate against the hips' yaw (`Stance.Layer.WaistCounter` 0.55, `NeckCounter` 0.35: on a sideways run the hips turn 25 deg toward travel while the head stays ~2.5 deg off play), slow breathing, free arm balancing. Never touches the legs, so planted feet stay planted.
- **Clips** (`/animate`, Blender MCP; recipe `anims/_notpong.py` in the kit, legs + hips only): `NP_Ready` (feet wider than shoulders at +-1.3, knees 50, pelvis tipped forward, a slow 2 s weight shift with feet IK-planted), `NP_ShuffleRight/Left/Forward/Back` (base +-1.2: feet come closer between steps, never cross, hips open 4 deg toward the stepping foot), `NP_RunRight/Left` (a low side gallop with the hips turned 25 deg toward travel; feet 1.56-3.41 apart, never crossing), `NP_RunForward`, `NP_RunBack` (backpedal). All "CHECKS: all clear".
- Settings: `Config.Stance.Locomotion` (thresholds, blend rates, authored clip speeds, cadence clamps), `Config.Stance.Layer`.
- The bot uses the same footwork (its own walk cycle is no longer used).

### 3. Dives (F, manual contact, backward, 1.3 s) — contact SUPERSEDED by Pass 3 (automatic return); key, directions, recovery and animations still apply
- **Key F** for every direction (E is no longer bound). Direction relative to the court-facing direction (the avatar faces the table; WASD is camera-relative with the camera behind you): **S alone or S+A / S+D = backward dive** along the held direction (back diagonals keep their sideways component and play the backward animation); A / D = that side; no keys or W alone = toward the locked stroke's side. `ShotInput.diveKind` (backward share >= `DiveBackwardThreshold` 0.35) classifies it the same way on every machine.
- **A dive never hits.** The automatic fixed-speed dive return is removed (RallyService `tryDiveReturn`, ShotLaunch's dive branch, `DiveReturn*` settings). The charge, the drag and the locked stroke **survive** the dive; you can also start charging during it. For `DiveContactWindow` **0.45 s** from the dive's start (the lunge + the landing) a normal swing gets an extended reach (anchor `DiveAnchorAhead` 3 studs along the dive direction from the server's root, radius +`DiveReachBonus` 5) and is judged like any swing (timing window, power, spin, smash, stretch risk). After that window, no new charge can start and a release is a miss ("still recovering from the dive"): no free retries during the get-up.
- **Recovery 1.3 s** (`DiveRecovery`): no walking, no jumping, no new charge, no second dive; stamina cost and exhaustion rules unchanged; the server owns stamina and eligibility; one dive per incoming ball.
- **Animations** (Action4, every joint): `NP_DiveRight/Left` re-timed to 1.65 s (0.35 lunge + 1.3 get-up: floor 21-34, brace 44, kneel 64, rise 84, ready 99) and **`NP_DiveBack`** (new: push back, airborne fall with the paddle reaching up/forward, land on the hips with the shoulders up, sit up, kneel, rise). Arm clipping fixed at the source: the old wrist targets were 2.2-3.5 studs from a ~1.9-stud arm, so the IK stretched the arms straight across the head/chest; targets are now clamped to reach, every frame 0-64 is baked with the arms re-solved clear of the head, torso and floor (searching nearby wrist points / elbow directions, preferring the previous frame's solution), then smoothed. The trailing leg's sideways value had the wrong sign (it crossed the other leg); fixed.

### 4. Manual serve (player; the bot keeps its automatic serve) — toss timing, slow motion, contact and launch SUPERSEDED by Pass 3; the hand-held ball, region and controls still apply
- **Ball in the free hand**: during your ReadyToServe the one gameplay ball rests on your LEFT hand (server mode `hand`; BallView draws the one BallVisual on your real LeftHand every frame; the server keeps its gameplay part at the same spot). The toss clip's first frame holds the arm.
- **Where**: anywhere legal behind your end line: the ball must leave the hand behind the end line (by its radius), within the table's width + `CornerAllowance` 3 studs beyond either side line, at most `RegionDepth` 22 behind, on the platform. Derived from the table/platform at runtime (`ServeRules.region/check`). The client outlines where to stand on the floor (blue = legal, red = not) with the reason on screen; the server re-checks at the toss and refuses with the reason ("Serve refused: ..."). Walk freely before tossing.
- **Space** tosses (it never jumps while it is your serve). From the toss on you are **locked in place** (no walking, boosting or diving) until the serve resolves. (Toss timing, contact rule and launch: see Pass 3; the apex slow motion, the fixed-height timer and the fixed launch mapping described here before were removed.)
- **Strike**: a **fresh** left-click after the toss (a button held from before never counts) locks the **aim** and the forehand/backhand stroke; drag = spin; release = swing (forehand: `NP_ServeStrike` from the cocked pose; backhand: the backhand swing). One swing per toss.
- **Faults**: a toss that is never struck (or a miss) falls to the floor = "dropped the serve toss" (point to the receiver); net + otherwise legal = **let** (replayed). Waiting before tossing is never a fault. Once tossed there is no cancel: leaving, respawning or losing focus lets the ball drop (a fault).

### Tests
**Automated / scripted in Studio Play** (remotes, the `NotPongShotDebug` bridge, `Humanoid:MoveTo`; real **Space / S / F / E key presses** through Studio's input tool; no real mouse):
- Diagnosis numbers above (before/after), on your avatar.
- Footwork: root height constant while moving (11.121 both ways; it moved 0.47 before); footwork weights never below 1.0 (the default walk never shows); paddle shoulder held at its pose while moving (65 deg backhand / 45 forehand; it halved before); feet on the floor standing (0.995 vs floor 1.0; bot 1.008-1.018); planted-foot slide per contact 0.1-0.3 studs once moving (the first step 2.3, contacts 2-4 0.4-0.6 while the blend settles; part of it is the facing turning ~1.5 deg per contact).
- Off platform: our tracks at weight 0, default camera, AutoRotate on; hovering within +-0.5 of the edge: 0 switches; back on: stance + footwork + facing return, HipHeight unchanged (6.747).
- Serve: ball on the palm (1.25-1.26 studs above the hand's centre) on and off the platform; Space -> toss without jumping; release 0.24 s after Space; apex slow motion at the server's apex (21.6); legal serves: centre forehand clean 33% (bot returned it), **right corner at the region's limit** backhand 33% aimed -5 deg (legal); faults: no swing -> "dropped the serve toss"; rising swing -> "too early (the ball was still high)"; late swing -> "too late"; full power -> "serve out"; illegal spot -> refused locally (red outline + reason) and by the server when requested directly; repeated swings at one toss refused; WalkSpeed 0 during the toss and 24 after.
- Dives: F bound (E does nothing); S+F -> backward dive (classified Back); charge kept through a dive (still CHARGING, power counting); dive + swing -> "forehand SMASH clean" (a real hit, judged as a swing); backward dive without a swing -> no hit, point lost; release during the recovery -> miss "still recovering from the dive", and a new press refused; lunge 0.37 s, recovery 1.28-1.30 s; jumping disabled and WalkSpeed 0 during, restored after.
- Console clean (no script errors) in every run.
- Kit checks: every clip "CHECKS: all clear" except NP_DiveRight/Left (see known issues).

**Visual (screenshots from the game camera, stills only)**: the serve-ready pose with the ball in the left hand, the region outline and hint; a side shuffle (wide base, lead foot stepping); a Shift run frame. Blender frame sheets of the run, toss and dives on the block rig.

**Not verified**: smoothness at full frame rate (the tools give stills; Studio rendered at ~15 fps in the background, and for part of the session not at all); anything with a **real mouse** (charge feel, the aim line following the cursor, drag spin on a serve); the dive's reach extension actually saving a ball out of normal reach (the test ball was reachable anyway); focus loss mid-serve (by design it drops, a fault; not run); respawn mid-toss; frame rates other than Studio's; a PvP match (slow motion stays solo-only by the existing policy).

### Known issues / notes
- (Superseded by Pass 3: the serve's fixed-height timer that made your first four physical serves "too early" is gone.)
- **Once seen, not reproduced**: during your session the held ball stopped following your hand (it stayed at the server's estimate) and the serve hint was empty; a fresh session tested on/off the platform could not reproduce it. (Pass 3 adds two fallbacks; see there.)
- Dive clips: small remaining arm contacts on a few frames (<= 0.3 block units: right dive 10, 39-41, 53; left dive 10-11, 17-18), and a fast arm turn on a few frames (8-12 is the airborne reach smear). From up to 0.5 units through most of the floor phase before.
- Footwork: residual planted-foot slide 0.1-0.3 studs per contact while moving; the first step after standing slides as the feet narrow from the ready base.
- Serve aim and stroke both come from the cursor's screen X, so aiming left of centre also picks a backhand.
- The bot's footwork measured at rest only (feet on the floor); not watched while it moves.
- `live.make` in the kit saves a copy `out/<clip>.blend` per build; those copies include your table meshes from the open file (your .blend itself was not saved; the temporary scene was removed).

### Files (this pass)
- Shared: `Config.luau` (Animation, Stance.Locomotion/Layer, Movement dive settings, Serve player-serve settings), `StancePose.luau` (footwork controller, additive layer, dive kinds, serve toss/strike), `NotPongAnims.luau` (no fit offset), `NotPongAnimData.luau` (regenerated: 14 clips), `ShotInput.luau` (diveKind, reachFor), `ShotLaunch.luau` (serve launch; dive return removed), **new** `ServeRules.luau`.
- Server: `Main.legacy.luau` (retargeting), `RallyService.luau` (player serve, apex slow motion, serve judging, manual dive reach, no auto return), `MovementService.luau` (dive contact window, 1.3 s, serve lock), `Stance.luau` (comment).
- Client: `Main.local.luau` (retargeting, serve wiring), `ServeInput.luau` (rewritten: hand-held ball pose, region, aim line, Space toss), `ShotController.luau` (serve charge/aim/window, dive-kept charge and dive reach), `ShotFeedback.luau` (no rally arrow or swing on serves), `MovementInput.luau` (F, backward/diagonal rules, dive kinds), `BallView.luau` (ball on the hand).
- /animate kit: `anims/_notpong.py` (ready loop, shuffles, runs, dives, backward dive, serve toss/strike), `anims/NP_Ready.py`, `NP_Run*.py`, `NP_DiveBack.py`, `NP_ServeToss.py`, `NP_ServeStrike.py`.

### Manual playtest checklist
1. Stand still: knees bent, wide base, a slow weight shift; the paddle stays up.
2. Move left/right/back/diagonal and reverse quickly: short side-steps, no body bobbing, the paddle arm stays up. Hold Shift sideways: a low gallop with the hips turned, head and paddle toward the table.
3. Walk off the platform: normal Roblox walk/run without the old shake; walk back on.
4. (Serve and dive items: use the Pass 3 checklist below.)


## Pass 3: camera follow, serve view, natural toss, forgiving serves, automatic dives, clean-shot honesty (2026-11-16, awaiting your review)

Requested in chat (supersedes earlier instructions on manual dive contact, deliberately unforgiving serves and apex serve slow motion): a balanced, fluid lateral camera; a lower serve camera that blends up after the strike; a natural, slower toss with **no serve slow motion**; contact-based, legal serves; automatic dive returns (~90% legal); an investigation of clean (green) shots that miss; the remaining shuffle shake. Rally slow motion, scoring, lets, rotation, bot serves, assets, scale and physics are unchanged.

References studied: `videoplayback.mp4` (watched with /watch, local frames) and `docs/Not pong obsidian vault/table-tennis-camera-inspo.png`. In the video the rally camera sits high behind the server with the player near the screen centre and follows them sideways; for the serve it drops to about head height with a nearly level view (horizon in the upper third, the table in the lower middle); after the strike it rises smoothly back to the rally view in ~1.25 s; the toss rises about a head above the hand.

### 1. Camera (`Client/CameraController`, `Config.Camera`)
- **Diagnosed**: a fixed right-shoulder offset (8 studs) with the camera following only 70% of the player's X: at the left side wall the avatar sat in the left third of the screen (root at 0.33 of the width) with its backhand side near the edge, at the right wall it sat centred. And the follow target led the player by the RAW velocity x 0.125 s: at a shuffle reversal that target jumped ~6 studs in one frame, so the camera accelerated harder than the player (measured on a recorded A/D shuffle path: camera 701 studs/s^2 vs the root's own 610) - the body appeared to jerk on screen.
- **Now**: one camera owner writing CFrame **and Focus** each frame; the target is the root position (stable physics, never the animated head/feet) plus a look-ahead of velocity x `LeadTime` 0.1, clamped to `MaxLead` 3 studs and eased at `LeadRate` 6/s (off during dives); X and Z each follow through a critically damped spring (`LateralSmoothTime` / `DepthSmoothTime` 0.14 s; frame-rate independent, no overshoot of a fixed target); `ShoulderOffset` 8 -> 3 (constant, never flips), `CameraXFollow` 0.7 -> 0.88, `LateralFollow` 0.4 -> 0.45. Rally height, distance, pitch and FOV unchanged. A fast output easing (`OutputSmoothing` 30/s) only absorbs respawn / side-flip discontinuities.
- **Serve framing** (`Config.Camera.Serve`): during your own serve's preparation and toss the camera lowers to `Height` 17 studs above the floor (about head height) at the same horizontal follow distance, aimed at the table centre `LookHeight` 2.5 above the surface (pitch ~5 deg down instead of ~17), shoulder offset **10** (at 4.5 the translucent avatar covered the middle of the table in Studio stills; at 10 the server stands centre-left as in the reference). **(Superseded by Pass 4: the sideways offset now follows the court position, `LateralOffset` / `CenterBlend` / `OffsetSmoothTime`.)** Blends are eased (smootherstep) over `EnterTime` 0.8 s / `ExitTime` 1.25 s; FOV never changes. Explicit cases: your serve struck (the referee counted the hit) -> blend up with the outgoing ball; a missed swing / dropped toss -> stays low until the point resolves; PointScored (fault, let pending) -> keeps the current framing, the next state decides; your next serve -> stays low; the bot's serve, rallies, waiting, match over -> rally framing; respawn -> snaps to the right framing. The aim is cursor-screen based and locked at the press, so camera motion never changes a locked aim.

### 2. Natural toss, no serve slow motion (`Config.Serve`, `Shared/ServeRules`, Server/RallyService, Client/ServeInput, StancePose.serve)
- The apex slow motion is **removed** (server `startServeSlowMotion`, the "serve" slow-motion kind, the client's serve slow-motion effects, `ApexSlowMotion` / `MaxSlowDuration`). Nothing slows during a serve: simulation, movement, animations, no tint/timer. The rally charge slow motion is never started or predicted for your serve (it still works in rallies, including when returning the bot's serve).
- The toss clip plays at `TossAnimSpeed` **0.75** (the authored hand path, a slower readable lift); the ball leaves the hand at the clip's Release marker: `TossReleaseDelay` = `TossReleaseMarker` 0.25 / 0.75 = **0.333 s** after Space, the same moment on server and client. Upward speed **36 studs/s** (`PlayerTossSpeed`) with the normal shared physics (gravity, drag): measured apex **12.5 studs above the table** (~6 above the hand, ~1.5 head heights) 0.35 s after release; frame-to-frame vertical acceleration stayed at gravity through the apex (no hover). Measured alternatives: 28 -> apex 10.3 at 0.28 s, 32 -> 11.35 / 0.31, 40 -> 13.8 / 0.38 (a lower toss gives less time).

### 3. Contact-based, forgiving serves (`ServeRules.phase/classify/target`, `ShotLaunch.serve`, RallyService `judgeServe`)
- **Contact phase** (replaces the fixed-height timer): the falling toss, its centre between `ContactMinHeight` **6** and `ContactMaxHeight` 13 studs above the table (so from the apex down to about the head top) and within the locked stroke's horizontal reach. The paddle meets the ball `HitDelay` 0.07 s after the release (the strike clip's Hit marker), so the server judges the ball at release + 0.07 on its own simulation of the toss. Measured phase: **0.362 s** at normal speed. Middle 60% = clean, outer 20% each side = weak (`WeakEdge`): **both legal**. Before the phase = "too early (the ball was still rising)", after = "too late"; never struck = dropped toss (fault). The client's timing bar shows the phase (weak edges amber, middle green).
- **Why 6 and not chest height**: measured on this table (net 2.63 high, 47.3 long, drag), a legal serve exists for only ~1-16% of contacts 1-2.5 studs above the table and ~35-75% at 4-5.5, even with a full scan; from ~7 up it exists for every input. The ready paddle sits ~8 above the table, so the band matches where the paddle is.
- **Legal-serve solve** (Pass 4 adds the safe serve envelope and changes the ladder and budget; see there) (`ShotLaunch.serve`, shared physics, decided once at contact, nothing steered afterwards): the second bounce is aimed by the inputs (aim -> across, `LateralMargin` 4.5 inside the side lines; power -> depth `SecondDepthMin` 8 .. `SecondDepthMax` 18 studs past the net = pace); first bounce on your half (`FirstBounceDepth` 0.6) on the way; `ShotSolver.solveServe` bisects the speed (30-140) simulating table and net **with the full drag spin**; if that fails, a coarse scan (`ScanFirstDepths` x `ScanSpeeds`); then the same spin direction at `SpinLadder` 0.6 / 0.3 / 0; last resort half the aim at medium depth. Weak contacts: `WeakDepthFactor` 0.85 and the weak spin factor. Cost bounded by `SolveFlightTime` 1.2 and `SolveBudget` 0.02 (an earlier version spent ~0.4 s on rare serves).
- The aim cue is now a line from the hand to a ring where the second bounce is aimed; the ring's depth follows your power while charging.
- The serve contact is applied on the physics tick that reaches it (or by rewinding when latency put it in the past). Bot serving is unchanged.

### 4. Automatic dive returns (`Config.Movement.DiveReturn*`, RallyService `tryDiveContact`, `ShotLaunch.diveReturn/diveMishit`)
- F (left/right/backward), stamina 50, 1.3 s recovery and the animations are unchanged. **No charge, drag or release**: pressing F commits; the server's dive gate cancels any charge (pressAt/stroke) and ends a rally slow motion, marks the incoming ball's swing as used (a stale release can never become a second shot); the client cancels its charge on the lunge and refuses new charges for the whole dive.
- Contact: during the dive's contact window (0.45 s), the FIRST physics tick at which the referee lets you play the ball (your turn, exactly one bounce on your half), the ball is falling or past your end line, inside the dive-extended reach (anchor 3 studs along the dive, radius 9 + 5) and not under/inside the table. No teleport: the launch starts from the ball's real position. One contact per dive and per incoming ball; if the window closes first: "Dive: the ball was out of reach" (counted as unreachable).
- Outcome rolled **once** on the server at that tick (`DiveReturnChance` **0.9**): a defensive return (**Pass 4: now the slowest of `DiveReturnSpeeds` peaking at most `DiveReturnMaxApex` 18 above the table; the values here were** `DiveReturnSpeed` 60, topspin 25, toward the middle at depth 0.6, solved with the shared physics and verified by simulating the flight; slower / more central alternatives if needed) or a physical mishit (`DiveMishitKinds`: long (over-hit at `DiveMishitLongSpeed` 100), wide, net), with "DIVE SAVE" / "DIVE MISHIT" feedback and an impact burst. Unreachable attempts, deliberate mishits and unexpected solver failures are counted separately (`ServerStorage.NotPongRallyDebug`) and logged (solver failures as warnings).

### 5. Clean shots that missed (investigated; ShotLaunch, ShotController, ShotFeedback, TrajectoryArrow, RallyService)
Reproduced with a harness in real rallies against the bot (random stroke, spin, power, positions, still and moving players; releases inside the green window; the arrow captured at the release frame; the server's actual launch re-simulated). Findings on the old code (39 clean shots): no clean shot missed in that sample, but **smash** predictions were 6-13 studs from where the ball really landed (ordinary still shots 0.4-1.7), the arrow had vanished at the release in 5 of 9 moving shots, and in slow motion the arrow showed "clean" for releases the server then judged too early. Causes:
1. **The timing error inside the green window was too steep**: yaw = timing x risk x 6 deg over a +-0.125 s window, i.e. up to 48 deg/s for a full-power shot and **144 deg/s for a smash** (risk x3). The arrow is necessarily a frame old at the release (measured 15-67 ms here), which alone moved a smash's landing by ~10 studs. Fix: `CleanTimingScale` **0.35** (`ShotLaunch.effectiveTiming`): inside the green window only 35% of the timing error counts, ramping continuously to the full error at the weak band's edge (weak/mistimed contacts keep their full risk).
2. **Server and client anchors differed while moving**: the server saw the client-owned root ~0.1 s late, so the contact window's ideal moment, the timing error and the stretch were computed from a different spot; and the client froze its window early. Fix: the client sends its root with each press/release; the server uses it only within `MaxRootMismatch` 6 studs of its own view; the client computes its window exactly like the server (from the snapshot of the opponent's hit, with the current anchor, every frame).
3. **Spin calibration fallback**: when the partly compensated spin had no solution the launch fell back to a spin-free calibration and then flew with full spin. Now the compensation is stepped down in the same spin direction (`ShotSolver.solveWithSpinFallback`).
4. **Slow-motion arrow**: it showed the quality the server estimated when slow motion began; it now judges "release now" on the slowed timeline (the rally slow motion itself is unchanged).
5. **Honest preview**: amber + "RISKY" when the same shot released 0.05 s later (`Arrow.TimingLookahead`) would fail or the landing is within `EdgeMargin` 1.5 studs of a side line / end line / the net line; a changed verdict snaps (no easing from an old path); smoothing 22 -> 35/s.
After the fixes (30 clean shots, both strokes, all spin directions): the arrow showed a landing for all 30, all 30 landed; mean distance between the arrow's predicted landing and the real one: ordinary **1.0** studs, smash **3.5** (was ~7). No random misses were added; risk stays in smashes, stretch, weak timing and extreme spin.

### 6. Shuffle shake (StancePose.start, camera)
- **Diagnosed**: (a) the camera's raw velocity lead (above): the biggest contributor to apparent body shake at reversals (camera acceleration now 308 studs/s^2 max on the same recorded path, was 701; lateral 262, was 629); (b) the footwork smoothed one direction VECTOR, which passes through ~zero in a left/right reversal, where the normalised shares briefly gave the legs to the forward/back clips (replayed on the recorded reversals: up to 53% forward/back share during purely sideways motion) - a leg flick at every reversal.
- **Fixed**: each direction clip's share now eases on its own toward the current direction's share (sum always 1; replayed: <= 29%, from the diagonal moves in the recording); `DirectionRate` 12 -> 15. The low stance, clips, cadence and planting are unchanged. /animate (Blender) was not used this pass: the measured causes were in the blend code and the camera, not the clips.

### Tests
**Automated / scripted in Studio Play** (remotes, `Player.NotPongShotDebug` / `NotPongArrowDebug`, the new `ServerStorage.NotPongRallyDebug`, teleports in the harness only, and real **Space / A / D / S** key presses through Studio's input tool; no real mouse):
- Serve solver sweep (final code, running server): **7290/7290 legal** over heights 6-12.4, 9 spots across the legal region, power 0/0.5/1, aim -1/0/1, 9 spin settings, clean and weak; 89% with the full spin; mean 6 ms, max 122 ms.
- Live serves: 7 in-phase serves (clean and weak, both strokes, centre / both corners / deep, power 0-100%, top/back/side/diagonal spin) all **legal** (Serving -> Rally); swing while rising -> "too early (the ball was still rising)", fault; late -> the client marks it "held past the toss", the toss drops, fault; no swing -> "dropped the serve toss"; 27 more auto-serves in the dive runs all legal.
- Real Space press: release 0.35 s after Space; apex 12.53 above the table; no pause at the apex.
- Serve camera: holds at 18 (17 above the floor), pitch -4.9 during preparation and toss; after the strike rises to 31.3 / -17.2 over ~1.25 s, max 20 studs/s and 49 studs/s^2, FOV 58 throughout; a missed serve keeps the low view through the fault, then rises before the bot's serve; bot serves stay in the rally view.
- Lateral framing (projected): root on screen 0.40 (left wall) .. 0.48 (centre) .. 0.55 (right wall), was 0.33 .. 0.55; both blades and every table corner and the opponent in view from all walls/corners in both framings. Follow at 15/30/60/144 fps: within 0.28 studs (60 vs 144) and 1.2 studs at 15 fps; lag at a full-speed reversal <= 1 stud; overshoot after a stop <= 0.9 (the eased look-ahead).
- Dives, live: **31 dives at balls 12.3-14.8 studs from the normal reach anchor (reach 9)**: 31 eligible, 26 returns (84%), all 26 solved legal and none went out or into the net (each was followed by the bot's return or a pop-up), 5 mishits (2 net, 2 wide, 1 long; each lost the point), 0 unreachable, 0 solver failures. Offline: 600/600 defensive returns legal from random contacts (max 2 ms); after the long-mishit fix every mishit kind misses; the roll split 0.901 over 10,000 rolls.
- Clean shots: before 39 / after 30 (numbers in section 5).
- Interrupted states: respawn mid-toss -> "dropped the serve toss", then the next serve starts with the ball on the new character's palm (0.01-0.03 studs, following while moving); focus loss mid-serve-charge -> charge cancelled, a later release ignored, the toss drops (fault); rally slow motion still triggers in rallies after serves.
- Console clean in every run.

**Visual (stills from the game camera, taken at the end once Studio rendered again; no footage)**: the serve view before the toss (low, near-level, region outline, ball in the left hand; after moving the shoulder offset to 10 the server stands centre-left and the table's right side, net and opponent are clear); mid-toss (ball above the head, paddle cocked, the timing bar's amber/green contact phase with the needle entering it, power charging, the aim line gold once locked); the serve view at the left wall (red outline + reason); the rally view at the right and left side walls (the player just right / left of centre with room on both sides, the whole table and the opponent in view). For most of the session Studio's 3D viewport rendered nothing (UI only), so everything else is numeric.

**Not verified**: anything by eye at full frame rate (camera motion and the serve-to-rally blend, the toss's pace, the footwork at reversals, the amber RISKY state, dive saves); a real mouse; network latency (the root claim and the window match were measured at Studio latency only); a PvP match; the bot's footwork while moving.

### Known issues / notes
- A rare serve solve can still cost up to ~0.12 s of server time (one longer server frame at contact); typical 6 ms.
- The serve contact band (6+ studs above the table) means serves are struck at about head height; lower contacts are "too late". That is a physics consequence of this table's net height and length (measured above).
- The dive count (31) is small for a 90% estimate (84% observed is within the expected spread); the roll itself was checked over 10,000 draws.
- The look-ahead overshoots a stop by up to ~0.9 studs (eased); `MaxLead` / `LeadTime` reduce it.
- Footwork foot-slide could not be measured reliably: Studio ran at ~15 fps in the background.
- `Config.Camera.Smoothing` / `VelocityLead` and `Serve.AimLineLength` are kept as documented legacy values; nothing reads them now.

### Files (this pass)
- Shared: `Config.luau` (Camera follow + Serve framing, Serve toss/contact/solve, Movement DiveReturn*, ShotControl CleanTimingScale / MaxRootMismatch, Arrow honesty settings, Locomotion DirectionRate), `ServeRules.luau` (contact phase, classify, target), `ShotLaunch.luau` (legal-serve solve, dive return / mishit, effective timing, spin-compensation ladder), `ShotSolver.luau` (solveServe flight horizon), `StancePose.luau` (per-direction footwork shares, toss speed, no serve slow-down).
- Server: `RallyService.luau` (serve judging + deferred contact, no serve slow motion, dive commit + automatic contact, root claim, debug bridge), `MovementService.luau` (comment).
- Client: `CameraController.luau` (rewritten follow + serve framing), `ShotController.luau` (dive commit, window like the server, root claim, serve phase), `ShotFeedback.luau` (serve phase bar, dive feedback, honest preview, slow-motion verdict), `TrajectoryArrow.luau` (RISKY state, snap on verdict change), `ServeInput.luau` (aim ring, no slow motion), `BallView.luau` (hand fallback).

### Manual playtest checklist
1. Rally: walk/shuffle to both side walls and the back corners: the avatar stays near the centre with room on both sides; quick A/D reversals: no camera lurch, no leg flick.
2. Your serve: the camera lowers before the toss; Space: a gentle toss; click after the ball leaves the hand, release as it falls past head height: legal serve, then the camera rises. Try early (still rising), late (low), no swing, the corners, full power and spins. The ring shows where the second bounce goes.
3. Dives: F with A/D/S at a ball you cannot reach: automatic return (mostly legal), no clicking; a charge in progress is dropped.
4. Clean shots: watch the arrow: amber "RISKY" means a slightly later release fails; green shots should land.

## Pass 4: safe serve curves, Q serving posture, court-position serve camera, defensive dive lobs, solver cost, new table (2026-11-17, awaiting your review)

Requested in chat. Kept unchanged: no serve slow motion, the natural toss, the forgiving contact rule, rally slow motion, trajectory/timing guidance, the clean-shot fixes, the footwork and camera follow, scoring, lets, rotation, bot serving. Not added (as asked): long-rally speed escalation, practice challenges, opponent windup telegraphs (kept in `docs/Not pong obsidian vault/future ideas.md`).

### Controls now (superseded controls marked)
| Control | Now | Before |
|---|---|---|
| **Q** (your serve, ball in hand, before Space) | toggles the serving posture: **LeftLead** (left hip toward the table = forehand serve) / **RightLead** (right hip = backhand serve). Remembered for your next serve | (unbound) |
| **Space** | tosses and **locks the posture** for that serve (Q does nothing during the toss and the stroke) | tossed |
| Serve stroke | **from the posture** | was the cursor's screen side at the press (superseded) |
| Cursor (serve) | aim only (where the second bounce goes) | aim + stroke |
| Rally forehand/backhand | unchanged: the cursor's screen side | |
| F (dive) | unchanged; the return is now a slower, higher defensive lob | flat return at 60 studs/s |

### 1. Serve curvature: the safe serve envelope (`ShotLaunch.serveEnvelope`, `Config.Serve.Envelope`)
- **Measured problem**: checking only the first two bounces let **785 of 1458 legal test serves (54%)** leave over the receiver's side line after their receiver-side bounce (sideways : forward speed up to 8.6 : 1), even 36 spin-free ones from wide spots aimed wide.
- **Envelope (testable, ball-centre values; the whole predicted flight with the shared physics)**: E1 legal (own half, then the receiver's); E2 the receiver-side bounce at least `BounceMargin` 1.5 inside the side lines, and from there to the receiver's end-line plane the centre stays `SideMargin` 0.75 inside the side lines (a slow serve may bounce again on their half; leaving by the floor/table side first = escape); E3 right after that bounce sideways speed <= `MaxLateralRatio` 0.6 x the speed toward the end line; E4 playable: horizontal speed after that bounce <= `MaxReceiveSpeed` 85 and it crosses the end-line plane <= `EndLineMaxHeight` 19 above the floor.
- **Before contact, never after**: the aimed second bounce is first shifted against the predicted post-bounce drift (`CompensationSteps` 2, `CompensationGain` 0.9) with the full spin; then the sidespin steps down (`SideSpinLadder` 1 / 0.7 / 0.45 / 0.2; topspin/backspin kept); then the aim eases toward the centre; last a spin-free centre serve. The forgiving rule is kept: an in-phase contact always gets a legal, safe serve.
- **Result** (1458 serves: 3 heights x 6 spots x power 0/0.5/1 x aim -1/0/1 x 9 spins): **1458 inside the envelope**; after the receiver bounce max sideways ratio 0.60, max speed 63, apex 2.3-6.9 above the table; 394 of 972 sidespin serves kept the full sidespin, the rest a reduced curve (median bend ~2.2 studs from the straight line, earlier run); 41 (2.8%) ended as the spin-free centre serve (10 from the budget).
- **High serves**: solved player serves bounce at most ~7 above the table after the receiver bounce, under the 7.5 smash height, so none are smashable in practice; there is no serve exemption in the smash rules (any eligible high ball, serve or not, is smashable).

### 2. Q serving posture (`Config.Serve.Posture`, ServeInput, StancePose layer, ServeRules, RallyService)
- Moderately side-on: the hips turn `HipYaw` 25 deg (the legs turn with them about the vertical; feet stay on the floor), the chest keeps `ChestFollow` 0.4 of it, the neck turns the rest back. Measured on your avatar: hips -24 / +26 deg, head within 1.4-1.8 deg of straight at the table, both feet at the floor (1.00). Fades while walking (pre-toss repositioning), blends in/out over `BlendTime` 0.25 s, held `FollowThroughHold` 0.6 s after the strike, then back to the ready stance. Rallies never show it.
- The server receives the posture with the toss request, validates it and locks it; the serve stroke (contact anchor, strike animation) comes from it. The hand's hold/release point is turned with the chest on both server and client (`ServeRules.handPoint(..., posture)`), so the legal-region check and the toss start from the visible hand: measured palm vs model 0.32-0.34 studs in both postures (1.1-1.2 without the correction).
- /animate (Blender) was not needed: the posture is an additive layer on the existing toss / strike / stance clips (the same clips play in both postures).

### 3. Serve camera offset from court position (`Config.Camera.Serve.LateralOffset` 10 / `CenterBlend` 12 / `OffsetSmoothTime` 0.3)
- Replaces the fixed right offset: offset = LateralOffset x f(courtX / CenterBlend), f(u) = u(3 - u^2)/2 clamped (smooth, no flip at the centre), courtX = the followed root X relative to the table centre, mirrored for the other end; then a critically damped spring. Q never affects it. Measured: offset +-10 / +-6.9 / +-2.5 at court x +-20 / +-6 / +-2 (identical mirrored); camera X - root X at the left limit -7.96 (both postures), centre +3.62/+3.63, right limit +7.17 (both). Head-height serve view, follow distance and the blend into the rally framing unchanged.

### 4. Defensive dive returns (`Config.Movement.DiveReturnSpeeds` / `DiveReturnMaxApex` / `DiveSolveBudget`)
- The slowest of 46 / 52 / 58 / 64 / 72 / 80 studs/s (horizontal) that lands legally and peaks at most 18 above the table; topspin 5, depth 0.7. A single slow speed was tried first and rejected: 46 studs/s had to arc 25-50 studs high against drag and cost up to 0.68 s to solve.
- Measured (400 random contacts incl. 213 wide/deep): **400 legal**, apex 14.1-23.9 (median 16.9) above the table, 0.87-1.27 s to the opponent's bounce, solve <= 15 ms. Rolls (0.9), one contact per dive, no contact in the get-up: unchanged.

### 5. Serve-solver cost
- Inner solves bounded (`SolveCost`: 14 iterations, 2 speed retries, 0.15-stud tolerance, 10 bisection steps), the costly scan only when the bisection found nothing legal, a result cache (quantized inputs, re-validated against the exact contact), and `SolveBudget` 0.035 s before the spin-free fallback. Measured: worst **42 ms** (was 122), mean 8.6 ms.

### 6. New table and net (concept image `docs/Not pong obsidian vault/ping-pong-table-concept.png`; reference frames from the video)
- Built with the Blender MCP in a separate scene (your open `tableTennisTable.blend` was not saved or changed; the temporary scene was removed). Source: `assets/table/NotPongTable_v2.blend` (editable, this table only); import file `assets/table/NotPongTable_v2.fbx`; uploaded with your API key as model asset **100478979603787** (an earlier version, 106257705592531, is unused; delete it in Creator Hub if you like).
- Parts (`Workspace.NotPongArena.Table.Visual.TableAsset`): `Top` (red-orange slab) and `Lines` (white edge + centre lines) structural Top zone; `EdgeBand` (thick charcoal band, cosmetic); `Legs` (two end frames: legs splaying out onto chamfered floor beams, cosmetic); `NetMesh` (thick dark strands, **2 rows x 35 columns of 0.91 x 0.91 openings, strands 0.20**, structural Net); `NetTape` (white top bar = the net top and the gameplay net length, structural); `NetPosts` (posts, arms, clamps, cosmetic). Openings are smaller than the 1.5-stud ball; the ball's net collision is still `TableWorld` (unchanged).
- Fitted with the existing workflow (`prepareTableAsset` + `fitTableAsset`): surface 9.740 (Config 9.74), net top 12.371 (Config 12.371), bar length 39.761 = net length, net at the table centre line, legs on the floor; `validateTableAsset` and `validate` 0 problems; no re-fit warning at Play; one TableAsset. Appearance is yours to edit (colours/materials persist).
- Backup: `ServerStorage/NotPongBackup_2026-11-17/TableAsset_previous` (your previous navy table, unchanged) + README with restore steps.
- **Save the place** to keep the new table (it lives in the Edit data model; nothing was published or saved by me).
- Reference findings vs assumptions: the video (640x360) shows a terracotta top, deep dark apron, slanted dark legs on a floor rail, dark square posts and a light net of ~6 rows; its strand thickness and under-table construction are not readable. The final look follows your concept image, not the video, where they differ (dark strands, 2 rows).

### Tests
**Automated / scripted in Studio Play** (debug bridges, remotes, teleports in harnesses; real **Q and Space** presses; no real mouse):
- Serve envelope sweeps above; dive sweeps above; solver cost above.
- Q: LeftLead/RightLead toggled by the real Q key; the stroke followed the posture with the cursor on the opposite screen half (LeftLead + cursor left -> forehand; RightLead + cursor right -> **backhand**, server agreed, legal serve); Q during the toss refused (real key + debug path); posture locked.
- Camera offsets (above), both postures at the left limit, centre and right limit.
- Table: alignment, persistence across Play/Stop, single asset, console clean.
- Console clean after fixing two errors introduced and caught this pass (a camera field shadowing the new offset function; a posture variable declared after use).

**Visual (stills from the game camera)**: the new table and net in the serve view and the rally view (the dark two-row grid and the white bar read clearly at both distances; the posture visibly turned in the serve view; the posture hint).

**Not verified**: anything at full frame rate (camera motion with the court offset, the posture blend into toss/strike, net shimmer during camera movement: only stills were possible); a real mouse; the hand/ball release jump in motion (~15 fps capture could not resolve it; held-ball accuracy 0.32-0.34 studs); a match against the bot with the new serves end-to-end by a person.

### Known issues
- Serve: 59% of sidespin serves have their sidespin reduced to stay inside the envelope; 2.8% fall back to a spin-free centre serve. Loosen `Envelope.SideMargin` / `MaxLateralRatio` for more curve.
- No player serve is high enough to smash.
- The posture is a local additive layer: other clients would not see it (single-player today).
- Dive lobs are not slow in horizontal speed (58-80): deep contacts need it against drag; the defensive character comes from the height and flight time.
- Bot pop-ups: your log shows frequent "too early (ball not in reach yet)" swings at the bot's high pop-ups (observed, not investigated this pass).

### Files (this pass)
- Shared: `Config.luau`, `ShotLaunch.luau` (serveEnvelope, serve ladder/cache/budget, diveReturn), `ShotSolver.luau` (cost bounds), `ServeRules.luau` (posture, posture-aware hand point/check), `StancePose.luau` (posture layer).
- Server: `RallyService.luau` (posture lock, stroke from posture).
- Client: `ServeInput.luau` (Q, posture lock, hints), `ShotController.luau` (serve stroke override), `StanceController.luau` (posture), `CameraController.luau` (court-position offset).
- Assets: `assets/table/NotPongTable_v2.blend`, `assets/table/NotPongTable_v2.fbx`. Studio: new TableAsset, backup folder.

### Manual playtest checklist
1. Your serve: Q a few times before Space (hips switch, head stays on the table, feet planted); Space, then Q (nothing happens). Serve with the cursor on either side: the stroke follows the posture.
2. Serve from the left, centre and right: the camera favours your left / is balanced / favours your right, sliding smoothly as you walk; Q never moves it.
3. Strong sidespin serves (drag left/right): a visible curve, then the ball heads to the bot's end, not out over the side.
4. Dive (F) at a far ball: a high, slower lob that lands on the bot's half.
5. Look at the new table and net during rallies and serves: do the squares read, any shimmer? Recolour anything in Studio if you like, then **save the place**.

## Pass 5: hybrid footwork, detailed larger paddle, cursor-side holding lean (2026-11-17, awaiting your review)

Kept unchanged: WalkSpeed, acceleration, WASD, platform bounds, ball physics, swing timing, camera, the ready stance's lower body and posture, the serve system (Q posture still decides the serve stroke), rally slow motion, dives.

### 1. Why the legs micro-stepped (measured)
The shuffle clips moved the body only 1.5 block-rig studs per cycle (5.1 studs on the 3.37x avatar). The cadence correctly followed the real speed, so at 24 studs/s the legs ran ~4.75 cycles a second, ~9.5 foot movements a second. Slowing the playback alone would have made the feet skate.

### 2. Hybrid footwork (`/animate` kit + `Shared/StancePose.start`, `Config.Stance.Locomotion`)
- New clips, built headlessly with the /animate kit (`kit/run.py make`, recipe `anims/_notpong.py`: `side_pose`, `cross_pose`, `step_pose`; your live Blender untouched), converted with `tools/anim_to_luau.py` into `NotPongAnimData.luau` (16 clips):
  - `NP_ShuffleRight/Left`: step-out-and-close, **1.7 studs per cycle**, feet from 1.3 (closed) to 3.0 (open) apart, never crossing; CHECKS all clear.
  - `NP_CrossRight/Left` (new): the trail leg crosses **in front**, the lead leg steps out behind it, hips open 16 deg toward travel, **3.0 per cycle**; one frame where the lower legs brush (~0.2 studs) at the crossing.
  - `NP_ShuffleForward/Back`: controlled walking steps, 2.6 per cycle, knees bent, no run bounce.
  - Unchanged: `NP_Ready` (idle legs), `NP_Run*` (Shift), dives, serve clips. `NotPongReadyStance` / `NotPongSwing` tracks unchanged (the legacy `NotPongReadyStanceLegs` builder is still unused).
- Transition: sideways movement in one direction for `CrossoverAfter` 0.22 s above `CrossoverMinSpeed` 16 studs/s blends the crossover in (`CrossBlendIn` 9/s); it stays until the sideways speed drops below `CrossoverExitSpeed` 8 (hysteresis), blending out at `CrossBlendOut` 12/s; a reversal caps it at `ReversalCrossCap` 0.2 at once, so quick A/D plays as a direction-change shuffle step. Repeated taps never reach the threshold. The body's movement is never delayed (only the clip choice changes). Stopping settles into the ready stance (`StopRate`). Diagonals blend the direction clips' shares.
- Cadence: one cycle clock = real speed / (the blended `Stride` x the avatar's scale) x `PlaybackScale`, clamped `MinCycleRate` / `MaxCycleRate`; every clip's planted foot moves back exactly as fast as the body moves on, so feet do not skate.
- Player and bot: the same controller (client for the player, server for the bot), the same clips and settings.
- **Make it more / less exaggerated**: `Stride.*` (bigger = longer, fewer steps; must match the clip, rebuild it in the kit if you change the shape), `CrossoverAfter` / `CrossoverMinSpeed` (crossover sooner/later), `PlaybackScale` (cadence), the kit constants `SIDE_NARROW/SIDE_WIDE`, `CROSS_*`, `STEP_STRIDE_*` for the shapes.
- Measured with real A/D/W/S keys (60 fps): taps 0.55-0.75 cycles of shuffle, no crossover; holding A or D: crossover above 0.5 after 0.32 s, ~2.4 cycles/s once crossing (was ~4.75), 2.9-3.1 averaged over the 1.2 s hold; rapid A/D switching: no crossover; W 2.5 cycles/s; S was 3.9 cycles/s and its stride was lengthened from 2.2 to 2.6.

### 3. Detailed larger paddle (`Workspace.NotPongArena.PaddleTemplate`)
- Built with the Blender MCP in a temporary scene (removed; your file not saved): `assets/paddle/NotPongPaddle_v2.blend` (editable) + `.fbx`, uploaded with your API key as asset 99034390255354. Zones = separate MeshParts: `FrontRubber`, `BackRubber`, `WoodBlade` (core, layered edge, throat), `Handle` (grip), `EndCap`. Blade 4.16 x 4.30 (1.3x the previous 3.2), rubbers inset 0.05 so the wood edge shows; handle 1.75 (fist-sized, not scaled). The `Grip` attachment copies the old one's pose relative to the blade/handle, so it sits in the hand the same way. Previous template backed up in `ServerStorage/NotPongBackup_2026-11-17/PaddleTemplate_previous`.
- **Customization workflow** (cosmetic only, no stats): each zone's `Color` + `Material` + a `SurfaceAppearance` named `Pattern` with `AlphaMode = Overlay` and a `ColorMap`: transparent texels show the part's Color, so colour and pattern are independent, and any rubber design works with any grip design. (A plain `TextureID` ignores Color: tried and replaced.) Pattern library (`tools/paddle_patterns.py` -> `assets/paddle/patterns/*.png`, uploaded as Images): pips 110926290854873, geometric 133124499125419, grip stripes 125416236478404, grip chevron 89658614787064, wood plies 101915834660786. UVs: rubbers planar across the blade; wood edge u around / v across the thickness; handle u around / v along. Edit the **template** (it is cloned onto the player and the bot at Play; verified: one paddle each, the template's colours and patterns on both, persisting across Play/Stop).

### 4. Contact area follows the blade (`Config.Paddle.BladeScale`, `Config.ShotControl.ArmReach`, end of `Config.luau`)
- Hit detection is a horizontal radius around the stroke's reach anchor (not paddle-part collision). It is now split into `ArmReach` 7.4 (fixed) + `BladeContactRadius` = `BaseBladeRadius` 1.6 x `BladeScale` 1.3 = 2.08, so `PaddleReach` = **9.48** (was 9): the contact area grows by exactly the blade's growth; the arm's reach is not multiplied. The bot's reach grows by the same 0.48 (8.48). Serves, returns, smashes, backhands and dives all use it.
- Approximation and its limits: a circle around the anchor, not the blade's shape or orientation (the wrist lean does not move the contact area); an exact blade-shaped swept test would need a new hit system.
- Measured: a ball 9.47 from the anchor is in reach, 9.49 is not; a pass whose closest point is 9.43 can be hit, 9.53 cannot (the old 9.00 refused both).
- Keep them aligned: change `BladeScale` AND resize the template's rubbers/blade (not the handle) by the same factor; PaddleFactory warns at Play if the template's blade width disagrees.

### 5. Cursor-side holding lean (`Config.Stance.RightWrist`, `Config.Stance.Backhand.RightWrist`)
- The wrist is part of each stroke's ready pose (the stance track owns it; the swing leaves it unkeyed, so the lean carries through the swing; serve and dive clips own the arm while they play). So it follows the cursor side while idle, locks at charge start, ignores the drag, and switches after recovery, exactly like the stroke; the stroke cross-fade (`StrokeBlendTime` 0.12 s) blends it; `StrokeDeadZone` keeps the side at the centre.
- Measured from the rally camera: forehand lean ~5 deg before -> **+33 deg** toward the right (face square to the table, 0.99); backhand ~49 deg -> **-31 deg** toward the left. 10 quick cursor crossings inside the dead zone: 0 stroke changes. A charge started on the right stayed forehand (locked) while the cursor was dragged to the left (the drag still made sidespin); the stroke updated once the stroke ended.
- Serve: the Q posture keeps deciding the serve stroke (and so the lean); the cursor cannot override it during the toss.
- Bot: picks forehand/backhand from the predicted contact's side relative to where it will stand (`BotController:setStroke`); it usually positions for a forehand.
- No gameplay effect: launch direction, spin and contact are unchanged by the lean.

### Tests
**Automated / scripted (Studio Play; real A/D/W/S keys; debug bridges)**: footwork scenarios 1-8 above (numbers in section 2); paddle presence/zones on player and bot; reach boundary; lean angles and lock/dead zone; customization persistence across Play/Stop; console clean.
**Visual (stills from the game camera)**: the larger paddle with the forehand lean in the serve view; a crossover stride frame while holding D; the back rubber's geometric pattern tinted blue (overlay working).
**Needs your manual check in Studio**: the motion itself at full speed (crossover look, stop settle, reversal step, diagonals, swinging while moving, scenario 10), the bot's footwork while it moves (scenario 11), foot sliding by eye, smash/dive clipping with the bigger blade, real-mouse feel.

### Known issues
- The crossover's lower legs brush (~0.2 studs) on the crossing frame.
- The pattern textures were in Roblox moderation review when applied; an unapproved one renders plain until approved.
- Contact area is a circle (see section 4).
- **Save the place** to keep the new paddle template and its patterns (Edit data model).

### Files (this pass)
- Shared: `Config.luau`, `StancePose.luau`, `NotPongAnimData.luau` (regenerated). Server: `PaddleFactory.luau`, `Stance.luau`, `BotController.luau`. Client: `StanceController.luau`, `ServeInput.luau` (debug only).
- Kit: `anims/_notpong.py`, `anims/NP_ShuffleRight/Left/Forward/Back.py`, new `anims/NP_CrossRight/Left.py`.
- Assets/tools: `assets/paddle/NotPongPaddle_v2.blend/.fbx`, `assets/paddle/patterns/*.png`, `tools/paddle_patterns.py`.

### Manual playtest checklist
1. Tap A / D: one controlled shuffle step. Hold A / D: it develops into crossover strides; release: feet plant, back to the ready stance. Quick A-D-A-D: shuffle steps, no crossover. W / S / diagonals.
2. Move the cursor left/right while idle: the paddle leans ~30 deg toward that side. Charge, drag across the centre: the lean stays; it switches after the stroke.
3. Q before your serve: the serve stroke follows the posture whatever the cursor does.
4. Edit `PaddleTemplate` zones (Color, Material, the `Pattern` SurfaceAppearance's ColorMap) and press Play: both paddles show it.

## Pass 5b: paddle v3 from the build guide (2026-11-16, awaiting your review)

Requested in chat with `docs/Not pong obsidian vault/paddle design2.png` as an appearance guide: keep the blade size and hit area, shorter handle that fits the avatar's hand, thicker blade with visible plies and separate rubber faces, fine rubber texture instead of the coarse dots, better wood grain / bevels / grip edges, front, back and handle independently customizable. **Supersedes Pass 5 section 3's paddle description** (zones, handle length, pattern IDs); the customization workflow (Color + Overlay SurfaceAppearance) is unchanged.

### What was inspected first
- v2 template: blade 4.16 x 4.30 (rubbers 4.06 x 4.20 inset 0.05), wood 0.12 thick at the blade (rubbers at +/-0.06..0.12), handle 1.75 + end cap 0.20 (blade edge to cap end 2.35 = 0.55 of the blade height), `Grip` at Handle-local (0, -0.447, -0.048).
- The avatar's block hand is 3.37 x 1.01 x 3.37 studs and the handle runs through its 3.37 depth: the fist covers Handle-local y -2.42..1.03, i.e. **the whole v2 handle and cap were already inside the fist**; only the blade (from y 1.275) shows. Any handle under ~3.4 studs is hidden in the hand, so "fits the hand" = the grip point stays inside the handle and the blade starts clear of the fist.

### Paddle v3 (`Workspace.NotPongArena.PaddleTemplate`)
- Source: `tools/build_paddle_v3.py` (run inside Blender; builds in a temporary scene, writes `assets/paddle/NotPongPaddle_v3.blend` + `.fbx`, removes the scene). Uploaded as Model asset **105684859632328**. All dimensions are constants at the top of the script.
- Zones (separate MeshParts): `FrontRubber`, `BackRubber` (top sheets 0.03, rounded outer edge, inset 0.015), `Sponge` (both layers, 0.035 each), `WoodBlade` (outer plies, 2 x 0.09, two plies each via the texture's glue line), `WoodCore` (centre ply 0.08, darker), `Handle` (flared grip), `EndCap`. Edge from the back: black rubber, sponge, ply, ply, core, ply, ply, sponge, red rubber; total thickness 0.39 (wood 0.26, was 0.12).
- Blade outline unchanged (ellipse 4.16 x 4.30, same centre): `WoodBlade.Size.X` = 4.16, so the BladeScale check and the 9.48 contact radius are unchanged. No gameplay value was touched.
- Handle: shortened from the bottom, blade edge to cap end **2.025** (was 2.35; 0.47 of the blade height, "about half the blade" per the guide); waist 0.62, flaring to 0.78 at the cap and 1.30 where it meets the blade (top follows the blade outline); cap 0.13. The blade's placement in the hand is unchanged: the `Grip` attachment keeps the same world pose (now Handle-local (0, -0.826, -0.048) because the Handle part's centre moved), measured identical to 1e-6. The grip point sits 0.21 above the handle bottom; the fist still covers the handle; the flare and blade come out of it.
- Bevels: rubbers 0.014 rounded edge, plies 0.005-0.012 (a visible groove between plies), sponge 0.003; handle is a smooth superellipse loft.
- Default looks: FrontRubber red (205, 35, 30), BackRubber charcoal (45, 45, 50) (it was blue only as the Pass 5 customization test), Sponge cream, wood light / core darker, Handle wood with blue + charcoal inlays, EndCap dark.

### Textures (`tools/paddle_textures_v3.py`, 1024 px, uploaded as Images)
| Texture | Asset | Used on |
|---|---|---|
| rubber_grain (overlay) | 101271327264461 | FrontRubber, BackRubber, Sponge ColorMap |
| rubber_grain_normal | 121467049606766 | FrontRubber, BackRubber NormalMap |
| rubber_rough | 83627610964601 | rubbers, Sponge, WoodBlade, WoodCore RoughnessMap |
| wood_grain (overlay, ply glue lines) | 136918838472101 | WoodBlade, WoodCore ColorMap |
| wood_grain_normal | 80670354954243 | WoodBlade, WoodCore NormalMap |
| grip_stripes_v3 (crisp flush inlays + lengthwise grain) | 76180200532344 | Handle ColorMap |
| grip_chevron_v3 (alternative grip) | 116049682878676 | not applied (swap into Handle.Pattern.ColorMap) |
UV conventions are in the generator's docstring (rubbers planar across the blade; wood edge u around x6, v across the wood thickness with glue lines at v 0.173/0.346/0.654/0.827; handle u around with 0.25 = front face, v along with 1 = top). They were "Reviewing" in moderation when applied; they render in your Studio already.

### Backups / cleanup
- v2 template moved to `ServerStorage/NotPongBackup_2026-11-17/PaddleTemplate_v2` (README updated); `PaddleTemplate_previous` (v1) still there. The temporary import and preview copies were deleted.
- **Blender crashed once** during the first export attempt (exporting from a scene the window wasn't showing; crash log `%TEMP%\tableTennisTable.crash.txt`). Blender reopened from its 2:58 PM autosave of your table file; your `tableTennisTable.blend` on disk was not written (last saved 11/15). The script now shows its own scene during the export and switches back. I did not save any Blender file of yours.

### Tests
**Scripted (Studio)**: part sizes/offsets against the Blender geometry (all 7 within 1e-4); Grip world pose unchanged; Play x2: player and bot each have one paddle with all 7 zones and their SurfaceAppearances, collision/query off, the template's later colour edits on both (persistence across Play/Stop); no PaddleFactory blade-scale warning; console clean.
**Visual (stills)**: Blender material previews (front, back, edge, three-quarter, handle and ply close-ups); Studio front, back, edge close-up, handle/flare close-up; in hand from the side (edge, flare leaving the fist) and from the front.
**Not checked**: the paddle during a full rally / swing / dive at speed (clipping with the thicker edge), how the textures look after moderation if any is rejected.

### Files
- New: `tools/build_paddle_v3.py`, `tools/paddle_textures_v3.py`, `assets/paddle/NotPongPaddle_v3.blend/.fbx`, `assets/paddle/patterns/{rubber_grain, rubber_grain_normal, rubber_rough, wood_grain, wood_grain_normal, grip_stripes_v3, grip_chevron_v3}.png`.
- Comments only: `server/Server/PaddleFactory.luau` (zone list), `shared/Shared/Config.luau` (BladeScale retune note).
- Studio (unsaved until you save): `NotPongArena.PaddleTemplate` replaced; backup folder.

## Pass 5c: rubber shape, edge band, plain colours, backhand face flip (2026-11-16, awaiting your review)

Requested in chat with the "rubber shape & edge band" sheet. **Supersedes Pass 5b's zones, textures and default looks** (the v3 blade outline, thickness, handle and grip are kept) and **Pass 5 section 5's backhand pose values**.

### Paddle v4 (`Workspace.NotPongArena.PaddleTemplate`)
- Source `tools/build_paddle_v4.py` (Blender, temporary scene) -> `assets/paddle/NotPongPaddle_v4.blend` + `.fbx`, Model asset **116550750298564**. v3 backed up as `ServerStorage/NotPongBackup_2026-11-17/PaddleTemplate_v3` (v2 and v1 still there).
- **Rubbers**: both faces have a flat lower edge at 0.46 studs above the blade's bottom with 0.34-radius rounded corners (`RUB_FLAT_Z`, `RUB_CORNER`); the wooden shoulder above the handle is exposed. The wood outline is unchanged (ellipse 4.16 x 4.30); only the rubber is trimmed. The sponge is now part of each rubber sheet (0.065 thick), so the total stays 0.39 (wood 0.26).
- **Edge band**: `EdgeBand` is the centre layer of the blade, 0.07 thick (27% of the 0.26 sidewall), so from outside it is a black band centred on the edge with 0.095 of wood visible on each side. Started at 1/3 (0.09) and narrowed after a true side view (the reference's stripe is narrower than each wood layer). It follows the blade outline and stops where the handle meets the blade.
- **Handle**: same length and width profile; its top now thins to the wood thickness so the flare runs flush into the exposed shoulder.
- **Plain colours, no textures**: every zone is SmoothPlastic with its own Color: FrontRubber red (200, 30, 28), BackRubber black (28, 28, 30), WoodBlade and Handle light tan (232, 196, 146), EdgeBand (22, 22, 24), EndCap (40, 40, 44). No SurfaceAppearance, Texture or Decal on any zone (also checked on both runtime paddles). The texture assets from v3 remain uploaded and their generators remain in `tools/`, unused.
- **Customizing later**: change a zone's Color/Material, or add a `SurfaceAppearance` to that one zone (AlphaMode Overlay keeps its Color under transparent texels). UVs are kept: rubbers planar across the blade; wood/band sidewall u around, v across the wood thickness (band v 0.365-0.635); handle u around (0.25 front) / v along.
- **Import note**: this upload came into Studio rotated 180 deg about the vertical, which put the red rubber on the paddle's -Z side; fixed by placement (red at +Z as in v3) and checked in Play by geometry (which side the red part is on), not by name.

### Backhand face flip (`Config.Stance.Backhand`, `Config.Swing.Backhand`, `StrokeBlendTime`)
- Measured first: the grip puts the blade's face normal roughly along the forearm. Forehand (baseline, unchanged): red face toward the table 0.97, the camera sees the black face. The old backhand still pointed the red face forward-left (0.60), so the camera saw black in both.
- New backhand ready pose (forward kinematics on the avatar's real joint attachments, verified to 0.0000 studs against the live paddle, with clearance checks for blade, hand and forearm against torso/head/upper arm, also through the cross-fade): shoulder (50, 71, 2), elbow (71, -83, 0) (forearm pronated), wrist (-17, 19, -39), torso twist 36. Elbow up in front of the right chest, forearm across the body, wrist cocked. The paddle stays on the same hand and grip.
- Measured live (bot serving, gameplay camera): forehand -> camera sees **black**, red toward the table 0.97-0.98, lean 33-36 deg right; backhand -> camera sees **red** (0.73), black toward the table 0.82, lean 27 deg left, blade 3.2 left / 3.2 up / 6.5 forward of the root (backhand reach anchor is 4 left).
- Transition: `StrokeBlendTime` 0.12 -> 0.2 s; sampled every frame: the face turns over smoothly in ~0.2 s (largest step 13.6 deg / 1.28 studs per frame at ~60 fps), grip attached throughout.
- Backhand swing re-solved for the new base (back = wound left, strike in front with the black face to the table, follow up and right); played live: no blade contact with the body on any frame.
- Smash: always used the forehand arm; it now also keys the forehand wrist (`StancePose.buildSwing`), so the flipped backhand wrist never twists the blade on the forehand arm.
- Rules unchanged: cursor left = backhand, right = forehand; locked at charge start (tested: pointer moved left and a left drag (sidespin 90) while charging kept forehand / black), updated after the stroke (switched to backhand / red after release); during your serve the Q posture decides (a live serve was logged "forehand" with the cursor on the left).
- Gameplay unchanged: hit detection is the same reach circle; no launch, power or spin value reads the wrist or the paddle parts.

### Tests
**Scripted (Studio Play)**: face seen by the gameplay camera per stroke (geometric normal, red side found by position); transition per-frame sampling; charge lock + drag; backhand swing, forehand swing and backhand-held smash with per-frame blade-vs-body checks; a legal player serve (toss + strike); player and bot paddles = 6 v4 zones, no texture layers; console clean.
**Visual**: Blender material previews of v4: front, back, true side close-up (black rubber / wood / band / wood / red), three-quarter, shoulder and handle. **Not captured**: Studio views and in-hand / transition stills: Studio's 3D viewport stopped rendering during this pass (Edit and Play showed only UI); the in-hand results above are measurements.
**Not re-tested live**: dives (two scripted attempts missed the live-rally window; nothing in the dive path changed: the dive clips own every joint); the bot holding a backhand (it uses the same Config pose; verified only through the shared code).

### Known issues
- A smash taken while the stance shows the backhand jumps to the forehand side at the start (existing behaviour: smashes always use the forehand arm), now more visible because the backhand arm is turned.
- Studio's viewport not rendering: bring the Studio window forward / restart Studio, then check the views in the checklist.
- **Save the place** to keep the v4 template (Edit data model).

### Files
- New: `tools/build_paddle_v4.py`, `assets/paddle/NotPongPaddle_v4.blend/.fbx`.
- `shared/Shared/Config.luau` (Stance.Backhand, StrokeBlendTime, Swing.Backhand, BladeScale note), `shared/Shared/StancePose.luau` (smash keys the forehand wrist), `server/Server/PaddleFactory.luau` (comment).

### Checklist
1. Template views: front (red, flat lower edge, tan shoulder), back (black), side (black band centred, wood both sides), three-quarter.
2. Rally: cursor right -> forehand, you see the black face; cursor left -> backhand, the paddle turns over and you see the red face; the switch is a smooth ~0.2 s turn.
3. Charge on one side, drag across: no flip until the stroke ends. Q before your serve still decides the serve stroke.
4. A dive and a smash from the backhand side.

## Pass 6: click-and-flick rally (2026-11-17, awaiting your playtest)

Requested in chat: player-controlled movement, mouse-positioned paddle preparation, click-to-commit aiming and a timed flick for power and spin; reach + timing decide contact; the arm visibly meets the ball. Your decisions (asked first): **serves use the flick too**; the **F dive and its automatic return are replaced by a contextual emergency save** inside click-and-flick (details below); **rally slow motion is off** for now. **Supersedes** every earlier section about hold-to-charge, drag-to-spin, release-to-strike, the charge slow motion trigger, the F dive / automatic dive return / dive mishits, and the serve's hold-to-charge strike.

### Architecture (one input path)
- **Prepare** (no button): the cursor's absolute screen position (`ShotInput.prep`; `GetMouseLocation` / `ViewportSize`, both over the whole window incl. the top-bar inset, recomputed every frame) gives the stroke (left of the dead zone = backhand), the **base aim** across the opponent's half (-1..1, `Config.Prep.AimHalfSpan`) and the **profile** (higher on the screen = higher arc, lower = low drive; `ProfileTop` / `ProfileBottom`).
- **Commit** (a fresh left press): snapshots stroke, aim, profile and the paddle preparation; holds the mouse in place (`MouseBehavior.LockCurrentPosition`, released on release / swing / reset) so the cursor never drifts, screen edges never stop a flick and preparation cannot change; starts a fresh `Shared/FlickGesture` detector fed only with relative movement after the press. Holding never adds power. Movement is never touched.
- **Flick** (while holding): one recognised flick = one swing request; release without a flick = cancel (no request); after a swing a fresh press is needed (a held button never re-commits).
- **Server** (`RallyService.judgeRally` / `judgeServe`): validates seat, duplicate seq, rate limit, finite values and a plausible flick (`ShotInput.validateFlick`: rejected, never clamped into a shot), recomputes power / spin from the raw measurements (`ShotInput.flickShot`), judges the contact moment = flick start + `Flick.ContactDelay` (serve: + `Serve.HitDelay`, the same 0.07 s) against the incoming ball's window from the player's real position (`ShotInput.contactWindow` / `classify`), one swing per ball / toss, and launches with `ShotLaunch` (locked base aim + profile) on the physics tick that reaches the contact (`pendingContact`) or by rewinding to it. The client never sends a power, velocity, contact point or target.
- **Removed legacy paths**: hold-to-charge (`ShotLaunch.powerFromHold`, `ChargeTime/ChargeExponent`), drag spin (`ShotInput.dragToSpin/clampDrag`, `Spin*` drag settings), release-to-strike and auto-release, the `ChargeStart` remote and press tracking, the charge slow-motion trigger (`trySlowMotion`; the slow-motion plumbing stays, `ChargeFreeze.Enabled = false`), the F dive (`MovementService.requestDive`, `DiveRequest`, the dive gate, `tryDiveContact`, `ShotLaunch.diveReturn/diveMishit`, `Config.Movement.Dive*`, `DivePose`, the dive clips and `StancePose.dive`), the client's charge prediction / slow-motion prediction, the "release now" arrow and the charge meter.

### Gesture recognition and contact timing (`Shared/FlickGesture`, `Config.Flick`)
- Distances / speeds in **reference pixels** (screen px x 1080 / viewport height). A sample = one movement event covering the time since the previous rendered frame (input arrives in frame batches); velocity = net displacement / elapsed time (floored at `MinElapsed`), never per frame.
- **Start**: within the last `OnsetWindow` (0.05 s) the moving samples (each >= `JitterPixels` 1.5) add up to >= `OnsetDistance` 36 px at >= `OnsetSpeed` 1100 px/s average with coherence (net / path length) >= 0.8. **Segment**: from that window's first moving sample until the movement slows below 35% of its peak, turns > 60 deg, pauses `SegmentGap` 0.03 s, or `SegmentMax` 0.06 s after detection. **Result** = the segment's average speed and direction. A sample faster than `MaxSpeed` 20000 px/s invalidates the gesture (the detector restarts while still committed).
- **Processing delay**: finalised at most OnsetWindow + SegmentMax (0.11 s) after the hand started moving (measured 0.05-0.10 s); the swing moment is the flick's **start**; contact = start + 0.07 s on client and server; the server accepts timestamps up to `MaxLatencyCompensation` 0.2 + `RecognitionAllowance` 0.11 s old (its history covers that rewind).
- **Why these defaults separate a flick from ordinary movement** (initial values, tune with a real mouse): resting / aiming hands move a few px per frame (< ~600 px/s) and wander; a deliberate flick moves 40-300 px in 30-80 ms in one direction (~1500-6000 px/s). Measured on synthetic streams: 240 px/s drift, +-6 px jitter and a steady 800 px/s move never trigger; the same 1500 px/s flick at 30 / 60 / 144 fps gives the same speed and power; faster flicks give more power.
- Timing: the rally window is the incoming ball's (bounced once on your half, in reach, falling or past your end line); after the bounce the ball becomes hittable only once it falls, so the window can open shortly before its ideal moment (measured 0.075 s): flicking ~0.05 s too early is "too early", as it should be over the table. A far-too-early flick is a miss, never queued.

### Power, spin, aim, reach (`Config.Flick`, `Config.Prep`, `Config.Emergency`, `ShotControl`)
- Power = `MinPower` 0.15 at OnsetSpeed .. 1 at `FullPowerSpeed` 5000 px/s (`PowerExponent` 1) -> `MinShotSpeed..MaxShotSpeed` as before.
- Spin along the flick (up = topspin, down = backspin, right / left = curve to that screen side, diagonals split), strength `SpinAtMinPower` 25 .. `SpinAtFullPower` 90 rad/s with the power. Measured from BOTH ends (`ShotLaunch` with hitter Player / Bot): a right flick lands 4.5 studs to the hitter's right, left to the left, topspin 3.7 studs shorter, backspin 1.3 longer; the base aim (+-1 = 13.5 studs across, as the hitter sees it) maps the same way from either end.
- Spin bends the flight around the locked base aim (the calibration keeps the old partial compensation); it never replaces the aim. Profile: drive = speed x1.0, arc = x0.72 (a higher flight), +0.08 depth, 3.5-stud net clearance at full arc.
- Reach unchanged: the stroke's anchor and `PaddleReach` 9.48 from the player's real position (server view, client root claim within `MaxRootMismatch`). Emergency ring: up to PaddleReach + `ReachExtra` 4.5, used only for a ball whose path never enters the normal reach.

### Emergency save (your design)
- Two zones: normal (regular strokes) and the outer ring (a save). You still move yourself, hold left-click and time the flick (the ring's own window). Entering the ring never hits by itself; mistimed / unreachable attempts miss. No stamina cost, no random roll, no cooldown, no reach or readiness penalty.
- A save is a slow, high defensive lob (`ShotLaunch.emergencyLob`: the slowest of `Speeds` 46-80 studs/s that lands legally peaking <= `MaxApex` 18 studs, depth 0.7, following the base aim by 0.5); the flick's power plays no part and its spin is x0.3 capped at 20 rad/s (measured: a fast diagonal flick -> spin 19.1, lob 72 studs/s apex 16.5).
- An attempt (the ball inside the ring at the contact time) plays the body's reach (`NP_SaveRight/Left`, below) and, from landing (contact + `LandDelay` 0.25 s) for `StandUpTime` 0.5 s, WalkSpeed x `RecoverySpeedFactor` 0.8 (server, timestamped, self-ending; respawn / leaving clear it). Measured: 24 -> 19.2 for ~0.5 s, back to 24. Preparing, flicking and hitting stay available.

### Serves (flick)
- Space tosses as before; a FRESH click while the toss is up locks the serve aim (cursor X); a flick strikes (speed = power, direction = spin); the Q posture still decides the stroke; release without a flick cancels (click again while the toss is up). The server requires the click after the toss started. The serve lock (no walking during the toss) is the existing serve rule, unchanged. Measured: hold 0.3 s still -> power 0, no swing; flick -> "forehand clean, on time, power 50%: legal serve"; prediction "clean" matched.

### Animation (ownership and adaptive contact)
- **Legs / footwork / hips / root / facing**: untouched (the existing footwork layer, FacingController); the root is never moved or rotated to help a hit.
- **Paddle arm** (`Shared/PaddleArm`, StancePose arm layer, `Config.ArmLayer`): written after the Animator each frame over the stance track's right shoulder / elbow / wrist, for the LOCAL player only (the bot has no shot controller, weight 0). Preparation = a 3 x 3 grid per stroke (inner / mid / outer x low / mid / high) **solved offline with forward kinematics on the avatar's real joints** (blade on target, striking face toward the table, tip lean, joint limits, zero contact with torso / head / upper arm; the approved ready poses are the exact middles), blended in angle space and eased (`PrepSmoothing`). Measured: forehand blade 6.6 / 8.2 / 9.8 studs right across, 0.4 / 3.1 / 5.1 up; backhand -3.2 / -5.0 left, 1.1 / 5.5 up; forehand shows black, backhand red.
- **Stroke**: on the flick the arm solves a contact pose (`PaddleArm.solveContact`: blade centre on the predicted ball minus the face offset, striking face along the outgoing direction, joint limits, clearance from torso / head / upper arm / table top, upper-body support = an extra waist lean / twist / side bend capped at 18 / 40 / 22 deg used only when the arm alone cannot reach), strokes to it by the contact moment (at least `MinStrikeTime` 0.06 s), follows through (`Follow`), returns to preparation. Measured blade-to-ball error at the solved contact: forehand 0.11-0.28 studs (at the anchor, close, 4 wide), backhand 0.68-1.26, emergency save 0.51; near the reach edge (balls ~11 studs out at chest height) 2.4-3.9 short; clearance 0 in every case; ~8 ms per swing at 40 passes (now 28).
- **Emergency save body**: `NP_SaveRight/Left` (/animate kit, headless Blender: `anims/_notpong.py` `build_save`, 45 frames = a lunge, Land at 0.25 s, 0.5 s stand-up; legs, hips, chest, head, free arm; the paddle arm stays with the arm layer; CHECKS all clear; sheets reviewed front and side, a first too-deep version that collapsed the body was redone). Played by the stance controller (`playSave`) on a predicted attempt; during the stand-up its weight drops with your movement so the footwork keeps responding.
- Serve hold / toss / strike clips own the arm (the layer fades out during your serve). The arm layer and save clip run on your client only (other players' clients would see the stance arm; irrelevant vs the bot).

### Feedback (`ShotFeedback`, rewritten)
- Aim marker on the opponent's half (ring = base aim, post height = drive .. arc), following the cursor, purple when locked; the FLICK dial where you clicked (after the flick: the spin's direction and strength, power %); Power / Curve panel after the flick only; timing bar = the window (orange "EMERGENCY SAVE" for the ring) with the needle at the contact a flick NOW would give; after the flick a tick at the flick's contact and the server's verdict (CLEAN / WEAK / EARLY / LATE / MISS / SAVE!); the trajectory arrow shows the predicted flight from the ACTUAL flick inputs until the verdict. The charge meter, drag dial and "release now" arrow are gone. Serve hints describe click-and-flick.

### Tests
**Automated / scripted (Studio Play, debug bridges; the character placed on the ball's path by the test harness only)**: flick detector (drift, jitter, slow move: no flick; 30/60/144 fps equivalence; more speed = more power; directions; absurd input rejected); validation rejects; prep mapping; serve by flick (hold = no power, legal serve); rally: clean hits with right / left curve, early / late misses, release without flick (no request), one gesture = one attempt (a second flick ignored), committed aim stays locked while the pointer moves, client prediction = server verdict in every case, predicted vs server launch velocity within 0.02-0.9 studs/s; emergency save (attempt, lob, capped spin, 80% for ~0.5 s, save clip played, arm reach); out-of-range = no window; focus loss and respawn clear the commitment and release the mouse; bot serves / returns / scoring normal; console clean.
**Bug found and fixed**: the client kept the opponent-hit snapshot by hit counter, which restarts each point, so a new point's serve could reuse the previous point's snapshot (stale window; also in the old code). Now cleared whenever the ball is held.
**Not done / needs you**: Studio's 3D view rendered nothing during this pass (Edit and Play showed only the UI), so **no visual check of the arm, the save clip or the feedback was possible**; real-mouse flick feel and threshold tuning; frame-rate feel; UI-consumed clicks (a click on a GUI button); full-speed rendered motion.

### Remaining questions / limitations
- **Aim and stroke share the cursor's horizontal position**: a forehand always aims at the right half of the table and a backhand at the left. Do you want cross-court (e.g. forehand to the left) — e.g. placement relative to each half?
- Thresholds are first guesses until tested with your mouse; the reach edge looks a little short visually; the arm/save visuals are client-only (PvP would need replication).
- Slow motion: off; the old plumbing remains for a future trigger.

### Files
- New: `shared/Shared/FlickGesture.luau`, `shared/Shared/PaddleArm.luau`; kit `anims/NP_SaveRight.py`, `anims/NP_SaveLeft.py` (+ `build_save` in `anims/_notpong.py`).
- Rewritten: `client/Client/ShotController.luau`, `client/Client/ShotFeedback.luau`, `server/Server/MovementService.luau`; regenerated `shared/Shared/NotPongAnimData.luau` (15 clips: + NP_SaveRight/Left, - the 3 dive clips; 355 KB, was 590).
- Changed: `shared/Shared/Config.luau` (Flick, Prep, Emergency, ArmLayer, AimMarker, SaveColor; ChargeFreeze off; charge / drag / dive settings removed), `shared/Shared/ShotInput.luau`, `shared/Shared/ShotLaunch.luau`, `shared/Shared/StancePose.luau` (arm layer, playSave, dive player removed), `shared/Shared/NotPongAnims.luau` (comment), `server/Server/RallyService.luau`, `client/Client/ServeInput.luau`, `client/Client/MovementInput.luau` (F dive removed), `client/Client/StanceController.luau` (attachShot), `client/Client/Main.local.luau`, `client/Client/PowerMeter.luau` (comment).

### Checklist (manual, real mouse)
1. On the platform: move the cursor around — the paddle moves left/right and up/down, the aim ring follows across the opponent's half and its post grows toward the top of the screen; left half = backhand (red face toward you).
2. Hold left-click without moving: nothing happens, no power. Move the cursor slowly while holding: nothing. Release: cancelled.
3. Hold, then flick up at the right moment as the ball comes into reach: a clean topspin shot toward the aim ring; flick right / left for curve; faster flick = harder.
4. Flick far too early / too late / out of reach: EARLY / LATE / MISS. One flick per click.
5. A ball that only passes your outer reach: the bar turns orange; a timed flick = SAVE! lob, the body lunges and stands up, you walk at 80% for half a second.
6. Serve: Space, click while the ball is up, flick.
7. Walk during everything: never frozen, never pulled toward the ball.

## Pass 6b: contact ring replaces the accuracy bar (2026-11-17, awaiting your playtest)

A hollow ring round the incoming ball (`Client/ContactRing`, `Config.Feedback.ContactRing`); the timing bar, needle, flick tick and "EMERGENCY SAVE" caption are gone (the CLEAN / EARLY / MISS verdict text stays as plain text). **Gameplay, timing windows, reach, flick detection and shot behaviour are unchanged.**
- Look: faint full-circle track + a brighter arc drawn clockwise from 12 o'clock (72 pooled bars, so any fraction is exact), ring radius `FarRadius` 78 px tightening toward the ball but never below the ball's projected radius + `NearGap` 9 px; thickness 4 px / track 2 px (all in Config).
- **Eligibility = the server's rule**: the contact moment (now + `Flick.ContactDelay`) classified against the incoming ball's contact window from the player's real position (`ShotInput.classify ~= "miss"`; the outer emergency window counts too). Complete + green exactly while a flick would register; it stays complete and green for the whole valid window (clean + weak margins), then fades in 0.18 s without unwinding.
- Progress = predicted approach: time until a flick becomes valid over `LeadTime` 0.9 s (independent of zoom and screen distance), capped at 0.97 until eligible; with no reachable window it follows distance to the contact area, capped at 0.8, never green. Smoothing only on the approach; green is instant; displayed progress never decreases for a ball.
- Centred on the rendered ball every frame (`BallView.onFrame`); only for your incoming rally return (never a serve, the bot's ball, or off the platform); cleared on the verdict, point reset, respawn and when the ball stops being incoming.
- Tested (script): flick while green -> server clean; flick early (ring ~21%) -> server "too early"; flick after the window -> "too late"; green window ~0.4 s; ring radius 25-78 px against a 10-17 px ball radius (never inside the ball). **Not seen**: Studio's 3D view / UI render was unavailable, so the ring's look and the arc drawing are unverified visually. Edge cases (a flick within about one frame of the first / last green moment) can differ from the server by latency.

## Pass 6c: more forgiving contact timing + matte NOT PONG ball (2026-11-17, awaiting your playtest)

### Contact timing (`Config.ShotControl`; the ring follows automatically: it reads the same numbers through `ShotInput.classify`)
- Before -> after: `LateReleaseTolerance` 0.1 -> **0.22**; `EarlyReleaseTolerance` 0.1 (unchanged); `ContactWindowDuration` 0.25 (unchanged); `Flick.ContactDelay` 0.07 (unchanged). Hitting range, ball speed, flick power/spin and movement untouched.
- **Why only the late side, and why not +20%.** Measured over 21 real rally windows (the server's own contact model, ball placed on its path at 3 offsets): the window OPENS (the bounced ball is falling and inside the reach) at ideal -0.16 s on average, which is inside the early tolerance in 19 of 21 windows, so the early side is gated by that opening and the early tolerance does nothing (it was left at 0.1). The ball LEAVES reach at ideal +0.25 s on average, before the old late limit (+0.225) in 9 of 21 windows (fast balls), so the late tolerance helps only on slower balls. Mean valid contact range 0.372 s -> **0.412 s (+11%)**; measured per window: slower balls 0.41-0.45 -> 0.45-0.51, fast balls unchanged. A true +20% needs a change to when contact opens/closes (the hitting range / legal-contact rule), which was held fixed; options: allow contact a little before the ball is falling, or a short grace after it leaves the reach.
- Flick-recognition delay: unchanged and consistent: the swing moment is the flick's first moving sample and contact = that + 0.07 s on client, ring and server alike (recognition takes 0.05-0.10 s, so an on-time gesture is judged at its start, not at recognition).
- Telemetry added for tuning by real play: the rally debug bridge reports swings, clean, weak, earlyMiss, lateMiss, noReach and the mean contact offset (`RallyService` swingStats). No human play data exists yet, so the early/late miss comparison above is geometric, not from players.
- Verified in Play: ring green and server agree at the late edge (inside by ~0.02 s: green + "weak, late"; outside by ~0.04 s: not green + "too late"); early flicks (ring not green) -> "too early"; a ball out of reach -> no window / miss; one flick per attempt; no queueing of an early flick.

### Matte ball (`BallTemplate/Ball/BallVisual`, now a MeshPart)
- Source: `tools/build_ball.py` (Blender, temporary scene) -> `assets/ball/NotPongBall_v1.blend` + `.fbx` (Model asset 95494529222637); a perfectly smooth UV sphere, 1.5 studs across (96 x 48 quads), equirectangular UVs (u 0.5 = front, v 0.5 = equator), no geometry for the print.
- **Diameter measured in the project**: the previous visual was a Part (shape Ball) of exactly 1.5 x 1.5 x 1.5 = the gameplay ball (`Config.Ball.VisualDiameter` 1.5, `BallVisualScale` 1); the new MeshPart is 1.5 x 1.5 x 1.5 (the mesh imports 150, sized down). The gameplay `Ball` part (invisible, 1.5), the physics, mass, bounce, spin, collision groups, `BallView`, trail and the hand-held / toss behaviour are untouched; the visual keeps CanCollide / CanQuery / CanTouch off and the `NP_Ball` group.
- Look: base colour `MeshPart.Color` (232, 229, 224) warm matte white, `SmoothPlastic`, Reflectance 0, `SurfaceAppearance` "Print" with `AlphaMode = Overlay`, `RoughnessMap` = flat white (fully rough) and `ColorMap` = the logo as flat black ink on a transparent 4096 x 2048 overlay (asset 96955801771572; generated by `tools/ball_textures.py` from `docs/.../Screenshot 2026-11-17 034156.png`, copied to `assets/ball/`). The logo spans ~92 degrees of longitude, printed on the surface: it rotates with the ball, no decal, no raised lettering.
- **Customizing later**: colour = `BallVisual.Color` (the print does not change it); logo / graphics = `Print.ColorMap` (any equirectangular transparent PNG); size and gameplay never depend on either. No menu or shop.
- Backup: `ServerStorage/NotPongBackup_2026-11-17/BallVisual_previous` (the orange Part); README updated. The template edit lives in `Workspace.NotPongArena` (Edit data model: save the place).
- Verified (script, Play + Stop): exactly one gameplay `Ball` + one `BallVisual` in the workspace, template properties and print still set after Play/Stop; the ball in the hand sits on the left hand (offset 0.02); during a serve flight the visual moved and rotated every frame (angular speed median 60, max 79 rad/s = the ball's own spin; no per-frame jumps beyond travel). **Seen** (Studio stills): the white matte sphere, no gloss, the black logo reading "NOT PONG" on one side and plain white on the other; in a Play capture the ring and the logo ball at the bot's end. **Not judged**: how the logo looks under the 60-80 rad/s spin at full speed (it may strobe at 60 fps: that spin is gameplay, unchanged); logo sharpness at distance.

## Pass 6d: rally diagnosis telemetry (2026-11-17; no gameplay change)

Gameplay settings and ball speed unchanged. Added attempt telemetry so rally difficulty is diagnosed from your real play (`Config.Telemetry`, on by default; "[Tel]" lines in the Output window; `Player.NotPongTelemetry:Invoke("summary")`).
- **Client** (`Client/Telemetry`): one outcome per incoming ball: `unreachable` (no window from where you stood), `noAttempt` (ring went green, no click), `noAttemptNeverGreen`, `noFlick` (clicked, no flick recognised; logged with the hand's peak speed / net distance / coherence vs the thresholds and which one it missed; `noFlickTried` when it looked like an attempt), `early`, `earlyRisingBall` (refused only because the ball was still rising inside the reach), `late`, `outOfReach`, `contactOk / contactNet / contactOut / contactOwn` (accepted contact and where the shot was predicted to land), `save...`. Per flick: hand-start -> recognised delay, flick start vs the ring turning green, speed / power / spin / direction, the arm's stroke time. Per ball: stroke changes and aim / profile drift while it approached. Summary every 10 attempts.
- **Server** (`RallyService`): every verdict with its window, the falling-ball rule's gap (`ShotInput.contactWindow(..., ignoreRising)`, diagnostics only) and `RISING-BLOCKED`, predicted landing, `NOSWING` (a ball never swung at, with whether it was reachable from where you ended), `POINT` endings with rally length. Counters in the rally debug bridge.
- `FlickGesture` keeps peak statistics for diagnostics only (the recogniser does not read them).

**Code-level findings so far (not human data):**
- The falling-ball rule: in the logged swing it removed 0.20 s before the window opened; over 21 windows the window opened on average 0.16 s before the ideal moment, which was the binding early limit in 19 of 21.
- Visible responsiveness: the stroke is shown when the flick is RECOGNISED (measured 0.05-0.10 s after the hand starts); the contact moment is flick start + 0.07 s, so by then contact has usually already passed and the arm strokes in its 0.06 s minimum: the paddle visibly meets the ball ~0.05-0.1 s after the judged contact, and the ball's new direction arrives with the next server snapshot after that.
- Shot model sweep (2592 accepted contacts: 6 contact points x 4 flick speeds x 4 directions x 3 timings x 3 aims x 3 profiles): 91% land overall; a straight-up flick at centre aim 100% at any speed; aim +1 with a right-curving flick only 28% (the curve adds to an edge aim and carries it out); flick 6000 px/s 86% vs 2500 px/s 97%; weak-late hard flicks 79%; profile 1 (high arc) 87%.

## Pass 7 Stage 1: legal rising-ball returns + brief miss reasons (2026-11-17, awaiting your real-mouse playtest)

**Rule change.** A ball may now be hit RISING or FALLING once it has bounced once on your half and is inside the hitting range (same reach radius 9.48 and height band) and the flick's contact lands in the timing window. The old extra condition "falling, or already past your end line" is a reversible flag: `Config.ShotControl.RequireFallingBall = false` (set `true` to revert exactly). One function decides it for everyone: `ShotInput.contactWindow` (server judge, client window/prediction, contact ring, telemetry), so the green ring and the server verdict stay in agreement.
- **Before:** the window opened only when the bounced ball started falling (or crossed the end line): ~0.16-0.20 s after it was already in reach, and the early side of the window was set by that, not by the timing tolerance.
- **After:** the window opens as soon as the bounced ball is in reach. Measured on live balls: it opens 0.06-0.26 s earlier (server "rising gap" 0.262 / 0.179 / 0.133 / 0.058 s); in an Edit-mode sweep of 18 synthetic returns, up to 0.21 s earlier (mean 0.05 s); the ideal moment (closest approach) and the window's exit are unchanged in every case. Valid contact range = [max(window opens, ideal − 0.225), min(ball leaves reach, ideal + 0.345)]; the early limit is now often the timing tolerance itself, so early misses are still real misses.
- **High bounces:** a ball can be in reach on the way up, rise above the height band, then come back down into reach. Each pass is its own segment (the window is never open while the ball is out of reach); the main window is the pass where the ball comes closest (the later one if within 0.5 studs) and the other pass is kept as `window.earlier`, judged by `ShotInput.classify` and shown by the ring. (No live high-bounce two-pass case occurred in the tests: verified only by code path, see "Not verified".)
- **Unchanged:** ball speed and shot physics, hitting range, flick thresholds and the power/spin mapping, movement, aim mapping, the emergency-save ring (it still requires a falling ball: all its `contactWindow` calls pass `requireFalling = true`), the bot's own strike rule (`Striker`), the serve toss phase (`ServeRules`).

**Feedback (HUD, brief and distinct):** NO FLICK (a commitment against a live ball ended without a recognised flick: released, or the point ended while holding; deliberate cancels and serves stay silent), TOO EARLY, TOO LATE, OUT OF REACH, CONTACT • OUT / CONTACT • NET (the server accepted the contact but the shot, predicted by the same physics, will not land on the opponent's half), plus the existing CLEAN / WEAK • EARLY / WEAK • LATE / SAVE!. If the server could not judge because the point had already ended when the flick arrived, the HUD shows the client's own verdict for that flick. The server now always computes the predicted landing (`info.land`) for the HUD; detailed numbers stay in the [Tel] lines.

**Telemetry:** with the rule off, the server compares each accepted contact with the old rule: `RISING-HIT` / `risingHit` (accepted, the old rule would have refused it) and the rising gap (how much earlier the window opened). `RISING-BLOCKED` / `earlyRisingBall` only appear if the flag is set back to true. `NOSWING` "only while rising" likewise.

**Tests (scripted through the debug bridges in Play; NOT a real mouse, NOT visual):**
| Case | Setup | Result | Ring green at flick |
|---|---|---|---|
| Rising-ball hit | stood so the ball is in reach rising over the table; contact 0.12 s before the old rule would open | CLEAN, ball vY +13.5 at contact, Z 80.4 (end line 83.6), server `RISING-HIT`, landed OK | yes |
| Falling-ball hit | at the closest-approach point, contact at the ideal | CLEAN (offset −0.013), ball vY −5.4 | yes |
| Illegal volley | (from behind the line the returns bounce at Z 72-75, out of reach: not stageable in Play) the judge's exact call with an anchor over the table, contact 0.1 s before the bounce with the ball IN reach, 3 balls | miss "too early"; the window opens exactly at the bounce | — |
| Too early | contact 0.08 s before the earliest valid moment | miss, too early (offset −0.29) | no |
| Too late | contact 0.08 s after the last valid moment | miss, too late (offset +0.37); HUD TOO LATE | no |
| Out of reach | 24 studs to the side | miss, ball never in reach; HUD OUT OF REACH | no (none) |
| Emergency save | 2 studs outside the normal reach | SAVE (emergency, clean), ball falling (vY −16); save window still opens only when falling (0.688 vs 0.662 s without the rule) | yes (emergency) |
| NO FLICK | committed, slow hand (547 px/s < 1100), released after the ball passed | HUD NO FLICK | — |
| CONTACT • OUT | contact just past the client's late limit, accepted weak, predicted out | HUD CONTACT • OUT | — |
No script errors in the Output window.

**Not verified:** feel with a real mouse (does hitting the rising ball feel natural, is the earlier green too early?); a live two-pass high bounce (code path only); the HUD texts seen on screen (read back from the label, not looked at); the rejected-after-point-end fallback (the case that showed the gap was fixed, but the fixed path was not re-triggered; the next late test was judged by the server normally); the bot's returns are unchanged, so rally difficulty may also change because players now meet the ball earlier, nearer the table.

**Known issues:** the client's own prediction can differ from the server's verdict near a boundary (seen once: client "weak early −0.130", server "clean −0.121"; the clean half-window is 0.125 s), pre-existing, from the client predicting from its latest snapshot vs the server's rewind. A volley's miss reason reads "too early (ball not in reach yet)" (the ball is in reach but has not bounced); the HUD says TOO EARLY, which fits.

**Files changed:** `Shared/ShotInput.luau` (contactWindow: optional falling rule, multi-pass segments, `Window.earlier`, `shiftWindow`; classify judges the earlier pass), `Shared/Config.luau` (`ShotControl.RequireFallingBall`), `Server/RallyService.luau` (emergency windows keep the falling rule, rule-comparison telemetry `risingHit`, landing always computed), `Client/ShotController.luau` (windows via `shiftWindow`, emergency window keeps the falling rule), `Client/ContactRing.luau` (approach progress toward the next pass), `Client/ShotFeedback.luau` (miss-reason texts, NO FLICK, CONTACT • OUT/NET, rejected fallback), `Client/Telemetry.luau` (`risingHit`).

## Pass 8: mouse-only rally input prototype (2026-11-17, input experiment, awaiting your real-mouse comparison)

**Switch:** `Config.ShotControl.RallyInput` = `"MouseOnly"` (default for this experiment) or `"ClickLock"` (the Pass 6 click-and-flick). Exactly one is active (a module constant read at start: change it and restart Play). Serves are the same in both (Space toss, press, flick). Ball speed, reach, contact timing and windows, flick thresholds (`Config.Flick`), power / spin mapping, shot physics, the emergency save and its get-up, movement, camera, bot and scoring are unchanged; the server is untouched (its rally judge never used the click time).

**How it plays (MouseOnly):** the cursor prepares as before (stroke from the screen side, aim, profile, paddle position). While a ball is coming to you, a deliberate flick IS the swing: no button, no hold, no release, no rearm. After recovery the cursor prepares again by itself. The left button does nothing in rallies.

**Preparation vs flick (`Shared/MouseSwing`, pure; tunables `Config.MouseOnlyRally`):**
1. *When*: a flick counts only if its contact (flick start + 0.07 s) falls in the ATTEMPT ZONE: 0.5 s before to 0.45 s after the ball's ideal contact moment (the earlier pass's ideal for a two-pass bounce; the emergency ring's window; for a ball out of every reach, its closest approach within 20 studs, so out-of-reach attempts still miss as OUT OF REACH). The zone is wider than the valid window, so early / late attempts still miss. Outside it every movement is preparation. Nothing is ever buffered: a flick outside the zone is ignored, not saved for later.
2. *What*: the flick is measured by `FlickGesture` (same thresholds). A flick ends by slowing or turning; if its measurement runs out of time (SegmentMax) while the hand is still moving, the next 30 ms decide: still moving the same way at ≥ 50% of the flick's speed = a SWEEP (reposition), ignored. Any movement longer than 400 ref px is a sweep however it ends.
3. *Settling*: after a sweep / flick / warp nothing new can start until the movement pauses (40 ms), slows below 700 ref px/s, or turns > 60° — so the tail of a sweep never becomes a swing, while "switch stance, then flick up" needs no pause.
4. *Warp*: a single movement event > 400 ref px (cursor reset, focus return) is never movement.
5. *Snapshot*: every live preparation is kept for 0.5 s; a candidate's onset (inside the zone) freezes the preparation and restores the one recorded before the flick's first movement event, so the flick's path never changes the stroke or the aim (a left flick from forehand stays a forehand with its aim). The committed stroke / aim / profile are kept through contact and recovery; the adaptive arm still solves to the ball.
6. *Visual*: a candidate onset inside the zone starts a reversible wind-up of the paddle arm (`Config.ArmLayer.Windup`, ~0.05 s, eased back out if the candidate is ignored); the swing then starts from it and still meets the ball at the resolved contact time (existing arm sync). The wind-up also plays in ClickLock (visual only).
- Separated in code: live preparation (`updatePrep` + history), candidate measurement (`MouseSwing`/`FlickGesture`), committed stroke / aim (`applySnapshot` at the swing), final power / spin (`ShotInput.flickShot`, recomputed by the server).

**Developer indicator** (`ShotControl.ShowInputDebug`, bottom left, temporary): mode + PREPARING / PREPARING (ball coming) / PREPARING (swing zone) / SWING ONSET... / SWING RECOGNIZED / RECOVERING, and briefly the last IGNORED reason (reposition (sweep), outside the swing zone, warp) or MISS reason. The contact ring and the HUD verdicts are unchanged; green never swings by itself.

**Telemetry**: `ignoredSweep`, `ignoredOutsideZone`, `ignoredOther` counters and `IGNORED (...)` lines; `COMMIT (mouse-only ...)` lines; recognition delay as before.

**Genuine ambiguity (reported, not hidden):** a short, fast sideways reposition inside the swing zone has the same shape as a sideways flick. Synthetic minimum-jerk movements (every frame rate):
| movement | result |
|---|---|
| hops 80 px / 50 ms, 100/60, 120/70, 150/90, 200/100 ms | SWING (indistinguishable from a sideways flick) |
| repositions 150–300 px in 120 ms (and 150 px in 180 ms; 300/180 at 60 fps) | SWING |
| repositions 150–800 px in ≥ 250 ms, 500–800 px at any tested speed | preparation (sweep) |
So inside the swing zone (~0.95 s per ball) a quick small re-aim across the screen centre can become a swing; before the zone it never does. If real play shows this happening, the fair comparison is a keyboard stroke-selection variant (not built).

**Tests (scripted through the debug bridge; `drag` moves the cursor override AND feeds the same movement path; NOT a real mouse):**
- Offline (Edit, `MouseSwing` alone, 30 / 60 / 144 / 240 fps): deliberate flicks 60/60 recognised at every rate (40–300 px, 40–100 ms, up/down/left/right/diagonal); recognition median 0.100 / 0.067 / 0.056 / 0.050 s after the hand started (max 0.133 / 0.100 / 0.083 / 0.079); 2 s of ±6 px jitter → 0 swings; slow positioning → 0; stance switch then an immediate up / same-direction / reverse flick → 1 swing each, the switch ignored. Repositions → swing: 6/32 (8/32 at 60 fps), all in the ambiguous band above.
- Play (MouseOnly, 60 fps): slow positioning and fast FH→BH→FH switches inside the swing zone → 0 requests, the stroke followed the cursor (2 sweeps ignored). Left flick from forehand crossing the screen centre (cursor ended at 0.462, backhand territory) → committed Forehand with the pre-flick aim 0.095, curve left, CLEAN. Switch BH→FH then an immediate up flick → Forehand topspin CLEAN. Down flick → backspin CLEAN; diagonal → top + side CLEAN. One flick + a 250 px tail + a second flick at the same ball → exactly 1 request. Jitter, a 600 px warp and a left-click inside the zone → 0 requests. Flick from the right screen edge inward → CLEAN with the edge's aim; flick INTO the edge → nothing (see limitations). Early (−0.38 s) → TOO EARLY, late (+0.42 s) → TOO LATE, 16 studs aside → OUT OF REACH (near zone). Emergency save from 2 studs outside reach → SAVE. 8-ball rally returned by flicks alone → 8 returns, 8 requests, no button. Focus loss mid-flick → candidate dropped, 0 requests. Server respawn mid-rally → clean IDLE, no candidate, fresh classifier. Holding A (real key input) → MoveDirection 1.0 / 24 studs/s throughout preparation and RECOVERY. In-game recognition 0.066 s median (detect 0.033 s) at 60 fps. Serves (press + flick) worked in every run.
- Play (ClickLock): no classifier created; a free flick without a click → 0 requests; click + flick → CLEAN.
- Rendered stills: the dev indicator, ring and HUD in a mouse-only rally (the 60 ms swing itself was not caught on a still).

**Not verified:** real-mouse comfort and accidental-swing rate in real play (the core question); a swing while walking (the keyboard test caught preparation and recovery, not the swing frame); frame rates other than Studio's 60 in Play; the wind-up's look; whether `InputObject.Delta` is non-zero for an unlocked cursor in the live client (then edge flicks would work).

**Limitations / known issues:** a flick INTO a screen edge cannot register (the free cursor stops; movement is read from the cursor position when Delta is zero). A ball that never comes within the hitting height band near you (e.g. a very high pop-up passing overhead) has no zone, so flicks at it are ignored rather than shown as OUT OF REACH. A flick whose measurement times out while still moving costs up to 30 ms more before it is sent (contact time is unaffected: it is taken from the flick start). A stance switch that ends near the start of a same-direction flick, without slowing, is one movement (a sweep).

**Physical-mouse comparison checklist (both modes, same session):** 1) rally 2 minutes in MouseOnly, then 2 minutes in ClickLock; 2) while the ball comes, re-aim and switch forehand/backhand quickly — count swings you did not mean (dev indicator shows them; `ignoredSweep` in telemetry); 3) flick sideways for curve from a held pose — did any count as a reposition (IGNORED: reposition)?; 4) switch stance and flick at once — natural?; 5) does the stroke start soon enough after your hand moves?; 6) do you ever reach the screen edge mid-flick?; 7) which mode lets you keep your eyes on the ball? Then `Player.NotPongTelemetry:Invoke("print")`.

**Files:** new `Shared/MouseSwing.luau`; changed `Shared/FlickGesture.luau` (closedBy, onsetEventT, onset()), `Shared/Config.luau` (`RallyInput`, `MouseOnlyRally`, `ArmLayer.Windup`, ShowInputDebug comment), `Client/ShotController.luau` (mouse-only path, prep history, `computeWindows`, zone, onset events, bridge `drag` + fields), `Shared/StancePose.luau` (wind-up), `Client/ShotFeedback.luau` (dev indicator), `Client/Telemetry.luau` (ignored counters).

## Next

**Your real-mouse comparison of the two rally input modes (Pass 8 checklist)**, and the Stage 1 playtest (rising returns + miss reasons), then Stage 2 (input / animation / contact sync) only after your feedback. Before it: your telemetry playtest (Pass 6d), then one controlled comparison at a time; afterwards (not yet) capped speed escalation in long rallies. Then the click-and-flick rally (Pass 6 checklist) with a real mouse — the flick thresholds (`Config.Flick`) and preparation ranges (`Config.Prep`) need tuning by feel — and a visual check once Studio renders again; then the open question on cross-court aim.
