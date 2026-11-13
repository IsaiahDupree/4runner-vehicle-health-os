"""Print details, assembly views and vertical service checks for the Rev B case."""

import json
from math import cos, pi, sin
from pathlib import Path

import FreeCAD as App
import Part

from mechanical_audit import box, cylinder, reopen, rounded, translated


V = App.Vector
ROOT = Path(__file__).resolve().parent
SPEC = json.loads((ROOT / "service-case.json").read_text(encoding="utf-8"))
PRINT = SPEC["printed"]
HARDWARE = SPEC["hardware"]
TOOLS = SPEC["tool_envelopes"]

# One-millimeter strokes keep small, functional labels printable in SLS.
GLYPHS = {
    "1": ("010", "110", "010", "010", "111"),
    "2": ("111", "001", "111", "100", "111"),
    "B": ("110", "101", "110", "101", "110"),
    "G": ("111", "100", "101", "101", "111"),
    "I": ("111", "010", "010", "010", "111"),
    "N": ("101", "111", "111", "111", "101"),
    "R": ("110", "101", "110", "101", "101"),
    "V": ("101", "101", "101", "101", "010"),
    "W": ("10001", "10001", "10101", "10101", "11111"),
    " ": ("00",) * 5,
}


def add_print_features(base, lid, g, ports):
    height = g["body_height_mm"]
    reach = PRINT["port_finger_depth_mm"]
    half = PRINT["port_finger_width_mm"] / 2
    corner = PRINT["port_finger_corner_mm"]
    if min(port["center_y_mm"] - half for port in ports) < 12 or max(
        port["center_y_mm"] + half for port in ports
    ) > g["depth_mm"] - 10:
        raise ValueError("latch relief touches a lid corner support")
    if ports[0]["center_y_mm"] - ports[1]["center_y_mm"] < 2 * half:
        raise ValueError("latch reliefs overlap")
    for port in ports:
        y = port["center_y_mm"] - half
        cutter = rounded(-1.5, y, height - reach, g["wall_mm"] + 3.5, 2 * half, 2 * reach, corner)
        base = base.cut(cutter)
        lid = lid.cut(rounded(-1.5, y, -.05, reach + 1.5, 2 * half, g["lid_mm"] + .1, corner))
    stroke = PRINT["port_label_stroke_mm"]
    relief = PRINT["port_label_relief_mm"]
    if PRINT["port_label_height_mm"] != stroke * 5:
        raise ValueError("port glyph height and stroke must agree")
    # Orient the words for a reader looking into the connector face.
    lettering = []
    for port, title in zip(ports, ("12V IN", "RGBW")):
        rows = ["0".join(GLYPHS[letter][row] for letter in title) for row in range(5)]
        for row, pixels in enumerate(rows):
            for col, pixel in enumerate(pixels):
                if pixel == "1":
                    x = 6.5 + (4 - row) * stroke
                    y = port["center_y_mm"] + (len(pixels) / 2 - col - 1) * stroke
                    lettering.append(box(x, y, g["lid_mm"] - .04, stroke + .04, stroke + .04, relief + .04))
    return base, lid.fuse(lettering).removeSplitter()


def socket_screw(x, y, seat, length):
    shaft = cylinder(x, y, seat - length, 3.0, length)
    head = cylinder(x, y, seat, 5.5, 3.0)
    r = TOOLS["hex_driver_bit_across_flats_mm"] / (2 * cos(pi / 6))
    points = [V(x + r * cos(n * pi / 3), y + r * sin(n * pi / 3), seat + 1.6) for n in range(6)]
    socket = Part.Face(Part.makePolygon(points + points[:1])).extrude(V(0, 0, 1.5))
    return shaft.fuse(head.cut(socket)).removeSplitter()


