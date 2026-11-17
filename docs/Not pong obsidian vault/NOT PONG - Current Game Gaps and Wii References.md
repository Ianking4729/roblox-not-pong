# NOT PONG - Current Game Gaps and Wii References

Updated 2026-11-17. Source: `F:\roblox games\roblox-not-pong\docs\current-state.md`, dated November 14. Capabilities below are document-reported, not independently verified live.

## Existing game

- Hold left click for power, drag for spin, release to swing. Cursor position does not choose a landing target.
- Topspin, backspin, sidespin and combinations with flight and bounce effects.
- Server-authoritative fixed-step physics, swept contacts, serves/lets, rally rules and scoring.
- Bot prediction, movement and returns.
- Swing animation, Motor6D grip, stance/grounding and walking blends.
- Trajectory arrow, power/curve meters, timing verdicts, impacts, trail and receiver outlines.
- Manual movement, stamina-limited Shift boost, table guard and character fading.
- Latest refinement adds low shoulder camera, stronger curves and solo charge slow motion.

## Confirmed user decisions

- Use Wii as a reference for selected missing features, not a complete gameplay template.
- Left side of the player's screen selects backhand; right selects forehand.
- Lock stance when charging starts and keep it through the stroke. Dragging for spin does not switch the active stroke. After recovery, the current pointer side selects the next ready stance.
- Continue discussing research-inspired additions before preparing a broader implementation prompt.

### Confirmed 2026-11-15

- Gameplay reach follows the locked stroke: the backhand uses a mirrored anchor on the player's left with the same radius.
- Ordinary returns stay forgiving; shot risk concentrates in high-power, stretched, diving and smash contacts. Errors come from contact timing and are shown by the arrow, not random.
- Smash: eligible when the ball is at least 7.5 studs above the table at contact, no more than 6 studs behind the player's end line, with power at least 0.75 and a clean or weak contact. Faster, deeper, with three times the timing sensitivity; can go long or into the net. Gold arrow with a SMASH label; overhead swing.
- High balls for smashing come from bot pop-ups under pressure plus a small random lob rate.
- Charge slow motion: lead window shortened to 0.13 s so presses inside it can reach contact before the 0.4 s cap.
- Dive (E, not otherwise remapped): direction follows movement input; with no input it goes toward the locked stroke side. A reachable ball gets an automatic weak return. Costs 50 stamina, 1.0 s recovery, one dive per incoming ball. (Superseded on 2026-11-15, pass 2: see below.)
- Keep Claude prompts and agent instructions out of this vault.

### Confirmed 2026-11-15 (uploaded assets and table size)

- The user's uploaded table and paddle replace the placeholder visuals.
- Table enlarged to 1.5x the previous playing area, keeping the wider-than-official shape: 47.27 long x 34.5 wide; the height stays 8.74 studs. The ball is enlarged in proportion to 1.5 studs, with the visible ball equal to the simulated ball.
- The incomplete table import is fixed by re-exporting from the Blender source with modifiers applied and importing it in Studio.
- Shot speeds are raised partially (x1.15) for the bigger table, so flights take longer than before.
- The dive and footwork animations target the standard R15 rig.

### Confirmed 2026-11-15 (pass 2: movement, dives, serve)

- Movement should look fluid and athletic: wide, low ready stance with subtle weight shifts; short lateral shuffles where the foot nearest the movement direction leads and the feet do not cross; longer running steps on Shift with the body turned roughly 20-30 degrees toward sideways travel while attention and paddle stay on play; legs keep moving while the upper body charges or swings.
- Off the platform the game uses standard Roblox camera, controls, animations and facing; back on, the sports camera, facing, stance and footwork return.
- Dive key is F for every direction; E is no longer a dive key. A dive gives movement and extended reach only, never an automatic hit: the normal hold/drag/release swing decides contact. Charge, spin and the committed stroke survive a dive. (Contact superseded on 2026-11-16, pass 3: automatic dive returns; see below.)
- Backward dive: hold S and press F (relative to the court-facing direction), with its own animation (push back, reach, land on back/hip, get up).
- Dive recovery is 1.3 s (was 1.0); stamina cost and exhaustion rules unchanged.
- The player's serve is manual: the ball is held in the free (left) hand; serving is allowed from behind the player's own end line across the table's width plus a small corner allowance; Space tosses; the cursor position before charging sets the serve direction (serving only); a fresh charge after the toss; slow motion starts at the toss's apex (solo only); no guaranteed-landing assistance; a missed toss, illegal bounce sequence or out-of-bounds serve loses the point; net + otherwise legal is a let. The bot's serve stays automatic. (Apex slow motion and the unforgiving, no-assistance launch superseded on 2026-11-16, pass 3; see below.)

