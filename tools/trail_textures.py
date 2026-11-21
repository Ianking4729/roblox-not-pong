"""Cut ball-trail textures out of the SyphoDev "Trails" reference sheets (read only; the library is never modified).

The comet sheets (9251.jpg white, 9247.jpg coloured) are JPGs with the transparency checkerboard BAKED IN. To get real
alpha we model that background and invert the screen blend of a white glow over it:

    I = B + (255 - B) * a   ->   a = (I - B) / (255 - B)

B (the checkerboard) is rebuilt from the image itself: the cell edges are found per axis from the summed gradient, each
cell's background tone is its low percentile, and one smooth surface per checker colour is fitted with outlier
rejection (cells covered by a comet read too bright and are dropped). The textures are white RGB + alpha, so the game
tints them with the rally-stage colour (Trail.Color). 9247 (coloured) is the colour reference for those stages.

Output: assets/vfx/comet_*.png, saved head-at-TOP for Roblox Trails (see save_tex), plus a preview sheet.
Run: python tools/trail_textures.py [--preview out.png]
"""

import argparse
import math
import os

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "docs", "Not pong obsidian vault", "SyphoDev VFX Texture Pack", "SyphoDev VFX Texture Pack",
                   "sprites", "Trails")
OUT = os.path.join(ROOT, "assets", "vfx")


def edges_1d(profile, approx=119, tol=14):
    """Cell boundaries along one axis from a summed |gradient| profile (irregular spacing allowed)."""
    n = len(profile)
    sm = np.convolve(profile, np.ones(3) / 3, mode="same")
    # first boundary: strongest peak in the first cell
    first = int(np.argmax(sm[60:60 + approx])) + 60
    # walk backwards / forwards picking the strongest peak near each expected position
    out = [first]
    p = first
    while p - approx > tol:
        lo, hi = max(0, p - approx - tol), p - approx + tol
        q = lo + int(np.argmax(sm[lo:hi]))
        out.insert(0, q)
        p = q
    p = first
    while p + approx + tol < n:
        lo, hi = p + approx - tol, p + approx + tol
        q = lo + int(np.argmax(sm[lo:hi]))
        out.append(q)
        p = q
    return [0] + [e + 1 for e in out] + [n]


def checker_background(gray):
    h, w = gray.shape
    gx = np.abs(np.diff(gray, axis=1))
    gy = np.abs(np.diff(gray, axis=0))
    # use the median over the other axis so bright comets do not dominate
    xe = edges_1d(np.median(gx, axis=0))
    ye = edges_1d(np.median(gy, axis=1))
    cells = []  # (cx, cy, parity, p_low, i, j)
    for j in range(len(ye) - 1):
        for i in range(len(xe) - 1):
            x0, x1, y0, y1 = xe[i], xe[i + 1], ye[j], ye[j + 1]
            m = 6
            if x1 - x0 < 2 * m + 4 or y1 - y0 < 2 * m + 4:
                continue
            block = gray[y0 + m:y1 - m, x0 + m:x1 - m]
            cells.append(((x0 + x1) / 2 / w, (y0 + y1) / 2 / h, (i + j) % 2, np.percentile(block, 8), i, j))
    cells = np.array(cells)

    def design(x, y, deg=3):
        cols = []
        for a in range(deg + 1):
            for b in range(deg + 1 - a):
                cols.append((x ** a) * (y ** b))
        return np.stack(cols, axis=-1)

    fits = {}
    for par in (0, 1):
        c = cells[cells[:, 2] == par]
        keep = np.ones(len(c), bool)
        for _ in range(8):
            A = design(c[keep, 0], c[keep, 1])
            coef, *_ = np.linalg.lstsq(A, c[keep, 3], rcond=None)
            pred = design(c[:, 0], c[:, 1]) @ coef
            res = c[:, 3] - pred
            s = 1.4826 * np.median(np.abs(res[keep])) + 0.5
            keep = res < 2.5 * s  # comets only ever ADD light
        fits[par] = coef
    # per-pixel tones of both checker colours
    yy, xx = np.mgrid[0:h, 0:w]
    xn, yn = xx / w, yy / h
    ci = np.searchsorted(xe, xx, side="right") - 1
    cj = np.searchsorted(ye, yy, side="right") - 1
    par = (ci + cj) % 2
    F0 = design(xn, yn) @ fits[0]
    F1 = design(xn, yn) @ fits[1]
    if F0.mean() > F1.mean():  # name them: light / dark
        F0, F1 = F1, F0
        par = 1 - par
    return F1, F0, par, xe, ye  # light tone, dark tone, 1 = light cell, cell edges


