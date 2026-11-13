"""infinite-triangle-3d: the Arkad intro, 7 s, 1080 × 1080, transparent.

1. The endless (Penrose) triangle: three square beams along X, Y and Z, seen down the (1,1,1) diagonal where the
   end of the third falls exactly in front of the start of the first, so the corners look joined. It drifts by
   turning about that diagonal (the view axis), which keeps the illusion.
2. It flattens along the view axis (invisible to the orthographic camera, only the shading evens out) and makes
   one full turn about the vertical; edge-on, the flat sheet is swapped for a solid dark triangle shaped like the
   mark, and the camera for a perspective one framing the same plane.
3. Face-on, two sparks of Arkad yellow start from the base corners and draw the outline; it flares, goes out, and
   the yellow Arkad logo is left in the triangle's place.
The light (outline, sparks, edge glints) is drawn on each rendered frame by `post`."""
import math, re
import bmesh, bpy
from mathutils import Vector
import regista3d as r3


def svg_polygons(path, steps=12):
    """Every subpath of the file's path data as a list of (x, y) points (M/L/H/V/C/Z, absolute and relative)."""
    d = re.search(r' d="([^"]+)"', open(path).read()).group(1)
    toks = re.findall(r"[MmLlHhVvCcZz]|-?\d*\.?\d+(?:e-?\d+)?", d)
    polys, cur, pos, start, i, cmd = [], [], (0.0, 0.0), (0.0, 0.0), 0, None

    def num():
        nonlocal i
        i += 1
        return float(toks[i - 1])

    while i < len(toks):
        if re.match(r"[A-Za-z]", toks[i]):
            cmd = toks[i]
            i += 1
        if cmd in "Zz":
            polys.append(cur)
            cur, pos = [], start
            continue
        rel, c = cmd.islower(), cmd.upper()
        if c == "M":
            x, y = num(), num()
            pos = (pos[0] + x, pos[1] + y) if rel else (x, y)
            start, cur, cmd = pos, [pos], ("l" if rel else "L")
        elif c == "L":
            x, y = num(), num()
            pos = (pos[0] + x, pos[1] + y) if rel else (x, y)
            cur.append(pos)
        elif c == "H":
            x = num()
            pos = (pos[0] + x if rel else x, pos[1])
            cur.append(pos)
        elif c == "V":
            y = num()
            pos = (pos[0], pos[1] + y if rel else y)
            cur.append(pos)
        elif c == "C":
            p = [num() for _ in range(6)]
            if rel:
                p = [p[k] + pos[k % 2] for k in range(6)]
            x0, y0 = pos
            for k in range(1, steps + 1):
                t = k / steps
                u = 1 - t
                cur.append((u ** 3 * x0 + 3 * u * u * t * p[0] + 3 * u * t * t * p[2] + t ** 3 * p[4],
                            u ** 3 * y0 + 3 * u * u * t * p[1] + 3 * u * t * t * p[3] + t ** 3 * p[5]))
            pos = (p[4], p[5])
    return [[q for k, q in enumerate(P) if k == 0 or (abs(q[0] - P[k - 1][0]) + abs(q[1] - P[k - 1][1])) > 1e-6] for P in polys]


