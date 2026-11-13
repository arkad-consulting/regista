import Foundation

/// The headless Blender script behind graphics.blenderTitle: the Python prototype's `title3d.py` (extruded
/// 3D title on two bevelled pills, spring-in, slow drift, EEVEE, transparent PNG sequence) with the colours,
/// font, size and frame rate passed in. Written next to the render and run with `blender -b -P`.
/// Bump `version` when the script changes: renders are cached by parameters + version.
enum BlenderTitleScript {
    static let version = 2

    static let source = #"""
"""Regista graphics.blenderTitle: extruded 3D title on two pills, transparent RGBA PNG sequence.
Usage: blender -b -P title3d.py -- OUT_DIR --line1 A --line2 B --font F.woff2 [--engine EEVEE|CYCLES] [--seconds 4]
       [--samples 64] [--fps 30] [--width 1080] [--height 540] [--pill1 #002FA7] [--pill2 #F7F4EC]
       [--text1 #F7F4EC] [--text2 #141414] [--accent #002FA7] [--accent-chars "="]
"""
import bpy, bmesh, math, os, sys, time, argparse

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--engine", default="EEVEE", choices=["EEVEE", "CYCLES"])
ap.add_argument("--seconds", type=float, default=4)
ap.add_argument("--samples", type=int, default=64)
ap.add_argument("--fps", type=int, default=30)
ap.add_argument("--width", type=int, default=1080)
ap.add_argument("--height", type=int, default=540)
ap.add_argument("--line1", default="AGGIORNATO")
ap.add_argument("--line2", default="")
ap.add_argument("--font", required=True)
ap.add_argument("--pill1", default="#002FA7")
ap.add_argument("--pill2", default="#F7F4EC")
ap.add_argument("--text1", default="#F7F4EC")
ap.add_argument("--text2", default="#141414")
ap.add_argument("--accent", default="#002FA7")
ap.add_argument("--accent-chars", default="=")
a = ap.parse_args(argv)
os.makedirs(a.out, exist_ok=True)


def lin(hexs):  # sRGB hex -> linear RGBA
    c = [int(hexs.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c] + [1]


def darker(hexs, k):
    c = lin(hexs)
    return [c[0] * k, c[1] * k, c[2] * k, 1]


FPS = a.fps
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.fps, sc.frame_start, sc.frame_end = FPS, 1, max(1, int(round(a.seconds * FPS)))
sc.render.resolution_x, sc.render.resolution_y, sc.render.resolution_percentage = a.width, a.height, 100
sc.render.film_transparent = True
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA"
sc.render.image_settings.compression = 15
sc.view_settings.view_transform = "Standard"  # brand hex in = brand hex out (AgX would desaturate)
sc.view_settings.exposure = 0.35
sc.render.filepath = os.path.join(a.out, "")

world = bpy.data.worlds.new("w")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.55, 0.58, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.3
sc.world = world


def mat(name, face, side):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.42
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    vt = nt.nodes.new("ShaderNodeVectorTransform")
    vt.vector_type, vt.convert_from, vt.convert_to = "NORMAL", "WORLD", "OBJECT"
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position, ramp.color_ramp.elements[0].color = 0.55, side
    ramp.color_ramp.elements[1].position, ramp.color_ramp.elements[1].color = 0.9, face
    nt.links.new(geo.outputs["Normal"], vt.inputs[0])
    nt.links.new(vt.outputs[0], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], ramp.inputs[0])
    nt.links.new(ramp.outputs[0], bsdf.inputs["Base Color"])
    return m


def text_obj(body, font, size, mats, accent):
    cu = bpy.data.curves.new("t", "FONT")
    cu.body, cu.font, cu.size = body, font, size
    cu.align_x, cu.align_y = "CENTER", "CENTER"
    cu.extrude, cu.bevel_depth, cu.bevel_resolution = 0.05, 0.016, 3
    ob = bpy.data.objects.new("t", cu)
    sc.collection.objects.link(ob)
    for m in mats:
        cu.materials.append(m)
    for i, ch in enumerate(body):
        if accent and ch in accent:
            cu.body_format[i].material_index = 1
    return ob


def pill(w, h, depth, m):
    r, n = h * 0.21, 10
    me = bpy.data.meshes.new("pill")
    bm = bmesh.new()
    pts = []
    for cx, cy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90),
                       (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)):
        for k in range(n + 1):
            t = math.radians(a0 + 90 * k / n)
            pts.append(bm.verts.new((cx + r * math.cos(t), cy + r * math.sin(t), 0)))
    bm.faces.new(pts)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("pill", me)
    sc.collection.objects.link(ob)
    me.materials.append(m)
    so = ob.modifiers.new("solid", "SOLIDIFY")
    so.thickness, so.offset = depth, -1
    bv = ob.modifiers.new("bevel", "BEVEL")
    bv.width, bv.segments, bv.limit_method = depth * 0.35, 4, "ANGLE"
    for p in me.polygons:
        p.use_smooth = True
    return ob


