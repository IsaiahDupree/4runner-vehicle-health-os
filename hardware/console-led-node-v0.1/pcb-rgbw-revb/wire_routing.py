"""Fit two Rev C power conductors in the published enclosure assembly."""

import json
from math import asin, atan2, cos, pi, sin, sqrt, tan
from pathlib import Path

import FreeCAD as App
import Part

from design import FUSE_GEOMETRY
from mechanical_audit import reopen, translated
from service_case import add_feature, depth_render
from toyota_power import SPEC as POWER


V = App.Vector
X, Z = V(1, 0, 0), V(0, 0, 1)
ROOT = Path(__file__).resolve().parent
SPEC = json.loads((ROOT / "toyota-wire-route.json").read_text(encoding="utf-8"))
COLORS = {"1": (65, 85, 103), "2": (207, 66, 50)}
TOL = 0.01


def section(path, radius):
    spine = Part.Wire(path)
    circle = Part.Circle(path[0].valueAt(path[0].FirstParameter),
                         path[0].tangentAt(path[0].FirstParameter), radius)
    solid = spine.makePipeShell([Part.Wire([circle.toShape()])], True, False)
    if not solid.isValid() or len(solid.Solids) != 1 or solid.Volume <= 0:
        raise ValueError("Invalid round wire sweep")
    return solid


def bend(center, start, mid, end):
    return Part.Arc(center + start, center + mid, center + end).toShape()


def render_route(out, doc, group, routes):
    """Render an installed overview and a close-up of the reopened wire solids."""
    from PySide2 import QtCore, QtGui, QtWidgets

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    center_y = routes["1"]["case_pad_xyz_mm"][1]
    preview_shapes = [(obj.Shape, tuple(round(ch * 255) for ch in obj.ReferenceColor[:3]))
                      for obj in group.Group]
    # A cutaway view makes the routing through the saddle visible.
    top_rail = doc.Base.Shape.cut(Part.makeBox(17, 14, 24, V(-4, center_y - 7, 30)))
    shield = doc.Shield.Shape
    stack = [(solid, (51, 107, 92) if solid.BoundBox.XLength > 110 else (54, 66, 76))
             for solid in shield.Solids]
    overview = [(top_rail, (92, 110, 122)), *stack, (doc.ToyotaMate.Shape, (223, 211, 171)),
                (doc.F1.Shape, (126, 77, 164)), (doc.F2.Shape, (90, 100, 109)),
                (doc.Lead2.Shape, (47, 116, 114)), *preview_shapes]
    closeup = [*stack, *preview_shapes]
    light = V(-.38, -.54, .76)
    for filename, title, subtitle, parts, camera, focused in (
        ("Toyota-wire-route.png", "Toyota input to the Rev C shield",
         "Nominal CAD cutaway · both conductors are visible through the case opening", overview, V(-.47, -.77, 2.9), False),
        ("Toyota-wire-pad-detail.png", "Power wire bends at J1",
         "Lid and saddle hidden · blue-gray to ground · red to switched +12 V", closeup, V(-.44, -.80, 1.8), True),
    ):
        camera.normalize()
        right = Z.cross(camera)
        right.normalize()
        up = camera.cross(right)

        def project(point):
            return point.dot(right), -point.dot(up)

        triangles = []
        for shape, color in parts:
            if focused:
                crop = Part.makeBox(38, 30, 24, V(0, center_y - 14, 22))
                shape = shape.common(crop)
            nodes, faces = shape.tessellate(.14)
            for i, j, k in faces:
                a, b, c = nodes[i], nodes[j], nodes[k]
                normal = (b - a).cross(c - a)
                if normal.Length < 1e-8 or normal.dot(camera) <= 0:
                    continue
                normal.normalize()
                shade = .65 + .33 * max(0, normal.dot(light))
                triangles.append((tuple(p.dot(camera) for p in (a, b, c)),
                                  [project(p) for p in (a, b, c)], [round(ch * shade) for ch in color]))
        xs = [x for _, points, _ in triangles for x, _ in points]
        ys = [y for _, points, _ in triangles for _, y in points]
        cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
        scale = min(1360 / (max(xs) - min(xs)), 710 / (max(ys) - min(ys)))
        image = depth_render(triangles, scale, cx, cy, QtGui)
        painter = QtGui.QPainter(image)
        painter.setRenderHint(QtGui.QPainter.Antialiasing)
        painter.setFont(QtGui.QFont("Segoe UI", 30, QtGui.QFont.Bold))
        painter.setPen(QtGui.QColor("#182c39"))
        painter.drawText(64, 76, title)
        painter.setFont(QtGui.QFont("Segoe UI", 14))
        painter.setPen(QtGui.QColor("#49616e"))
        painter.drawText(65, 113, subtitle)
        painter.setFont(QtGui.QFont("Segoe UI", 15, QtGui.QFont.Bold))
        callouts = (
            [(doc.ToyotaMate.Shape.BoundBox.Center, "Toyota mating housing"),
             (V(POWER["case"]["tie_slot_centers_x_mm"][-1], center_y,
                doc.Lead1.Shape.BoundBox.ZMax), "Case saddle"),
             (V(19.5, center_y, 26), "J1 power pads")] if not focused else
            [(V(*routes["1"]["case_pad_xyz_mm"]), "J1-1  Ground"),
             (V(*routes["2"]["case_pad_xyz_mm"]), "J1-2  Switched +12 V")]
        )
        positions = [(105, 215), (335, 875), (1050, 850)] if not focused else [(145, 845), (1040, 290)]
        for (point, label), (label_x, label_y) in zip(callouts, positions):
            px, py = project(point)
            mark = QtCore.QPointF(800 + (px - cx) * scale, 545 + (py - cy) * scale)
            line_start = QtCore.QPointF(label_x + 12, label_y - 10)
            painter.setPen(QtGui.QPen(QtGui.QColor("#38586a"), 2))
            painter.drawLine(line_start, mark)
            painter.setBrush(QtGui.QColor("#f8fafb"))
            painter.drawEllipse(mark, 4, 4)
            metrics = painter.fontMetrics()
            label_rect = QtCore.QRectF(label_x - 14, label_y - 35, metrics.horizontalAdvance(label) + 28, 47)
            painter.drawRoundedRect(label_rect, 8, 8)
            painter.setPen(QtGui.QColor("#182c39"))
            painter.drawText(label_x, label_y - 4, label)
        painter.setFont(QtGui.QFont("Segoe UI", 13))
        painter.setPen(QtGui.QColor("#49616e"))
        painter.drawText(65, 987, "Toyota cavity assignments and final vehicle lead length depend on the truck measurements.")
        painter.end()
        if not image.save(str(out / filename)):
            raise ValueError(f"Unable to save {filename}")


