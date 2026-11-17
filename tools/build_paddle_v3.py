"""Build the NOT PONG v3 paddle in Blender (run inside Blender: exec(open(path).read()) via the Blender MCP or the
Text editor). Builds in its own temporary scene, writes assets/paddle/NotPongPaddle_v3.blend (editable source) and
NotPongPaddle_v3.fbx (for upload), then removes the temporary scene; the user's open file is never saved or changed
otherwise. Set KEEP_SCENE = True before running to keep the scene for previewing.

Blender axes = Roblox paddle axes:  X = width, Z = toward the blade tip (Roblox +Y), Y = front face (Roblox +Z).
Origin: the old v2 handle top (Roblox Handle centre = Blender (0, 0, -0.875) in v2; kept so the grip is unchanged).
Units: 1 Blender unit = 1 stud.

Zones (one mesh object each = one Roblox MeshPart, independently coloured / textured):
  NPP_FrontRubber, NPP_BackRubber  top sheets (0.03 thick, rounded outer edge)
  NPP_Sponge                       both sponge layers (0.035 each)
  NPP_WoodBlade                    outer plies, front and back (0.09 each; two plies each via the texture glue line)
  NPP_WoodCore                     centre ply (0.08)
  NPP_Handle                       flared grip, top follows the blade outline
  NPP_EndCap                       end cap
Blade outline (unchanged from v2): ellipse 4.16 x 4.30 centred at Z 2.55. Grip point (Roblox Handle/Grip) at Z -1.322.
UV conventions: see tools/paddle_textures_v3.py.
"""
import math
import os

import bpy

ROOT = r"F:\roblox games\roblox-not-pong\assets\paddle"
NAME = "NotPongPaddle_v3"
KEEP_SCENE = globals().get("KEEP_SCENE", False)

# ---- dimensions (studs) ---------------------------------------------------------------------------------------------
CZ = 2.55  # blade centre (Blender Z)
HW, HH = 2.08, 2.15  # wood outline half width / half height (unchanged)
N = 160  # outline segments
WOOD_OUT, CORE = 0.13, 0.04  # wood faces at +/-0.13, centre ply +/-0.04
SPONGE = 0.035
TOP = 0.03
RUB_INSET, SPONGE_INSET = 0.015, 0.012
HANDLE_BOTTOM = -1.495  # Roblox paddle y -0.62
CAP_BOTTOM = -1.625  # Roblox paddle y -0.75 -> blade edge to cap end 2.025 (~0.47 of the blade height)
RING = 64  # handle ring segments
WOOD_U_REPEAT = 6


def outline_pt(i, inset=0.0, n=N):
    a = 2 * math.pi * i / n
    return (HW - inset) * math.cos(a), CZ + (HH - inset) * math.sin(a)


def disc_edge_z(x, inset=0.0):
    """Lower blade outline height at width x."""
    hw, hh = HW - inset, HH - inset
    k = max(0.0, 1 - (x / hw) ** 2)
    return CZ - hh * math.sqrt(k)


def perim_u():
    pts = [outline_pt(i) for i in range(N + 1)]
    d = [0.0]
    for i in range(1, N + 1):
        d.append(d[-1] + math.dist(pts[i - 1], pts[i]))
    return [x / d[-1] for x in d]


PU = perim_u()


def planar_uv(x, z):
    return (x + HW) / (2 * HW), (z - (CZ - HH)) / (2 * HH)


