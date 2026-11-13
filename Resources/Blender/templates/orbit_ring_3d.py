"""orbit-ring-3d: words, logos or photos travelling on a tilted 3D ring around the speaker. Two full-frame
layers: `back` (the far half, drawn behind the person) and `front` (the near half, over the person)."""
import math, os
import bpy
import regista3d as r3


def build(K):
    f = K.field
    items = [str(x) for x in (f("items") or ["APPLICATIONS", "IA", "AUTOMATISATION", "INTÉGRATION"])][:10]
    cx, cy = f("center") or [540, 640]
    R = float(f("radius", 340)) / 100
    tilt = math.radians(float(f("tilt", 24)))
    speed = float(f("speed", 0.18)) * (-1 if f("direction", "ccw") == "cw" else 1)
    mat_kind = f("material", "flat")
    color = r3.lin(f("color", "#F4BD56"))
    text_color = r3.lin(f("textColor", "#FFF2E9"))
    show_ring = f("ring", True)

    K.world(color=(0.08, 0.07, 0.06), strength=1.0)  # dark surroundings: contrasty gold
    K.studio_lights(key=800)
    K.camera(distance=16)

    def surface(name, c):
        if mat_kind == "gold":
            return K.material(name, c, metallic=1.0, roughness=0.25)
        if mat_kind == "metal":
            return K.material(name, (0.8, 0.8, 0.82, 1), metallic=1.0, roughness=0.18)
        return K.material(name, c, roughness=0.4, coat=0.6)

    # the ring's frame: local XY circle tilted so its near half (local y > 0) faces the camera and sits lower
    ring = K.empty("ring")
    ring.location = K.at(cx, cy)
    ring.rotation_euler = (math.pi / 2 + tilt, 0, 0)

    halves = {}
    if show_ring:
        m_ring = surface("ring", color)
        for name, a, b in (("front", 0.0, 0.5), ("back", 0.5, 1.0)):
            cu = bpy.data.curves.new("ring-" + name, "CURVE")
            cu.dimensions = "3D"
            sp = cu.splines.new("NURBS")
            n = 64
            sp.points.add(n - 1)
            for i in range(n):
                th = 2 * math.pi * i / n
                sp.points[i].co = (R * math.cos(th), R * math.sin(th), 0, 1)
            sp.use_cyclic_u, sp.order_u, sp.resolution_u = True, 4, 12
            cu.bevel_depth, cu.bevel_resolution = 0.035, 4
            cu.bevel_factor_mapping_start = cu.bevel_factor_mapping_end = "SPLINE"
            cu.bevel_factor_start, cu.bevel_factor_end = a, b
            cu.materials.append(m_ring)
            halves[name] = K.link(bpy.data.objects.new("ring-" + name, cu), ring)

    m_text = surface("text", text_color)
    m_shadow = K.material("shadow", (0.0, 0.0, 0.0, 1), roughness=1.0)
    m_shadow.diffuse_color = (0, 0, 0, 1)
    font = f("font")
    nodes = []
    for i, it in enumerate(items):
        holder = K.empty("item", ring)
        if os.path.isfile(it):
            ob = K.image_plane(it, float(f("imageHeight", 150)) / 100, parent=holder)
        else:
            ob = K.text(it, font, float(f("textSize", 82)) / 100, m_text, extrude=0.16, bevel=0.016, parent=holder)
            w = K.width_of(ob)
            if w > 3.3:  # long words stay inside the frame when they pass the sides
                ob.data.size *= 3.3 / w
            # a dark copy just behind: a soft drop shadow so gold reads on light walls
            sh = K.text(it, font, ob.data.size, m_shadow, extrude=0.02, bevel=0.0, parent=ob)
            sh.location = (0.035, -0.045, -0.2)
        # the item stands up facing the camera: undo the ring's tilt
        ob.rotation_euler = (-(math.pi / 2 + tilt), 0, 0)
        nodes.append((holder, ob, 2 * math.pi * i / len(items)))

    T = K.seconds

    def update(t, layer):
        grow = r3.spring(t - 0.05, zeta=0.6, f=1.1)
        leave = 1 - r3.ease_out(r3.window(t, T - 0.4, 0.4))
        k = max(grow * leave, 0.001)
        ring.scale = (k, k, k)
        for name, ob in halves.items():
            ob.hide_render = name != layer
        for i, (holder, ob, th0) in enumerate(nodes):
            th = th0 + 2 * math.pi * speed * t + math.pi * 0.35
            holder.location = (R * math.cos(th), R * math.sin(th), 0)
            pop = r3.spring(t - 0.15 - i * 0.07, zeta=0.5, f=1.6)
            s = max(pop * leave, 0.001)
            holder.scale = (s, s, s)
            near = math.sin(th) > 0
            ob.hide_render = (layer == "front") != near or pop <= 0.01

    return update, ["back", "front"]
