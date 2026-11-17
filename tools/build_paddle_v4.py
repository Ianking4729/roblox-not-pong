"""Build the NOT PONG v4 paddle in Blender (run inside Blender: exec(open(path).read()) via the Blender MCP or the
Text editor). Builds in its own temporary scene, writes assets/paddle/NotPongPaddle_v4.blend (editable source) and
NotPongPaddle_v4.fbx (for upload), then removes the temporary scene. The user's open file is never saved.
Set KEEP_SCENE = True before running to keep the scene for previewing, EXPORT = False to skip writing files.

v4 (2026-11-16, "rubber shape & edge band" sheet): both rubbers have a flat lower edge with rounded corners (the wooden
shoulder above the handle shows), a narrow black band runs round the middle of the blade's sidewall (own zone), the
sponge is part of each rubber sheet, and the materials are plain colours (no textures in the source).

Blender axes = Roblox paddle axes:  X = width, Z = toward the blade tip (Roblox +Y), Y = front face (Roblox +Z).
Origin: the v2 handle top (Roblox Handle centre of v2 = Blender (0, 0, -0.875)), so the grip is unchanged.
1 Blender unit = 1 stud.

Zones (one mesh object each = one Roblox MeshPart):
  NPP_FrontRubber, NPP_BackRubber  rubber sheets incl. sponge (0.065 thick), flat lower edge + rounded corners
  NPP_WoodBlade                    the two outer wood layers (0.095 each) = the visible wood on both sides of the band
  NPP_EdgeBand                     the centre layer (0.07), seen only as the black band round the sidewall
  NPP_Handle                       flared grip; its top follows the blade outline and thins to the wood thickness
  NPP_EndCap                       end cap
Blade outline (unchanged): ellipse 4.16 x 4.30 centred at Z 2.55; total thickness 0.39 (wood 0.26) as in v3.
UVs (kept for future custom textures):
  rubbers        : planar, 0..1 across the WOOD outline's bounding box (same mapping front and back)
  rubber sides   : u around the outline, v in a thin band at the bottom of the texture
  wood / band    : faces planar like the rubbers; sidewall u around the outline (x6), v across the wood thickness
                   (0 = back face, 1 = front face; the band occupies v 0.365..0.635)
  handle         : u around (0.25 = front face centre, 0.75 = back face centre), v along (0 bottom, 1 top)
"""
import math
import os

import bpy

ROOT = r"F:\roblox games\roblox-not-pong\assets\paddle"
NAME = "NotPongPaddle_v4"
KEEP_SCENE = globals().get("KEEP_SCENE", False)

# ---- dimensions (studs) ---------------------------------------------------------------------------------------------
CZ = 2.55  # blade centre (Blender Z)
HW, HH = 2.08, 2.15  # wood outline half width / half height (unchanged)
N = 192  # outline segments
WOOD_OUT = 0.13  # wood faces at +/-0.13
BAND = 0.035  # black band = centre layer +/-0.035: 0.07 of the 0.26 sidewall (27%; started at 1/3 = 0.09, judged
#               too heavy next to the reference, where the stripe is narrower than each visible wood layer)
RUBBER = 0.065  # rubber sheet incl. sponge (total thickness 2 x 0.195 = 0.39, as v3)
RUB_INSET = 0.015  # rubber outline inside the wood outline
RUB_FLAT_Z = 0.86  # flat lower edge of the rubbers (blade bottom is at 0.40)
RUB_CORNER = 0.34  # rounded corner radius where the flat edge meets the curve
HANDLE_BOTTOM = -1.495  # Roblox paddle y -0.62
CAP_BOTTOM = -1.625  # Roblox paddle y -0.75
RING = 64
WOOD_U_REPEAT = 6


# ---- outlines -------------------------------------------------------------------------------------------------------
def resample(poly, n):
    """Closed polyline -> n points evenly spaced by arc length, starting at poly[0]."""
    pts = poly + [poly[0]]
    d = [0.0]
    for i in range(1, len(pts)):
        d.append(d[-1] + math.dist(pts[i - 1], pts[i]))
    total = d[-1]
    out, j = [], 0
    for k in range(n):
        s = total * k / n
        while d[j + 1] < s:
            j += 1
        t = (s - d[j]) / max(d[j + 1] - d[j], 1e-12)
        out.append((pts[j][0] + (pts[j + 1][0] - pts[j][0]) * t, pts[j][1] + (pts[j + 1][1] - pts[j][1]) * t))
    return out


def ellipse_outline(inset):
    a, b = HW - inset, HH - inset
    return [(a * math.cos(2 * math.pi * i / N), CZ + b * math.sin(2 * math.pi * i / N)) for i in range(N)]


