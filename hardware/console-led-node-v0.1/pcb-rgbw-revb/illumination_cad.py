"""Route the four Toyota branch wires in the installed Rev D assembly."""

from itertools import combinations
import json
from math import acos, atan2, cos, hypot, pi, sin, sqrt

import FreeCAD as App
import Part

import illumination as rev_d
from design import FUSE_GEOMETRY
from mechanical_audit import reopen, translated
from service_case import add_feature, depth_render
from toyota_power import SPEC as POWER
from wire_routing import SPEC as REVC_ROUTE, V, X, Z, rear_exit, section, wire_path


CASE = POWER["case"]
SLEEVE_WALL = .32
SLEEVE_END = 6.4


def sleeve_restraint(center, radius, *, case=CASE):
    """Closed strap envelope through the first slot and over the sleeve."""
    width = case["tie_strap_width_mm"]
    floor = case["tie_slot_floor_z_mm"] + .04
    strap = .65
    half = case["saddle_half_width_mm"]
    shoulder = case["lead_seat_z_mm"] + .7
    face_x = case["tie_slot_centers_x_mm"][0] - width / 2

    def loop(x, side, bottom, arc_radius):
        rise = shoulder - center.z
        angle = atan2(rise, side) + acos(arc_radius / hypot(side, rise))
        at = lambda y, z: V(x, center.y + y, z)
        dy, dz = arc_radius * cos(angle), arc_radius * sin(angle)
        right, left = at(dy, center.z + dz), at(-dy, center.z + dz)
        arc = Part.Arc(right, at(0, center.z + arc_radius), left).toShape()
        edges = Part.makePolygon([left, at(-side, shoulder), at(-side, bottom),
                                  at(side, bottom), at(side, shoulder), right]).Edges
        return Part.Face(Part.Wire([arc, *edges]))

    inside = loop(face_x - .1, half + .25, floor + strap, radius + .04).extrude(X * (width + .2))
    outside = loop(face_x, half + .25 + strap, floor, radius + .04 + strap).extrude(X * width)
    band = outside.cut(inside).removeSplitter()
    if not band.isValid() or len(band.Solids) != 1:
        raise ValueError("Invalid installed strap envelope")
    return band


