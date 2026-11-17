"""Generate the NOT PONG v3 paddle textures (1024 px) into assets/paddle/patterns/.

All COLOUR maps are overlays (Roblox SurfaceAppearance.AlphaMode = Overlay): transparent texels show the MeshPart's
Color, so every zone's colour stays selectable in Studio and the texture only adds detail on top.

UV conventions of assets/paddle/NotPongPaddle_v3.blend (built by tools/build_paddle_v3.py):
  FrontRubber / BackRubber / Sponge faces : planar, 0..1 across the blade outline's bounding box (textures tile)
  rubber / sponge side band              : u around the outline, v in a thin band at the bottom of the texture
  WoodBlade / WoodCore edge band         : u around the outline (repeats 6x), v across the WOOD thickness
                                           (0 = back face of the back ply, 1 = front face of the front ply);
                                           glue lines sit at v = 0.173 / 0.346 / 0.654 / 0.827 (5 plies)
  Handle (grip)                          : u around the handle (0.25 = front face centre, 0.75 = back face centre),
                                           v along it (0 = bottom, 1 = top of the flare); image top = v 1
Run: python tools/paddle_textures_v3.py   (needs numpy + Pillow)
"""
import os

import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "paddle", "patterns")
S = 1024


def fnoise(scale_x, scale_y, seed):
    """Periodic (tileable) smooth noise in [-1, 1]: Gaussian-filtered white noise, feature size ~scale px."""
    rng = np.random.default_rng(seed)
    w = rng.standard_normal((S, S))
    fy = np.fft.fftfreq(S)[:, None]
    fx = np.fft.fftfreq(S)[None, :]
    filt = np.exp(-2 * (np.pi ** 2) * ((fx * scale_x) ** 2 + (fy * scale_y) ** 2))
    n = np.real(np.fft.ifft2(np.fft.fft2(w) * filt))
    return n / (np.abs(n).max() + 1e-9)


def save_rgba(name, rgb, alpha):
    a = np.clip(alpha, 0, 255).astype(np.uint8)
    img = np.dstack([np.clip(rgb[..., i], 0, 255).astype(np.uint8) for i in range(3)] + [a])
    Image.fromarray(img, "RGBA").save(os.path.join(OUT, name + ".png"))
    print("wrote", name)


def save_gray(name, g):
    Image.fromarray(np.clip(g * 255, 0, 255).astype(np.uint8), "L").save(os.path.join(OUT, name + ".png"))
    print("wrote", name)


def save_normal(name, h, strength):
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5 * strength
    dy = (np.roll(h, 1, axis=0) - np.roll(h, -1, axis=0)) * 0.5 * strength  # image row 0 = top (+v)
    n = np.dstack([-dx, -dy, np.ones_like(h)])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    rgb = (n * 0.5 + 0.5) * 255
    Image.fromarray(rgb.astype(np.uint8), "RGB").save(os.path.join(OUT, name + ".png"))
    print("wrote", name)


def solid(value):
    return np.full((S, S), float(value))


def rubber():
    # Fine pebbled top-sheet grain: rounded bumps a few px across (about 0.02-0.03 studs on the 4.2-stud blade).
    h = 0.6 * fnoise(2.2, 2.2, 11) + 0.3 * fnoise(5, 5, 12) + 0.1 * fnoise(18, 18, 13)
    h = np.tanh(2.2 * h / (np.abs(h).max() + 1e-9))
    dark = np.clip((-h - 0.15) * 110, 0, 60)
    light = np.clip((h - 0.45) * 70, 0, 26)
    use_light = light > dark
    rgb = np.where(use_light[..., None], 255.0, 0.0) * np.ones((S, S, 3))
    save_rgba("rubber_grain", rgb, np.where(use_light, light, dark))
    save_normal("rubber_grain_normal", h, 2.2)
    save_gray("rubber_rough", 0.78 + 0.08 * h)


PLY_LINES = (0.173, 0.346, 0.654, 0.827)


