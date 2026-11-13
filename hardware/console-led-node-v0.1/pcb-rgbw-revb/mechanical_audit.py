"""Generate the case and check reopened solids against the installed assembly."""

import argparse
import json
import os
from pathlib import Path
import platform
import sys


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from design import CASE, FUSE_GEOMETRY, FUSES, OUTLINE, PORTS, REFERENCE, UPPER_MOUNTS


def launch(mode, out):
    if platform.system() != "Windows" or platform.node().split(".")[0].casefold() != "orion":
        raise RuntimeError("Orion FreeCAD required")
    sys.path.insert(0, os.environ["ORION_CONSOLE_CONTROL_ROOT"])
    from modeling.jobs.ac_diagnostic_enclosure import find_freecad
    from modeling.jobs.ac_handheld import run_freecad

    native = find_freecad()
    if not native:
        raise RuntimeError("FreeCAD unavailable")
    code = (f"import sys\nsys.path.insert(0, {str(ROOT)!r})\n"
            f"from mechanical_audit import execute\nexecute({mode!r}, {str(out)!r})\n")
    run_freecad(native, code, out, 140)


def execute(mode, output):
    global App, Part, MeshPart, V
    import FreeCAD as App
    import Part
    import MeshPart
    V = App.Vector

    out = Path(output)
    if mode == "models":
        component_models(out)
    elif mode == "jlc-case":
        dimensions = {**CASE, "insert_depth_mm": 7.0, "lower_boss_diameter_mm": 8.0}
        base = enclosure(out, dimensions, render=False)
        manufacturing_coupon(out, base, dimensions)
    else:
        enclosure(out)


def box(x, y, z, width, depth, height):
    return Part.makeBox(width, depth, height, V(x, y, z))


def cylinder(x, y, z, diameter, height):
    return Part.makeCylinder(diameter / 2, height, V(x, y, z))


def rounded(x, y, z, width, depth, height, radius):
    solid = box(x, y, z, width, depth, height)
    edges = [e for e in solid.Edges if len(e.Vertexes) == 2
             and abs(e.Vertexes[0].Point.z - e.Vertexes[1].Point.z) > height - 0.001]
    return solid.makeFillet(radius, edges)


def reopen(path):
    shape = Part.Shape()
    shape.read(str(path))
    if shape.isNull() or not shape.isValid() or not shape.Solids:
        raise RuntimeError(f"invalid STEP solid: {path.name}")
    return shape


def translated(shape, x, y, z):
    result = shape.copy()
    result.translate(V(x, y, z))
    return result


def component_models(out):
    models = out / "models"
    models.mkdir(exist_ok=True)
    for ref, port in PORTS.items():
        dims = port["header_extent_mm"]
        left, right = dims["y_from_pad"]
        front, back = -dims["face_from_pad"], -dims["back_from_pad"]
        height = dims["height"]
        envelope = box(left, back, 0, right - left, front - back, height)
        # Shroud opening illustrates the mate; external dimensions come from
        # the package drawing and KiCad F.Fab. The latch is checked as a reserve.
        opening = box(left + 1.0, front - 5.5, 1.1, right - left - 2.0, 5.7, height - 2.2)
        header = envelope.cut(opening).removeSplitter()
        header.exportStep(str(models / (ref + ".step")))
    spec = FUSE_GEOMETRY
    width, depth, height = (spec[key] for key in ("body_x_mm", "body_y_mm", "holder_z_mm"))
    holder = box(-width / 2, -depth / 2, 0, width, depth, height)
    for x in (-3.9, 3.9):
        holder = holder.cut(box(x - 1.6, -.5, 2.2, 3.2, 1, height))
    holder.exportStep(str(models / "MINI-3568.step"))
    for path in models.glob("*.step"):
        reopen(path)


