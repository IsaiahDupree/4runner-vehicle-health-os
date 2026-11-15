"""Render and screen the exact released gland enclosure on Orion."""

import hashlib
import json
from pathlib import Path

import FreeCAD as App
import Part
from PySide2 import QtCore, QtGui, QtWidgets

from design import FUSE_GEOMETRY
from gland_case import axial
from mechanical_audit import ROOT, box, translated
from service_case import depth_render, socket_screw

V = App.Vector
Z = V(0, 0, 1)
TOLERANCE = .10
PLATE_LIFT = 34
DISCONNECT_LIFT = 28
UNMATE_RESERVE = 12
EPS_VOLUME = .012
# Molex plug drawing SDA-43020-**** and receptacle drawing 430250000-SD.
MOLEX_MATED_LENGTH = 24.77
MOLEX_DRAWING_TOLERANCE = .25
MOLEX_WIDTHS = {"J1": 10.90, "J2": 13.89}


def bounds_box(bounds, *, dx=0, dy=0, dz=0, pad=0):
    return box(bounds.XMin + min(0, dx) - pad, bounds.YMin + min(0, dy) - pad,
               bounds.ZMin + min(0, dz), bounds.XLength + abs(dx) + 2 * pad,
               bounds.YLength + abs(dy) + 2 * pad, bounds.ZLength + abs(dz))


def swept_round(x, y, z, diameter, length, lift, pad=0):
    """Conservative swept cylinder for a translate along +Z with XY allowance."""
    d = diameter + 2 * pad
    return axial(x - pad, y, z, d, length + 2 * pad).fuse([
        box(x - pad, y - d / 2, z, length + 2 * pad, d, lift),
        axial(x - pad, y, z + lift, d, length + 2 * pad),
    ]).removeSplitter()


