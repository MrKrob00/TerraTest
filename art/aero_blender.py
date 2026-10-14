"""AERO'S BASIC BLOCK AND STANDARD WHEEL, MADE IN BLENDER: the second of two versions of the same design
(the first is art/aero_models.py), so the two ways of making a model can be compared. DRAFTS for the
player's approval, not wired into the game.

    blender -b --factory-startup --python art/aero_blender.py -- aero_block_bl|aero_wheel_bl
        -> objects/<name>_texture.png + art/out/<name>.glb (one node per part, at its pivot)

What Blender does here that the hand-written generator does not:
  - the chamfer is a BEVEL MODIFIER (0.035 m, two segments), the same on every edge;
  - the chevron and the vent slots are CUT into the faces (boolean, 6-10 mm deep), not painted;
  - the rim's six spoke holes are real holes;
  - the colour is a SHADER (the bands, the V dip and the emblem's fold computed from the point's
    position), and the shading is BAKED into the texture by Cycles: ambient occlusion darkens the
    grooves, the inner corners and the tyre's insides, and the convex edges catch a glint
    (`Pointiness`) - the light the blocks never get from the engine.
The block stays a full cube on its cell (it joins on every face); every cut goes INTO the faces.

Axes: everything is placed in GAME axes through G() (game y up, game +Z the hull face a wheel bolts to);
the glTF exporter turns Blender's Z-up into glTF's Y-up.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_GLB = os.path.join(ROOT, "art", "out", "%s.glb")
OUT_PNG = os.path.join(ROOT, "objects", "%s_texture.png")

C = 0.035
BAND = 1.0 / 6.0
DIP = 0.10
BLUE = ((14, 188, 232), (6, 156, 206))
WHITE = ((244, 245, 248), (224, 227, 233))
ORANGE = ((252, 94, 10), (228, 70, 12))
TEX = 256


def G(x, y, z):
    """A game point (y up, +Z toward the hull) in Blender's axes (z up)."""
    return Vector((x, -z, y))