def box(img, r):
    """Mean over a (2r+1)^2 window (integral image; edges renormalised)."""
    h, w = img.shape
    I = np.pad(img, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    y0 = np.clip(np.arange(h) - r, 0, h)
    y1 = np.clip(np.arange(h) + r + 1, 0, h)
    x0 = np.clip(np.arange(w) - r, 0, w)
    x1 = np.clip(np.arange(w) + r + 1, 0, w)
    S = I[y1][:, x1] - I[y0][:, x1] - I[y1][:, x0] + I[y0][:, x0]
    n = (y1 - y0)[:, None] * (x1 - x0)[None, :]
    return S / n


def heal_borders(a, xe, ye, band=6):
    """Fill the thin lines left along checker cell borders by interpolating across them (edges in a's own coords)."""
    h, w = a.shape
    a = a.copy()
    for e in xe:
        l, r = e - band - 1, e + band
        if l < 0 or r > w - 1:
            continue
        f = (np.arange(l + 1, r) - l) / (r - l)
        a[:, l + 1:r] = a[:, l:l + 1] * (1 - f) + a[:, r:r + 1] * f
    for e in ye:
        t, b = e - band - 1, e + band
        if t < 0 or b > h - 1:
            continue
        f = ((np.arange(t + 1, b) - t) / (b - t))[:, None]
        a[t + 1:b, :] = a[t:t + 1, :] * (1 - f) + a[b:b + 1, :] * f
    return a


class Sheet:
    """9251 is not one clean composite: the light checker cells read ~1.8x the dark ones in the background, and inside
    the comets that checker shows through by a DIFFERENT amount per comet (the stock artwork layered them differently).
    Model per comet, with m in [0, 1] (0 = glow over the checker, 1 = checker multiplied over the glow):
        I = c^m * (B / c^m + a (255 - B / c^m)),  c = 1 on light cells, dark/light on dark cells, B = checker tone.
    m is chosen per cut so the light and dark cells inside that comet match (no checker left)."""

    def __init__(self, name):
        rgb = np.asarray(Image.open(os.path.join(LIB, name)).convert("RGB")).astype(np.float32)
        self.gray = rgb.max(axis=2)  # (a coloured glow lightens every channel; max keeps the glow)
        light, dark, par, self.xe, self.ye = checker_background(self.gray)
        self.par = par
        c = np.where(par == 1, 1.0, dark / np.maximum(light, 1.0))
        self.c = box(box(c, 1), 1)  # the JPEG's soft cell borders
        self.B = np.where(par == 1, light, dark)
        self.B = box(box(self.B, 1), 1)

    def alpha(self, m, region=None, heal=True):
        sl = region if region is not None else (slice(None), slice(None))
        cm = self.c[sl] ** m
        Bm = self.B[sl] / cm
        a = (self.gray[sl] / cm - Bm) / np.maximum(255.0 - Bm, 1.0)
        a = np.clip(a, 0, 1)
        y0 = sl[0].start or 0
        x0 = sl[1].start or 0
        if heal:
            a = heal_borders(a, [e - x0 for e in self.xe[1:-1]], [e - y0 for e in self.ye[1:-1]])
        return np.clip((a - 0.06) / (1 - 0.06), 0, 1)  # JPEG noise floor

    def checker_score(self, a, x0, y0, inside):
        """Mean signed log-contrast of light vs neighbouring dark cells, over glow cells inside the band."""
        xe = [e - x0 for e in self.xe]
        ye = [e - y0 for e in self.ye]
        h, w = a.shape
        M = {}
        for j in range(len(ye) - 1):
            for i in range(len(xe) - 1):
                xa, xb, ya, yb = xe[i] + 10, xe[i + 1] - 10, ye[j] + 10, ye[j + 1] - 10
                if xa < 0 or ya < 0 or xb > w or yb > h or xb <= xa or yb <= ya:
                    continue
                M[(i, j)] = (a[ya:yb, xa:xb].mean(), inside(x0 + (xa + xb) / 2, y0 + (ya + yb) / 2))
        vals = []
        for (i, j), (v, ok) in M.items():
            nb = [M.get(k) for k in ((i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1))]
            if not ok or any(n is None for n in nb):
                continue
            n = sum(q[0] for q in nb) / 4
            if 0.06 < min(v, n) and max(v, n) < 0.9:
                light = self.par[int(y0 + ye[j] + 20), int(x0 + xe[i] + 20)] == 1
                vals.append((1 if light else -1) * math.log(v / n))
        return (float(np.mean(vals)) if vals else 0.0), len(vals)

    def best_m(self, head, tail, half_width):
        hx, hy = head
        tx, ty = tail
        L = math.hypot(tx - hx, ty - hy)
        dx, dy = (tx - hx) / L, (ty - hy) / L
        x0 = int(max(min(hx, tx) - half_width, 0))
        x1 = int(min(max(hx, tx) + half_width, self.gray.shape[1]))
        y0 = int(max(min(hy, ty) - half_width, 0))
        y1 = int(min(max(hy, ty) + half_width, self.gray.shape[0]))

        def inside(x, y):
            u = (x - hx) * dx + (y - hy) * dy
            v = -(x - hx) * dy + (y - hy) * dx
            return 0 <= u <= L and abs(v) <= half_width

        region = (slice(y0, y1), slice(x0, x1))
        scores = []
        for m in np.linspace(0, 1, 11):
            sc, n = self.checker_score(self.alpha(m, region), x0, y0, inside)
            scores.append((abs(sc), m, sc, n))
        # refine around the best
        best = min(scores)[1]
        for m in np.linspace(max(best - 0.1, 0), min(best + 0.1, 1), 9):
            sc, n = self.checker_score(self.alpha(m, region), x0, y0, inside)
            scores.append((abs(sc), m, sc, n))
        return min(scores)


def suppress_checker_band(a, period=238, fine=5, keep=0.35):
    """What the blend model leaves of the checker lives at the CELL scale. Split the alpha into
    envelope (box one checker period wide: the checker cancels) + mid band + fine detail (strands, specks) and pass
    only `keep` of the mid band, which holds the leftover checker (and some broad wisp shape)."""
    r = period // 2
    env = box(box(a, r // 2), r // 2)
    sm = box(a, fine)
    return np.clip(env + (sm - env) * keep + (a - sm), 0, 1)


def cut(alpha, head, tail, half_width, size, head_pad=0.0, gamma=1.0, gain=1.0, fade_tail=0.12, fade_side=0.12,
        head_right=False):
    """Sample a straight band from head to tail into a (W x H) texture; u = 0 at the head."""
    W, H = size
    hx, hy = head
    tx, ty = tail
    L = math.hypot(tx - hx, ty - hy)
    dx, dy = (tx - hx) / L, (ty - hy) / L
    px, py = -dy, dx
    sx, sy = hx - dx * head_pad, hy - dy * head_pad
    Lt = L + head_pad
    u = (np.arange(W) + 0.5) / W
    v = (np.arange(H) + 0.5) / H - 0.5
    U, V = np.meshgrid(u, v)
    X = sx + U * Lt * dx + V * 2 * half_width * px
    Y = sy + U * Lt * dy + V * 2 * half_width * py
    img = Image.fromarray((alpha * 255).astype(np.uint8), mode="L")
    # bilinear sample (supersample 2x2 to keep fine strands)
    arr = np.asarray(img).astype(np.float32)
    out = np.zeros_like(U)
    for ox in (-0.25, 0.25):
        for oy in (-0.25, 0.25):
            xs = X + ox * Lt / W * dx + oy * 2 * half_width / H * px
            ys = Y + ox * Lt / W * dy + oy * 2 * half_width / H * py
            x0 = np.clip(np.floor(xs).astype(int), 0, arr.shape[1] - 2)
            y0 = np.clip(np.floor(ys).astype(int), 0, arr.shape[0] - 2)
            fx = np.clip(xs - x0, 0, 1)
            fy = np.clip(ys - y0, 0, 1)
            s = (arr[y0, x0] * (1 - fx) * (1 - fy) + arr[y0, x0 + 1] * fx * (1 - fy)
                 + arr[y0 + 1, x0] * (1 - fx) * fy + arr[y0 + 1, x0 + 1] * fx * fy)
            out += s / 4
    a = out / 255.0
    a = np.clip(a * gain, 0, 1) ** gamma
    # soft edges so the band never shows a hard cut
    a *= np.clip((1 - U) / max(fade_tail, 1e-3), 0, 1)
    a *= np.clip((0.5 - np.abs(V)) / max(fade_side, 1e-3), 0, 1)
    if head_right:
        a = a[:, ::-1]
    return a


def save_tex(a, name):
    # Roblox Trails (verified in Studio 2026-11-20): the texture's TOP row is drawn at the moving part and its height
    # runs down the trail's length; its width spans Attachment0 -> Attachment1. Our cuts are head-left, so rotate.
    a = a.T
    h, w = a.shape
    rgba = np.zeros((h, w, 4), np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = (np.clip(a, 0, 1) * 255).astype(np.uint8)
    Image.fromarray(rgba, "RGBA").save(os.path.join(OUT, name))


def preview(paths, out):
    tiles = []
    for p in paths:
        im = Image.open(os.path.join(OUT, p)).convert("RGBA").transpose(Image.Transpose.TRANSPOSE)  # (head left)
        bg = Image.new("RGBA", im.size, (18, 20, 30, 255))
        bg.alpha_composite(im)
        tiles.append(bg.convert("RGB"))
    W = max(t.width for t in tiles)
    H = sum(t.height + 8 for t in tiles)
    sheet = Image.new("RGB", (W, H), (60, 60, 60))
    y = 0
    for t in tiles:
        sheet.paste(t, (0, y))
        y += t.height + 8
    sheet.save(out)


# Comets on 9251.jpg (original pixels: head centre, a point down the tail, half width of the band)
CUTS = {
    # (head_pad < 0 starts the band just behind the comet's head: in game the real ball is the head;
    #  m = the blend factor measured by Sheet.best_m, fixed here so a rerun is fast; delete it to re-measure)
    # bright streaky comet (top right): the main textured body of the ball trail
    "comet_body.png": dict(head=(4095, 1850), tail=(2860, 900), half_width=330, size=(1024, 256), head_pad=-90,
                           m=0.075, gamma=1.1, fade_tail=0.25),
    # many fine strands + a little dust (centre right): the speed strands, sharper with the pace
    "comet_strands.png": dict(head=(4125, 2860), tail=(2000, 1880), half_width=430, size=(1024, 256), head_pad=-600,  # (Pass 15: start where the strands are widest, so no pointed head)
                             
                              m=0.8, gamma=1.15, fade_tail=0.3),
    # dusty comet (centre left): sparkle specks around the flight
    "comet_dust.png": dict(head=(2200, 1325), tail=(780, 2020), half_width=420, size=(1024, 256), head_pad=-250,
                           m=0.2, gamma=1.2, fade_tail=0.3),
    # smoky comet (bottom left): soft wavy wisps at the top stages
    "comet_wisps.png": dict(head=(2385, 3460), tail=(150, 2120), half_width=380, size=(1024, 256), head_pad=-110,
                            m=0.1, gamma=1.1, fade_tail=0.35, keep=0.5),
    # slim bright comet (bottom right): the hot core streak right behind the ball
    "comet_core.png": dict(head=(4290, 3305), tail=(2780, 3610), half_width=120, size=(1024, 128), head_pad=-160,
                           m=0.65, gamma=1.0, fade_tail=0.2, fade_side=0.2),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", default=None)
    ap.add_argument("--head-right", action="store_true")
    ap.add_argument("--alpha-dump", default=None, help="save the extracted 9251 alpha at m = 0 (debug)")
    args = ap.parse_args()
    sheet = Sheet("9251.jpg")
    if args.alpha_dump:
        Image.fromarray((sheet.alpha(0) * 255).astype(np.uint8)).resize((1125, 1000)).save(args.alpha_dump)
    for name, kw in CUTS.items():
        kw = dict(kw)
        m = kw.pop("m", None)
        if m is None:
            score, m, signed, n = sheet.best_m(kw["head"], kw["tail"], kw["half_width"])
            print(f"{name}: m = {m:.3f} (residual checker {signed:+.3f} over {n} cells)")
        a = sheet.alpha(m, heal=False)
        a = heal_borders(a, sheet.xe[1:-1], sheet.ye[1:-1])
        a = suppress_checker_band(a, keep=kw.pop("keep", 0.35))
        save_tex(cut(a, head_right=args.head_right, **kw), name)
        print("wrote", name)
    if args.preview:
        preview(list(CUTS), args.preview)


if __name__ == "__main__":
    main()
