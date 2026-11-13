"""stat-3d: a big extruded number that counts up ("+40 %", "3×"), a label under it, and bars that rise
(or a curve that grows) from the values. Transparent overlay, 1080 × 600 (the top band): figure and
label on the left, chart on the right; without a chart the figure is centred."""
import math, re
import regista3d as r3


def parse(value):
    """'+40 %' -> ('+', 40.0, 0 decimals, ' %'); text without a number counts nothing."""
    m = re.match(r"^(\D*?)(\d+(?:[.,]\d+)?)(.*)$", value)
    if not m:
        return value, None, 0, "", "."
    num = m.group(2)
    sep = "," if "," in num else "."
    decimals = len(num.split(sep)[1]) if sep in num else 0
    return m.group(1), float(num.replace(",", ".")), decimals, m.group(3), sep


def build(K):
    f = K.field
    value = str(f("value", "+40 %"))
    label = str(f("label", "de temps gagné"))
    chart = f("chart", "bars")
    values = [float(v) for v in (f("values") or [2, 3, 5, 8])][:8]
    color = r3.lin(f("color", "#F4BD56"))
    accent = r3.lin(f("accent", "#D89528"))
    ink = r3.lin(f("labelColor", "#FFF2E9"))
    gold = f("material", "gold") == "gold"

    K.world(color=(0.08, 0.07, 0.06), strength=1.0)  # dark surroundings: the gold reflects contrast, not grey
    K.studio_lights(key=750)
    K.camera(distance=14)
    root = K.empty("root")
    root.location = K.at(K.W / 2, K.H / 2)

    m_num = K.material("num", color, metallic=1.0 if gold else 0.0, roughness=0.26 if gold else 0.35, coat=0 if gold else 0.6)
    m_bar = K.material("bar", color, metallic=0.7 if gold else 0.0, roughness=0.32, coat=0.5)
    m_top = K.material("top", accent, metallic=0.7 if gold else 0.0, roughness=0.3, coat=0.5)
    m_label = K.material("label", ink, roughness=0.5)

    parsed = parse(value)
    prefix, target = parsed[0], parsed[1]
    has_chart = chart in ("bars", "curve") and len(values) >= (1 if chart == "bars" else 2)
    cx = -2.45 if has_chart else 0.0
    colw = 4.6 if has_chart else 9.4
    num = K.text(value, f("font"), 2.3, m_num, extrude=0.3, bevel=0.03, parent=root)
    num.location = (cx, 0.75, 0)
    w = K.width_of(num)
    if w > colw:
        num.data.size *= colw / w
    # the label sits on a dark pill so it reads on any footage
    lab = K.empty("label", root)
    lab.location = (cx, -1.25, 0)
    txt = K.text(label, f("labelFont") or f("font"), 0.6, m_label, extrude=0.03, bevel=0.004, parent=lab)
    w = K.width_of(txt)
    if w > colw - 0.5:
        txt.data.size *= (colw - 0.5) / w
        w = colw - 0.5
    pill = K.rounded_box(w + 0.7, 1.0, 0.12, K.material("pill", r3.lin(f("pillColor", "#14100A")), roughness=0.5), radius=0.06, parent=lab)
    txt.location.z = 0.02

    bars, tube, tip = [], None, None
    base_y, top_h, left, right = -2.5, 4.6, 0.5, 4.5
    vmax = max(values) if values else 1
    n = len(values)
    if chart == "bars" and has_chart:
        gap = (right - left) / n
        bw = gap * 0.64
        for i, v in enumerate(values):
            b = K.rounded_box(bw, 1.0, 0.7, m_top if i == n - 1 else m_bar, radius=0.1, parent=root)
            b.location = (left + gap * (i + 0.5), base_y, 0)
            bars.append((b, max(v / vmax, 0.04) * top_h))
    elif chart == "curve" and has_chart:
        import bpy
        cu = bpy.data.curves.new("curve", "CURVE")
        cu.dimensions = "3D"
        sp = cu.splines.new("BEZIER")
        sp.bezier_points.add(n - 1)
        for i, v in enumerate(values):
            p = sp.bezier_points[i]
            p.co = (left + (right - left) * i / (n - 1), base_y + max(v / vmax, 0.04) * top_h, 0)
            p.handle_left_type = p.handle_right_type = "AUTO"
        cu.bevel_depth, cu.bevel_resolution = 0.13, 6
        cu.use_fill_caps = True
        cu.materials.append(m_bar)
        tube = K.link(bpy.data.objects.new("tube", cu), root)
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.3, segments=32, ring_count=16)
        tip = bpy.context.active_object
        tip.data.materials.append(m_top)
        tip.parent = root
        pts = [tuple(p.co) for p in sp.bezier_points]
    T = K.seconds

    def update(t, layer):
        # whole group: tilts in, then drifts slowly so the 3D reads
        s = r3.spring(t - 0.05, zeta=0.55, f=1.2)
        root.rotation_euler = (math.radians(-14) * (1 - s) + math.radians(3) * math.sin(t * 0.9),
                               math.radians(22) * (1 - s) + math.radians(6) * math.sin(t * 0.7 + 0.6), 0)
        k = 0.85 + 0.15 * s
        root.scale = (k, k, k)
        # the number counts up over the first 55 % of the time
        if target is not None:
            _, _, decimals, suffix, sep = parsed
            v = target * r3.ease_out(r3.window(t, 0.1, max(T * 0.55, 0.6)), 4)
            shown = ("%." + str(decimals) + "f") % v
            num.data.body = prefix + shown.replace(".", sep) + suffix
        lab_s = r3.ease_out(r3.window(t, 0.35, 0.5))
        lab.location.y = -1.25 - 0.3 * (1 - lab_s)
        lab.scale = (1, max(lab_s, 0.001), 1)
        for ob in (txt, pill):
            ob.hide_render = lab_s <= 0.02
        for i, (b, h) in enumerate(bars):
            g = r3.spring(t - 0.45 - i * 0.12, zeta=0.5, f=1.5)
            hh = max(h * g, 0.002)
            for v in b.data.vertices:  # move the top and bottom faces: the bevel keeps its radius
                v.co.y = hh / 2 if v.co.y > 0 else -hh / 2
            b.data.update()
            b.hide_render = g <= 0.01
            b.location.y = base_y + hh / 2
        if tube is not None:
            g = r3.ease_in_out(r3.window(t, 0.45, max(T * 0.5, 0.8)))
            tube.data.bevel_factor_end = max(g, 0.001)
            x = g * (len(pts) - 1)
            i = min(int(x), len(pts) - 2)
            u = x - i
            a, b2 = pts[i], pts[i + 1]
            tip.location = (a[0] + (b2[0] - a[0]) * u, a[1] + (b2[1] - a[1]) * u, 0)
            tip.scale = (1, 1, 1) if g > 0.01 else (0.001, 0.001, 0.001)

    return update, ["main"]
