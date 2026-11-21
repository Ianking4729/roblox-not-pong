# NOT PONG VFX manifest

Source library (unchanged): `docs/Not pong obsidian vault/SyphoDev VFX Texture Pack/SyphoDev VFX Texture Pack/`
(2,459 images: `sprites/`, `flipbooks/`, `beams/`, contact sheets in `_sheets/`). Chosen from the contact sheets
`sprite_impacts.jpg`, `sprite_rings.jpg` and `beam_beams.jpg`. Only these six were copied here and uploaded
(2026-11-19, via Studio's image upload). Runtime use: `Client/ShotVfx.luau`, tunables `Config.Feedback.ShotVfx`.

| Role | Library path | Uploaded asset | Used for |
|---|---|---|---|
| Contact glint | `sprites/impacts/hit_cross_glow_01.png` | `rbxassetid://87790381341943` | every accepted contact (small, brief) |
| Strong burst | `sprites/impacts/starburst_soft_02.png` | `rbxassetid://72862746379191` | strong returns (size / brightness by power) |
| Smash burst | `sprites/impacts/comic_burst_glow_03.png` | `rbxassetid://90799407633776` | smashes |
| Smash lines | `sprites/impacts/speed_lines_glow_02.png` | `rbxassetid://133061155758744` | smashes (radial accent) |
| Scoop ring | `sprites/rings/ring_soft_08.png` | `rbxassetid://139930241889632` | emergency saves |
| Swing trail | `beams/energy_soft_01.png` | `rbxassetid://115112933165849` | paddle Trail on strong strokes and smashes |
| Speed streaks | `beams/speed_streaks_glow_04.png` | `rbxassetid://110996654515595` | ball speed strands from the first escalated rally return (2026-11-19 Pass 12; `Config.Feedback.Trail.SpeedStreaks`, `Client/BallTrail.luau`) |

To swap an effect: pick another file from the library, upload it, and replace the id in `Config.Feedback.ShotVfx`.

`sprites/Trails/` (4 images) holds REFERENCE pictures with baked backgrounds, not usable textures: they guided the look of the speed streaks, whose texture is the beam above.

## Pass 13 (2026-11-19)

| Role | Source | Uploaded asset | Used for |
|---|---|---|---|
| Speed strands (in use) | `assets/vfx/trail2_strands_tip.png`, cut from `sprites/Trails/trail2.png` (top-left fan; alpha from brightness, contrast raised; the library file is untouched) | `rbxassetid://137747350429133` | `Config.Feedback.Trail.SpeedStreaks.Texture` |
| Speed strands, mirrored | `assets/vfx/trail2_strands_tip_flipped.png` | `rbxassetid://132828512069466` | spare (a mirrored copy along the length) |
| (superseded) | first cut of the same fan | `rbxassetid://112101805488080` | replaced by the crisper cut |

`beams/speed_streaks_glow_04` (Pass 12) read as invisible in play and is no longer used.

## Comet trail layers (2026-11-20)

Cut from the user's `sprites/Trails/9251.jpg` (white comets) by `tools/trail_textures.py`; `9247.jpg` (coloured comets)
is the colour reference (white-hot head, stage-coloured body). The sheets have the transparency checkerboard BAKED into
the JPG; the tool rebuilds that checkerboard (cell edges + a smooth tone per checker colour) and inverts each comet's
blend with it (a per-comet blend factor, measured), then damps what is left at the cell scale. White RGB + alpha: the
game tints them with the rally-stage colour. Saved head-at-TOP, because Roblox Trails draw the texture's top row at the
moving part and run its height along the length (verified in Studio; the Pass 13 strand texture was horizontal, so it
was drawn sideways).

| Layer | File | Source comet on 9251.jpg | Uploaded asset | Config |
|---|---|---|---|---|
| Main ribbon | `comet_body.png` | top right (streaky) | `rbxassetid://72980472869758` | `Feedback.Trail.Texture` |
| Core | `comet_core.png` | bottom right (slim, bright) | `rbxassetid://132909147510341` | `Feedback.Trail.Comet.Layers` Core |
| Strands | `comet_strands.png` | centre right (fine strands) | `rbxassetid://102139176700481` | ... Strands |
| Dust | `comet_dust.png` | centre left (sparkle specks) | `rbxassetid://139442035808667` | ... Dust |
| Wisps | `comet_wisps.png` | bottom left (smoky) | `rbxassetid://84393863768285` | ... Wisps |

Superseded (horizontal, uploaded before the orientation check): body `88827675678333`, strands `96247411612185`, dust
`97773315776041`, wisps `131177347532033`, core `91839106377999`. `trail2_strands_tip*.png` (Pass 13) is no longer used.

## Pass 15 (2026-11-21): comet textures re-cut so the head is the widest part

The strands / dust / core cuts started where the comet is still narrow, so the layers read as a tail growing away from the ball.
`tools/trail_textures.py` now starts those three cuts where the comet is widest (larger `head_pad`). Body and wisps are unchanged.
Previous PNGs kept in `assets/vfx/superseded/pass14_comet/`.

| Layer | File | New asset id | Replaces |
|---|---|---|---|
| Core | `comet_core.png` | `rbxassetid://100596374827505` | `132909147510341` |
| Strands | `comet_strands.png` | `rbxassetid://94684561859469` | `102139176700481` |
| Dust | `comet_dust.png` | `rbxassetid://123517828766864` | `139442035808667` |