def screen(doc, fit, source):
    base, lid, panel, pcb = (doc.getObject(name).Shape for name in ("Base", "Lid", "GlandPlate", "Shield"))
    fuses = {ref: doc.getObject(ref).Shape for ref in ("F1", "F2")}
    populated = Part.makeCompound([pcb, *fuses.values()])
    panel_bounds = panel.BoundBox
    gland_shapes = {}
    for ref, spec in fit["glands"].items():
        y = spec["center_y_mm"]
        body = doc.getObject(ref + "Body").Shape.BoundBox
        nut = doc.getObject(ref + "Nut").Shape.BoundBox
        gland_shapes[ref] = (
            (body.XMin, y, body.Center.z, spec["body_width_mm"], body.XLength),
            (panel_bounds.XMin, y, body.Center.z, spec["nominal_thread_mm"], spec["thread_length_mm"]),
            (nut.XMin, y, nut.Center.z, spec["nut_corner_diameter_mm"], nut.XLength),
        )
    checks = []

    def check(name, moving, fixed, *, blocked=False):
        volume = moving.common(fixed).Volume if moving.BoundBox.intersect(fixed.BoundBox) else 0
        passed = volume > EPS_VOLUME if blocked else volume < EPS_VOLUME
        checks.append({"check": name, "expected": "blocked" if blocked else "clear",
                       "overlap_mm3": round(volume, 5), "passed": passed})

    for allowance in (0, TOLERANCE):
        plate_path = bounds_box(panel_bounds, dz=PLATE_LIFT, pad=allowance)
        moving_parts = [(f"{ref} {name}", swept_round(*dims, PLATE_LIFT, pad=allowance))
                        for ref, shapes in gland_shapes.items()
                        for name, dims in zip(("body", "shank", "locknut"), shapes)]
        for name, volume in [("plate", plate_path), *moving_parts]:
            for fixed_name, fixed in (("shell", base), ("populated PCB and fuses", populated)):
                check(f"{name} full lift vs {fixed_name} at {allowance:.2f} mm XY allowance", volume, fixed)

    check("Oversize control catches a rail collision", bounds_box(panel_bounds, dz=4, pad=.30), base, blocked=True)
    check("Lid blocks plate removal after taking up the seated gap", translated(panel, 0, 0, .6), lid, blocked=True)
    for dx in (-.40, .40):
        check(f"Rails retain plate under {dx:+.2f} mm axial travel", translated(panel, dx, 0, 0), base, blocked=True)

    connectors = {ref: doc.getObject(ref + "Disconnect").Shape for ref in gland_shapes}
    pullers = {}
    for ref, fuse in fuses.items():
        b = fuse.BoundBox
        w, d, travel = (FUSE_GEOMETRY[key] for key in ("puller_width_mm", "puller_depth_mm", "puller_travel_mm"))
        pullers[ref] = box(b.Center.x - w / 2, b.Center.y - d / 2, b.ZMin + .4,
                           w, d, b.ZLength + travel)

    dimension_results = {}
    for ref, connector in connectors.items():
        dimensions = connector.BoundBox
        row = {
            "width_margin_mm": round(dimensions.XLength - MOLEX_WIDTHS[ref] - MOLEX_DRAWING_TOLERANCE, 3),
            "length_margin_mm": round(dimensions.YLength - MOLEX_MATED_LENGTH - MOLEX_DRAWING_TOLERANCE, 3),
        }
        dimension_results[ref] = row
        for name, margin in row.items():
            checks.append({"check": f"{ref} drawing comparison {name}",
                           "expected": "positive margin", "margin_mm": margin, "passed": margin > 0})
        mate = next(port for port in connectors if port != ref)
        obstacles = {"shell": base, "plate": panel, "populated PCB and fuses": populated,
                     "neighbor disconnect": connectors[mate]}
        obstacles.update({f"{port} {name}": axial(*dims) for port, shapes in gland_shapes.items()
                          for name, dims in zip(("body", "shank", "locknut"), shapes)})
        lift = bounds_box(connector.BoundBox, dz=DISCONNECT_LIFT, pad=TOLERANCE)
        for name, fixed in obstacles.items():
            check(f"{ref} complete vertical removal vs {name}", lift, fixed)
        lifted = translated(connector, 0, 0, DISCONNECT_LIFT)
        lifted_bounds = lifted.BoundBox
        # Reserve a full-body slide in both directions to cover either half being held.
        axial_room = bounds_box(lifted_bounds, dy=UNMATE_RESERVE, pad=TOLERANCE)
        axial_room = axial_room.fuse(bounds_box(lifted_bounds, dy=-UNMATE_RESERVE, pad=TOLERANCE))
        check(f"{ref} above-rim axial unmating reserve", axial_room, Part.makeCompound(list(obstacles.values())))
        for fuse, puller in pullers.items():
            check(f"{fuse} puller path vs parked {ref} disconnect", puller, connector)

    return {
        "contract": "vhos_revg_gland_service_review_v1",
        "source_assembly_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "horizontal_allowance_mm_per_side": TOLERANCE,
        "gland_plate_lift_mm": PLATE_LIFT,
        "disconnect_lift_mm": DISCONNECT_LIFT,
        "unmate_reserve_mm": UNMATE_RESERVE,
        "manufacturer_dimensions": {
            "mated_length_mm": MOLEX_MATED_LENGTH,
            "drawing_widths_mm": MOLEX_WIDTHS,
            "general_drawing_allowance_mm": MOLEX_DRAWING_TOLERANCE,
            "housing_envelope_margins": dimension_results,
            "sources": [
                "https://www.molex.com/content/dam/molex/molex-dot-com/products/automated/en-us/salesdrawingpdf/430/43020/430200601_sd.pdf?inline=",
                "https://www.molex.com/content/dam/molex/molex-dot-com/products/automated/en-us/salesdrawingpdf/430/43025/430250600_sd.pdf?inline=",
            ],
        },
        "verified_slack": "Service envelope only. Actual wire bends and slack require the harness.",
        "checks": checks,
        "passed": all(row["passed"] for row in checks),
        "physical_validation": False,
    }


def design_rows(doc):
    rows = {}
    for group in (doc.Print, doc.PCB, doc.Hardware, doc.WireMount):
        for item in group.Group:
            rows[item.Name] = (item.Shape, tuple(round(ch * 255) for ch in item.ReferenceColor[:3]))
    for ref, tint in (("J1", (175, 116, 58)), ("J2", (34, 130, 134))):
        rows[ref + "Disconnect"] = (rows[ref + "Disconnect"][0], tint)
    # Give the board packages and PCB distinct colors using their actual solid bounds.
    board, color = rows.pop("Shield")
    for i, solid in enumerate(board.Solids):
        b = solid.BoundBox
        c = color if b.XLength > 100 and 1.4 < b.ZLength < 1.8 else (
            (173, 181, 183) if b.XLength > 17 and b.XMax > 140 else (68, 76, 83))
        rows[f"PCB{i}"] = (solid, c)
    return rows


