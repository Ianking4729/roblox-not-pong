# Current State

_Last updated: 2026-11-14 (Gameplay refinement awaiting review: much stronger sidespin curves, faster shots, a low over-the-shoulder camera, and server-authoritative charge slow motion; see "Refinement" below. Before it: the Charge -> Curve -> Release core rework, Phase 4 feedback/movement, Phase 2-3 physics, rallies and shot controls)._

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

## Next

Playtest charge slow motion and the new stamina-limited Shift boost in Roblox Studio using their checklists above; neither change has been runtime-verified yet.