def wood():
    # Edge grain: streaks running along u (around the blade), warped by stretched noise; dark glue lines between plies.
    y = (np.arange(S)[:, None] / S) * np.ones((1, S))
    warp = 0.012 * fnoise(220, 10, 21) + 0.004 * fnoise(60, 4, 22)
    grain = np.sin(2 * np.pi * (y + warp) * 46)
    fine = fnoise(90, 1.5, 23)
    dark = np.clip(grain * 38, 0, 38) + np.clip(fine * 40, 0, 30)
    v = 1 - y  # image top = v 1
    glue = np.zeros((S, S))
    for c in PLY_LINES:
        d = np.abs(v - c) * S
        glue = np.maximum(glue, np.clip(1.6 - d / 4.0, 0, 1) * 185)
    alpha = np.maximum(dark, glue)
    rgb = np.dstack([np.full((S, S), 70.0), np.full((S, S), 38.0), np.full((S, S), 14.0)])
    rgb = np.where((glue > dark)[..., None], np.array([40.0, 22.0, 8.0]), rgb)
    save_rgba("wood_grain", rgb, alpha)
    save_normal("wood_grain_normal", 0.5 * grain + 0.5 * fine, 1.2)


def grip_base_grain():
    # Lengthwise wood grain for the handle's uncovered wood (runs along v).
    x = (np.arange(S)[None, :] / S) * np.ones((S, 1))
    warp = 0.01 * fnoise(10, 260, 31)
    g = np.sin(2 * np.pi * (x + warp) * 38)
    fine = fnoise(1.5, 80, 32)
    return np.clip(g * 30, 0, 30) + np.clip(fine * 30, 0, 22)


def band(u, centre, half):
    """Antialiased 0..1 coverage of |u - centre| < half (u in texels across S)."""
    d = np.abs(u - centre * S) - half * S
    return np.clip(0.5 - d, 0, 1)


def grip_stripes():
    # Flush inlay down the front and back faces: charcoal border, blue centre; ends square under the flare (v 0.80).
    u = np.arange(S)[None, :] * np.ones((S, 1)) + 0.5
    v = 1 - (np.arange(S)[:, None] + 0.5) / S * np.ones((1, S))
    length = np.clip((0.80 - v) * S + 0.5, 0, 1)
    black = np.zeros((S, S))
    blue = np.zeros((S, S))
    for c in (0.25, 0.75):
        black = np.maximum(black, band(u, c, 0.060))
        blue = np.maximum(blue, band(u, c, 0.024))
    black *= length
    blue *= length
    grain = grip_base_grain()
    rgb = np.dstack([np.full((S, S), 70.0), np.full((S, S), 40.0), np.full((S, S), 15.0)])
    rgb = rgb * (1 - black[..., None]) + np.array([24.0, 24.0, 28.0]) * black[..., None]
    rgb = rgb * (1 - blue[..., None]) + np.array([30.0, 105.0, 235.0]) * blue[..., None]
    alpha = grain * (1 - black) + 255 * black
    save_rgba("grip_stripes_v3", rgb, alpha)


def grip_chevron():
    # Alternative wrap: red chevrons pointing to the blade on a charcoal wrap, crisp antialiased edges.
    u = (np.arange(S)[None, :] + 0.5) / S * np.ones((S, 1))
    v = 1 - (np.arange(S)[:, None] + 0.5) / S * np.ones((1, S))
    uu = (u * 2) % 1  # one chevron column per face
    w = (v * 5 - np.abs(uu - 0.5) * 1.6) % 1
    edge = np.minimum(np.abs(w - 0.0), np.abs(w - 0.3)) * S / 5
    inside = (w < 0.3).astype(float)
    aa = np.clip(edge * 1.0, 0, 1)
    red = inside * aa + (1 - inside) * (1 - aa) * 0  # crisp red band
    length = np.clip((0.80 - v) * S + 0.5, 0, 1)
    rgb = np.dstack([np.full((S, S), 32.0), np.full((S, S), 30.0), np.full((S, S), 34.0)])
    rgb = rgb * (1 - red[..., None]) + np.array([230.0, 60.0, 50.0]) * red[..., None]
    grain = grip_base_grain()
    alpha = (240 * length) + grain * (1 - length)
    rgb = rgb * length[..., None] + np.array([70.0, 40.0, 15.0]) * (1 - length[..., None])
    save_rgba("grip_chevron_v3", rgb, alpha)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    rubber()
    wood()
    grip_stripes()
    grip_chevron()