### Confirmed 2026-11-16 (pass 3: camera, serve, dives, clean shots)

- These supersede the earlier decisions on manual dive contact, deliberately unforgiving serves and apex-triggered serve slow motion.
- Camera: balanced, fluid lateral follow in both directions with room on both sides of the body and paddle; less fixed right-shoulder bias without abrupt shoulder switching; table, opponent and ball flight readable; current follow distance and rally angle as starting points; standard Roblox camera off the platform.
- Serve camera: lower, about head height and more horizontal during preparation and toss at the same follow distance; smooth blend up into the rally angle after the strike; no FOV jumps or whipping; bot serves, faults, lets, resets and interrupted attempts handled explicitly; a missed swing is not a successful serve transition.
- No slow motion of any kind during serving. Rally slow motion stays unchanged.
- The toss is a somewhat slower, natural, readable toss from the hand opposite the paddle, released at a synchronized release marker, with no pause, hover or time dilation at the apex; global gravity and rally physics are not changed for it.
- Serving is contact-based and forgiving: a reachable paddle stroke meeting the descending ball during the valid contact phase produces a legal serve (first bounce on the server's half, second on the receiver's); power changes pace, spin changes flight and bounce, aim changes placement within a legal envelope; launch parameters are adapted before contact, never corrected after. Real misses remain for genuinely early or late swings, unreachable balls and unstruck tosses. Legal region, Space toss, fresh click to lock aim and charge, drag for spin, release to swing, and stroke locking are kept.
- Dives: F, left/right/backward, stamina cost and 1.3 s recovery kept; no charge, drag or release needed; an automatic defensive return is attempted only during a bounded legal dive-contact phase within reach, with no hits before the required bounce, on the wrong turn, through the table or during the get-up, and no teleporting; at most one contact per dive and per incoming ball; eligible contacts give about 90% legal returns (configurable, initially 0.90), decided once on the server; failures are coherent physical mishits with clear feedback. This is not a 90% chance of reaching any ball.
- Clean (green) shots that appear to land should be reliably playable; no simple widening of the green zone, no hidden mid-flight correction and no random misses on ordinary shots; risk stays in extreme spin, poor reach, aggressive smashes and mistiming; unsafe trajectories are communicated clearly.

## Potential gaps, not approved features

### Decisions from the latest discussion

- Practice/return-target challenges are deferred; not part of the next additions.
- The user wants situational smashes on high balls.
- The user wants a player-triggered dive to reach otherwise out-of-reach balls, costing stamina. E is the proposed key, not finalized. Dive cost, direction, contact controls and recovery rules are undecided.
- The user observes that player shots almost always land on the table and wants meaningful opportunities for errors, including missing the table. Exact balance changes have not been chosen.

The documented ShotLaunch calibrates launch yaw/elevation with a physics solver toward an in-bounds calibration point, using partial spin compensation before launching with full spin. That provides substantial landing assistance while preserving some spin-induced errors. The latest document reports 884/900 clean-contact shots landing in a sampled grid; this is not a live player success rate. Timing/reach can already cause misses. How much to reduce launch assistance versus expand timing/position consequences remains undecided.

- Mouse-side forehand/backhand preparation was implemented on 2026-11-15 (screen-left backhand, screen-right forehand, locked from charge start through recovery), with reach following the stroke. Stance-specific reach, timing-based shot errors, smash, bot pop-ups and the dive were implemented the same day and verified by scripted Studio tests; none has been played with a physical mouse and keyboard yet.
- Stroke pose readability and paddle clipping still need visual assessment.
- Camera clips the near-left table corner at the far-right near-table position.
- A dedicated return-target challenge and a distinct situational smash are not documented.
- A full environment art assessment has not been performed. Nintendo's developer interview confirms a poolside setting; original poolside art is an optional direction.

## Measured game facts (Studio, 2026-11-15)