def picture(out, filename, title, subtitle, rows, direction, decorate=None):
    camera = V(*direction)
    camera.normalize()
    right = Z.cross(camera)
    right.normalize()
    up = camera.cross(right)
    light = V(-.62, -.38, .93)
    light.normalize()
    triangles = []
    for shape, color in rows.values():
        nodes, faces = shape.tessellate(.28)
        for face in faces:
            pts = tuple(nodes[i] for i in face)
            normal = (pts[1] - pts[0]).cross(pts[2] - pts[0])
            if normal.Length <= 1e-8 or normal.dot(camera) <= 0:
                continue
            normal.normalize()
            shade = .68 + .32 * max(0, normal.dot(light))
            triangles.append((tuple(p.dot(camera) for p in pts),
                              [(p.dot(right), -p.dot(up)) for p in pts], tuple(round(c * shade) for c in color)))
    xs = [x for _, points, _ in triangles for x, _ in points]
    ys = [y for _, points, _ in triangles for _, y in points]
    scale = min(1280 / (max(xs) - min(xs)), 690 / (max(ys) - min(ys)))
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    image = depth_render(triangles, scale, cx, cy, QtGui)

    def project(point):
        return QtCore.QPointF(800 + (point.dot(right) - cx) * scale,
                              545 + (-point.dot(up) - cy) * scale)

    painter = QtGui.QPainter(image)
    painter.setRenderHint(QtGui.QPainter.Antialiasing)
    painter.setPen(QtGui.QColor("#142d3b"))
    painter.fillRect(64, 52, 42, 3, QtGui.QColor("#0e817d"))
    painter.setFont(QtGui.QFont("Segoe UI", 31, QtGui.QFont.Bold))
    painter.drawText(64, 105, title)
    painter.setPen(QtGui.QColor("#36535f"))
    painter.setFont(QtGui.QFont("Segoe UI", 15))
    painter.drawText(64, 980, subtitle)
    if decorate:
        decorate(painter, project)
    painter.end()
    if not image.save(str(out / filename)):
        raise ValueError(f"Could not save {filename}")
    return image


def arrow(painter, start, end, color):
    run = end - start
    length = (run.x() ** 2 + run.y() ** 2) ** .5
    if length <= 2:
        return
    dx, dy = run.x() / length, run.y() / length
    painter.setPen(QtGui.QPen(color, 2.4))
    painter.drawLine(start, end)
    for side in (-1, 1):
        painter.drawLine(end, end + QtCore.QPointF(-11 * dx + side * 5 * dy, -11 * dy - side * 5 * dx))