def srgb(c):
    """An sRGB byte colour as Blender's linear float colour."""
    def lin(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return (lin(c[0]), lin(c[1]), lin(c[2]), 1.0)


# ── materials: the colour as a shader, baked with the light ────────────────────────────────────

def _math(nt, op, a, b=None, c=None, clamp=False):
    if isinstance(c, bool):
        c, clamp = None, c
    n = nt.nodes.new("ShaderNodeMath")
    n.operation = op
    n.use_clamp = clamp
    for i, v in enumerate((a, b, c)):
        if v is None:
            continue
        if isinstance(v, (int, float)):
            n.inputs[i].default_value = v
        else:
            nt.links.new(v, n.inputs[i])
    return n.outputs[0]


def _mix(nt, fac, a, b):
    n = nt.nodes.new("ShaderNodeMix")
    n.data_type = "RGBA"
    for v, sock in ((fac, n.inputs[0]), (a, n.inputs[6]), (b, n.inputs[7])):
        if isinstance(v, tuple):
            sock.default_value = v
        elif isinstance(v, (int, float)):
            sock.default_value = v
        else:
            nt.links.new(v, sock)
    return n.outputs[2]


def _finish(nt, col, ao_floor=0.5, glint=True, glint_col=(1, 1, 1, 1)):
    """colour x baked occlusion (+ a glint on convex edges) into the emission the bake reads."""
    ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
    ao.inputs["Distance"].default_value = 0.25
    ao.samples = 16
    k = _math(nt, "MULTIPLY_ADD", ao.outputs["AO"], 1.0 - ao_floor, ao_floor)
    col = _mix(nt, 0.0, col, (1, 1, 1, 1))  # a copy we can multiply
    mul = nt.nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs[0].default_value = 1.0
    nt.links.new(col, mul.inputs[6])
    comb = nt.nodes.new("ShaderNodeCombineColor")
    for i in range(3):
        nt.links.new(k, comb.inputs[i])
    nt.links.new(comb.outputs[0], mul.inputs[7])
    out_col = mul.outputs[2]
    if glint:
        # the glint lies on the CHAMFERS: a face whose normal leans off every axis. Pointiness was tried
        # first and on a mesh this coarse it is a per-vertex value smeared over whole faces (glassy streaks)
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        sn = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Normal"], sn.inputs[0])
        big = _math(nt, "MAXIMUM", _math(nt, "ABSOLUTE", sn.outputs[0]),
                    _math(nt, "MAXIMUM", _math(nt, "ABSOLUTE", sn.outputs[1]), _math(nt, "ABSOLUTE", sn.outputs[2])))
        g = _math(nt, "LESS_THAN", big, 0.97)
        g = _math(nt, "MULTIPLY", g, 0.8)
        out_col = _mix(nt, g, out_col, glint_col)
    em = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(out_col, em.inputs["Color"])
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(em.outputs[0], out.inputs["Surface"])


def band_material(name, y_lo=-0.5, y_hi=0.5, dip=DIP, top_blue=True):
    """The Aero bands over the object's own height (game y_lo..y_hi), dipping into a V in the middle of
    each side face, the left half of every face (seen from outside) a shade lighter: the emblem."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sn = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(geo.outputs["Normal"], sn.inputs[0])
    bx, by, bz = sep.outputs[0], sep.outputs[1], sep.outputs[2]
    nx, ny, nz = sn.outputs[0], sn.outputs[1], sn.outputs[2]
    # across the face: for a face looking along Blender X it is -y*sign, along Y it is x*sign
    h = _math(nt, "ADD", _math(nt, "MULTIPLY", by, _math(nt, "MULTIPLY", nx, -1.0)),
              _math(nt, "MULTIPLY", bx, ny))
    mid = (y_lo + y_hi) / 2.0
    span = (y_hi - y_lo)
    t = _math(nt, "DIVIDE", _math(nt, "SUBTRACT", bz, mid), span)       # -0.5..0.5 over the height
    ah = _math(nt, "MINIMUM", _math(nt, "ABSOLUTE", h), 0.5)
    d = _math(nt, "MULTIPLY", _math(nt, "MULTIPLY_ADD", ah, -2.0, 1.0), dip)
    above = _math(nt, "GREATER_THAN", t, _math(nt, "SUBTRACT", BAND, d))
    below = _math(nt, "LESS_THAN", t, _math(nt, "SUBTRACT", -BAND, d))
    left = _math(nt, "LESS_THAN", h, 0.0)
    blue = _mix(nt, left, srgb(BLUE[1]), srgb(BLUE[0]))
    white = _mix(nt, left, srgb(WHITE[1]), srgb(WHITE[0]))
    orange = _mix(nt, left, srgb(ORANGE[1]), srgb(ORANGE[0]))
    col = _mix(nt, above, white, blue)
    col = _mix(nt, below, col, orange)
    # the top all blue, the bottom all orange
    if top_blue:
        col = _mix(nt, _math(nt, "GREATER_THAN", nz, 0.7), col, blue)
    col = _mix(nt, _math(nt, "LESS_THAN", nz, -0.7), col, orange)
    _finish(nt, col)
    return m


def flat_material(name, c, ao_floor=0.45, glint=True, glint_col=(1, 1, 1, 1)):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    rgb = nt.nodes.new("ShaderNodeRGB")
    rgb.outputs[0].default_value = srgb(c)
    _finish(nt, rgb.outputs[0], ao_floor, glint, glint_col)
    return m


# ── geometry ───────────────────────────────────────────────────────────────────────────────────

def new_obj(name, me):
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def box(name, lo, hi, mat):
    """An axis box between two GAME points."""
    a, b = G(*lo), G(*hi)
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    ctr = (a + b) / 2
    size = Vector((abs(b.x - a.x), abs(b.y - a.y), abs(b.z - a.z)))
    for v in bm.verts:
        v.co = Vector((v.co.x * size.x, v.co.y * size.y, v.co.z * size.z)) + ctr
    bm.to_mesh(me)
    bm.free()
    ob = new_obj(name, me)
    ob.data.materials.append(mat)
    return ob


def cyl(name, centre, axis, r, depth, verts, mat, phase=0.0):
    """A prism of `verts` sides round a GAME axis."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=verts, radius1=r, radius2=r, depth=depth)
    bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(phase, 3, "Z"))
    ax = G(*axis).normalized()
    rot = Vector((0, 0, 1)).rotation_difference(ax).to_matrix()
    bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=rot)
    bmesh.ops.translate(bm, verts=bm.verts, vec=G(*centre))
    bm.to_mesh(me)
    bm.free()
    ob = new_obj(name, me)
    ob.data.materials.append(mat)
    return ob