def box(bm, x0, x1, y0, y1, z0, z1, keep=None):
    """An axis-aligned box; `keep` = the outward normals of the faces to build (default all six)."""
    faces = {
        "+x": [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        "-x": [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)],
        "+y": [(x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0)],
        "-y": [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        "+z": [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        "-z": [(x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0)],
    }
    for k, quad in faces.items():
        if keep is None or k in keep:
            bm.faces.new([bm.verts.new(p) for p in quad])


def rounded_triangle(corners, r, steps=10):
    """Closed outline of a triangle (counter-clockwise corners) with corners rounded by r; also the index of each
    corner's arc midpoint in the outline."""
    out, mids = [], []
    n = len(corners)
    for i in range(n):
        p, a, b = Vector(corners[i]), Vector(corners[i - 1]), Vector(corners[(i + 1) % n])
        u, v = (a - p).normalized(), (b - p).normalized()
        half = u.angle(v) / 2
        c = p + (u + v).normalized() * (r / math.sin(half))  # the arc's centre, inside the corner
        n0 = Vector((-u.y, u.x))  # outward normals of the incoming and outgoing edges (counter-clockwise outline)
        n1 = Vector((v.y, -v.x))
        a0, a1 = math.atan2(n0.y, n0.x), math.atan2(n1.y, n1.x)
        while a1 < a0:
            a1 += 2 * math.pi
        for k in range(steps + 1):
            ang = a0 + (a1 - a0) * k / steps
            out.append(c + Vector((math.cos(ang), math.sin(ang))) * r)
        mids.append(len(out) - 1 - steps // 2)
    return out, mids


def dark_material(name, color, culling):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.use_backface_culling = culling
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = r3.lin(color)
    b.inputs["Roughness"].default_value = 0.42
    b.inputs["Specular IOR Level"].default_value = 0.6
    return m, b


def build(K):
    f = K.field
    k = K.seconds / 7.0  # the timeline below is written for 7 s and stretches with the clip
    scale = float(f("scale", 9.0))  # world units across the frame width
    ppu = K.W / scale  # px per unit on the plane through the frame centre
    color = f("color", "#34322F")
    K.fx = {"edge": 0.0, "run": -1.0, "flare": 0.0, "ppu": ppu}

    # the stage: local XY = the screen plane through the frame centre, +Z towards the camera, +Y up
    diag = Vector((1, 1, 1)).normalized()
    stage = K.empty("stage")
    stage.rotation_mode = "QUATERNION"
    stage.rotation_quaternion = q = (-diag).to_track_quat("-Z", "Y")
    turner = K.empty("turner", stage)  # the full turn, about the vertical
    spinner = K.empty("spinner", turner)  # the drift, about the view axis

    # -- the endless triangle, built in world axes and baked into stage coordinates
    L, w = 4.0, float(f("beam", 0.95))
    h = w / 2
    bm = bmesh.new()
    box(bm, -h, L + h, -h, h, -h, h)  # A along +X (holds the first and second corners)
    box(bm, L - h, L + h, h, L + h, -h, h)  # B along +Y (holds the third corner)
    box(bm, L - h, L + h, L - h, L + h, h, L - h, keep={"+x", "-x", "+y", "-y", "-z"})  # C along +Z, open on top
    # the closing corner: only the two faces the camera sees; through the missing +X face (back faces culled) the
    # start of A shows, lined up with them — the joint that cannot exist
    box(bm, L - h, L + h, L - h, L + h, L - h, L + h, keep={"+y", "+z"})
    centre = Vector((2 * L / 3, L / 3, 0))  # mean of the three visible corners (0,0,0), (L,0,0), (L,L,0)
    to_stage = q.inverted()
    for v in bm.verts:
        v.co = to_stage @ (v.co - centre)
    me = bpy.data.meshes.new("tribar")
    bm.to_mesh(me)
    bm.free()
    m_tri, b_tri = dark_material("tribar", color, culling=True)
    me.materials.append(m_tri)
    tri = K.link(bpy.data.objects.new("tribar", me), spinner)

    # -- the solid triangle and the logo, both from the mark's SVG, face-on in the stage plane
    polys = svg_polygons(f("svg"))
    outer, hole = polys[0], polys[1]
    xs, ys = [p[0] for p in outer], [p[1] for p in outer]
    size = float(f("size", 640)) / ppu  # the logo's width in units
    s = size / (max(xs) - min(xs))
    ox, oy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2

    def to2(p):
        return ((p[0] - ox) * s, -(p[1] - oy) * s)

    # the mark's three corners: top, bottom-left, right (counter-clockwise once y points up)
    tips = [min(outer, key=lambda p: p[1]), max(outer, key=lambda p: p[1] - p[0]), max(outer, key=lambda p: p[0])]
    outline, mids = rounded_triangle([to2(p) for p in tips], r=0.12 * size / 6)
    depth = float(f("depth", 70)) / ppu
    bevel = 0.035
    cu = bpy.data.curves.new("frame", "CURVE")
    cu.dimensions, cu.fill_mode = "2D", "BOTH"
    cu.extrude = depth / 2 - bevel
    cu.bevel_depth, cu.bevel_resolution = bevel, 3
    # the hole: the mark's inner triangle, opened up so the inner walls catch the light
    hc = Vector(map(sum, zip(*[to2(p) for p in hole]))) / len(hole)
    opening = float(f("hole", 1.7))
    for P in (outline, [hc + (Vector(to2(p)) - hc) * opening for p in hole]):
        sp = cu.splines.new("POLY")
        sp.points.add(len(P) - 1)
        for i, p in enumerate(P):
            sp.points[i].co = (p.x, p.y, 0, 1)
        sp.use_cyclic_u = True
    m_frame, b_frame = dark_material("frame", color, culling=False)
    cu.materials.append(m_frame)
    frame = K.link(bpy.data.objects.new("frame", cu), turner)
    frame.location.z = -depth / 2  # front face on the stage plane

    lcu = bpy.data.curves.new("logo", "CURVE")
    lcu.dimensions, lcu.fill_mode = "2D", "BOTH"
    for P in (outer, hole):
        sp = lcu.splines.new("POLY")
        sp.points.add(len(P) - 1)
        for i, p in enumerate(P):
            x, y = to2(p)
            sp.points[i].co = (x, y, 0, 1)
        sp.use_cyclic_u = True
    m_logo = bpy.data.materials.new("logo")
    m_logo.use_nodes = True
    m_logo.surface_render_method = "BLENDED"
    nt = m_logo.node_tree
    nt.nodes.remove(nt.nodes["Principled BSDF"])
    tc, sep = nt.nodes.new("ShaderNodeTexCoord"), nt.nodes.new("ShaderNodeSeparateXYZ")
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value, mr.inputs["From Max"].default_value = -size / 2, size / 2
    ramp = nt.nodes.new("ShaderNodeValToRGB")  # the logo's own gradient, left to right, unlit: exact brand hex
    ramp.color_ramp.elements[0].color = r3.lin(f("colorLeft", "#F6CF6B"))
    ramp.color_ramp.elements[1].color = r3.lin(f("colorRight", "#BE8602"))
    em, clear, mix = (nt.nodes.new(n) for n in ("ShaderNodeEmission", "ShaderNodeBsdfTransparent", "ShaderNodeMixShader"))
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    nt.links.new(sep.outputs["X"], mr.inputs["Value"])
    nt.links.new(mr.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], em.inputs["Color"])
    nt.links.new(clear.outputs[0], mix.inputs[1])
    nt.links.new(em.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], nt.nodes["Material Output"].inputs["Surface"])
    lcu.materials.append(m_logo)
    logo = K.link(bpy.data.objects.new("logo", lcu), turner)
    logo.location.z = 0.004

    # -- light and cameras
    K.sc.eevee.use_shadows = False  # a shadow would give the trick away
    K.world(color=(0.05, 0.05, 0.06), strength=0.6)
    suns = {}
    glow_hex = f("glow", "#F4BD56")
    for name, vec, energy, col in (("key", (0.15, 0.35, 1.0), 4.2, (0.96, 0.97, 1.0)),
                                   ("warm", (-0.4, -0.9, -0.3), 2.2, r3.lin(glow_hex)[:3]),
                                   ("fill", (1.0, -0.2, 0.15), 0.7, (0.8, 0.86, 1))):
        sun = bpy.data.lights.new(name, "SUN")
        sun.energy, sun.color = energy, col
        o = K.link(bpy.data.objects.new(name, sun))
        o.rotation_euler = (-Vector(vec)).normalized().to_track_quat("-Z", "Y").to_euler()
        suns[name] = sun
    flare = bpy.data.lights.new("flare", "AREA")  # warms the face when the outline flares
    flare.size, flare.color, flare.energy = 6, r3.lin(glow_hex)[:3], 0
    fo = K.link(bpy.data.objects.new("flare", flare), stage)
    fo.location = (0, -1.5, 5)

    ortho = K.camera(distance=40, ortho=True)
    ortho.data.ortho_scale = scale
    persp = K.camera(distance=16)
    persp.data.lens = 36 * 16 / scale  # same framing of the stage plane
    for cam in (ortho, persp):
        cam.parent = stage  # looks down the stage's -Z with its +Y up

    theta0 = math.radians(float(f("startAngle", -40)))
    direction = -1 if f("direction", "cw") == "cw" else 1

    # the outline the sparks draw, in px: the base runs from both corners to its middle, each side from its base
    # corner up to the top
    def px(p):
        return (K.W / 2 + p.x * ppu, K.H / 2 - p.y * ppu)

    def arc(i0, i1):  # outline points from index i0 forward to i1
        n = len(outline)
        return [px(outline[(i0 + j) % n]) for j in range(((i1 - i0) % n) + 1)]

    iT, iBL, iR = mids
    base = arc(iBL, iR)
    half = len(base) // 2
    K.fx["paths"] = [arc(iT, iBL)[::-1], arc(iR, iT), base[:half + 1], base[half:][::-1]]

    def update(t, layer):
        theta = theta0 * (1 - r3.ease_in_out(r3.window(t, 0, 1.5 * k)))
        squash = 1 - 0.998 * r3.ease_in_out(r3.window(t, 0.95 * k, 0.5 * k))
        phi = direction * 2 * math.pi * r3.ease_in_out(r3.window(t, 1.35 * k, 2.0 * k))
        spinner.rotation_euler = (0, 0, theta)
        tri.scale = (1, 1, squash)
        turner.rotation_euler = (0, phi, 0)
        solid = abs(phi) > math.pi / 2  # past edge-on: the flat sheet is invisible, swap it for the solid one
        tri.hide_render, frame.hide_render = solid, not solid
        K.sc.camera = persp if solid else ortho
        out = r3.ease_in_out(r3.window(t, 5.15 * k, 0.55 * k))  # the flare goes out and the face goes dark
        flat = 1 - (squash - 0.002) / 0.998  # flattening turns every face to the camera: dim the key to keep it dark
        suns["key"].energy = 4.2 * (1 - 0.65 * flat) if not solid else 1.6 * (1 - 0.6 * out)
        run = r3.window(t, 3.5 * k, 1.2 * k)
        up = r3.ease_out(r3.window(t, 4.7 * k, 0.35 * k))
        down = out
        K.fx["edge"] = float(f("glowAmount", 1.0)) * 0.7 * (1 - r3.ease_in_out(r3.window(t, 0.9 * k, 0.5 * k)))
        K.fx["run"] = r3.ease_in_out(run) if t >= 3.5 * k else -1.0
        K.fx["flare"] = (1 + 1.4 * up) * (1 - down)
        flare.energy = 220 * up * (1 - down)
        reveal = r3.ease_in_out(r3.window(t, 5.65 * k, 0.55 * k))
        mix.inputs[0].default_value = reveal
        b_frame.inputs["Alpha"].default_value = 1 - r3.ease_in_out(r3.window(t, 5.95 * k, 0.3 * k))  # under the logo
        logo.hide_render = reveal <= 0

    return update, ["main"]


def post(K, path):
    """The light, drawn on the rendered frame so it follows what the eye sees: yellow glints on the lower edges of
    the endless triangle (never betraying the impossible joint), then the sparks and the glowing outline."""
    import numpy as np
    fx = K.fx
    if fx["edge"] <= 0 and fx["run"] < 0:
        return
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)  # rows bottom-up, straight alpha
    a = px[..., 3]
    sz = w / 1080

    def blur(x, r):
        r = max(1, int(round(r)))
        for axis in (0, 1):
            c = np.cumsum(np.pad(x, [(r + 1, r) if k == axis else (0, 0) for k in (0, 1)], mode="edge"), axis=axis)
            x = ((np.take(c, range(2 * r + 1, c.shape[axis]), axis=axis) - np.take(c, range(0, c.shape[axis] - 2 * r - 1), axis=axis))
                 / (2 * r + 1))
        return x

    def soft(x, sigma):
        """Three box passes ≈ a gaussian of `sigma` px, scaled so a 1 px-dense line peaks at 1."""
        r = max(1, int(round(sigma * sz)))
        return blur(blur(blur(x, r), r), r) * math.sqrt(2 * math.pi) * r

    glow = np.zeros((h, w), dtype=np.float32)
    core = np.zeros((h, w), dtype=np.float32)
    if fx["edge"] > 0:
        gy, gx = np.gradient(blur(a, 2 * sz))
        # the outward normal of the contour is -grad(alpha); keep the edges whose outside faces down (rows go up)
        edge = np.clip(np.clip(gy + gx * 0.25, 0, None) * 6.0, 0, 1)
        glow += np.clip(blur(edge, 3 * sz) * 1.4 + blur(edge, 14 * sz) * 1.2 + blur(edge, 40 * sz) * 0.6, 0, 1) * fx["edge"]
    if fx["run"] >= 0:
        line = np.zeros((h, w), dtype=np.float32)
        heads = np.zeros((h, w), dtype=np.float32)
        for run_path in fx["paths"]:
            P = np.array(run_path, dtype=np.float32) * (w / K.W)  # the render may be scaled down (percent)
            seg = np.linalg.norm(np.diff(P, axis=0), axis=1)
            cum = np.concatenate([[0], np.cumsum(seg)])
            lit = cum[-1] * fx["run"]
            n = max(2, int(lit / 0.5))
            d = np.linspace(0, lit, n)
            xs, ys = np.interp(d, cum, P[:, 0]), np.interp(d, cum, P[:, 1])
            np.add.at(line, (np.clip((h - 1 - ys).astype(int), 0, h - 1), np.clip(xs.astype(int), 0, w - 1)), 0.5)
            if fx["run"] < 1:
                hx, hy = int(xs[-1]), int(h - 1 - ys[-1])
                if 0 <= hx < w and 0 <= hy < h:
                    heads[hy, hx] += 1.0
        k = fx["flare"]
        r_spark = max(1, int(round(3 * sz)))
        dot = blur(blur(blur(heads, r_spark), r_spark), r_spark) * 2 * math.pi * r_spark ** 2  # a round point
        core += np.clip((np.clip(soft(line, 1.2) * 1.3, 0, 1) + dot * 1.6) * min(k, 1.0), 0, 1)
        halo = soft(line, 5) * 0.5 + soft(line, 16) * 0.28 + soft(line, 45) * 0.14
        spark = soft(soft(heads, 8), 8) * 1.4 + soft(soft(heads, 26), 26) * 0.5
        glow += np.clip((halo + spark) * k, 0, 1.6)
    hexs = K.field("glow", "#F4BD56").lstrip("#")
    col = np.array([int(hexs[i:i + 2], 16) / 255 for i in (0, 2, 4)], dtype=np.float32)
    hot = np.array([1.0, 0.96, 0.82], dtype=np.float32)  # the core runs whiter than the halo
    rgb = px[..., :3] * a[..., None] + glow[..., None] * col + core[..., None] * hot  # premultiplied sum
    out_a = np.clip(np.maximum(a, np.maximum(np.clip(glow, 0, 1), core)), 0, 1)
    rgb = np.clip(rgb, 0, None)
    px[..., :3] = np.where(out_a[..., None] > 1e-4, np.minimum(rgb / np.maximum(out_a[..., None], 1e-4), 1), 0)
    px[..., 3] = out_a
    img.pixels[:] = px.ravel()
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