def flat_outline(inset):
    """Rubber outline: the blade ellipse (inset) cut by a flat lower edge, with filleted corners. Starts at the
    rightmost point and runs counter-clockwise (+X -> +Z), like the ellipse, so rows of different insets line up."""
    a, b = HW - RUB_INSET - inset, HH - RUB_INSET - inset
    zf = RUB_FLAT_Z + inset
    r = max(RUB_CORNER - inset, 0.02)
    dense = [(a * math.cos(t), CZ + b * math.sin(t)) for t in (2 * math.pi * k / 4000 for k in range(4000))]

    def nearest(cx, cz):
        return min(dense, key=lambda p: (p[0] - cx) ** 2 + (p[1] - cz) ** 2)

    # right fillet centre (cx, zf + r): the circle touches the flat line and the ellipse (bisection on cx)
    cz = zf + r
    lo, hi = 0.0, a * math.sqrt(max(0.0, 1 - ((cz - CZ) / b) ** 2))
    for _ in range(60):
        mid = (lo + hi) / 2
        p = nearest(mid, cz)
        if math.dist(p, (mid, cz)) > r:
            lo = mid
        else:
            hi = mid
    cx = (lo + hi) / 2
    tp = nearest(cx, cz)  # tangent point on the ellipse
    a_end = math.atan2(tp[1] - cz, tp[0] - cx)  # fillet arc: from straight down (-pi/2) to the tangent point
    t_tan = math.atan2((tp[1] - CZ) / b, tp[0] / a)  # ellipse parameter of the tangent point (negative, lower right)
    poly = []
    # ellipse: from the right tangent point, counter-clockwise over the top to the left tangent point
    steps = 1200
    t0, t1 = t_tan, math.pi - t_tan
    for k in range(steps + 1):
        t = t0 + (t1 - t0) * k / steps
        poly.append((a * math.cos(t), CZ + b * math.sin(t)))
    lp = []
    for k in range(61):
        ang = a_end + (-math.pi / 2 - a_end) * k / 60  # right arc from tangent point down to the flat line
        lp.append((cx + r * math.cos(ang), cz + r * math.sin(ang)))
    left_arc = [(-x, z) for (x, z) in lp]  # mirror: from the left tangent point down to the line
    poly += left_arc[1:]
    poly += [(-cx + 2 * cx * k / 40, zf) for k in range(1, 40)]  # the flat edge, left -> right
    poly += list(reversed(lp))[:-1]  # right arc: from the line up to the right tangent point
    # rotate so the polygon starts at the rightmost point (z = CZ), matching the ellipse rows
    k0 = min(range(len(poly)), key=lambda i: (poly[i][0] - a) ** 2 + (poly[i][1] - CZ) ** 2)
    poly = poly[k0:] + poly[:k0]
    return resample(poly, N)


def disc_edge_z(x, inset=0.0):
    """Lower blade (wood) outline height at width x."""
    hw, hh = HW - inset, HH - inset
    k = max(0.0, 1 - (x / hw) ** 2)
    return CZ - hh * math.sqrt(k)


def perim_u(pts):
    d = [0.0]
    for i in range(1, len(pts) + 1):
        d.append(d[-1] + math.dist(pts[i - 1], pts[i % len(pts)]))
    return [x / d[-1] for x in d]


def planar_uv(x, z):
    return (x + HW) / (2 * HW), (z - (CZ - HH)) / (2 * HH)


# ---- mesh helpers ---------------------------------------------------------------------------------------------------
def make_obj(name, verts, faces, uvs, coll):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    uvl = me.uv_layers.new(name="UVMap")
    for f, fu in zip(me.polygons, uvs):
        for li, uv in zip(f.loop_indices, fu):
            uvl.data[li].uv = uv
    me.validate()
    for p in me.polygons:
        p.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(38))
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def slab(outline, y0, y1, bevel0, bevel1, side_v, u_repeat, acc):
    """Outline slab between Y=y0 (back) and Y=y1 (front); bevel0/1 round the back/front edges. outline(inset) -> N
    points. Appends to acc = (verts, faces, uvs)."""
    verts, faces, uvs = acc
    base = len(verts)
    rows = [(bevel0, y0)]
    if bevel0 > 0:
        rows += [(bevel0 * 0.29, y0 + bevel0 * 0.29), (0.0, y0 + bevel0)]
    if bevel1 > 0:
        rows += [(0.0, y1 - bevel1), (bevel1 * 0.29, y1 - bevel1 * 0.29)]
    rows.append((bevel1, y1))
    R = len(rows)
    pu = perim_u(outline(0.0))
    for (ie, y) in rows:
        for (x, z) in outline(ie):
            verts.append((x, y, z))
    for r in range(R - 1):
        for i in range(N):
            j = (i + 1) % N
            a, b = base + r * N + i, base + r * N + j
            c, d = base + (r + 1) * N + j, base + (r + 1) * N + i
            faces.append((a, d, c, b))  # outward normals
            u0, u1 = pu[i] * u_repeat, pu[i + 1] * u_repeat
            v0, v1 = side_v(rows[r][1]), side_v(rows[r + 1][1])
            uvs.append(((u0, v0), (u0, v1), (u1, v1), (u1, v0)))
    for (r, flip) in ((0, False), (R - 1, True)):  # back cap faces -Y, front cap +Y
        cidx = len(verts)
        verts.append((0.0, rows[r][1], CZ))
        for i in range(N):
            j = (i + 1) % N
            a, b = base + r * N + i, base + r * N + j
            f = (cidx, b, a) if flip else (cidx, a, b)
            faces.append(f)
            uvs.append(tuple(planar_uv(verts[k][0], verts[k][2]) for k in f))