def bar(name, a, b, w, t, mat):
    """A flat bar between two GAME points: an elongated hexagon section, its width horizontal."""
    A, B = G(*a), G(*b)
    ax = (B - A).normalized()
    side = ax.cross(Vector((0, 0, 1)))
    if side.length < 1e-4:
        side = Vector((1, 0, 0))
    side.normalize()
    up = side.cross(ax)
    sec = [(w / 2, 0), (w / 4, t / 2), (-w / 4, t / 2), (-w / 2, 0), (-w / 4, -t / 2), (w / 4, -t / 2)]
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    va = [bm.verts.new(A + side * s + up * u) for s, u in sec]
    vb = [bm.verts.new(B + side * s + up * u) for s, u in sec]
    for i in range(6):
        j = (i + 1) % 6
        bm.faces.new((va[i], va[j], vb[j], vb[i]))
    bm.faces.new(list(reversed(va)))
    bm.faces.new(vb)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    ob = new_obj(name, me)
    ob.data.materials.append(mat)
    return ob


def bevel(ob, width, segments=2, limit_angle=None):
    md = ob.modifiers.new("bevel", "BEVEL")
    md.width = width
    md.segments = segments
    md.harden_normals = False
    if limit_angle is not None:
        md.limit_method = "ANGLE"
        md.angle_limit = math.radians(limit_angle)
    else:
        md.limit_method = "NONE"
    apply(ob, md)


def cut(ob, cutter, transfer=True):
    """Boolean difference; the faces the cutter leaves take the cutter's material."""
    md = ob.modifiers.new("cut", "BOOLEAN")
    md.operation = "DIFFERENCE"
    md.solver = "EXACT"
    md.object = cutter
    md.use_self = True
    md.use_hole_tolerant = True
    if transfer:
        md.material_mode = "TRANSFER"
    before = len(ob.data.polygons)
    apply(ob, md)
    print("CUT", ob.name, cutter.name, before, "->", len(ob.data.polygons))
    bpy.data.objects.remove(cutter, do_unlink=True)


def union(ob, other):
    md = ob.modifiers.new("join", "BOOLEAN")
    md.operation = "UNION"
    md.solver = "EXACT"
    md.object = other
    md.material_mode = "TRANSFER"
    apply(ob, md)
    bpy.data.objects.remove(other, do_unlink=True)


def apply(ob, md):
    bpy.context.view_layer.objects.active = ob
    with bpy.context.temp_override(object=ob, active_object=ob):
        bpy.ops.object.modifier_apply(modifier=md.name)


def join(objs, name):
    for o in bpy.context.selected_objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    objs[0].name = name
    return objs[0]


def set_origin(ob, game_pt):
    """Moves the object's origin to a GAME point, the mesh staying where it is."""
    p = G(*game_pt)
    ob.data.transform(Matrix.Translation(-p))
    ob.location = p


def chevron_cutter(name, centre, normal, right, half_w, height, stroke, depth, mat):
    """Two slanted bars forming a V on a face, as a cutter `depth` into it."""
    out = []
    top = centre + Vector((0, 0, height / 2))
    bot = centre - Vector((0, 0, height / 2))
    for s in (-1, 1):
        a = top + right * (half_w * s)
        me = bpy.data.meshes.new(name)
        bm = bmesh.new()
        d = (bot - a).normalized()
        perp = normal.cross(d).normalized()
        ends = [a - d * stroke * 0.3, bot + d * stroke * 0.3]
        vs = []
        for e in ends:
            for sg in (-1, 1):
                for dd in (-depth, depth):
                    vs.append(bm.verts.new(e + perp * (stroke / 2 * sg) + normal * dd))
        bmesh.ops.convex_hull(bm, input=vs)
        bm.to_mesh(me)
        bm.free()
        o = new_obj(name + str(s), me)
        o.data.materials.append(mat)
        out.append(o)
    return join(out, name)


# ── the models ─────────────────────────────────────────────────────────────────────────────────