def build(out, *, doc=None, revision="D", case=CASE, contract=rev_d.CONTRACT):
    if doc is None:
        doc = App.openDocument(str(out / "4Runner_Service_Assembly.FCStd"))
    source = json.loads((out / "mechanical-observation.json").read_text())
    pads = json.loads((out / "harness-pads.json").read_text())["J1"]["pads"]
    dimensions = source["dimensions"]
    ox, oy = dimensions["pcb_origin_xy_mm"]
    board_z = dimensions["esp_pcb_bottom_mm"] + dimensions["stack_pitch_mm"] + dimensions["pcb_thickness_mm"]
    port_y = next(row["center_y_mm"] for row in source["port_windows"] if row["ref"] == "J1")
    center = V(0, port_y, case["lead_seat_z_mm"] + rev_d.CASE_SLEEVE_OD / 2)
    housing = doc.ToyotaMate.Shape
    entries = {pin: center + V(0, *row["offset_yz_mm"]) for pin, row in pads.items()}
    exits = {pin: rear_exit(housing, entry, pads[pin]["od_mm"]) for pin, entry in entries.items()}
    sleeve_start = max(housing.BoundBox.XMax + 1, max(exits.values()) + REVC_ROUTE["rear_exit_to_sleeve_mm"])
    radius = rev_d.CASE_SLEEVE_OD / 2
    outer = Part.makeCylinder(radius, SLEEVE_END - sleeve_start, V(sleeve_start, center.y, center.z), X)
    inner = Part.makeCylinder(radius - SLEEVE_WALL, SLEEVE_END - sleeve_start + .02,
                              V(sleeve_start - .01, center.y, center.z), X)
    sleeve = outer.cut(inner)
    doc.Lead1.Shape = sleeve
    doc.Lead1.Label = "Toyota branch · 7.2 mm sleeve envelope"
    doc.Lead1.GeometrySource = "Nominal sleeve. Ends between case tie slots to allow wire fan-out."
    title = f"Rev {revision} · " + ("IR1 four-pad RGBW shield" if revision == "D" else "single-board RGBW controller")
    doc.Shield.Label = title
    doc.Label = f"4Runner Rev {revision} case and Toyota branch wires"
    doc.removeObject("J1Relief2")
    doc.removeObject("J1Relief1")
    tie = sleeve_restraint(center, radius, case=case)
    add_feature(doc, doc.Loom, "ToyotaSleeveTie", "Toyota sleeve restraint at first saddle slot", tie,
                "Nominal strap, 2.5 mm wide by 0.65 mm thick. Verify the actual tie and head in the case.",
                (75, 81, 87))

    lower = [obj.Shape for obj in doc.PCB.Group if obj.Name != "Shield"]
    board = f"Rev {revision} PCB"
    hardware = Part.makeCompound([obj.Shape for obj in doc.Hardware.Group])
    width, depth, travel = (FUSE_GEOMETRY[k] for k in
                            ("puller_width_mm", "puller_depth_mm", "puller_travel_mm"))
    pullers = []
    for fuse in (doc.F1, doc.F2):
        bounds = fuse.Shape.BoundBox
        pullers.append(Part.makeBox(width, depth, bounds.ZLength + travel,
                                   V(bounds.Center.x - width / 2, bounds.Center.y - depth / 2, bounds.ZMin + .4)))
    obstacles = {"base": doc.Base.Shape, "closed lid": doc.Lid.Shape, board: doc.Shield.Shape,
                 "installed hardware": hardware, "sleeve": sleeve,
                 "fuse puller envelope": Part.makeCompound(pullers), "sleeve restraint": tie}
    if lower:
        obstacles["lower board"] = Part.makeCompound(lower)
    checks = []

    def clear(label, moving, obstacle, minimum=0):
        volume = moving.common(obstacle).Volume if moving.BoundBox.intersect(obstacle.BoundBox) else 0.0
        distance = moving.distToShape(obstacle)[0]
        checks.append({"check": label, "clearance_mm": round(distance, 4), "interference_mm3": round(volume, 6),
                       "pass": volume <= .01 and distance + .0001 >= minimum})

    for name in ("base", "closed lid", board, "installed hardware"):
        clear("Sleeve against " + name, sleeve, obstacles[name])
    for name, shape in obstacles.items():
        if name != "sleeve restraint":
            clear("Sleeve restraint against " + name, tie, shape)
    for offset in (-.65, .65):
        shifted_sleeve = translated(sleeve, 0, offset, 0)
        for name in ("base", "closed lid", board):
            clear(f"Sleeve at {offset:+g} mm lateral offset against {name}", shifted_sleeve, obstacles[name])

    group = doc.addObject("App::DocumentObjectGroup", "ToyotaConductors")
    group.Label = "Four-wire branch from IR1 to J1"
    insulated, stripped, rows = {}, {}, {}
    for pin, row in pads.items():
        pad_x, pad_y = row["xy_mm"]
        pad = V(ox + pad_x - 100, oy + 153.34 - pad_y, board_z)
        dy, dz = row["offset_yz_mm"]
        spec = {**REVC_ROUTE, "wire_bend_radius_mm": row["bend_mm"],
                "branch_start_x_mm": SLEEVE_END + .15, "fanout_end_x_mm": 9.0}
        path, start, tail, fan_radius, bare_bend = wire_path(sleeve_start, center, pad,
                                                            {"y_offset": dy, "z_offset": dz}, spec=spec)
        if start.x <= exits[pin]:
            raise ValueError(f"J1-{pin} starts inside the connector envelope")
        path[0] = Part.makeLine(V(exits[pin], start.y, start.z), path[0].valueAt(path[0].LastParameter))
        insulated[pin] = section(path, row["od_mm"] / 2)
        bare_path = [Part.makeLine(tail, pad - Z * (dimensions["pcb_thickness_mm"] + spec["pad_protrusion_mm"]))]
        if bare_bend is not None:
            bare_path.insert(0, bare_bend)
        gauge = section(bare_path, row["gauge_mm"] / 2)
        area = .50 if row["awg"] == 20 else .35
        stripped[pin] = section(bare_path, sqrt(area / pi))
        label = f'IR1-{row["cavity"]} to J1-{pin} · {row["label"]}'
        add_feature(doc, group, f"J1Wire{pin}", label, insulated[pin],
                    "Nominal breakout exit and TXL section. Factory tee and actual crimp depth require measurement.", row["rgb"])
        add_feature(doc, group, f"J1End{pin}", f"J1-{pin} stripped end", stripped[pin],
                    "Strand envelope through the actual plated bore.", (216, 157, 84))
        for name, shape in obstacles.items():
            clear(f"J1-{pin} against {name}", insulated[pin], shape, .10 if name == board else 0)
        clear(f"J1-{pin} against the Toyota housing", insulated[pin], housing, .10)
        clear(f"J1-{pin} stripped-end gauge inside exported bore", gauge, doc.Shield.Shape, .05)
        clear(f"J1-{pin} stripped-end gauge against the base", gauge, doc.Base.Shape)
        if lower:
            clear(f"J1-{pin} stripped-end gauge against the lower board", gauge, obstacles["lower board"])
        for lift in (.4, 4, 12):
            clear(f"J1-{pin} against lid at {lift:g} mm lift", insulated[pin], translated(doc.Lid.Shape, 0, 0, lift))
        rows[pin] = {"IR1_cavity": row["cavity"], "net": row["net"], "body_od_mm": row["od_mm"],
                     "bore_mm": row["drill_mm"], "pad_xyz_mm": list(pad), "minimum_bend_radius_mm": round(
                         min(fan_radius, row["bend_mm"]), 2), "strip_length_mm": round(sum(e.Length for e in bare_path), 2),
                     "centerline_length_mm": round(sum(e.Length for e in path + bare_path), 2)}

    for a, b in combinations(pads, 2):
        for first, second, kind in ((insulated[a], insulated[b], "jackets"), (stripped[a], stripped[b], "stripped ends"),
                                    (insulated[a], stripped[b], "jacket and end"), (stripped[a], insulated[b], "end and jacket")):
            clear(f"J1-{a} and J1-{b} {kind}", first, second, .08)

    report = {"contract": contract, "sleeve_od_mm": rev_d.CASE_SLEEVE_OD, "sleeve_wall_mm": SLEEVE_WALL,
              "routes": rows, "checks": checks, "nominal_pass": all(c["pass"] for c in checks),
              "factory_pass_through": "External inline tee. IR1 1–6 run straight through to original mate.",
              "physical_vehicle_fit_verified": False, "terminal_positions_inside_housing_verified": False}
    (out / "ir1-wire-fit.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["nominal_pass"]:
        raise ValueError(f"Rev {revision} installed wire clearances failed. See ir1-wire-fit.json.")

    doc.recompute()
    native_path = out / f"4Runner_Rev{revision}_Assembly.FCStd"
    doc.saveAs(str(native_path))
    wires_path = out / f"4Runner_Rev{revision}_Toyota_Wires.step"
    Part.makeCompound([obj.Shape for obj in group.Group] + [sleeve]).exportStep(str(wires_path))
    if len(reopen(wires_path).Solids) != 9:
        raise ValueError("STEP must retain four wires, four stripped ends and the sleeve")
    assembly = out / f"4Runner_Rev{revision}_Assembly.step"
    solids = [obj.Shape for group_obj in (doc.Print, doc.PCB, doc.Hardware, doc.Loom, group)
              for obj in group_obj.Group]
    Part.makeCompound(solids).exportStep(str(assembly))
    reopen(assembly)
    App.closeDocument(doc.Name)
    doc = App.openDocument(str(native_path))
    if len(doc.ToyotaConductors.Group) != 8 or any(not obj.Shape.isValid() for obj in doc.ToyotaConductors.Group):
        raise ValueError(f"Native Rev {revision} assembly did not retain the four-wire branch")
    preview(out, doc, revision)
    App.closeDocument(doc.Name)


def preview(out, doc, revision):
    from PySide2 import QtCore, QtGui, QtWidgets

    gui = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    camera = V(-.34, -.58, 2.4)
    camera.normalize()
    right = Z.cross(camera)
    right.normalize()
    up = camera.cross(right)
    light = V(-.38, -.54, .76)
    base = doc.Base.Shape.cut(Part.makeBox(19, 17, 24, V(-4, 45, doc.Lead1.Shape.BoundBox.ZMin - 7.45)))
    stack = []
    for solid in doc.Shield.Shape.Solids:
        bounds = solid.BoundBox
        board = bounds.XLength > 110 and abs(bounds.ZLength - 1.6) < .1
        radio = revision in {"E", "F"} and bounds.XMax > 124 and bounds.XLength > 17
        color = (43, 104, 86) if board else (182, 188, 191) if radio else (61, 73, 80)
        stack.append((solid, color))
    wires = [(obj.Shape, tuple(round(ch * 255) for ch in obj.ReferenceColor[:3])) for obj in doc.ToyotaConductors.Group]
    parts = [(base, (96, 115, 128)), (doc.ToyotaMate.Shape, (235, 217, 182)), *stack, *wires,
             (doc.F1.Shape, (121, 75, 162)), (doc.F2.Shape, (89, 95, 105)), (doc.Lead2.Shape, (51, 118, 118))]
    tris = []
    for shape, color in parts:
        vertices, faces = shape.tessellate(.15)
        for a, b, c in faces:
            points = [vertices[i] for i in (a, b, c)]
            normal = (points[1] - points[0]).cross(points[2] - points[0])
            if normal.Length > 1e-8 and normal.dot(camera) > 0:
                normal.normalize()
                shade = .69 + .31 * max(0, normal.dot(light))
                tris.append((tuple(p.dot(camera) for p in points),
                             [(p.dot(right), -p.dot(up)) for p in points], tuple(round(ch * shade) for ch in color)))
    xs = [x for _, pts, _ in tris for x, _ in pts]
    ys = [y for _, pts, _ in tris for _, y in pts]
    scale = min(1390 / (max(xs) - min(xs)), 710 / (max(ys) - min(ys)))
    canvas = depth_render(tris, scale, (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, QtGui)
    paint = QtGui.QPainter(canvas)
    paint.setRenderHint(QtGui.QPainter.Antialiasing)
    paint.setPen(QtGui.QColor("#18313c"))
    paint.setFont(QtGui.QFont("Segoe UI", 29, QtGui.QFont.Bold))
    paint.drawText(65, 76, "Rev D · Toyota IR1 wiring" if revision == "D" else f"Rev {revision} · Single-board controller")
    paint.setFont(QtGui.QFont("Segoe UI", 15))
    paint.drawText(66, 115, "Four Toyota wires enter the case. The ESP32-S3 mounts on the PCB."
                   if revision in {"E", "F"} else "Four wires through the existing Toyota entry to the shield")
    for i, (pin, row) in enumerate(rev_d.BRANCH.items()):
        x, y = 65 + (i % 2) * 345, 931 + (i // 2) * 40
        paint.setBrush(QtGui.QColor(*row["rgb"]))
        paint.setPen(QtGui.QColor("#334c58"))
        paint.drawRoundedRect(QtCore.QRectF(x, y - 16, 30, 15), 3, 3)
        paint.drawText(x + 42, y, f'IR1-{row["cavity"]}  →  J1-{pin}   {row["label"]}')
    paint.setPen(QtGui.QColor("#455d69"))
    paint.drawText(975, 971, "Nominal fit · sleeve shown cut away")
    paint.end()
    if not canvas.save(str(out / f"Rev{revision}-Toyota-wiring.png")):
        raise RuntimeError(f"Could not save the Rev {revision} wiring preview")