def make_obj(name, verts, faces, uvs, coll):
    """faces: list of vertex-index tuples; uvs: per face, a tuple of (u, v) per corner."""
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    uvl = me.uv_layers.new(name="UVMap")
    k = 0
    for f, fu in zip(me.polygons, uvs):
        for li, uv in zip(f.loop_indices, fu):
            uvl.data[li].uv = uv
        k += 1
    me.validate()
    for p in me.polygons:
        p.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(38))
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def slab(name, y0, y1, inset, bevel0, bevel1, side_v, coll, extra=None):
    """Blade-outline slab between Y=y0 (back) and Y=y1 (front). bevel0/1: rounded edge size on the back/front face.
    side_v(y) -> v for the side band; faces get planar UVs. Returns (verts, faces, uvs) appended to extra if given."""
    verts, faces, uvs = extra if extra else ([], [], [])
    base = len(verts)
    rows = []  # (inset_extra, y)
    rows.append((bevel0, y0))
    if bevel0 > 0:
        rows.append((bevel0 * 0.29, y0 + bevel0 * 0.29))
        rows.append((0.0, y0 + bevel0))
    if bevel1 > 0:
        rows.append((0.0, y1 - bevel1))
        rows.append((bevel1 * 0.29, y1 - bevel1 * 0.29))
    rows.append((bevel1, y1))
    R = len(rows)
    for (ie, y) in rows:
        for i in range(N):
            x, z = outline_pt(i, inset + ie)
            verts.append((x, y, z))
    # side quads (with seam handled by uv wrap using perimeter parameter)
    for r in range(R - 1):
        for i in range(N):
            j = (i + 1) % N
            a, b = base + r * N + i, base + r * N + j
            c, d = base + (r + 1) * N + j, base + (r + 1) * N + i
            faces.append((a, d, c, b))  # outward normals (outline runs +X -> +Z, rows run -Y -> +Y)
            u0, u1 = PU[i], PU[i + 1]
            uvs.append(((u0, side_v(rows[r][1])), (u0, side_v(rows[r + 1][1])), (u1, side_v(rows[r + 1][1])),
                        (u1, side_v(rows[r][1]))))
    # caps: fan around a centre vertex (back cap faces -Y, front cap +Y)
    for (r, y, flip) in ((0, rows[0][1], False), (R - 1, rows[-1][1], True)):
        cidx = len(verts)
        verts.append((0.0, y, CZ))
        for i in range(N):
            j = (i + 1) % N
            a, b = base + r * N + i, base + r * N + j
            f = (cidx, b, a) if flip else (cidx, a, b)
            faces.append(f)
            uvs.append(tuple(planar_uv(verts[k][0], verts[k][2]) for k in f))
    if extra is None:
        return make_obj(name, verts, faces, uvs, coll)
    return None


def smooth_interp(pts, t):
    """Catmull-Rom through (t, value) points."""
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
DEPTH = [(0.0, 0.48), (0.3, 0.445), (0.7, 0.44), (1.0, 0.42)]
SQUARE = 3.2  # superellipse exponent of the grip section (2 = ellipse, higher = squarer)


def section(t, theta):
    w, d = smooth_interp(WIDTH, t) / 2, smooth_interp(DEPTH, t) / 2
    c, s = math.cos(theta), math.sin(theta)
    e = 2 / SQUARE
    return w * math.copysign(abs(c) ** e, c), d * math.copysign(abs(s) ** e, s)


def handle(coll):
    verts, faces, uvs = [], [], []
    top0 = disc_edge_z(0)
    ts = [i / 40 for i in range(41)]
    for t in ts:
        for k in range(RING + 1):  # duplicated seam column for clean UVs
            th = 2 * math.pi * k / RING
            x, y = section(t, th)
            z = HANDLE_BOTTOM + t * (top0 - HANDLE_BOTTOM)
            if t > 0:
                ztop = disc_edge_z(max(-HW + 0.01, min(HW - 0.01, x))) - 0.004
                z = HANDLE_BOTTOM + t * (ztop - HANDLE_BOTTOM)
            verts.append((x, y, z))
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
        verts.append((0.0, 0.0, min(p[2] for p in ring)))  # top: stays under the blade outline (no poke-through)
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