def build_block():
    band = band_material("aero_band")
    ink = flat_material("aero_ink", (16, 16, 20), ao_floor=0.6, glint=False)
    vent = flat_material("aero_vent", (40, 42, 50), ao_floor=0.3, glint=False)
    ob = box("aero_block", (-0.5, -0.5, -0.5), (0.5, 0.5, 0.5), band)
    bevel(ob, C, 2)
    # four side faces: game normals +-X, +-Z
    for n_game in ((1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1)):
        n = G(*n_game).normalized()
        right = Vector((0, 0, 1)).cross(n).normalized()
        face_c = n * 0.5
        # the chevron in the white band (its middle dips with the bands)
        cc = face_c + Vector((0, 0, -DIP * 0.5))
        cutter = chevron_cutter("chev", cc, n, right, 0.19, 0.12, 0.075, 0.008, ink)
        cut(ob, cutter)
        # three vent slots each side in the orange band
        for s in (-1, 1):
            for k in range(3):
                z = -0.27 - 0.065 * k
                length = 0.18 - 0.03 * k
                ctr = face_c + right * (s * (0.20 + length / 2)) + Vector((0, 0, z))
                lo_b = ctr - right * (length / 2) - Vector((0, 0, 0.011)) - n * 0.012
                hi_b = ctr + right * (length / 2) + Vector((0, 0, 0.011)) + n * 0.012
                me = bpy.data.meshes.new("vent")
                bm = bmesh.new()
                bmesh.ops.create_cube(bm, size=1.0)
                size = Vector([abs(hi_b[i] - lo_b[i]) for i in range(3)])
                c2 = (lo_b + hi_b) / 2
                for v in bm.verts:
                    v.co = Vector([v.co[i] * size[i] for i in range(3)]) + c2
                bm.to_mesh(me)
                bm.free()
                vc = new_obj("vent", me)
                vc.data.materials.append(vent)
                cut(ob, vc)
    return {"aero_block_bl": (ob, (0, 0, 0))}


TC = (0.0, -0.385, -0.25)
R, W = 0.50, 0.36
RIM_R = 0.34
ARM_PIVOT = (0.0, -0.05, 0.28)


def build_wheel():
    pyl_mat = band_material("aero_pylon", y_lo=-0.32, y_hi=0.22, dip=0.0)
    carbon = flat_material("aero_carbon", (40, 42, 50), ao_floor=0.5, glint=False, glint_col=srgb((150, 154, 168)))
    upright = band_material("aero_upright", y_lo=TC[1] - 0.18, y_hi=TC[1] + 0.22, dip=0.0)
    rubber = flat_material("aero_rubber", (32, 32, 37), ao_floor=0.35, glint=False, glint_col=srgb((90, 90, 100)))
    titan = flat_material("aero_titan", (186, 192, 202), ao_floor=0.45, glint=False)
    stripe = flat_material("aero_stripe", ORANGE[0], ao_floor=0.6, glint=False)
    hub = flat_material("aero_hub", BLUE[0], ao_floor=0.6, glint=False)
    # the PYLON: a tapered box, bevelled
    py = box("pylon", (-0.20, -0.32, 0.28), (0.20, 0.22, 0.5), pyl_mat)
    bm = bmesh.new()
    bm.from_mesh(py.data)
    for v in bm.verts:
        if v.co.y < -0.3:            # the front (game z 0.28) end, taper it
            v.co.x *= 0.65
            v.co.z = (v.co.z - G(0, -0.05, 0).z) * 0.60 + G(0, -0.06, 0).z
    bm.to_mesh(py.data)
    bm.free()
    bevel(py, 0.02, 1)
    # the ARM: wishbones, push rod, upright, axle
    up_top = (0.0, TC[1] + 0.17, -0.02)
    up_bot = (0.0, TC[1] - 0.13, -0.02)
    arm = []
    for sx in (-0.10, 0.10):
        arm.append(bar("wb", (sx, 0.04, 0.28), up_top, 0.06, 0.022, carbon))
        arm.append(bar("wb", (sx, -0.18, 0.28), up_bot, 0.06, 0.022, carbon))
    arm.append(bar("rod", (0.0, 0.09, 0.30), (0.0, up_bot[1] + 0.03, 0.01), 0.035, 0.035, carbon))
    u = box("upright", (-0.07, up_bot[1] - 0.03, -0.065), (0.07, up_top[1] + 0.03, 0.025), upright)
    bevel(u, 0.02, 2)
    arm.append(u)
    arm.append(cyl("axle", (0.0, TC[1], -0.07), (0, 0, 1), 0.06, 0.03, 8, carbon))
    arm_ob = join(arm, "aero_wheel_bl_arm")
    # the TYRE: a 12-sided ring with bevelled shoulders, hollow in the middle
    tyre = cyl("tyre", TC, (0, 0, 1), R, W, 12, rubber, phase=math.pi / 12)
    bevel(tyre, C, 2, limit_angle=50)
    hole = cyl("hole", TC, (0, 0, 1), RIM_R, W + 0.2, 12, rubber, phase=math.pi / 12)
    cut(tyre, hole, transfer=False)
    # an orange ring on the outer sidewall, set in a few millimetres
    ring_o = cyl("ring_o", (TC[0], TC[1], TC[2] - W / 2), (0, 0, 1), 0.452, 0.012, 24, stripe)
    ring_i = cyl("ring_i", (TC[0], TC[1], TC[2] - W / 2), (0, 0, 1), 0.428, 0.03, 24, stripe)
    cut(ring_o, ring_i, transfer=False)
    cut(tyre, ring_o)
    # the RIM: a disc recessed 0.03 into the outer face, six real spoke holes, a blue hub
    rz = TC[2] - W / 2 + 0.045
    rim = cyl("rim", (TC[0], TC[1], rz), (0, 0, 1), RIM_R + 0.004, 0.03, 12, titan, phase=math.pi / 12)
    for k in range(6):
        a = (k + 0.5) * math.pi / 3
        pts = []
        for r0, da in ((0.135, 0.20), (0.135, -0.20), (0.30, -0.33), (0.30, 0.33)):
            pts.append((TC[0] + r0 * math.cos(a + da * 0.5 * (0.2 / r0 * 2.2)), TC[1] + r0 * math.sin(a + da * 0.5 * (0.2 / r0 * 2.2))))
        me = bpy.data.meshes.new("hole")
        bmh = bmesh.new()
        vs = []
        for (x, y) in pts:
            for dz in (-0.05, 0.05):
                vs.append(bmh.verts.new(G(x, y, rz + dz)))
        bmesh.ops.convex_hull(bmh, input=vs)
        bmh.to_mesh(me)
        bmh.free()
        cutter = new_obj("spoke_hole", me)
        cutter.data.materials.append(titan)
        cut(rim, cutter, transfer=False)
    hubo = cyl("hub", (TC[0], TC[1], rz - 0.02), (0, 0, 1), 0.10, 0.03, 12, hub)
    bevel(hubo, 0.012, 1)
    tyre_ob = join([tyre, rim, hubo], "aero_wheel_bl_tyre")
    py.name = "aero_wheel_bl_body"
    return {"aero_wheel_bl_body": (py, (0, 0, 0)), "aero_wheel_bl_arm": (arm_ob, ARM_PIVOT),
            "aero_wheel_bl_tyre": (tyre_ob, TC)}