- (Before the 2026-11-15 enlargement: table 31.51 x 23, ball 0.4 gameplay / 1.0 visual.) Gameplay reach is a 9-stud circle around a point 4 studs right and 3 forward of the player's root, covering roughly 5 studs left to 13 studs right of the body regardless of pose. The backhand pose holds the blade about 3.5 studs left of the root.
- Bot returns peak 3.5–8.2 studs above the table after bouncing on the player's half (median 5.8). The reach height limit is about 10.3 studs above the table.
- The shot model corrects launch elevation and direction fully toward an in-bounds point; landing errors come only from the uncompensated share of spin and the random error on weak contacts. Clean-contact timing within the window does not change direction.
- Stamina: boost drains in ~0.8 s and refills in ~3 s; the refill delay counts from exhaustion, not from releasing Shift.
- Slow motion: with the original 0.45 s lead window, presses earlier than ~0.14 s before contact could not be timed before the 0.4 s real-time cap; the lead window is now 0.13 s and a 0.11 s press tested clean.
- Bot lobs bounced 8–10.6 studs above the table in live tests, so the smashable part of their fall is short.

## Measured game facts (Studio, 2026-11-15, after the table enlargement)

- The uploaded table model arrived with only one of four leg quarters, one of four net quarters and one of two net holders, and without materials: the Blender Mirror/Array modifiers had not been applied on export. The full net mesh is 49,600 triangles.
- Edit-mode changes did not reach the game for two reasons: the uploaded paddle and table were never used by the game (it built its own primitive paddle), and any gameplay-geometry mismatch made Play re-apply size and position to every arena part, including cosmetic ones.
- With air drag, a 30–35 studs/s lob cannot carry the longer table (0 of 120 lobs solved); about 52 studs/s solves almost all of them, bouncing 11–16 studs above the table.
- On the enlarged table, offline launches at medium power land 99% and at full power 96%; bot returns land 120/120, bouncing 6.2–15.1 studs above the table.
- The test avatar's R15 proportions equal the standard block R15 rig scaled 3.37x.

## Measured game facts (Studio, 2026-11-15, pass 2)

- With Roblox animation retargeting on, the default walk's hip motion was scaled twice on the 3.37x avatar (once by the model scale, once to the HipHeight): a 2.55-stud bob per stride with 0.93-stud jumps in single frames. With retargeting disabled: 0.86 studs and 0.31 per frame.
- The previous on-platform footwork let the default walk show through at every start and reversal (leg-track weights dipped to ~0.75), raised the body ~0.47 studs at each start through per-frame HipHeight changes, and its shuffle clips halved the paddle arm and the forward lean while moving (shoulder 45 to 22 degrees, lean 12 to 6).
- On the enlarged table with air drag, a hand-tossed serve struck 4-6 studs above the table needs roughly 90-150 studs/s horizontally to bounce on the server's half and still clear the net; slower serves mostly bounce twice on the server's side.
- The user's first four physical manual serves were all judged too early when the ideal contact was 4.5 studs above the table (released 0.65-0.93 s into the apex slow motion).

## Reference video observations (2026-11-16)

Source: `videoplayback.mp4` in the project folder (3:19, no speech; the on-screen text "SPOCCO RESORT", "6-Point Match" and "Reset Motion Controls" indicates a Nintendo Switch Sports table tennis match). Frames sampled locally.

- Rally camera: high behind the near player, who is drawn translucent near the horizontal centre of the screen; the camera tracks the player sideways, so the table shifts in the frame rather than the player.
- Serve camera: drops to roughly head height with a nearly level view (horizon in the upper third, the table in the lower middle); a "Server" label marks the server.
- The toss rises about a head above the hand before the strike.
- After the serve the camera rises back to the rally view over roughly 1.25 s, smoothly.

## Measured game facts (Studio, 2026-11-16, pass 3)