def cable_mate(ref, port, board_top):
    """Drawing-based outer envelope for illustration at the PCB mating plane."""
    x, y = port["face_x_mm"], port["center_y_mm"]
    if ref == "J1":
        width, length, height, offset = 9.0, 21.0, 14.3, .25
        insulation = (3.3, 3.3)
    else:
        width, length, height, offset = 13.2, 15.5, 8.0, .45
        insulation = (1.7,) * 5
    bottom = board_top - offset
    housing = rounded(x - length, y - width / 2, bottom, length, width, height, .8)
    latch = box(x - length + 3, y - 2, bottom + height - .2, length - 7, 4, 1.3)
    wires = [Part.makeCylinder(dia / 2, 19, V(x - length, y + (i - (len(insulation) - 1) / 2) * 2.4,
                                               bottom + height * .48), V(-1, 0, 0))
             for i, dia in enumerate(insulation)]
    return housing.fuse(latch).removeSplitter(), wires


def tool_checks(g, base, lid, shield, lower, lid_axes, upper_axes, lower_axes, fuses):
    """Audit continuous coaxial approach, allowance and hardware seating."""
    h = g["body_height_mm"]
    lower_z = g["esp_pcb_bottom_mm"]
    upper_z = lower_z + g["stack_pitch_mm"]
    washer = HARDWARE["washer_thickness_mm"]
    pcb = g["pcb_thickness_mm"]
    insert = HARDWARE["insert_length_mm"]
    pilot_depth = g["insert_depth_mm"]
    groups = [
        ("lid", lid_axes, h, g["lid_mm"], HARDWARE["lid_screw_length_mm"], None),
        ("controller", lower_axes, lower_z, pcb + washer, HARDWARE["board_screw_length_mm"], lower),
        ("shield", upper_axes, upper_z, pcb + washer, HARDWARE["board_screw_length_mm"], shield),
    ]
    fuse_bodies = Part.makeCompound(list(fuses.values()))
    results = []
    visible = []
    for role, axes, surface, stack, length, board in groups:
        for index, (x, y) in enumerate(axes, 1):
            name = f"{role}_{index}"
            shank_z = surface + TOOLS["heat_set_nose_length_mm"] - TOOLS["heat_set_downward_overtravel_mm"]
            handle_z = shank_z + TOOLS["heat_set_shank_length_mm"]
            seat = surface + stack
            bit_z = seat + 3.0
            driver_handle = bit_z + TOOLS["hex_driver_shaft_length_mm"]
            # The outer sections extend beyond the rim so these volumes
            # include every axial pose from first approach to full seating.
            nose = cylinder(x, y, surface, TOOLS["heat_set_nose_diameter_mm"], h + 1 - surface)
            shank = cylinder(x, y, shank_z, TOOLS["heat_set_shank_diameter_mm"],
                             max(1.0, h + 1 - shank_z))
            handle = cylinder(x, y, handle_z, TOOLS["heat_set_handle_diameter_mm"], 15)
            driver = cylinder(x, y, bit_z, TOOLS["hex_driver_shaft_diameter_mm"],
                              max(1.0, h + g["lid_mm"] + 1 - bit_z))
            driver_grip = cylinder(x, y, driver_handle, TOOLS["hex_driver_handle_diameter_mm"], 15)
            obstacles = [base]
            if role == "controller":
                obstacles.append(lower)
            elif role == "shield":
                obstacles += [shield, fuse_bodies]
            else:
                obstacles.append(lid)
            driver_hit = sum(interference(shape, path) for shape in obstacles for path in (driver, driver_grip))
            # Screw head and washer pass the higher part of the open cavity.
            seat_path = cylinder(x, y, seat - (washer if board is not None else 0), 7.0 if board is not None else 5.5,
                                 max(3.1, h + g["lid_mm"] + .1 - seat + washer))
            seat_hit = sum(interference(shape, seat_path) for shape in obstacles)
            path_hit = sum(interference(base, path) for path in (nose, shank, handle))
            entry = cylinder(x, y, surface - pilot_depth + .02, g["insert_pilot_mm"] - .06, pilot_depth - .02)
            entry_hit = interference(base, entry)
            end_probe = cylinder(x, y, surface - pilot_depth - .5, g["insert_pilot_mm"] - .3, .45)
            remaining_end = interference(base, end_probe)
            if not 0 <= remaining_end <= end_probe.Volume + .025:
                raise ValueError(f"{name} blind-end check exceeded probe volume")
            into_pilot = length - stack - HARDWARE["insert_seat_setback_mm"]
            gap_to_blind_end = pilot_depth - (length - stack)
            values = {
                "insert_approach_interference_mm3": round(path_hit, 6),
                "pilot_interference_mm3": round(entry_hit, 6),
                "driver_interference_mm3": round(driver_hit, 6),
                "head_or_washer_approach_interference_mm3": round(seat_hit, 6),
                "nominal_thread_overlap_mm": round(min(insert, into_pilot), 3),
                "screw_tip_to_blind_end_mm": round(gap_to_blind_end, 3),
                "insert_to_blind_end_mm": round(pilot_depth - insert, 3),
                "iron_handle_starts_above_rim_mm": round(handle_z - h, 3),
                "driver_handle_starts_above_rim_mm": round(driver_handle - h, 3),
            }
            # At full insertion the shank has its least headroom. A second
            # concentric pass records a small radial placement allowance.
            allowance = .25
            radial_gauges = [
                cylinder(x, y, surface, TOOLS["heat_set_nose_diameter_mm"] + 2 * allowance, h + 1 - surface),
                cylinder(x, y, shank_z, TOOLS["heat_set_shank_diameter_mm"] + 2 * allowance,
                         max(1.0, h + 1 - shank_z)),
            ]
            values["heat_set_radial_allowance_test_mm"] = allowance
            values["heat_set_radial_allowance_passed"] = all(interference(base, path) < .015 for path in radial_gauges)
            passed = (max(path_hit, entry_hit, driver_hit, seat_hit) < .015
                      and into_pilot >= 3 and gap_to_blind_end >= 1
                      and abs(end_probe.Volume - remaining_end) < .015)
            results.append({"id": name, "position_mm": [round(x, 3), round(y, 3), surface],
                            **values, "pass": bool(passed)})
            visible.append(cylinder(x, y, surface, TOOLS["heat_set_nose_diameter_mm"], shank_z - surface)
                           .fuse(cylinder(x, y, shank_z, TOOLS["heat_set_shank_diameter_mm"],
                                          max(7.0, h + 5 - shank_z))))
    return results, visible