def material(name, color, tex=None, normal=None, rough=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = rough
    if tex:
        img = bpy.data.images.load(os.path.join(ROOT, "patterns", tex + ".png"), check_existing=True)
        ti = nt.nodes.new("ShaderNodeTexImage")
        ti.image = img
        mix = nt.nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.inputs["A"].default_value = (*color, 1)
        nt.links.new(ti.outputs["Alpha"], mix.inputs["Factor"])
        nt.links.new(ti.outputs["Color"], mix.inputs["B"])
        nt.links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])
    if normal:
        img = bpy.data.images.load(os.path.join(ROOT, "patterns", normal + ".png"), check_existing=True)
        img.colorspace_settings.is_data = True
        ti = nt.nodes.new("ShaderNodeTexImage")
        ti.image = img
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(ti.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def srgb(r, g, b):
    def f(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return f(r), f(g), f(b)


def build():
    scene = bpy.data.scenes.new("NP_PaddleV3")
    coll = scene.collection
    objs = {}
    objs["FrontRubber"] = slab("NPP_FrontRubber", WOOD_OUT + SPONGE, WOOD_OUT + SPONGE + TOP, RUB_INSET, 0.004, 0.014,
                               thin_v, coll)
    objs["BackRubber"] = slab("NPP_BackRubber", -(WOOD_OUT + SPONGE + TOP), -(WOOD_OUT + SPONGE), RUB_INSET, 0.014,
                              0.004, thin_v, coll)
    sp = ([], [], [])
    slab(None, WOOD_OUT, WOOD_OUT + SPONGE, SPONGE_INSET, 0.003, 0.003, thin_v, coll, sp)
    slab(None, -(WOOD_OUT + SPONGE), -WOOD_OUT, SPONGE_INSET, 0.003, 0.003, thin_v, coll, sp)
    objs["Sponge"] = make_obj("NPP_Sponge", *sp, coll)
    wd = ([], [], [])
    slab(None, CORE, WOOD_OUT, 0.0, 0.005, 0.012, wood_v, coll, wd)
    slab(None, -WOOD_OUT, -CORE, 0.0, 0.012, 0.005, wood_v, coll, wd)
    objs["WoodBlade"] = make_obj("NPP_WoodBlade", *wd, coll)
    objs["WoodCore"] = slab("NPP_WoodCore", -CORE, CORE, 0.0, 0.005, 0.005, wood_v, coll)
    objs["Handle"] = handle(coll)
    objs["EndCap"] = endcap(coll)

    mats = {
        "FrontRubber": material("NPP3_FrontRubber", srgb(205, 35, 30), "rubber_grain", "rubber_grain_normal", 0.8),
        "BackRubber": material("NPP3_BackRubber", srgb(30, 30, 33), "rubber_grain", "rubber_grain_normal", 0.8),
        "Sponge": material("NPP3_Sponge", srgb(235, 205, 120), "rubber_grain", None, 0.9),
        "WoodBlade": material("NPP3_WoodBlade", srgb(222, 178, 120), "wood_grain", "wood_grain_normal", 0.55),
        "WoodCore": material("NPP3_WoodCore", srgb(150, 95, 50), "wood_grain", "wood_grain_normal", 0.55),
        "Handle": material("NPP3_Handle", srgb(214, 166, 104), "grip_stripes_v3", None, 0.45),
        "EndCap": material("NPP3_EndCap", srgb(36, 36, 40), None, None, 0.6),
    }
    for k, ob in objs.items():
        ob.data.materials.append(mats[k])
    return scene, objs, mats


def report(objs):
    for k, ob in objs.items():
        xs = [v.co for v in ob.data.vertices]
        mn = [min(v[i] for v in xs) for i in range(3)]
        mx = [max(v[i] for v in xs) for i in range(3)]
        print(k, "min", [round(a, 4) for a in mn], "max", [round(a, 4) for a in mx], "verts", len(xs),
              "faces", len(ob.data.polygons))


def export(scene, objs, mats):
    blend = os.path.join(ROOT, NAME + ".blend")
    fbx = os.path.join(ROOT, NAME + ".fbx")
    imgs = {n.image for m in mats.values() for n in m.node_tree.nodes if n.type == "TEX_IMAGE" and n.image}
    bpy.data.libraries.write(blend, {scene, *objs.values(), *(o.data for o in objs.values()), *mats.values(), *imgs},
                             fake_user=True, path_remap="ABSOLUTE")
    # The exporter evaluates the depsgraph of the window's scene: overriding only the context scene crashed Blender 5.3
    # (stale view-layer bases). So show the temporary scene in the window for the export and always switch back.
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
    imgs = {n.image for m in mats.values() for n in m.node_tree.nodes if n.type == "TEX_IMAGE" and n.image}
    for ob in objs.values():
        me = ob.data
        bpy.data.objects.remove(ob)
        bpy.data.meshes.remove(me)
    for m in mats.values():
        bpy.data.materials.remove(m)
    for i in imgs:
        if i.users == 0:
            bpy.data.images.remove(i)
    bpy.data.scenes.remove(scene)


SCENE, OBJS, MATS = build()
report(OBJS)
if globals().get("EXPORT", True):
    export(SCENE, OBJS, MATS)
if not KEEP_SCENE:
    cleanup(SCENE, OBJS, MATS)