def width_of(ob):
    bpy.context.view_layer.update()
    return ob.evaluated_get(bpy.context.evaluated_depsgraph_get()).dimensions.x


font = bpy.data.fonts.load(os.path.expanduser(a.font))
lines = [(a.line1, a.pill1, a.text1)] + ([(a.line2, a.pill2, a.text2)] if a.line2 else [])
m_acc = mat("acc", lin(a.accent), darker(a.accent, 0.7))
# camera sees 7.2 units across at z=0 (150 px per unit at 1080 wide)
ys = [0.8, -0.78] if len(lines) == 2 else [0.0]
rows = []
for i, (body, pc, tc) in enumerate(lines):
    pm = mat("pill%d" % i, lin(pc), darker(pc, 0.75))
    tm = mat("txt%d" % i, lin(tc), darker(tc, 0.85))
    t = text_obj(body, font, 1.08, [tm, m_acc], a.accent_chars if i == 1 else None)
    w = width_of(t)
    if w > 6.0:  # keep long lines inside the frame
        k = 6.0 / w
        t.data.size *= k
        w = width_of(t)
    p = pill(w + 0.8, 1.36, 0.2, pm)
    p.location = (0, ys[i], 0)
    t.parent, t.location = p, (0, -0.03, 0.06)
    rows.append(p)

cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
cam.data.lens, cam.data.sensor_fit, cam.data.sensor_width = 50, "HORIZONTAL", 36
cam.location = (0, 0, 10)
sc.collection.objects.link(cam)
sc.camera = cam

for name, loc, rot, energy, size, col in (("key", (-4, 3, 6), (-0.35, -0.5, 0), 420, 6, (1, 0.97, 0.92)),
                                          ("rim", (5, 2, -1.5), (0, 1.9, 0.3), 350, 3, (0.85, 0.9, 1)),
                                          ("fill", (3, -4, 7), (0.5, 0.3, 0), 120, 6, (1, 1, 1))):
    L = bpy.data.lights.new(name, "AREA")
    L.energy, L.size, L.color = energy, size, col
    o = bpy.data.objects.new(name, L)
    o.location, o.rotation_euler = loc, rot
    sc.collection.objects.link(o)


def spring(t, zeta=0.42, f=1.6):
    if t <= 0:
        return 0.0
    w = 2 * math.pi * f
    wd = w * math.sqrt(1 - zeta ** 2)
    return 1 - math.exp(-zeta * w * t) * (math.cos(wd * t) + zeta * w / wd * math.sin(wd * t))


for i, p in enumerate(rows):
    base = p.location.copy()
    for f in range(sc.frame_start, sc.frame_end + 1):
        t = (f - 1) / FPS
        s = spring(t - 0.15 - i * 0.22)
        drift = math.sin(t * 1.3 + i * 0.9)
        p.rotation_euler = (math.radians(-95) * (1 - s) + math.radians(6) * drift * min(1, t / 1.5),
                            math.radians(7) * math.sin(t * 0.9 + i) * min(1, t / 1.5),
                            math.radians(-4 + 8 * i) * (1 - s))
        p.location = (base.x + (1 - s) * (-0.4 + 0.8 * i), base.y - (1 - s) * 0.7, base.z + (1 - s) * -1.0)
        k = 0.8 + 0.2 * s
        p.scale = (k, k, k)
        p.keyframe_insert("rotation_euler", frame=f)
        p.keyframe_insert("location", frame=f)
        p.keyframe_insert("scale", frame=f)

if a.engine == "CYCLES":
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = d.type == "METAL"
    sc.render.engine = "CYCLES"
    sc.cycles.device = "GPU"
    sc.cycles.samples = a.samples
    sc.cycles.use_denoising = True
else:
    sc.render.engine = "BLENDER_EEVEE"
    sc.eevee.taa_render_samples = a.samples
    sc.eevee.use_shadows = True

t0 = time.time()
bpy.ops.render.render(animation=True)
el = time.time() - t0
n = sc.frame_end - sc.frame_start + 1
print("RESULT engine=%s frames=%d total=%.1fs per_frame=%.2fs out=%s" % (a.engine, n, el, el / n, a.out))
"""#
}
