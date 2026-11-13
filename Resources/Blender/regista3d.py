"""Regista 3D templates (issue #34): the shared runner and toolkit for headless Blender.

Usage: blender -b --factory-startup -P regista3d.py -- JOB.json

JOB = {"template": "stat_3d", "out": DIR, "width": 1080, "height": 1080, "fps": 30, "seconds": 3,
       "samples": 32, "percent": 100, "frames": [optional list of frame numbers], "fields": {...}}
Fields arrive resolved by Regista: colours as #RRGGBB, fonts and images as absolute paths.

A template is a module in templates/ with build(K) -> (update, layers):
  update(t, layer) poses the scene for t seconds (and shows what belongs to `layer`);
  layers is a list of layer names, each rendered to OUT/<layer>/0001.png… (RGBA, straight alpha).
"""
import bpy, bmesh, importlib, json, math, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))


# ---- colour ----------------------------------------------------------------------------------------------------
def lin(hexs, a=1.0):
    """sRGB hex -> linear RGBA (view transform Standard keeps the brand hex exact)."""
    h = hexs.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c) + (a,)


def shade(rgba, k):
    return (rgba[0] * k, rgba[1] * k, rgba[2] * k, rgba[3])


# ---- easing ----------------------------------------------------------------------------------------------------
def clamp01(x):
    return 0.0 if x < 0 else 1.0 if x > 1 else x


def ease_out(x, p=3):
    return 1 - (1 - clamp01(x)) ** p


def ease_in_out(x):
    x = clamp01(x)
    return 4 * x * x * x if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def spring(t, zeta=0.45, f=1.7):
    """0 → 1 with a small overshoot; t in seconds since the start of the move."""
    if t <= 0:
        return 0.0
    w = 2 * math.pi * f
    wd = w * math.sqrt(1 - zeta ** 2)
    return 1 - math.exp(-zeta * w * t) * (math.cos(wd * t) + zeta * w / wd * math.sin(wd * t))


def window(t, start, length):
    """Progress 0…1 of a move that starts at `start` and lasts `length` seconds."""
    return clamp01((t - start) / length) if length > 0 else float(t >= start)