# ── bake and export ────────────────────────────────────────────────────────────────────────────

def bake_and_export(name, parts):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 96
    scene.cycles.use_denoising = False   # this build has no OIDN, and with it on the bake comes out black
    scene.render.bake.margin = 3
    objs = [ob for ob, _ in parts.values()]
    # one shared UV atlas over every part
    for o in bpy.context.selected_objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
        if not o.data.uv_layers:
            o.data.uv_layers.new(name="UVMap")
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    print("UVCTX", [(o.name, len(o.data.polygons)) for o in objs])
    bpy.ops.uv.smart_project(angle_limit=math.radians(40), island_margin=0.01, area_weight=0.0)
    bpy.ops.uv.pack_islands(margin=0.004, rotate=True)
    bpy.ops.object.mode_set(mode="OBJECT")
    img = bpy.data.images.new(name + "_texture", TEX, TEX, alpha=False)
    for o in objs:
        for m in o.data.materials:
            nt = m.node_tree
            tn = nt.nodes.new("ShaderNodeTexImage")
            tn.image = img
            nt.nodes.active = tn
    # the shared world: a mid grey sky, so occlusion means the corners and nothing else
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (1, 1, 1, 1)
    scene.world = world
    bpy.ops.object.bake(type="EMIT", margin=3, use_clear=True)
    px = list(img.pixels)
    print("BAKEPX", max(px[0::4]), max(px[1::4]), sum(px[0::4]) / (len(px) / 4))
    img.filepath_raw = OUT_PNG % name
    img.file_format = "PNG"
    img.save()
    # export: one plain textured material on every part, each part's origin at its pivot
    exp = bpy.data.materials.new(name)
    exp.use_nodes = True
    nt = exp.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    tn = nt.nodes.new("ShaderNodeTexImage")
    tn.image = img
    tn.interpolation = "Closest"
    nt.links.new(tn.outputs["Color"], bsdf.inputs["Base Color"])
    tris = 0
    for part, (ob, pivot) in parts.items():
        ob.name = part
        ob.data.materials.clear()
        ob.data.materials.append(exp)
        set_origin(ob, pivot)
        ob.data.calc_loop_triangles()
        t = len(ob.data.loop_triangles)
        tris += t
        print("%s: %d triangles" % (part, t))
    print("%s: %d triangles" % (name, tris))
    for o in bpy.context.selected_objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=OUT_GLB % name, export_format="GLB", use_selection=True,
                              export_yup=True, export_apply=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["aero_block_bl"]
    for name in argv:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        parts = build_block() if name == "aero_block_bl" else build_wheel()
        bake_and_export(name, parts)


main()