def interference(shape, gauge):
    """Use disjoint bounds and subtract the obstacle from the tool volume."""
    volumes = []
    for solid in shape.Solids:
        if not solid.BoundBox.intersect(gauge.BoundBox):
            continue
        residual = gauge.cut(solid)
        removed = gauge.Volume - sum(piece.Volume for piece in residual.Solids)
        if removed < -.025:
            raise ValueError(f"tool cut grew by {-removed:.3f} mm³")
        volumes.append(max(0.0, removed))
    return sum(volumes)


def add_feature(doc, parent, name, label, shape, source, color):
    obj = doc.addObject("Part::Feature", name)
    obj.Label = label
    obj.Shape = shape
    obj.addProperty("App::PropertyString", "GeometrySource", "Reference").GeometrySource = source
    obj.addProperty("App::PropertyColor", "ReferenceColor", "Reference").ReferenceColor = tuple(c / 255 for c in color)
    parent.addObject(obj)
    return obj


def assembly(out, g, base, lid, shield, lower, lower_components, ports, lid_axes, upper_axes,
             lower_axes, fuses, *, accurate_depth=False, captive_loom=None):
    height = g["body_height_mm"]
    pcb_top = g["esp_pcb_bottom_mm"] + g["stack_pitch_mm"] + g["pcb_thickness_mm"]
    seats, paths = tool_checks(g, base, lid, shield, lower, lid_axes, upper_axes, lower_axes, fuses)
    states = dict(SPEC["service_states"])
    interface = SPEC["interface"]
    if captive_loom is not None:
        from toyota_power import SPEC as POWER

        interface = POWER["definition"]
        states["plug_service"] = "Unplug the vehicle-side and lamp-side mates outside the box."
        states["lead_service"] = "Remove the lid and release the case-side ties to service the leads."
    tool_report = {"contract": SPEC["definition"], "interface": interface,
                   "envelopes": TOOLS, "states": states, "axes": seats,
                   "cavity_checks_passed": all(seat["pass"] for seat in seats),
                   "actual_tool_and_print_verified": False}
    (out / "tool-access.json").write_text(json.dumps(tool_report, indent=2) + "\n", encoding="utf-8")
    if len(seats) != 11 or not tool_report["cavity_checks_passed"]:
        raise ValueError("insert or screw access findings; inspect tool-access.json")
    insert = reopen(ROOT / "inputs" / "ruthex_RX-M3x5_7.stp")
    materials = {
        "base": (69, 82, 94), "lid": (100, 114, 130), "shield": (44, 125, 101),
        "lower": (109, 67, 149), "insert": (214, 156, 70), "screw": (174, 185, 194),
        "plug": (41, 48, 59), "reference": (89, 146, 172),
    }
    doc = App.newDocument("FourRunnerRGBW_Service")
    groups = {}
    for key, label in (
        ("Print", "Printable enclosure"), ("PCB", "Two-board stack"),
        ("Hardware", "Inserts, screws and fuses"),
        ("Loom", "Captive Toyota power and LED leads" if captive_loom is not None else "Vehicle and light cable mates"),
    ):
        groups[key] = doc.addObject("App::DocumentObjectGroup", key)
        groups[key].Label = label
    rendered = []

    def add(group, name, label, shape, source, color, level=0, display=True):
        obj = add_feature(doc, groups[group], name, label, shape, source, color)
        if display:
            rendered.append((name, shape, color, level))
        return obj

    add("Print", "Base", "Base · 3201 PA-F", base, "Reopened printable case STEP", materials["base"])
    add("Print", "Lid", "Lid · labeled cable exits" if captive_loom is not None else "Lid · labeled latch reliefs",
        lid, "Reopened printable case STEP", materials["lid"], 5)
    stack_solids = []
    for solid in shield.Solids:
        b = solid.BoundBox
        if b.XLength > 110 and abs(b.ZLength - 1.6) < .12:
            color = materials["shield"]
        elif b.ZLength < .3:
            color = (175, 142, 67)
        else:
            color = (57, 68, 75)
        stack_solids.append((solid, color))
    add("PCB", "Shield", "Rev B · routed RGBW shield", shield, SPEC["source_notes"]["routed_shield"],
        materials["shield"], 3, display=False)
    rendered.extend(("Shield", solid, color, 3) for solid, color in stack_solids)
    for index, (label, shape) in enumerate(lower_components.items(), 1):
        source = "Espressif STEP with seller-image placement" if label == "ESP32 module" else SPEC["source_notes"]["controller"]
        color = materials["lower"] if label == "PCB" else materials["plug"]
        add("PCB", f"ControllerPart{index}", "ESP32-S3 UNO · " + label, shape, source, color, 1)
    for ref, shape in fuses.items():
        amps = 3 if ref == "F1" else 1
        color = (142, 91, 177) if ref == "F1" else (52, 60, 72)
        add("Hardware", ref, f"{ref} · {amps} A MINI fuse", shape, "MINI body height reserve above holder", color, 4)
    for index, seat in enumerate(seats, 1):
        x, y, surface = seat["position_mm"]
        name = seat["id"]
        lid_role = name.startswith("lid")
        level = 10 if lid_role else 4 if name.startswith("shield") else 2
        add("Hardware", f"Insert{index}", f"{name} · RX-M3x5.7", translated(insert, x, y, surface),
            SPEC["source_notes"]["insert"], materials["insert"])
        screw_z = surface + (g["lid_mm"] if lid_role else g["pcb_thickness_mm"] + HARDWARE["washer_thickness_mm"])
        length = HARDWARE["lid_screw_length_mm"] if lid_role else HARDWARE["board_screw_length_mm"]
        if not lid_role:
            thickness = HARDWARE["washer_thickness_mm"]
            washer = cylinder(x, y, screw_z - thickness, 7.0, thickness).cut(
                cylinder(x, y, screw_z - thickness - .05, 3.2, thickness + .1))
            add("Hardware", f"Washer{index}", f"{name} · insulating washer", washer, "7 mm OD × 0.5 mm",
                (220, 225, 226), level)
        add("Hardware", f"Screw{index}", f"{name} · M3 × {length:g}", socket_screw(x, y, screw_z, length),
            SPEC["source_notes"]["screws"], materials["screw"], level)
    for name, label, shape, source, color in captive_loom or ():
        add("Loom", name, label, shape, source, color)
    for port in () if captive_loom is not None else ports:
        ref = port["ref"]
        shape, wires = cable_mate(ref, port, pcb_top)
        add("Loom", ref + "Mate", ref + " · " + port["purpose"], shape, SPEC["source_notes"]["cable_plugs"],
            materials["plug"])
        palette = [(42, 46, 53), (176, 61, 59)] if ref == "J1" else [
            (173, 65, 63), (70, 125, 100), (75, 113, 166), (177, 126, 57), (218, 221, 215)]
        for i, (wire, color) in enumerate(zip(wires, palette), 1):
            add("Loom", ref + f"Wire{i}", ref + " · wire exit reserve", wire, "Short straight cable visualization", color)

    doc.recompute()
    project = out / "4Runner_Service_Assembly.FCStd"
    doc.saveAs(str(project))
    reopen_file = out / "4Runner_Service_Assembly.step"
    Part.makeCompound([obj.Shape for group in groups.values() for obj in group.Group]
                      ).exportStep(str(reopen_file))
    reopen(reopen_file)
    App.closeDocument(doc.Name)
    restored = App.openDocument(str(project))
    if len(restored.getObject("Hardware").Group) != 31 or not restored.getObject("Base").Shape.isValid():
        raise ValueError("saved FreeCAD assembly missing hardware or base")
    App.closeDocument(restored.Name)
    tool_doc = App.newDocument("FourRunnerRGBW_ServicePaths")
    tool_group = tool_doc.addObject("App::DocumentObjectGroup", "Approaches")
    tool_group.Label = "Vertical insert approaches"
    add_feature(tool_doc, tool_group, "Base", "Empty base", base, "Reopened printable case STEP", materials["base"])
    for index, (seat, path) in enumerate(zip(seats, paths), 1):
        add_feature(tool_doc, tool_group, f"Axis{index}", seat["id"] + " · iron approach",
                    path, "Analytical nose and shank envelope", materials["reference"])
    tool_doc.recompute()
    tool_doc.saveAs(str(out / "4Runner_Insert_Tool_Paths.FCStd"))
    App.closeDocument(tool_doc.Name)
    views(out, rendered, base, paths, accurate_depth=accurate_depth, captive=captive_loom is not None)