- The ball leaves the toss hand 6.55 studs above the table (about the 3.37x avatar's head top). With the shared physics (gravity 98.1, drag), a straight-up toss of 28 / 32 / 36 / 40 studs/s peaks 10.3 / 11.35 / 12.5 / 13.8 studs above the table, 0.28 / 0.31 / 0.35 / 0.38 s after release; a lower toss gives less time before contact.
- On this table (net 2.63 high, 47.3 long, with drag) a legal serve (own half, then the receiver's) exists for only about 1-16% of contacts 1-2.5 studs above the table and 35-75% at 4-5.5, but for every tested aim, power and spin from about 7 studs up; the ready paddle sits about 8 above the table.
- The old shot model's timing error inside the clean window changed a full-power shot's direction by up to 48 deg per second of timing and a smash's by up to 144 deg/s; with a one-frame-old preview, smash landings differed from the preview by 6-13 studs in a sampled run (ordinary still shots 0.4-1.7).
- The old camera's raw velocity look-ahead made it accelerate harder than the player at shuffle reversals (701 vs 610 studs/s^2 on a recorded path); the old footwork blend gave up to 53% of the legs to the forward/back clips during sideways reversals.
- In 31 live automatic dives at balls 12.3-14.8 studs from the normal reach anchor (reach 9), all were eligible; 26 were legal returns and 5 deliberate mishits.

## Outstanding validation

Real mouse feel, network latency and several visual refinements remain insufficiently checked.

## Interpretation cautions

The document is chronological. Its old target-locking, auto-return and no-swing-animation descriptions are superseded by later sections. Some configuration tables retain older values. Successful sync evidence refers to the Mac setup and does not establish today's Windows connection.

The reach anchor is right-offset and gameplay hit detection does not use the visible paddle. This matters when evaluating how a backhand pose lines up with legal contact; no stance-specific reach change has been approved.

Research sources: [[Wii Sports Resort - Table Tennis Research]].

## Confirmed serve and balance decisions — November 16, 2026

- High serves can be smashed by the receiver like other eligible high balls.
- Automatic dive returns should be slower, higher defensive shots that buy recovery time while offering the opponent an attacking opportunity. The established 90% eligible-contact return setting remains.
- Existing trajectory/timing guidance stays as it is.
- Automatic long-rally speed escalation is deferred.
- Q toggles serve hip-leading posture before the toss, independent of aim. The agreed sequence locks posture when Space starts the toss.
- Serve curves may bounce early, but should continue toward the receiver's back edge rather than escape over a sideline.
- Serve camera should follow the torso and favor the player's right when positioned right, favor the left when positioned left, and become balanced in the middle, like the desired rally framing. The exact interpretation of movement versus court position can be clarified before implementation; do not infer camera turning from torso yaw alone.
- Opponent preparation/windup animation is deferred to [[future ideas]].

## Confirmed decisions — November 17, 2026

- The serve camera's sideways offset depends on where the player stands across the court (court-relative, either table end), blending continuously through the middle, never on the Q posture. Lower head-height serve view and follow distance kept.
- The two serving postures are moderately side-on (one hip or the other leading), head toward the table, feet grounded; the posture, not the cursor, decides the serve stroke; the cursor stays the serve aim.
- No serve slow motion; the natural toss and the forgiving contact rule stay; no long-rally speed escalation, no practice challenges, no opponent windup telegraphs in this pass.
- The table and net take their look from the user's concept image `ping-pong-table-concept.png`: red-orange top with white edge and centre lines, thick charcoal edge band, chunky charcoal end frames whose legs splay out onto chamfered floor beams, a net of thick dark strands in two rows of large square openings under a white top bar, and square dark posts. Gameplay dimensions, net collision and ball size are unchanged.

## Confirmed decisions — November 17, 2026 (footwork and paddle)

- On-platform footwork is a hybrid: short sideways moves are controlled athletic shuffles (lead foot out, trail foot follows, no crossing); sustained sideways movement develops into crossover strides (the trailing leg crosses toward or in front of the leading leg); quick direction changes use a direction-change step; forward/backward are controlled steps; the existing idle ready stance and posture are kept; WalkSpeed and controls unchanged; player and bot share the system.
- The paddle is larger (about 1.3x the blade as a starting point) with a correspondingly larger contact area, without multiplying the arm's reach; the handle stays fitted to the hand.
- Paddle zones are independently customizable: front rubber, back rubber, handle/grip, wood edge and end cap (colour, printed pattern, surface texture); appearance is cosmetic only, with no stat effects. Reference: `paddle design.png`.
- The cursor's screen side sets the ready forehand/backhand and a moderate paddle lean (about 25-40 degrees) toward that side, committed at charge start, updated after recovery; dragging for spin does not change it; Q still decides the serving posture. Reference: the cursor-based paddle hold sheet.

## Confirmed decisions — November 16, 2026 (paddle build guide)

- The paddle follows `paddle design2.png` as an appearance guide (not a measured blueprint): the approved blade size and its matching hit area stay; the handle is compact (about half the blade's diameter) and fits the avatar's hand; the blade is visibly thicker with layered wood, and the rubber faces are separate layers (not a thick rubber slab); rubber texture is a fine grain, with no large stamped dots; wood grain, bevels and grip inlay edges are clean and crisp; the front rubber, back rubber and grip pattern stay independently customizable; the grip pivot stays aligned; skins have no gameplay effect.

## Confirmed decisions — November 16, 2026 (rubber shape, edge band, backhand face)

- Both rubber faces have a flat lower edge with softly rounded corners, exposing the wooden shoulder above the handle; the wooden blade's size and shape stay as approved (only the rubber is trimmed).
- A narrow, noticeable black band runs round the blade's sidewall (not across either face), narrower than the blade thickness with wood visible on both sides, as its own editable zone.
- For now the paddle uses clean solid colours with no surface patterns: red front rubber, black back rubber, light-tan wood and grip, black band and end cap. Front rubber, back rubber, grip, wood, and band/end cap stay independently customizable later.
- Forehand and backhand show opposite rubber faces to the player through a genuine wrist/forearm turn of the paddle in the same hand (cursor left = backhand, right = forehand), with the existing commitment rule (locked at charge start, spin drag never flips, updated after recovery) and the Q serving posture independent.

## Measured game facts (Studio, 2026-11-17)

- On the avatar's grip the paddle's face normal runs roughly along the forearm, so turning the face toward or away from the player needs the forearm's direction to change (elbow and forearm across the body), not a twist about the forearm. The previous backhand pose still pointed the red (front) face toward the table, so the player saw the black face in both strokes. (Measured 2026-11-16.)
- The avatar's block right hand is 3.37 x 1.01 x 3.37 studs and the paddle handle runs through its 3.37-stud depth, so the fist covers about 3.4 studs of handle around the grip point: a handle shorter than that is entirely hidden in the hand, and only the blade (and a flared throat) shows. (Measured 2026-11-16.)

- The previous shuffle clips moved the body 1.5 block-rig studs per cycle (5.1 studs on the 3.37x avatar), so at 24 studs/s the legs cycled about 4.75 times a second (about 9.5 foot movements a second). With 1.7-stud shuffles and 3.0-stud crossovers, sustained sideways movement settles near 2.4 cycles a second.
- The previous paddle's blade was 3.2 studs across; hit detection is a 9-stud radius around a reach anchor rather than paddle collision.
- From the rally camera, the previous forehand ready pose held the blade about 5 degrees from vertical on screen and the backhand about 49 degrees to the left.
- On a Roblox MeshPart, a TextureID ignores the part's Color; a SurfaceAppearance with AlphaMode Overlay shows the Color through transparent texels.

- Before the serve-envelope change, 785 of 1458 sampled legal player serves (54%) left over the receiver's side line after their receiver-side bounce (sideways : forward speed up to 8.6 : 1), including 36 spin-free serves from wide spots aimed wide.
- The serve solve could take up to 0.12 s of server time; with bounded inner solves and a 35 ms budget the worst measured case was 42 ms (mean 8.6 ms). A 12 ms budget sent 113 of 432 strong-spin serves to the spin-free fallback; 50 ms sent none.
- Solved player serves bounce at most about 7 studs above the table after the receiver-side bounce, below the 7.5-stud smash height.
- A fixed slow (46 studs/s horizontal) defensive dive return had to arc 25-50 studs above the table to carry the enlarged table against drag, and cost up to 0.68 s to solve; choosing the slowest of several speeds that peaks at most 18 studs above the table gave legal returns from all 400 sampled contacts (213 wide or deep), peaking 14-24 studs high, 0.87-1.27 s to the opponent's bounce.
- In the reference video (640x360) the net mesh shows roughly six rows of light strands under a lighter top band, dark square posts, a terracotta top, a deep dark apron and slanted dark legs on a floor rail; strand thickness and the leg construction under the table are not clearly visible at that resolution.