def smooth_interp(pts, t):
    for k in range(len(pts) - 1):
        if pts[k][0] <= t <= pts[k + 1][0]:
            p0 = pts[max(k - 1, 0)][1]
            p1, p2 = pts[k][1], pts[k + 1][1]
            p3 = pts[min(k + 2, len(pts) - 1)][1]
            s = (t - pts[k][0]) / (pts[k + 1][0] - pts[k][0])
            return 0.5 * ((2 * p1) + (-p0 + p2) * s + (2 * p0 - 5 * p1 + 4 * p2 - p3) * s * s
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * s ** 3)
    return pts[-1][1]


WIDTH = [(0.0, 0.78), (0.12, 0.70), (0.32, 0.62), (0.58, 0.645), (0.76, 0.75), (0.88, 0.94), (0.96, 1.16), (1.0, 1.30)]
# depth thins to the wood thickness (0.26) at the top so the flare runs flush into the exposed wooden shoulder
DEPTH = [(0.0, 0.48), (0.3, 0.445), (0.7, 0.44), (0.86, 0.39), (0.95, 0.30), (1.0, 0.262)]
SQUARE = 3.2


def section(t, theta):
    w, d = smooth_interp(WIDTH, t) / 2, smooth_interp(DEPTH, t) / 2
    c, s = math.cos(theta), math.sin(theta)
    e = 2 / SQUARE
    return w * math.copysign(abs(c) ** e, c), d * math.copysign(abs(s) ** e, s)


def handle(coll):
    verts, faces, uvs = [], [], []
    ts = [i / 48 for i in range(49)]
    for t in ts:
        for k in range(RING + 1):
            th = 2 * math.pi * k / RING
            x, y = section(t, th)
            ztop = disc_edge_z(max(-HW + 0.01, min(HW - 0.01, x))) - 0.004
            verts.append((x, y, HANDLE_BOTTOM + t * (ztop - HANDLE_BOTTOM)))
    W = RING + 1
    for r in range(len(ts) - 1):
        for k in range(RING):
            a, b = r * W + k, r * W + k + 1
            c, d = (r + 1) * W + k + 1, (r + 1) * W + k
            faces.append((a, b, c, d))
            uvs.append(((k / RING, ts[r]), ((k + 1) / RING, ts[r]), ((k + 1) / RING, ts[r + 1]), (k / RING, ts[r + 1])))
    for (r, flip) in ((0, True), (len(ts) - 1, False)):
        ring = [verts[r * W + k] for k in range(RING)]
        cidx = len(verts)
        verts.append((0.0, 0.0, min(p[2] for p in ring)))
        for k in range(RING):
            a, b = r * W + k, r * W + k + 1
            faces.append((cidx, b, a) if flip else (cidx, a, b))
            uvs.append(((0.5, 0.5), (0.5, 0.5), (0.5, 0.5)))
    return make_obj("NPP_Handle", verts, faces, uvs, coll)


def endcap(coll):
    verts, faces, uvs = [], [], []
    h = HANDLE_BOTTOM - CAP_BOTTOM
    rows = [(1.035, HANDLE_BOTTOM), (1.035, HANDLE_BOTTOM - h * 0.45), (1.0, HANDLE_BOTTOM - h * 0.75),
            (0.9, HANDLE_BOTTOM - h * 0.93), (0.72, CAP_BOTTOM)]
    W = RING + 1
    for (sc, z) in rows:
        for k in range(RING + 1):
            x, y = section(0.0, 2 * math.pi * k / RING)
            verts.append((x * sc, y * sc, z))
    for r in range(len(rows) - 1):
        for k in range(RING):
            a, b = r * W + k, r * W + k + 1
            c, d = (r + 1) * W + k + 1, (r + 1) * W + k
            faces.append((b, a, d, c))
            v0, v1 = r / (len(rows) - 1), (r + 1) / (len(rows) - 1)
            uvs.append((((k + 1) / RING, v0), (k / RING, v0), (k / RING, v1), ((k + 1) / RING, v1)))
    for (r, flip) in ((0, False), (len(rows) - 1, True)):
        cidx = len(verts)
        verts.append((0.0, 0.0, rows[r][1]))
        for k in range(RING):
            a, b = r * W + k, r * W + k + 1
            faces.append((cidx, b, a) if flip else (cidx, a, b))
            uvs.append(((0.5, 0.5), (0.5, 0.5), (0.5, 0.5)))
    return make_obj("NPP_EndCap", verts, faces, uvs, coll)