def depth_render(triangles, scale, cx, cy, QtGui):
    """Rasterize orthographic triangles so the opaque lid hides the circuit board."""
    import numpy as np

    width, height = 1600, 1040
    rgb = np.full((height, width, 3), (241, 244, 245), dtype=np.uint8)
    zbuffer = np.full((height, width), -np.inf, dtype=np.float32)
    for depths, points, color in triangles:
        x, y = zip(*((800 + (px - cx) * scale, 545 + (py - cy) * scale) for px, py in points))
        x0, x1 = max(0, int(min(x))), min(width, int(max(x)) + 1)
        y0, y1 = max(0, int(min(y))), min(height, int(max(y)) + 1)
        if x0 >= x1 or y0 >= y1:
            continue
        determinant = (y[1] - y[2]) * (x[0] - x[2]) + (x[2] - x[1]) * (y[0] - y[2])
        if abs(determinant) < 1e-7:
            continue
        gx = np.arange(x0, x1, dtype=np.float32)[None, :] + .5 - x[2]
        gy = np.arange(y0, y1, dtype=np.float32)[:, None] + .5 - y[2]
        a = ((y[1] - y[2]) * gx + (x[2] - x[1]) * gy) / determinant
        b = ((y[2] - y[0]) * gx + (x[0] - x[2]) * gy) / determinant
        c = 1 - a - b
        distance = depths[0] * a + depths[1] * b + depths[2] * c
        depth = zbuffer[y0:y1, x0:x1]
        visible = (a >= -1e-5) & (b >= -1e-5) & (c >= -1e-5) & (distance > depth)
        depth[visible] = distance[visible]
        rgb[y0:y1, x0:x1][visible] = color
    return QtGui.QImage(rgb.data, width, height, width * 3, QtGui.QImage.Format_RGB888).copy()