def wire_path(sleeve_start, sleeve_center, pad, offsets, *, spec=SPEC):
    """Straight run, tangent fanout, circular drop, and vertical pad entry."""
    radius = spec["wire_bend_radius_mm"]
    start = V(sleeve_start, sleeve_center.y + offsets["y_offset"],
              sleeve_center.z + offsets["z_offset"])
    branch = V(spec["branch_start_x_mm"], start.y, start.z)
    run = spec["fanout_end_x_mm"] - branch.x
    distance = pad.x - spec["fanout_end_x_mm"]
    delta = pad.y - branch.y
    # Solve delta = distance*tan(turn) + run*tan(turn/2), so the
    # fanout and the vertical bend join with the same tangent.
    turn = atan2(delta, distance + run / 2)
    for _ in range(5):
        error = distance * tan(turn) + run * tan(turn / 2) - delta
        turn -= error / (distance / cos(turn) ** 2 + run / (2 * cos(turn / 2) ** 2))
    lateral = run * tan(turn / 2)
    fan_radius = run / sin(abs(turn))
    if fan_radius < radius:
        raise ValueError("Insufficient room to fan out the conductor")
    start_heading = V(cos(turn), sin(turn), 0)
    end_fan = branch + V(run, lateral, 0)
    fan_center = V(branch.x, branch.y + fan_radius * (1 if turn > 0 else -1), branch.z)
    radial = branch - fan_center
    fan = bend(fan_center, radial, App.Rotation(Z, turn * 90 / pi).multVec(radial), end_fan - fan_center)

    reach = (V(pad.x, pad.y, end_fan.z) - end_fan).Length
    offset = max(0, reach - radius)
    vertical_start = end_fan + start_heading * offset
    # The nearer pad needs an S-bend in elevation to preserve the radius.
    # The farther pad has room for a straight run and a single quarter turn.
    angle = pi - asin(min(1.0, (1 + reach / radius) / 2))

    def point(origin, dx, dz):
        return origin + start_heading * dx + Z * dz

    def down(t):
        return point(vertical_start, radius * sin(t), -radius * (1 - cos(t)))

    drop = [Part.Arc(down(0), down(angle / 2), down(angle)).toShape()]
    if angle - pi / 2 > 1e-7:
        def back(t):
            return point(vertical_start, radius * (2 * sin(angle) - sin(t)),
                         -radius * (1 + cos(t) - 2 * cos(angle)))

        drop.append(Part.Arc(back(angle), back((angle + pi / 2) / 2), back(pi / 2)).toShape())
    tangent = drop[-1].valueAt(drop[-1].LastParameter)
    tail = pad + Z * spec["pad_approach_mm"]
    if abs(tangent.x - tail.x) > .001 or abs(tangent.y - tail.y) > .001 or tangent.z <= pad.z:
        raise ValueError(f"Wire bend does not land at {tuple(tail)} from {tuple(tangent)}")
    path = [Part.makeLine(start, branch), fan]
    if offset > 1e-7:
        path.append(Part.makeLine(end_fan, vertical_start))
    path.extend(drop)
    if tangent.z > tail.z:
        path.append(Part.makeLine(tangent, tail))
    else:
        # End the insulation on the final arc, above the board. The stripped
        # strand follows the rest of the bend before entering the plated hole.
        last = path[-1]
        lo, hi = last.FirstParameter, last.LastParameter
        for _ in range(28):
            mid = (lo + hi) / 2
            if last.valueAt(mid).z > tail.z:
                lo = mid
            else:
                hi = mid
        path[-1] = Part.Arc(last.valueAt(last.FirstParameter),
                            last.valueAt((last.FirstParameter + lo) / 2), last.valueAt(lo)).toShape()
        bare_bend = Part.Arc(last.valueAt(lo), last.valueAt((lo + last.LastParameter) / 2), tangent).toShape()
        return path, start, tangent, fan_radius, bare_bend
    return path, start, tail, fan_radius, None