# ---- toolkit -----------------------------------------------------------------------------------------------------
class Kit:
    """What a template builds with. Units: 100 px of the output frame = 1 Blender unit on the z=0 plane."""

    def __init__(self, job):
        self.job = job
        self.f = job.get("fields", {})
        self.W, self.H = job["width"], job["height"]
        self.fps = job["fps"]
        self.seconds = job["seconds"]
        self.sc = bpy.context.scene
        self._fonts = {}

    def field(self, name, default=None):
        v = self.f.get(name)
        return default if v is None or v == "" else v

    # px on the output frame (origin top-left) -> world units on z=0 (origin centre, y up)
    def at(self, x, y, z=0.0):
        return ((x - self.W / 2) / 100, (self.H / 2 - y) / 100, z)

    def link(self, ob, parent=None):
        self.sc.collection.objects.link(ob)
        if parent is not None:
            ob.parent = parent
        return ob

    def empty(self, name="group", parent=None):
        return self.link(bpy.data.objects.new(name, None), parent)

    # -- materials
    def material(self, name, color, metallic=0.0, roughness=0.4, emission=0.0, coat=0.0):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        b = m.node_tree.nodes["Principled BSDF"]
        b.inputs["Base Color"].default_value = color
        b.inputs["Metallic"].default_value = metallic
        b.inputs["Roughness"].default_value = roughness
        if coat:
            b.inputs["Coat Weight"].default_value = coat
        if emission:
            b.inputs["Emission Color"].default_value = color
            b.inputs["Emission Strength"].default_value = emission
        return m

    def gold(self, name="gold", color="#F4BD56"):
        return self.material(name, lin(color), metallic=1.0, roughness=0.28)

    def image_material(self, name, path):
        img = bpy.data.images.load(path, check_existing=True)
        img.alpha_mode = "STRAIGHT"
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        nt = m.node_tree
        b = nt.nodes["Principled BSDF"]
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = img
        nt.links.new(tex.outputs["Color"], b.inputs["Base Color"])
        nt.links.new(tex.outputs["Alpha"], b.inputs["Alpha"])
        b.inputs["Roughness"].default_value = 0.5
        m.surface_render_method = "BLENDED"
        return m, img

    # -- geometry
    def font(self, path):
        if path not in self._fonts:
            self._fonts[path] = bpy.data.fonts.load(path, check_existing=True)
        return self._fonts[path]

    def text(self, body, font, size, mat, extrude=0.08, bevel=0.012, align="CENTER", parent=None):
        cu = bpy.data.curves.new("text", "FONT")
        cu.body, cu.font, cu.size = body, self.font(font), size
        cu.align_x, cu.align_y = align, "CENTER"
        cu.extrude, cu.bevel_depth, cu.bevel_resolution = extrude, bevel, 3
        cu.materials.append(mat)
        return self.link(bpy.data.objects.new("text", cu), parent)

    def rounded_box(self, w, h, depth, mat, radius=None, parent=None):
        """A bevelled slab w × h (units), front face at z = 0, back at z = -depth."""
        me = bpy.data.meshes.new("box")
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1.0)
        bmesh.ops.scale(bm, vec=(w, h, depth), verts=bm.verts)
        bmesh.ops.translate(bm, vec=(0, 0, -depth / 2), verts=bm.verts)
        bm.to_mesh(me)
        bm.free()
        ob = self.link(bpy.data.objects.new("box", me), parent)
        me.materials.append(mat)
        r = min(radius if radius is not None else min(w, h) * 0.18, min(w, h, depth) / 2 * 0.98)
        bv = ob.modifiers.new("bevel", "BEVEL")
        bv.width, bv.segments = r, 6
        for p in me.polygons:
            p.use_smooth = True
        return ob

    def image_plane(self, path, height, parent=None):
        m, img = self.image_material("img", path)
        w = height * img.size[0] / max(img.size[1], 1)
        me = bpy.data.meshes.new("plane")
        me.from_pydata([(-w / 2, -height / 2, 0), (w / 2, -height / 2, 0), (w / 2, height / 2, 0), (-w / 2, height / 2, 0)],
                       [], [(0, 1, 2, 3)])
        me.uv_layers.new().data.foreach_set("uv", [0, 0, 1, 0, 1, 1, 0, 1])
        me.materials.append(m)
        return self.link(bpy.data.objects.new("image", me), parent)

    def width_of(self, ob):
        bpy.context.view_layer.update()
        return ob.evaluated_get(bpy.context.evaluated_depsgraph_get()).dimensions.x

    # -- camera and light
    def camera(self, distance=12.0, ortho=False):
        """Camera on +z looking at the origin; the z=0 plane maps exactly to the output frame (100 px per unit)."""
        cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
        d = cam.data
        d.sensor_fit = "HORIZONTAL"
        d.sensor_width = 36
        if ortho:
            d.type = "ORTHO"
            d.ortho_scale = self.W / 100
        else:
            d.lens = 36 * distance / (self.W / 100)
        d.clip_end = 200
        cam.location = (0, 0, distance)
        self.link(cam)
        self.sc.camera = cam
        return cam

    def studio_lights(self, key=600, warm=(1, 0.95, 0.88)):
        for name, loc, rot, energy, size, col in (
                ("key", (-5, 4, 8), (math.radians(-25), math.radians(-30), 0), key, 7, warm),
                ("rim", (6, 3, -3), (0, math.radians(115), math.radians(20)), key * 0.8, 4, (0.88, 0.92, 1)),
                ("fill", (4, -5, 9), (math.radians(30), math.radians(20), 0), key * 0.3, 8, (1, 1, 1))):
            L = bpy.data.lights.new(name, "AREA")
            L.energy, L.size, L.color = energy, size, col
            o = self.link(bpy.data.objects.new(name, L))
            o.location, o.rotation_euler = loc, rot

    def world(self, color=(0.5, 0.5, 0.52), strength=0.35):
        w = bpy.data.worlds.new("w")
        w.use_nodes = True
        bg = w.node_tree.nodes["Background"]
        bg.inputs[0].default_value = color + (1,)
        bg.inputs[1].default_value = strength
        self.sc.world = w


# ---- runner -----------------------------------------------------------------------------------------------------
def setup(job):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    r = sc.render
    r.resolution_x, r.resolution_y = job["width"], job["height"]
    r.resolution_percentage = job.get("percent", 100)
    r.fps = job["fps"]
    r.film_transparent = True
    r.image_settings.file_format = "PNG"
    r.image_settings.color_mode = "RGBA"
    r.image_settings.compression = 15
    r.engine = "BLENDER_EEVEE"
    sc.eevee.taa_render_samples = job.get("samples", 32)
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    return sc


def main():
    job_path = sys.argv[sys.argv.index("--") + 1]
    with open(job_path) as fh:
        job = json.load(fh)
    sc = setup(job)
    sys.modules.setdefault("regista3d", sys.modules[__name__])  # templates `import regista3d` (run as __main__)
    sys.path.insert(0, os.path.join(HERE, "templates"))
    mod = importlib.import_module(job["template"])
    K = Kit(job)
    update, layers = mod.build(K)
    post = getattr(mod, "post", None)  # optional per-frame image pass: post(K, path)
    total = max(1, int(round(job["seconds"] * job["fps"])))
    frames = job.get("frames") or list(range(1, total + 1))
    t0 = time.time()
    for layer in layers:
        os.makedirs(os.path.join(job["out"], layer), exist_ok=True)
    for f in frames:
        t = (f - 1) / job["fps"]
        for layer in layers:
            update(t, layer)
            sc.frame_set(f)
            sc.render.filepath = os.path.join(job["out"], layer, "%04d.png" % f)
            bpy.ops.render.render(write_still=True)
            if post:
                post(K, sc.render.filepath)
    el = time.time() - t0
    print("RESULT template=%s frames=%d layers=%s total=%.1fs per_frame=%.2fs" % (
        job["template"], len(frames), ",".join(layers), el, el / max(len(frames), 1)))


if __name__ == "__main__":
    main()