def views(out, rendered, base, paths, *, accurate_depth=False, captive=False):
    from PySide2 import QtCore, QtGui, QtWidgets

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    views_to_render = [
        ("closed.png", "4Runner RGBW controller",
         "Captive Toyota power lead and RGBW lead" if captive else "Closed case · vehicle input and RGBW output",
         [(shape, color) for _, shape, color, _ in rendered], V(-1.15, -.8, 1.85)),
        ("open.png", "Fuses and cable connections",
         "F1 3 A main and LED · F2 1 A logic · case-mounted cable relief"
         if captive else "F1 3 A main and LED · F2 1 A logic · both plugs seated",
         [(shape, color) for name, shape, color, level in rendered if name != "Lid" and level < 10],
         V(-1.05, -.78, 2.6)),
        ("exploded.png", "Two-board assembly", "Screw lid · fused RGBW shield · ESP32-S3 UNO · nylon base",
         [(translated(shape, -12 if name.startswith(("J1", "J2")) else 13 if level == 5 else 0,
                      30 if level == 5 else 0, 56 if level >= 5 else level * 10), color)
          for name, shape, color, level in rendered], V(-.85, -1.2, 1.45)),
        ("insert-access.png", "Heat-set insert access", "Eleven vertical approaches · empty base before installing either board",
         [(base, (73, 89, 103)), *((shape, (215, 153, 71)) for shape in paths)], V(-.9, -1.15, 2.25)),
    ]
    for filename, title, subtitle, parts, camera in views_to_render:
        camera.normalize()
        right = V(0, 0, 1).cross(camera)
        right.normalize()
        up = camera.cross(right)
        light = V(-.45, -.5, .82)
        light.normalize()
        triangles = []
        for shape, color in parts:
            nodes, faces = shape.tessellate(.32)
            for i, j, k in faces:
                a, b, c = nodes[i], nodes[j], nodes[k]
                normal = (b - a).cross(c - a)
                if normal.Length < 1e-8 or normal.dot(camera) <= 0:
                    continue
                normal.normalize()
                exposure = .56 + .40 * max(0, normal.dot(light))
                points = [(v.dot(right), -v.dot(up)) for v in (a, b, c)]
                triangles.append((tuple(v.dot(camera) for v in (a, b, c)), points,
                                  [round(ch * exposure) for ch in color]))
        xs = [x for _, points, _ in triangles for x, _ in points]
        ys = [y for _, points, _ in triangles for _, y in points]
        scale = min(1350 / (max(xs) - min(xs)), 735 / (max(ys) - min(ys)))
        cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
        if accurate_depth:
            image = depth_render(triangles, scale, cx, cy, QtGui)
        else:
            image = QtGui.QImage(1600, 1040, QtGui.QImage.Format_ARGB32)
            image.fill(QtGui.QColor("#f1f4f5"))
        painter = QtGui.QPainter(image)
        if not accurate_depth:
            painter.setPen(QtCore.Qt.NoPen)
            for _, points, color in sorted(triangles, key=lambda tri: sum(tri[0])):
                ink = QtGui.QColor(*color)
                painter.setPen(ink)
                painter.setBrush(ink)
                painter.drawPolygon(QtGui.QPolygonF([QtCore.QPointF(800 + (x - cx) * scale, 545 + (y - cy) * scale)
                                                     for x, y in points]))
        painter.setRenderHint(QtGui.QPainter.Antialiasing)
        painter.setPen(QtGui.QColor("#172a38"))
        painter.setFont(QtGui.QFont("Segoe UI", 31, QtGui.QFont.Bold))
        painter.drawText(64, 88, title)
        painter.setPen(QtGui.QColor("#485c68"))
        painter.setFont(QtGui.QFont("Segoe UI", 15))
        painter.drawText(64, 983, subtitle)
        painter.end()
        if not image.save(str(out / filename)):
            raise ValueError(f"unable to save {filename}")