def rear_exit(housing, sleeve_entry, diameter):
    """Find a two-wire exit from the housing envelope with cavities deferred."""
    bounds = housing.BoundBox
    # Project the conductor section onto the actual rear housing. Use a
    # small probe wider than the section so the visible end has a clear gap.
    probe = Part.makeCylinder(diameter / 2 + .04, bounds.XLength + 1,
                              V(bounds.XMax + .5, sleeve_entry.y, sleeve_entry.z), -X)
    contact = probe.common(housing)
    if contact.isNull() or not contact.Solids:
        raise ValueError("Nominal wire misses the rear connector housing")
    return contact.BoundBox.XMax + SPEC["rear_face_gap_mm"]


def build(out):
    from mechanical_audit import reopen, translated

    inputs = ROOT / "inputs"
    doc = App.openDocument(str(inputs / "4Runner_Service_Assembly.FCStd"))
    observations = json.loads((inputs / "mechanical-observation.json").read_text(encoding="utf-8"))
    dims = observations["dimensions"]
    pad_map = json.loads((inputs / "harness-pads.json").read_text(encoding="utf-8"))["J1"]["pads"]
    if {pin: info["net"] for pin, info in pad_map.items()} != POWER["pad_assignments"]["J1"]:
        raise ValueError("Published Rev C J1 pad map changed")
    board = doc.Shield.Shape
    board_top = dims["esp_pcb_bottom_mm"] + dims["stack_pitch_mm"] + dims["pcb_thickness_mm"]
    board_bottom = board_top - dims["pcb_thickness_mm"]
    y = next(row["center_y_mm"] for row in observations["port_windows"] if row["ref"] == "J1")
    origin_x, origin_y = dims["pcb_origin_xy_mm"]
    housing = doc.ToyotaMate.Shape
    diameter = POWER["case"]["lead_nominal_od_mm"]["J1"]
    center = V(0, y, POWER["case"]["lead_seat_z_mm"] + diameter / 2)
    sleeve_entries = {pin: center + V(0, offsets["y_offset"], offsets["z_offset"])
                      for pin, offsets in SPEC["jacket_centerline_mm"].items()}
    rear_exits = {pin: rear_exit(housing, entry, SPEC["insulation_od_mm"])
                  for pin, entry in sleeve_entries.items()}
    sleeve_start = max(housing.BoundBox.XMax + 1.0, max(rear_exits.values()) + SPEC["rear_exit_to_sleeve_mm"])
    sleeve_end = POWER["case"]["saddle_end_x_mm"]
    sleeve_length = sleeve_end - sleeve_start
    outer_radius = diameter / 2
    inner_radius = outer_radius - SPEC["sleeve_wall_mm"]
    outer = Part.makeCylinder(outer_radius, sleeve_length, V(sleeve_start, y, center.z), X)
    inner = Part.makeCylinder(inner_radius, sleeve_length + .02, V(sleeve_start - .01, y, center.z), X)
    jacket = outer.cut(inner)
    doc.Lead1.Shape = jacket
    doc.Lead1.Label = "Toyota input · 5.5 mm OD sleeve"
    doc.Lead1.GeometrySource = "Estimated split sleeve envelope over both power wires"
    doc.Shield.Label = "Rev C · routed RGBW shield"
    doc.Label = "4Runner Rev C Toyota wire routing"

    group = doc.addObject("App::DocumentObjectGroup", "ToyotaConductors")
    group.Label = "Toyota input conductors and J1 solder ends"
    checks = []
    rows = {}
    wire_solids, bare_solids = {}, {}

    def clear(name, moving, obstacle, minimum=0.0):
        overlap = max(0.0, moving.common(obstacle).Volume)
        distance = moving.distToShape(obstacle)[0]
        checks.append({"check": name, "clearance_mm": round(distance, 4),
                       "interference_mm3": round(overlap, 6),
                       "pass": overlap <= TOL and distance + .0001 >= minimum})

    fasteners = Part.makeCompound([obj.Shape for obj in doc.Hardware.Group
                                   if obj.Name.startswith(("Screw", "Washer"))])
    pull_w, pull_d, pull_travel = (FUSE_GEOMETRY[key] for key in
                                   ("puller_width_mm", "puller_depth_mm", "puller_travel_mm"))
    pullers = Part.makeCompound([Part.makeBox(pull_w, pull_d, obj.Shape.BoundBox.ZLength + pull_travel,
                                             V(obj.Shape.BoundBox.Center.x - pull_w / 2,
                                               obj.Shape.BoundBox.Center.y - pull_d / 2,
                                               obj.Shape.BoundBox.ZMin + .4)) for obj in (doc.F1, doc.F2)])
    ties = Part.makeCompound([doc.getObject(f"J1Relief{i}").Shape for i in (1, 2)])
    installed = {"case": doc.Base.Shape, "lid": doc.Lid.Shape, "shield": board,
                 "ESP32 board": Part.makeCompound([p.Shape for p in doc.PCB.Group if p.Name != "Shield"]),
                 "fuses": Part.makeCompound([doc.F1.Shape, doc.F2.Shape]), "screws and washers": fasteners,
                 "fuse puller envelope": pullers, "sleeve wall": jacket, "connector housing": housing,
                 "saddle ties": ties}
    for name, shape in (("case", doc.Base.Shape), ("lid", doc.Lid.Shape), ("shield", board), ("connector", housing)):
        clear(f"Toyota sleeve against {name}", jacket, shape)
    for pin, info in pad_map.items():
        if info["drill_mm"] <= SPEC["bore_clearance_gauge_mm"]:
            raise ValueError("J1 bore is smaller than the specified fit gauge")
        pcb_x, pcb_y = info["xy_mm"]
        pad = V(origin_x + pcb_x - 100, origin_y + 153.34 - pcb_y, board_top)
        path, start, tail, fan_radius, bare_bend = wire_path(sleeve_start, center, pad, SPEC["jacket_centerline_mm"][pin])
        conductor = section(path, SPEC["insulation_od_mm"] / 2)
        bare_path = [Part.makeLine(tail, pad - Z * (board_top - board_bottom + SPEC["pad_protrusion_mm"]))]
        if bare_bend is not None:
            bare_path.insert(0, bare_bend)
        strip = section(bare_path, SPEC["bore_clearance_gauge_mm"] / 2)
        bare = section(bare_path, sqrt(.50 / pi))
        stub = Part.makeCylinder(SPEC["insulation_od_mm"] / 2, start.x - rear_exits[pin], start, -X)
        clear(f"J1-{pin} stripped-end gauge in actual PCB bore", strip, board, .05)
        clear(f"J1-{pin} stripped-end gauge below board", strip, installed["ESP32 board"], .10)
        for name, shape in installed.items():
            clear(f"J1-{pin} insulated wire against {name}", conductor, shape, .10 if name == "shield" else 0)
        clear(f"J1-{pin} outer stub against connector", stub, housing, .10)
        for name, shape in (("case", doc.Base.Shape), ("lid", doc.Lid.Shape)):
            clear(f"J1-{pin} outer stub against {name}", stub, shape)
        for lift in (.4, 4.0, 12.0):
            clear(f"J1-{pin} under lid lifted {lift:g} mm", conductor, translated(doc.Lid.Shape, 0, 0, lift))
        color = COLORS[pin]
        label = "Ground" if pin == "1" else "Switched +12 V"
        route = stub.fuse(conductor).removeSplitter()
        if len(route.Solids) != 1 or not route.isValid():
            raise ValueError(f"Wire J1-{pin} is disconnected at the sleeve entry")
        wire_obj = add_feature(doc, group, f"J1Wire{pin}", f"{label} to J1-{pin}", route,
                               "Estimated wire OD and free shape. Toyota cavity assignment pending.", color)
        end_obj = add_feature(doc, group, f"J1End{pin}", f"J1-{pin} stripped end", bare,
                              "Nominal copper envelope from above the board through the published pad center.", (218, 166, 91))
        for obj in (wire_obj, end_obj):
            if App.GuiUp:
                obj.ViewObject.ShapeColor = obj.ReferenceColor
        wire_solids[pin], bare_solids[pin] = route, bare
        rows[pin] = {"signal": label, "pcb_net": info["net"], "toyota_cavity": None,
                     "pcb_xy_mm": info["xy_mm"], "housing_exit_xyz_mm": [stub.BoundBox.XMin, start.y, start.z],
                     "sleeve_entry_xyz_mm": list(start), "case_pad_xyz_mm": list(pad),
                     "minimum_bend_radius_mm": round(min(fan_radius, SPEC["wire_bend_radius_mm"]), 2),
                     "centerline_length_mm": round(sum(edge.Length for edge in path + bare_path) + stub.BoundBox.XLength, 2),
                     "inside_case_centerline_mm": round(sum(edge.Length for edge in path + bare_path) + sleeve_start, 2),
                     "strip_length_mm": round(sum(edge.Length for edge in bare_path), 2)}
    clear("ground and switched 12 V insulation separation", wire_solids["1"], wire_solids["2"], .10)
    for pin in ("1", "2"):
        other = "2" if pin == "1" else "1"
        clear(f"J1-{pin} stripped end against the other wire", bare_solids[pin], wire_solids[other], .10)
    clear("ground and switched 12 V stripped-end separation", bare_solids["1"], bare_solids["2"], .10)

    report = {"contract": SPEC["definition"], "interface": SPEC["interface"], "inputs": observations["geometry_authority"],
              "config": SPEC, "conductor_routes": rows, "sleeve_length_mm": round(sleeve_length, 2),
              "checks": checks, "passed": all(check["pass"] for check in checks),
              "physical_harness_fit_verified": False, "toyota_cavities_verified": False}
    (out / "toyota-wire-route.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if not report["passed"]:
        failures = [check for check in checks if not check["pass"]]
        raise ValueError(f"Toyota wire clearance findings: {failures}")
    doc.recompute()
    project = out / "4Runner_RevC_Toyota_Wiring.FCStd"
    doc.saveAs(str(project))
    step = out / "4Runner_RevC_Toyota_Wiring.step"
    Part.makeCompound([obj.Shape for obj in group.Group] + [jacket]).exportStep(str(step))
    exported = reopen(step)
    if len(exported.Solids) != 5:
        raise ValueError("STEP did not retain all wire and terminal solids")
    App.closeDocument(doc.Name)
    restored = App.openDocument(str(project))
    restored_group = restored.ToyotaConductors
    if len(restored_group.Group) != 4 or any(not obj.Shape.isValid() for obj in restored_group.Group):
        raise ValueError("Invalid conductor in the saved FreeCAD assembly")
    for name in ("Base", "Lid", "Shield", "ToyotaMate"):
        if not restored.getObject(name).Shape.isValid():
            raise ValueError(f"Invalid {name} in the saved FreeCAD assembly")
    render_route(out, restored, restored_group, rows)
    App.closeDocument(restored.Name)