def export_printable(shape, name, out, *, flip=False):
    path = out / (name + ".step")
    shape.exportStep(str(path))
    actual = reopen(path)
    if len(actual.Solids) != 1:
        raise RuntimeError(f"{name} is not one solid")
    print_shape = actual.copy()
    if flip:
        print_shape.rotate(V(0, 0, 0), V(1, 0, 0), 180)
    bounds = print_shape.BoundBox
    print_shape.translate(V(-bounds.XMin, -bounds.YMin, -bounds.ZMin))
    mesh = MeshPart.meshFromShape(Shape=print_shape, LinearDeflection=.10, AngularDeflection=.16, Relative=False)
    if not mesh.isSolid():
        raise RuntimeError(f"{name} mesh is open")
    mesh.write(str(out / (name + ".stl")))
    return actual, {"step": path.name, "stl": name + ".stl", "closed_mesh": True,
                    "facets": mesh.CountFacets, "solid_volume_mm3": round(actual.Volume, 2),
                    "bounds_mm": [round(x, 3) for x in (bounds.XLength, bounds.YLength, bounds.ZLength)]}


def manufacturing_coupon(out, base, g):
    """Use regions of the print base to sample both ports and all three boss types."""
    height, depth, floor = (g[key] for key in ("body_height_mm", "depth_mm", "floor_mm"))
    offset = g["lid_insert_pitch_offset_mm"]
    ox, oy = g["pcb_origin_xy_mm"]
    lower_z = g["esp_pcb_bottom_mm"]
    shield_z = lower_z + g["stack_pitch_mm"]
    pilot, insert_depth = g["insert_pilot_mm"], g["insert_depth_mm"]
    port_region = box(0, 14, 0, g["wall_mm"] + 2.7, 49, height)
    corner = box(0, 62.5, 0, 12, depth - 62.5, height)
    upper_x, upper_y = max(((ox + x, oy + y) for x, y in UPPER_MOUNTS if ox + x < 20),
                           key=lambda axis: axis[1])
    holes = json.loads((REFERENCE / "engineering-inputs.json").read_text())["headers"]["mounting_holes"]
    lower_hole = min((p for p in holes if [p["x_mm"], p["y_mm"]] != g["lower_support_only_xy_mm"]),
                     key=lambda p: p["x_mm"])
    lower_x, lower_y = ox + lower_hole["x_mm"], oy + lower_hole["y_mm"]
    lower_offset = (13 - lower_x, 25 - lower_y, 0)
    upper_boss = box(upper_x - 5, upper_y - 5, 0, 10, 10, shield_z)
    lower_boss = box(lower_x - 5, lower_y - 5, 0, 10, 10, lower_z)
    upper_floor = box(0, upper_y - 5, 0, upper_x + 5, 10, floor)
    lower_floor = box(0, 20, 0, 18, 10, floor)

    sample = base.common(port_region).fuse([base.common(region) for region in
        (corner, upper_boss, upper_floor, lower_floor)] + [translated(base.common(lower_boss), *lower_offset)])
    # The reinforcing floor also intersects the shallow controller pilot.
    # Restore the cut from the original blind end up to the boss top.
    sample = sample.cut(cylinder(13, 25, lower_z - insert_depth, pilot, insert_depth + .1)).removeSplitter()
    actual, report = export_printable(sample, "ports_and_inserts_coupon", out)

    checks = []
    for name, region, delta in (("J1_J2_port_wall", port_region, (0, 0, 0)),
                                ("lid_corner", corner, (0, 0, 0)),
                                ("shield_boss", upper_boss, (0, 0, 0)),
                                ("controller_boss", lower_boss, lower_offset)):
        # Compare the reopened STEP with the exact base regions, including the pilot in the floor.
        original = translated(base.common(region), *delta)
        printed = actual.common(translated(region, *delta))
        difference = original.cut(printed).Volume + printed.cut(original).Volume
        checks.append({"check": name, "symmetric_difference_mm3": round(difference, 6),
                       "pass": difference < .01})

    min_x, min_y = actual.BoundBox.XMin, actual.BoundBox.YMin
    bosses = []
    for name, x, y, z in (("lid", offset, depth - offset, height),
                          ("shield", upper_x, upper_y, shield_z), ("controller", 13, 25, lower_z)):
        gauge = cylinder(x, y, z - insert_depth, pilot, insert_depth)
        end = cylinder(x, y, z - insert_depth - .25, pilot * .9, .2)
        interference = actual.common(gauge).Volume
        missing_floor = end.Volume - actual.common(end).Volume
        checks.append({"check": name + "_open_pilot_blind_end", "pilot_interference_mm3": round(interference, 6),
                       "missing_end_material_mm3": round(missing_floor, 6),
                       "pass": interference < .01 and abs(missing_floor) < .01})
        bosses.append({"type": name, "pilot_xyz_mm": [round(x - min_x, 2), round(y - min_y, 2), z]})

    evidence = {"process": "JLC3DP SLS 3201 PA-F, standard finish", "sample": report, "checks": checks,
                "bosses": bosses, "pilot_diameter_mm": pilot, "blind_depth_mm": insert_depth,
                "physical_fit_verified": False, "insert_retention_tested": False}
    (out / "ports-and-inserts-coupon-checks.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    if not all(row["pass"] for row in checks):
        raise RuntimeError("coupon regions differ from the print case base")


def enclosure(out, g=CASE, *, render=True):
    width, depth, height = (g[k] for k in ("width_mm", "depth_mm", "body_height_mm"))
    wall, floor, lid_thickness = (g[k] for k in ("wall_mm", "floor_mm", "lid_mm"))
    origin_x, origin_y = g["pcb_origin_xy_mm"]
    lower_z = g["esp_pcb_bottom_mm"]
    shield_z = lower_z + g["stack_pitch_mm"]
    board_top = shield_z + g["pcb_thickness_mm"]
    offset = g["lid_insert_pitch_offset_mm"]
    pilot, insert_depth = g["insert_pilot_mm"], g["insert_depth_mm"]
    lid_axes = [(x, y) for x in (offset, width - offset) for y in (offset, depth - offset)]
    upper_axes = [(origin_x + x, origin_y + y) for x, y in UPPER_MOUNTS]
    ref = json.loads((REFERENCE / "engineering-inputs.json").read_text())
    lower_axes = [(origin_x + p["x_mm"], origin_y + p["y_mm"]) for p in ref["headers"]["mounting_holes"]]
    support_only = tuple(p + offset for p, offset in zip(g["lower_support_only_xy_mm"], (origin_x, origin_y)))
    lower_fasteners = [axis for axis in lower_axes if axis != support_only]
    shell = rounded(0, 0, 0, width, depth, height, 4).cut(
        rounded(wall, wall, floor, width - 2 * wall, depth - 2 * wall, height, 4 - wall))
    # Gussets connect corner lid bosses to both walls. Independent floor
    # bosses take PCB insertion and cable withdrawal loads through screws.
    for x, y in lid_axes:
        px = wall - .2 if x < width / 2 else width - wall - 8.0
        py = wall - .2 if y < depth / 2 else depth - wall - 8.0
        shell = shell.fuse(box(px, py, floor, 8.2, 8.2, height - floor))
    for group, z, diameter in ((upper_axes, shield_z, g["shield_boss_diameter_mm"]),
                               (lower_axes, lower_z, g["lower_boss_diameter_mm"])):
        for x, y in group:
            shell = shell.fuse(cylinder(x, y, floor, diameter, z - floor))
    for group, z in ((lid_axes, height), (upper_axes, shield_z), (lower_fasteners, lower_z)):
        for x, y in group:
            shell = shell.cut(cylinder(x, y, z - insert_depth, pilot, insert_depth + .1))
    ears = g["ear_extension_mm"]
    for x in (-ears, width - .5):
        shell = shell.fuse(box(x, depth / 2 - 8, 0, ears + .5, 16, floor))
    for x in (-ears / 2, width + ears / 2):
        shell = shell.cut(cylinder(x, depth / 2, -.1, g["ear_hole_mm"], floor + .2))

    openings = []
    cable_bodies = {}
    insertion_corridors = {}
    for ref_name, port in PORTS.items():
        ax, ay = port["xy"]
        dims, cable = port["header_extent_mm"], port["cable_allowance_mm"]
        face_x = origin_x + ax + dims["face_from_pad"]
        center_y = origin_y + ay + sum(dims["y_from_pad"]) / 2
        half = cable["half_width"] + .45
        bottom = board_top - cable["below_pcb"] - .5
        shell = shell.cut(box(-.1, center_y - half, bottom, wall + .2, 2 * half, height - bottom + .2))
        connector_bottom = board_top - cable["below_pcb"]
        runout = g["nominal_cable_bend_clearance_mm"]
        cable_bodies[ref_name] = box(face_x - 23, center_y - cable["half_width"], connector_bottom,
                                     23, 2 * cable["half_width"], cable["height"])
        insertion_corridors[ref_name] = box(-runout, center_y - cable["half_width"], connector_bottom,
                                             face_x + runout, 2 * cable["half_width"], cable["height"])
        openings.append({"ref": ref_name, "purpose": port["name"], "face_x_mm": round(face_x, 3),
                         "center_y_mm": round(center_y, 3), "width_mm": 2 * half,
                         "floor_z_mm": round(bottom, 3), "top_open_to_lid": True})

    lid = rounded(0, 0, 0, width, depth, lid_thickness, 4)
    for y in (wall + .4, depth - wall - 1.6):
        lid = lid.fuse(box(11.5, y, -1.2, width - 23, 1.2, 1.5))
    for x, y in lid_axes:
        lid = lid.cut(cylinder(x, y, -.2, 3.3, lid_thickness + .4))
    shell = shell.removeSplitter()
    lid = lid.removeSplitter()
    base, base_report = export_printable(shell, "case_base", out)
    actual_lid, lid_report = export_printable(lid, "case_lid", out, flip=True)
    installed_lid = translated(actual_lid, 0, 0, height)

    pcb = reopen(out / "routed_shield.step")
    board_width = max(p[0] for p in OUTLINE) - min(p[0] for p in OUTLINE)
    boards = [s for s in pcb.Solids if abs(s.BoundBox.XLength - board_width) < .12
              and abs(s.BoundBox.YLength - 53.34) < .12 and abs(s.BoundBox.ZLength - 1.6) < .12]
    if len(boards) != 1:
        raise RuntimeError("could not locate the native shield PCB datum")
    datum = boards[0].BoundBox
    if abs(datum.XMin - min(p[0] for p in OUTLINE)) > .10 or abs(datum.YMin) > .10:
        raise RuntimeError("native shield STEP origin changed")
    shield = translated(pcb, origin_x, origin_y, board_top - datum.ZMax)

    # Nominal lower board and mating features. The controller STEP is the
    # Espressif module only; the UNO board and its socket heights are estimates.
    lower_board = box(origin_x, origin_y, lower_z, 68.58, 53.34, 1.6)
    for x, y in lower_axes:
        lower_board = lower_board.cut(cylinder(x, y, lower_z - .1, 3.2, 1.8))
    lower_top = lower_z + 1.6
    sockets = []
    for group in ref["headers"]["headers"]:
        pads = group["pads"]
        x0, x1 = min(p["x_mm"] for p in pads), max(p["x_mm"] for p in pads)
        sockets.append(box(origin_x + x0 - 1.24, origin_y + pads[0]["y_mm"] - 1.24,
                           lower_top, x1 - x0 + 2.48, 2.48, 8.5))
    module = reopen(ROOT / "inputs" / "ESP32-S3-WROOM-1.step")
    module.rotate(V(0, 0, 0), V(0, 0, 1), -90)
    b = module.BoundBox
    module.translate(V(origin_x + 42.5 - b.XMin, origin_y + 13 - b.YMin, lower_top - b.ZMin))
    usb = box(origin_x - 1.5, origin_y + 29.5, lower_top, 8.5, 8.0, 3.4)
    barrel = box(origin_x - 2.0, origin_y + 5.8, lower_top, 12.2, 9.0, 10.4)
    lower = Part.makeCompound([lower_board, module, usb, barrel] + sockets)

    fuses = {}
    fuse_service = {}
    installed_top = FUSE_GEOMETRY["installed_height_reserve_mm"]
    holder_top = FUSE_GEOMETRY["holder_z_mm"]
    for ref_name, fuse in FUSES.items():
        x, y = (p + off for p, off in zip(fuse["xy"], (origin_x, origin_y)))
        fuses[ref_name] = rounded(x - 5.5, y - 1.9, board_top + holder_top, 11, 3.8,
                                  installed_top - holder_top, .55)
        pull_w, pull_d = (FUSE_GEOMETRY[k] for k in ("puller_width_mm", "puller_depth_mm"))
        fuse_service[ref_name] = box(x - pull_w / 2, y - pull_d / 2, board_top + holder_top + .4,
                                     pull_w, pull_d, installed_top - holder_top + FUSE_GEOMETRY["puller_travel_mm"])

    results = []

    def measure(name, one, other, maximum=.015):
        overlap = one.common(other)
        volume = float(overlap.Volume)
        row = {"check": name, "interference_mm3": round(volume, 6), "pass": volume <= maximum}
        if not row["pass"]:
            bounds = overlap.BoundBox
            row["interference_bounds_mm"] = [round(v, 3) for v in
                (bounds.XMin, bounds.YMin, bounds.ZMin, bounds.XMax, bounds.YMax, bounds.ZMax)]
        results.append(row)

    for name, shape in (("shield", shield), ("controller", lower), *fuses.items(), *cable_bodies.items()):
        measure(name + "_against_base", shape, base)
        measure(name + "_against_lid", shape, installed_lid)
    measure("shield_against_controller", shield, lower)
    measure("lid_seats_on_base", installed_lid, base)
    for name, shape in insertion_corridors.items():
        measure(name + "_mating_corridor_against_base", shape, base)
        measure(name + "_mating_corridor_against_lid", shape, installed_lid)
    for ref_name, swept in fuse_service.items():
        measure(ref_name + "_vertical_puller_base_lid_removed", swept, base)
        measure(ref_name + "_vertical_puller_shield_lid_removed", swept, shield)
        other_fuse = next(other for name, other in fuses.items() if name != ref_name)
        measure(ref_name + "_vertical_puller_other_fuse", swept, other_fuse)
    for i, (x, y) in enumerate(upper_axes, 1):
        driver = cylinder(x, y, board_top + .05, 6.4, 24)
        measure(f"upper_screw_{i}_driver_shield", driver, shield)
        measure(f"upper_screw_{i}_driver_base", driver, base)
    for i, (x, y) in enumerate(lower_fasteners, 1):
        measure(f"lower_screw_{i}_before_shield", cylinder(x, y, lower_top + .05, 6.4, 24), lower)

    screw_heads = []
    for axes, top in ((upper_axes, board_top), (lower_fasteners, lower_top)):
        for x, y in axes:
            washer = cylinder(x, y, top, 7, .5).cut(cylinder(x, y, top - .05, 3.2, .6))
            head = cylinder(x, y, top + .5, 5.5, 3)
            screw_heads.extend([washer, head])
    lid_heads = [cylinder(x, y, height + lid_thickness, 5.5, 3) for x, y in lid_axes]
    measures = Part.makeCompound(screw_heads)
    measure("board_fastener_head_and_washer_shield", measures, shield)
    measure("board_fastener_head_and_washer_controller", measures, lower)
    measure("board_fastener_head_and_washer_lid", measures, installed_lid)
    # The lid and base are generated as a pair. The coupon uses the actual
    # port walls so a failed sample can be corrected without a full print.
    coupon = base.common(box(0, 14, 0, wall + 2.7, 49, height)).removeSplitter()
    _, coupon_report = export_printable(coupon, "connector_fit_coupon", out)

    doc = App.newDocument("RevB")
    roles = [("Cabin_base", base), ("Removable_lid", installed_lid), ("Routed_shield", shield),
             ("UNO_ESP32_S3_nominal", lower), ("Fastener_heads_nominal", Part.makeCompound(screw_heads + lid_heads)),
             *[(k + "_installed", v) for k, v in fuses.items()],
             *[(k + "_mate_reserve", v) for k, v in cable_bodies.items()]]
    for name, shape in roles:
        obj = doc.addObject("Part::Feature", name)
        obj.Shape = shape
    doc.recompute()
    doc.saveAs(str(out / "installed_assembly.FCStd"))
    Part.makeCompound([shape for _, shape in roles]).exportStep(str(out / "installed_assembly.step"))
    reopen(out / "installed_assembly.step")
    report = {
        "dimensions": g, "port_windows": openings, "lid_mounts_xy_mm": lid_axes,
        "shield_mounts_xy_mm": upper_axes, "controller_fasteners_xy_mm": lower_fasteners,
        "controller_support_only_xy_mm": support_only,
        "fuse_to_lid_vertical_clearance_mm": round(height - board_top - installed_top, 3),
        "checks": results, "passed_nominal_interference": all(row["pass"] for row in results),
        "printable": [base_report, lid_report, coupon_report],
        "geometry_authority": {"shield": "reopened KiCad STEP", "ports": "drawing and footprint envelopes",
                               "mating_cables": "conservative straight-extraction envelopes",
                               "fuses": "installed height reserve", "lower_board": "UNO reference and photo estimates",
                               "esp_module": "Espressif reference STEP at estimated placement"},
        "physical_fit_verified": False, "thermal_or_vibration_qualified": False,
    }
    (out / "mechanical-observation.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if not report["passed_nominal_interference"]:
        raise RuntimeError("nominal clearance findings; see mechanical-observation.json")
    if render:
        preview(out / "open_case.png", base, lower, shield, fuses, measures, board_width)
    return base


def preview(path, shell, controller, shield, fuses, fasteners, board_width):
    """Orthographic preview of the actual solids used in the interference audit."""
    from PySide2 import QtCore, QtGui, QtWidgets

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    camera = V(-1.1, -1.25, 2.4)
    camera.normalize()
    right = V(0, 0, 1).cross(camera)
    right.normalize()
    up = camera.cross(right)
    sun = V(-.35, -.42, .84)
    materials = [(shell, (51, 80, 91)), (controller, (109, 75, 140)), (fasteners, (178, 190, 192))]
    for solid in shield.Solids:
        bounds = solid.BoundBox
        if abs(bounds.XLength - board_width) < .12 and abs(bounds.ZLength - 1.6) < .12:
            color = (43, 115, 91)
        elif bounds.XMax < 26 and bounds.ZLength > 7:
            color = (56, 65, 71)
        elif bounds.ZLength < .3:
            color = (181, 145, 64)
        else:
            color = (95, 111, 114)
        materials.append((solid, color))
    materials.extend((shape, (150, 111, 201) if name == "F1" else (63, 68, 79)) for name, shape in fuses.items())
    triangles = []
    for shape, color in materials:
        nodes, faces = shape.tessellate(.42)
        for i, j, k in faces:
            a, b, c = nodes[i], nodes[j], nodes[k]
            normal = (b - a).cross(c - a)
            if normal.Length < 1e-7 or normal.dot(camera) < 0:
                continue
            normal.normalize()
            light = .66 + .36 * max(0, normal.dot(sun))
            rgb = [min(255, round(value * light)) for value in color]
            points = [(v.dot(right), -v.dot(up)) for v in (a, b, c)]
            triangles.append(((a + b + c).dot(camera) / 3, points, rgb))
    xs = [x for _, points, _ in triangles for x, _ in points]
    ys = [y for _, points, _ in triangles for _, y in points]
    scale = min(1330 / (max(xs) - min(xs)), 770 / (max(ys) - min(ys)))
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    image = QtGui.QImage(1600, 1040, QtGui.QImage.Format_ARGB32)
    image.fill(QtGui.QColor("#edf2f0"))
    paint = QtGui.QPainter(image)
    paint.setPen(QtCore.Qt.NoPen)
    for _, points, color in sorted(triangles, key=lambda tri: tri[0]):
        paint.setBrush(QtGui.QColor(*color))
        polygon = QtGui.QPolygonF([QtCore.QPointF(800 + (x - cx) * scale, 540 + (y - cy) * scale) for x, y in points])
        paint.drawPolygon(polygon)
    paint.setPen(QtGui.QColor("#18332d"))
    paint.setFont(QtGui.QFont("Segoe UI", 31, QtGui.QFont.DemiBold))
    paint.drawText(65, 85, "4Runner RGBW Rev B")
    paint.setPen(QtGui.QColor("#405d55"))
    paint.setFont(QtGui.QFont("Segoe UI", 16))
    paint.drawText(65, 980, "Nominal CAD assembly with lid removed for fuse access")
    paint.end()
    if not image.save(str(path)):
        raise RuntimeError("case preview export failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["models", "assembly", "jlc-case"])
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    launch(args.mode, args.out.resolve())