def wood_v(y):
    return (y + WOOD_OUT) / (2 * WOOD_OUT)


def thin_v(y):
    return 0.01 + 0.02 * ((y + 0.2) / 0.4)


def material(name, color, rough):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = rough
    return m


def srgb(r, g, b):
    def f(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return f(r), f(g), f(b)


def build():
    scene = bpy.data.scenes.new("NP_PaddleV4")
    coll = scene.collection
    objs = {}
    acc = ([], [], [])
    slab(flat_outline, WOOD_OUT, WOOD_OUT + RUBBER, 0.004, 0.016, thin_v, 1, acc)
    objs["FrontRubber"] = make_obj("NPP_FrontRubber", *acc, coll)
    acc = ([], [], [])
    slab(flat_outline, -(WOOD_OUT + RUBBER), -WOOD_OUT, 0.016, 0.004, thin_v, 1, acc)
    objs["BackRubber"] = make_obj("NPP_BackRubber", *acc, coll)
    acc = ([], [], [])
    slab(ellipse_outline, BAND, WOOD_OUT, 0.004, 0.012, wood_v, WOOD_U_REPEAT, acc)
    slab(ellipse_outline, -WOOD_OUT, -BAND, 0.012, 0.004, wood_v, WOOD_U_REPEAT, acc)
    objs["WoodBlade"] = make_obj("NPP_WoodBlade", *acc, coll)
    acc = ([], [], [])
    slab(ellipse_outline, -BAND, BAND, 0.004, 0.004, wood_v, WOOD_U_REPEAT, acc)
    objs["EdgeBand"] = make_obj("NPP_EdgeBand", *acc, coll)
    objs["Handle"] = handle(coll)
    objs["EndCap"] = endcap(coll)
    mats = {
        "FrontRubber": material("NPP4_FrontRubber", srgb(200, 30, 28), 0.7),
        "BackRubber": material("NPP4_BackRubber", srgb(28, 28, 30), 0.7),
        "WoodBlade": material("NPP4_Wood", srgb(232, 196, 146), 0.55),
        "EdgeBand": material("NPP4_EdgeBand", srgb(22, 22, 24), 0.5),
        "Handle": material("NPP4_Grip", srgb(232, 196, 146), 0.5),
        "EndCap": material("NPP4_EndCap", srgb(40, 40, 44), 0.6),
    }
    for k, ob in objs.items():
        ob.data.materials.append(mats[k])
    return scene, objs, mats


def report(objs):
    for k, ob in objs.items():
        xs = [v.co for v in ob.data.vertices]
        mn = [min(v[i] for v in xs) for i in range(3)]
        mx = [max(v[i] for v in xs) for i in range(3)]
        print(k, "min", [round(a, 4) for a in mn], "max", [round(a, 4) for a in mx], "verts", len(xs))


def export(scene, objs, mats):
    blend = os.path.join(ROOT, NAME + ".blend")
    fbx = os.path.join(ROOT, NAME + ".fbx")
    bpy.data.libraries.write(blend, {scene, *objs.values(), *(o.data for o in objs.values()), *mats.values()},
                             fake_user=True, path_remap="ABSOLUTE")
    # The exporter evaluates the window scene's depsgraph: overriding only the context scene crashed Blender 5.3, so
    # show the temporary scene in the window for the export and always switch back.
    win = bpy.context.window
    previous = win.scene
    try:
        win.scene = scene
        bpy.context.view_layer.update()
        bpy.ops.export_scene.fbx(filepath=fbx, use_selection=False, axis_forward="-Z", axis_up="Y",
                                 object_types={"MESH"}, mesh_smooth_type="FACE", use_mesh_modifiers=True,
                                 path_mode="STRIP", bake_anim=False, global_scale=1.0, apply_unit_scale=True,
                                 add_leaf_bones=False)
    finally:
        win.scene = previous
    print("wrote", blend, "and", fbx)


def cleanup(scene, objs, mats):
    for ob in objs.values():
        me = ob.data
        bpy.data.objects.remove(ob)
        bpy.data.meshes.remove(me)
    for m in mats.values():
        bpy.data.materials.remove(m)
    bpy.data.scenes.remove(scene)


SCENE, OBJS, MATS = build()
report(OBJS)
if globals().get("EXPORT", True):
    export(SCENE, OBJS, MATS)
if not KEEP_SCENE:
    cleanup(SCENE, OBJS, MATS)