def photograph(out, doc, fit):
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    rows = design_rows(doc)
    screws = {}
    for axis in fit["tool_axes"]:
        if axis["id"].startswith("lid_"):
            x, y, z = axis["position_mm"]
            screws[axis["id"]] = (socket_screw(x, y, z + 3.2, 8), (119, 131, 143))
    closed = {k: row for k, row in rows.items() if k in ("Base", "Lid", "GlandPlate") or k.endswith(("Body", "Jacket"))}
    closed.update(screws)
    closed_img = picture(out, "01-closed-case.png", "Rev G closed enclosure",
                         "Toyota IR1 power enters through the M16 gland. The RGBW cable exits through the M12 gland.",
                         closed, (-1.15, -1.25, 1.6))

    exploded = {}
    for key, (shape, color) in (rows | screws).items():
        if key == "Lid" or key.startswith("lid_"):
            shape = translated(shape, -32, 28, 104 if key == "Lid" else 113)
        elif key.startswith("PCB") or key in ("F1", "F2"):
            shape = translated(shape, 6, 0, 25)
        elif key == "GlandPlate" or key.endswith(("Body", "Nut", "Jacket")):
            shape = translated(shape, -19, 0, 19)
        exploded[key] = (shape, color)
    stack_img = picture(out, "02-exploded-assembly.png", "Lid, board and removable gland plate",
                        "The connector envelopes sit ahead of the populated PCB and both MINI fuses.",
                        exploded, (-1.08, -1.32, 1.6))

    panel = rows["GlandPlate"]

    def dimensions(painter, project):
        y1, y2 = [fit["glands"][ref]["center_y_mm"] for ref in ("J1", "J2")]
        x = panel[0].BoundBox.XMin
        p1, p2 = (project(V(x, y, 22)) for y in (y1, y2))
        top = project(V(x, y1, panel[0].BoundBox.ZMax)).y() - 30
        ink = QtGui.QColor("#156c69")
        painter.setPen(QtGui.QPen(ink, 2))
        for p in (p1, p2):
            painter.drawLine(p + QtCore.QPointF(-7, 0), p + QtCore.QPointF(7, 0))
            painter.drawLine(p + QtCore.QPointF(0, -7), p + QtCore.QPointF(0, 7))
            painter.drawLine(QtCore.QPointF(p.x(), top - 10), QtCore.QPointF(p.x(), top + 15))
        midpoint = (p1.x() + p2.x()) / 2
        arrow(painter, QtCore.QPointF(midpoint - 87, top), QtCore.QPointF(p1.x(), top), ink)
        arrow(painter, QtCore.QPointF(midpoint + 87, top), QtCore.QPointF(p2.x(), top), ink)
        painter.setFont(QtGui.QFont("Segoe UI", 17, QtGui.QFont.Bold))
        painter.drawText(QtCore.QRectF(midpoint - 85, top - 19, 170, 38), QtCore.Qt.AlignCenter,
                         f"{fit['gland_center_spacing_mm']:.1f} mm")
        bottom = project(V(x, y1, panel[0].BoundBox.ZMin)).y() + 22
        for ref, point in (("J1", p1), ("J2", p2)):
            label = "Toyota  ·  Ø16.6 mm" if ref == "J1" else "RGBW  ·  Ø12.5 mm"
            painter.drawText(QtCore.QRectF(point.x() - 145, bottom, 290, 40), QtCore.Qt.AlignCenter, label)

    plate_img = picture(out, "03-gland-plate-dimensions.png", "Two round bores on a 5 mm plate",
                        "Install both glands and locknuts on the loose plate before sliding it into the printed guides.",
                        {"GlandPlate": panel}, (-1, 0, 0), dimensions)

    service = {key: row for key, row in rows.items() if key != "Lid"}
    parked, color = service["J1Disconnect"]
    raised = translated(parked, 0, 0, DISCONNECT_LIFT)
    service["J1Disconnect"] = (raised, color)

    def release(painter, project):
        p, q = (project(shape.BoundBox.Center) for shape in (parked, raised))
        p += QtCore.QPointF(-52, -5)
        q += QtCore.QPointF(-52, 16)
        ink = QtGui.QColor("#a25e2e")
        arrow(painter, p, q, ink)
        painter.setFont(QtGui.QFont("Segoe UI", 15, QtGui.QFont.Bold))
        badge = QtCore.QRectF(q.x() - 153, (p.y() + q.y()) / 2 - 18, 135, 36)
        painter.fillRect(badge, QtGui.QColor("#fbf2e5"))
        painter.drawText(badge, QtCore.Qt.AlignCenter, f"{DISCONNECT_LIFT} mm lift")

    service_img = picture(out, "04-disconnect-service.png", "Unplug above the rim",
                          "Lift the mated Toyota connector on its service loop. The RGBW connector can stay parked.",
                          service, (-1.12, -1.21, 2), release)

    sheet = QtGui.QImage(2400, 1560, QtGui.QImage.Format_RGB32)
    painter = QtGui.QPainter(sheet)
    painter.setRenderHint(QtGui.QPainter.SmoothPixmapTransform)
    for i, img in enumerate((closed_img, stack_img, plate_img, service_img)):
        painter.drawImage(QtCore.QRect((i % 2) * 1200, (i // 2) * 780, 1200, 780), img)
    painter.end()
    if not sheet.save(str(out / "RevG-gallery.png")):
        raise ValueError("Could not save the gallery")


def build(out: Path):
    inputs = ROOT / "inputs"
    source = inputs / "4Runner_RevG_Gland_Assembly.FCStd"
    fit = json.loads((inputs / "gland-fit.json").read_text())
    if not fit["passed"]:
        raise ValueError("Gland review expects the released, checked assembly")
    doc = App.openDocument(str(source))
    report = screen(doc, fit, source)
    (out / "service-clearance.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    photograph(out, doc, fit)
    App.closeDocument(doc.Name)
    if not report["passed"]:
        raise RuntimeError("Gland service findings in service-clearance.json")
