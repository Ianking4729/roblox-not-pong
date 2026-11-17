"""Generate the NOT PONG paddle pattern textures (RGBA PNG overlays) into assets/paddle/patterns/.

Each texture is mostly TRANSPARENT: on a Roblox MeshPart the part's Color shows through transparent texels, so a
zone's colour (MeshPart.Color) and its printed pattern (MeshPart.TextureID) stay independently selectable.
UV conventions of assets/paddle/NotPongPaddle_v2.blend:
  FrontRubber / BackRubber : planar, 0..1 across the blade outline's bounding box (patterns should tile)
  WoodBlade edge band      : u around the blade outline, v across the thickness (0 = back face, 1 = front face)
  Handle (grip)            : u around the handle, v along it (0 = bottom, 1 = top)
Pure Python (zlib), no dependencies. Run: python tools/paddle_patterns.py
"""
import math
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "paddle", "patterns")
S = 256


def write_png(path, px):
    raw = b"".join(b"\x00" + bytes(v for p in row for v in p) for row in px)
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def canvas(fn):
    return [[fn(x, y) for x in range(S)] for y in range(S)]


def pips(x, y):  # dotted rubber: a fine grid of soft dark pips
    cell = 16
    dx, dy = (x % cell) - cell / 2, (y % cell) - cell / 2
    d = math.hypot(dx, dy)
    a = max(0.0, 1 - d / 4.5)
    return (0, 0, 0, int(110 * a))


def geometric(x, y):  # triangles: lighter / darker facets with thin seams
    cell = 64
    u, v = (x % cell) / cell, (y % cell) / cell
    upper = u + v < 1 if (x // cell + y // cell) % 2 == 0 else u > v
    seam = min(abs(u + v - 1), abs(u - v), u, v) < 0.02
    if seam:
        return (0, 0, 0, 120)
    return (255, 255, 255, 50) if upper else (0, 0, 0, 45)


def stripes(x, y):  # grip: two blue bands edged with charcoal, wood (part colour) between
    u = x / S
    for c in (0.25, 0.75):
        d = abs(u - c)
        if d < 0.035:
            return (40, 110, 230, 255)
        if d < 0.075:
            return (30, 30, 34, 255)
    return (0, 0, 0, 0)


def chevron(x, y):  # grip: red chevrons pointing up, on a dark wrap
    u, v = x / S, y / S
    w = (v * 4 + abs(u - 0.5) * 2) % 1
    if w < 0.28:
        return (235, 70, 60, 255)
    return (32, 30, 32, 235)


def plies(x, y):  # wood edge: alternating light / dark plies across the thickness (v)
    v = y / S
    band = int(v * 7) % 2
    return (90, 55, 25, 120) if band else (255, 240, 210, 40)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("rubber_pips", pips), ("rubber_geometric", geometric), ("grip_stripes", stripes),
                     ("grip_chevron", chevron), ("wood_plies", plies)):
        path = os.path.join(OUT, name + ".png")
        write_png(path, canvas(fn))
        print("wrote", os.path.normpath(path))
