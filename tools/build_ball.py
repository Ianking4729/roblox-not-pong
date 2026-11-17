"""Build the NOT PONG ball in Blender (run inside Blender: exec(open(path).read()) via the Blender MCP). Builds in a temporary
scene, writes assets/ball/NotPongBall_v1.blend (editable source) and NotPongBall_v1.fbx, removes the temporary scene.
The user's open Blender file is never saved. EXPORT = False skips writing files; KEEP_SCENE = True keeps the scene to preview.

A perfectly smooth UV sphere, diameter 1.5 studs (1 unit = 1 stud; the game's ball is 1.5 studs across), equirectangular UVs:
u 0..1 = longitude (u 0.5 = the +Y-facing front after the FBX axis conversion), v 0..1 = latitude (0.5 = equator).
One material: matte white base colour; the logo is a separate overlay texture (tools/ball_textures.py), so colour and print are
independent. No dimples, bumps or geometry for the lettering. 96 x 48 quads (4608 faces), smooth shaded.
"""
import math
import os

import bmesh
import bpy

ROOT = r"F:\roblox games\roblox-not-pong\assets\ball"
NAME = "NotPongBall_v1"
DIAMETER = 1.5
SEG, RINGS = 96, 48
KEEP_SCENE = globals().get("KEEP_SCENE", False)

scene = bpy.data.scenes.new("NP_BallV1")
coll = scene.collection
me = bpy.data.meshes.new("NPB_Ball")
bm = bmesh.new()
r = DIAMETER / 2
# vertices: rings from north pole to south pole, SEG+1 columns (a duplicated seam column keeps UVs clean)
rows = []
for j in range(RINGS + 1):
    phi = math.pi * j / RINGS  # 0 = north pole
    row = []
    for i in range(SEG + 1):
        th = 2 * math.pi * i / SEG
        # longitude 0 (u 0.5) faces -Y in Blender; the FBX export (forward -Z, up Y) turns it into Roblox's front
        x = r * math.sin(phi) * math.sin(th - math.pi)
        y = -r * math.sin(phi) * math.cos(th - math.pi)
        z = r * math.cos(phi)
        row.append(bm.verts.new((x, y, z)))
    rows.append(row)
bm.verts.ensure_lookup_table()
uv = bm.loops.layers.uv.new("UVMap")
for j in range(RINGS):
    for i in range(SEG):
        a, b, c, d = rows[j][i], rows[j][i + 1], rows[j + 1][i + 1], rows[j + 1][i]
        try:
            f = bm.faces.new((a, d, c, b))
        except ValueError:
            continue
        f.smooth = True
        us = (i / SEG, i / SEG, (i + 1) / SEG, (i + 1) / SEG)
        vs = (1 - j / RINGS, 1 - (j + 1) / RINGS, 1 - (j + 1) / RINGS, 1 - j / RINGS)
        for loop, u, v in zip(f.loops, us, vs):
            loop[uv].uv = (u, v)
# weld the poles' degenerate duplicate vertices (positions only; UV loops keep their own coordinates)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
bm.to_mesh(me)
bm.free()
ob = bpy.data.objects.new("NPB_Ball", me)
coll.objects.link(ob)
mat = bpy.data.materials.new("NPB_Matte")
mat.use_nodes = True
bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
bsdf.inputs["Base Color"].default_value = (0.82, 0.80, 0.77, 1)  # sRGB ~ (232, 229, 224): warm matte white
bsdf.inputs["Roughness"].default_value = 1.0
for name in ("Specular IOR Level", "Specular"):
    if name in bsdf.inputs:
        bsdf.inputs[name].default_value = 0.0
img = bpy.data.images.load(os.path.join(ROOT, "ball_logo_overlay.png"), check_existing=True)
ti = mat.node_tree.nodes.new("ShaderNodeTexImage")
ti.image = img
mix = mat.node_tree.nodes.new("ShaderNodeMix")
mix.data_type = "RGBA"
mix.inputs["A"].default_value = (0.82, 0.80, 0.77, 1)
mat.node_tree.links.new(ti.outputs["Alpha"], mix.inputs["Factor"])
mat.node_tree.links.new(ti.outputs["Color"], mix.inputs["B"])
mat.node_tree.links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])
ob.data.materials.append(mat)
xs = [v.co for v in me.vertices]
print("verts", len(xs), "faces", len(me.polygons), "bbox", [round(max(v[i] for v in xs) - min(v[i] for v in xs), 4) for i in range(3)])

if globals().get("EXPORT", True):
    blend = os.path.join(ROOT, NAME + ".blend")
    fbx = os.path.join(ROOT, NAME + ".fbx")
    bpy.data.libraries.write(blend, {scene, ob, me, mat, img}, fake_user=True, path_remap="ABSOLUTE")
    win = bpy.context.window
    previous = win.scene
    try:
        win.scene = scene  # (the exporter evaluates the window's scene; see tools/build_paddle_v3.py)
        bpy.context.view_layer.update()
        bpy.ops.export_scene.fbx(filepath=fbx, use_selection=False, axis_forward="-Z", axis_up="Y", object_types={"MESH"},
                                 mesh_smooth_type="FACE", path_mode="STRIP", bake_anim=False, global_scale=1.0,
                                 apply_unit_scale=True, add_leaf_bones=False)
    finally:
        win.scene = previous
    print("wrote", blend, "and", fbx)
if not KEEP_SCENE:
    bpy.data.objects.remove(ob)
    bpy.data.meshes.remove(me)
    bpy.data.materials.remove(mat)
    if img.users == 0:
        bpy.data.images.remove(img)
    bpy.data.scenes.remove(scene)
