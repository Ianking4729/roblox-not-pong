"""Build the NOT PONG ball's print layers into assets/ball/ (needs numpy + Pillow).

  ball_logo_source.png   the reference logo (black on white), copied from the vault
  ball_logo_overlay.png  4096 x 2048 equirectangular overlay: the logo as flat black INK on a transparent background, placed
                         on the front of the sphere (u = 0.5, v = 0.5). Used as SurfaceAppearance.ColorMap with AlphaMode =
                         Overlay, so the MeshPart's Color shows through every transparent texel: base colour and print are
                         independent (change MeshPart.Color for a new ball colour, swap ColorMap for new graphics).
  ball_roughness.png     16 x 16 flat white = fully rough (matte); RoughnessMap.
UV convention of assets/ball/NotPongBall_v1.blend (tools/build_ball.py): equirectangular, u 0..1 = longitude (0.5 = front),
v 0..1 = latitude (0.5 = equator), image top = v 1. The logo spans LOGO_LON degrees of longitude (equirectangular distortion
is negligible near the equator at that size). Run: python tools/ball_textures.py
"""
import os
import shutil

import numpy as np
from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..", "assets", "ball")
SRC = os.path.join(os.path.dirname(__file__), "..", "docs", "Not pong obsidian vault", "Screenshot 2026-11-17 034156.png")
W, H = 4096, 2048
LOGO_LON = 92.0  # degrees of longitude the logo spans (the guide shows it filling about half of the visible disc)

os.makedirs(ROOT, exist_ok=True)
shutil.copyfile(SRC, os.path.join(ROOT, "ball_logo_source.png"))
img = Image.open(SRC).convert("L")
a = np.asarray(img, dtype=np.float32) / 255.0
ink = 1.0 - a  # black ink = 1
ys, xs = np.where(ink > 0.08)
box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
ink = ink[box[1]:box[3], box[0]:box[2]]
h, w = ink.shape
# target size in texels: LOGO_LON of 360 across the width; the same angular scale vertically (2048 px = 180 degrees)
tw = int(W * LOGO_LON / 360.0)
th = int(round(tw * h / w))
logo = np.asarray(Image.fromarray((ink * 255).astype(np.uint8)).resize((tw, th), Image.LANCZOS), dtype=np.uint8)
canvas = np.zeros((H, W, 4), dtype=np.uint8)  # RGB black, alpha = ink
x0, y0 = (W - tw) // 2, (H - th) // 2
canvas[y0:y0 + th, x0:x0 + tw, 3] = logo
Image.fromarray(canvas, "RGBA").save(os.path.join(ROOT, "ball_logo_overlay.png"))
Image.fromarray(np.full((16, 16), 255, np.uint8), "L").save(os.path.join(ROOT, "ball_roughness.png"))
print("logo", tw, "x", th, "texels at", x0, y0, "->", os.path.normpath(ROOT))
