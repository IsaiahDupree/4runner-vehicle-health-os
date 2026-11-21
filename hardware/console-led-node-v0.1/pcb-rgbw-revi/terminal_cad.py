"""Specification-based terminal reference and exported-assembly audits on Orion."""
from pathlib import Path
import csv
import gzip
import json
from itertools import combinations, permutations
from math import atan, cos, pi, sin, sqrt
import terminal_design as design
import FreeCAD as App
import Part
import MeshPart
import mechanical_audit as ma
ma.App, ma.Part, ma.MeshPart, ma.V = App, Part, MeshPart, App.Vector
from service_case import HARDWARE, add_feature, socket_screw, tool_checks
import durable_case

V = App.Vector


def dogleg(a, b, radius=5.0):
    """Two tangent circular bends with optional straight; parallel +X ends."""
    x = V(1, 0, 0)
    delta = b - a
    axial = delta.x
    lateral = V(0, delta.y, delta.z)
    distance = lateral.Length
    if axial < 2 * radius - 1e-6:
        raise ValueError("Insufficient axial run for specified wire bend")
    if distance < 1e-6:
        return [Part.makeLine(a, b)], None
    n = lateral / distance
    if distance >= axial:
        r, angle = axial / 2, pi / 2
        straight = distance - axial
    else:
        r = (axial * axial + distance * distance) / (4 * distance)
        angle = 2 * atan(distance / axial)
        straight = 0
    if r < radius - .001:
        raise ValueError("Bend radius below design floor")
    c1 = a + n * r
    e1 = a + x * (r * sin(angle)) + n * (r * (1 - cos(angle)))
    m1 = c1 + x * (r * sin(angle / 2)) - n * (r * cos(angle / 2))
    edges = [Part.Arc(a, m1, e1).toShape()]
    s2 = e1 + n * straight
    if straight:
        edges.append(Part.makeLine(e1, s2))
    c2 = s2 + x * (r * sin(angle)) - n * (r * cos(angle))
    m2 = c2 - x * (r * sin(angle / 2)) + n * (r * cos(angle / 2))
    edges.append(Part.Arc(s2, m2, b).toShape())
    return edges, r


def route_edges(a, b, pre=0, post=0):
    direction = V(1, 0, 0)
    edges, radius = dogleg(a + direction * pre, b - direction * post)
    if pre > 1e-6:
        edges.insert(0, Part.makeLine(a, a + direction * pre))
    if post > 1e-6:
        edges.append(Part.makeLine(b - direction * post, b))
    return edges, radius


def wire(a, b, diameter=1.6, pre=0, post=0):
    edges, radius = route_edges(a, b, pre, post)
    # Short conductor section inside the modeled terminal entry is intentional.
    edges.append(Part.makeLine(b, b + V(1.6, 0, 0)))
    path = Part.Wire(edges)
    circle = Part.Wire([Part.makeCircle(diameter / 2, a, V(1, 0, 0))])
    shape = path.makePipeShell([circle], True, False)
    if not shape.isValid() or len(shape.Solids) != 1:
        raise ValueError("Invalid wire sweep")
    return shape, path.Length, radius


def fanout(rows, center_y, radial, start_x, board_top):
    """Choose an uncrossed ring-to-row fanout, then verify exact swept solids."""
    import numpy as np
    count = len(rows)
    targets = [V(r["case_xy_mm"][0] - 5.4, r["case_xy_mm"][1], board_top + 6) for r in rows]
    best = None
    for phase in range(0, 360, 30):
        starts = [V(start_x, center_y + radial * cos(i * 2 * pi / count + phase * pi / 180),
                    22 + radial * sin(i * 2 * pi / count + phase * pi / 180)) for i in range(count)]
        samples = {}
        for target, b in enumerate(targets):
            for start, a in enumerate(starts):
                extra = b.x - a.x - 10.0
                if extra < 2.9:
                    raise ValueError("Fanout requires at least 13 mm axial space")
                for band in (0, 1):
                    pre, post = (0, extra) if band == 0 else (extra, 0)
                    edges, _ = route_edges(a, b, pre, post)
                    samples[target, start, band] = np.array([list(v) for e in edges for v in e.discretize(Deflection=.01)])
        separation = {}
        for i in range(count):
            for j in range(i + 1, count):
                for a in range(count):
                    for b in range(count):
                        if a == b:
                            continue
                        for ba in (0, 1):
                            for bb in (0, 1):
                                d = samples[i, a, ba][:, None, :] - samples[j, b, bb][None, :, :]
                                separation[i, j, a, ba, b, bb] = float(np.sqrt(np.min(np.einsum("ijk,ijk->ij", d, d))))
        pairs = [(i, j) for i in range(count) for j in range(i + 1, count)]
        for selected in combinations(range(count), count // 2):
            band = [int(i in selected) for i in range(count)]
            for assignment in permutations(range(count)):
                clearance = min(separation[i, j, assignment[i], band[assignment[i]], assignment[j], band[assignment[j]]]
                                for i, j in pairs) - 1.6
                if best is None or clearance > best[0]:
                    routes = []
                    for i, start in enumerate(assignment):
                        extra = targets[i].x - starts[start].x - 10
                        pre, post = (0, extra) if band[start] == 0 else (extra, 0)
                        routes.append((starts[start], pre, post))
                    best = clearance, routes, phase
        if best[0] >= .30:
            break
    if best[0] < .18:
        raise ValueError(f"Wire fanout needs more space: coarse clearance {best[0]:.4f} mm")
    return best[1], {"phase_deg": best[2], "sampled_surface_clearance_mm": best[0],
                     "sample_deflection_mm": .01, "exact_swept_solid_audit_required": True}


def build(folder):
    out = Path(folder)
    inputs = design.ROOT / "inputs"
    old = App.openDocument(str(inputs / "4Runner_RevG_Gland_Assembly.FCStd"))
    source = ma.reopen(inputs / "routed_shield.step")
    substrates = [s for s in source.Solids if abs(s.BoundBox.XLength - 133) < .1
                  and abs(s.BoundBox.YLength - 65) < .1 and 1.4 < s.BoundBox.ZLength < 1.8]
    if len(substrates) != 1:
        raise ValueError("Expected the exported 133 x 65 mm board substrate")
    board_top = 14.6
    dz = board_top - substrates[0].BoundBox.ZMax
    board = ma.translated(source, 86, 11.33, dz)
    substrate = ma.translated(substrates[0], 86, 11.33, dz)
    bottom = substrate.BoundBox.ZMin
    # Fill the former pilot before adding the stronger, displaced pillar.
    base = old.Base.Shape.fuse(Part.makeCylinder(3.5, 10.3, V(40, 16.13, 2.7)))
    base = base.fuse(Part.makeCylinder(4.5, 10.3, V(45, 14, 2.7)))
    base = base.cut(durable_case.insert_pilot(45, 14, 13, 4.0, 7.0))
    rails = [ma.box(x, y, 2.7, 1.8, length, bottom - 2.7)
             for y, length, xs in ((6.4, 30.9, (30.3, 37.0)), (38.6, 30.8, (27.3, 34.0))) for x in xs]
    base = base.fuse(rails).removeSplitter()
    base, base_info = ma.export_printable(base, "case_base", out)
    raw_lid = ma.translated(old.Lid.Shape, 0, 0, -36)
    raw_lid, lid_info = ma.export_printable(raw_lid, "case_lid", out, flip=True)
    lid = ma.translated(raw_lid, 0, 0, 36)
    panel_print = old.GlandPlate.Shape.copy()
    panel_print.rotate(V(), V(0, 1, 0), -90)
    panel, panel_info = ma.export_printable(panel_print, "gland_plate", out)
    panel.rotate(V(), V(0, 1, 0), 90)
    checks = []

    def check(name, shape, other, minimum=0, allowed=.015):
        overlap = shape.common(other).Volume if shape.BoundBox.intersect(other.BoundBox) else 0
        distance = shape.distToShape(other)[0] if minimum else None
        checks.append({"check": name, "overlap_mm3": round(overlap, 6),
                       "clearance_mm": round(distance, 4) if distance is not None else None,
                       "required_clearance_mm": minimum,
                       "pass": overlap < allowed and (distance is None or distance + 1e-4 >= minimum)})

    check("Exported populated board versus printed base", board, base)
    check("Exported populated board versus closed lid", board, lid, .55)
    check("Plate seated in revised base", panel, base, .18)
    check("Lid seated on revised base", lid, base)
    fuses = {ref: old.getObject(ref).Shape.copy() for ref in ("F1", "F2")}
    pullers = {}
    from design import FUSE_GEOMETRY
    for ref, fuse in fuses.items():
        b = fuse.BoundBox
        width, depth, travel = (FUSE_GEOMETRY[k] for k in ("puller_width_mm", "puller_depth_mm", "puller_travel_mm"))
        pullers[ref] = ma.box(b.Center.x - width / 2, b.Center.y - depth / 2,
                             b.ZMin + .4, width, depth, b.ZLength + travel)
        check(ref + " puller versus revised PCB", pullers[ref], board)
        check(ref + " puller versus revised base", pullers[ref], base)

    doc = App.newDocument("FourRunner_RevI_Terminal_Assembly")
    for name in ("Print", "PCB", "Hardware", "Loom", "Access"):
        doc.addObject("App::DocumentObjectGroup", name)
    add_feature(doc, doc.Print, "Base", "Rev I base with terminal bearing rails", base, "Reopened printable STEP", (66, 86, 99))
    add_feature(doc, doc.Print, "Lid", "Removable lid", lid, "Reopened printable STEP", (104, 126, 139))
    add_feature(doc, doc.Print, "GlandPlate", "Gland plate", panel, "Reopened printable STEP", (95, 132, 135))
    add_feature(doc, doc.PCB, "Shield", "Rev I integrated board", board, "Reopened native KiCad STEP", (36, 116, 87))
    for ref, fuse in fuses.items():
        add_feature(doc, doc.Hardware, ref, ref + " MINI fuse", fuse, "Retained installed fuse envelope", (142, 83, 159))
    gland_data = json.loads((inputs / "gland-fit.json").read_text())["glands"]
    gland_shapes = []
    for ref in ("J1", "J2"):
        g = gland_data[ref]
        for ending in ("Body", "Nut"):
            obj = old.getObject(ref + ending)
            shape = obj.Shape.copy()
            gland_shapes.append(shape)
            add_feature(doc, doc.Hardware, ref + ending, ref + " gland " + ending, shape,
                        "Retained dimensioned gland envelope", (45, 52, 58))
        thread = Part.makeCylinder(g["nominal_thread_mm"] / 2, g["thread_length_mm"],
                                   V(.6, g["center_y_mm"], 22), V(1, 0, 0))
        gland_shapes.append(thread)
        add_feature(doc, doc.Hardware, ref + "Thread", ref + " thread envelope", thread,
                    "Nominal thread; gland bore and sleeve omitted", (64, 71, 77))
        start = .6 - g["exposed_length_mm"] - 10
        jacket_end = 13.1 if ref == "J1" else 16.1
        jacket = Part.makeCylinder(g["jacket_mm"] / 2, jacket_end - start,
                                   V(start, g["center_y_mm"], 22), V(1, 0, 0))
        add_feature(doc, doc.Loom, ref + "Jacket", ref + f" intact jacket, stripped at X={jacket_end} mm", jacket,
                    "Selected cable-OD envelope; gland compresses jacket", (39, 88, 85) if ref == "J2" else (46, 51, 56))
        check(ref + " gland hardware versus PCB", Part.makeCompound(gland_shapes[-3:]), board, 1)

    mapping = json.loads((inputs / "terminal-map.json").read_text())["terminals"]
    wires, cut_rows, fanout_rows = {}, [], {}
    terminal_bodies = [s for s in board.Solids if 13.9 < s.BoundBox.ZLength < 14.2 and s.BoundBox.XMax < 40]
    if len(terminal_bodies) != 6:
        raise ValueError("Expected six actual exported terminal bodies")
    terminal_base_z = min(s.BoundBox.ZMin for s in terminal_bodies)
    palette = {"GND": (51, 59, 68), "ACC": (186, 63, 64), "TAIL": (45, 145, 102), "DIM": (195, 205, 192),
               "RSV3": (107, 158, 83), "RSV4": (179, 194, 162), "R-": (194, 61, 67), "G-": (41, 162, 103),
               "B-": (50, 103, 194), "+LED": (215, 161, 63), "W-": (215, 224, 225)}
    for cable, rows in (("J1", [r for r in mapping if r["vehicle_cavity"]]),
                        ("J2", [r for r in mapping if r["ref"] in {"JT4", "JT5", "JT6"} and r["label"] != "NC"])):
        rows.sort(key=lambda r: r["case_xy_mm"][1])
        radial = 2.2 if cable == "J1" else 1.9
        cy = gland_data[cable]["center_y_mm"]
        jacket_end = 13.1 if cable == "J1" else 16.1
        routes, fanout_rows[cable] = fanout(rows, cy, radial, jacket_end, terminal_base_z)
        for row, (start, pre, post) in zip(rows, routes):
            x, y = row["case_xy_mm"]
            entry = V(x - 5.4, y, terminal_base_z + 6.0)
            shape, length, radius = wire(start, entry, pre=pre, post=post)
            key = row["ref"] + "_" + str(row["pin"])
            wires[key] = shape
            add_feature(doc, doc.Loom, key, key + " " + row["label"], shape,
                        "Tangent circular wire path; entry height is a drawing-based estimate", palette[row["label"]])
            for label, obstacle in (("base", base), ("lid", lid), ("PCB", board), ("plate", panel)):
                check(key + " wire versus " + label, shape, obstacle)
            for ref, puller in pullers.items():
                check(key + " wire versus " + ref + " puller", shape, puller)
            cut_rows.append({"cable": cable, "terminal": key, "label": row["label"],
                             "vehicle_cavity": row["vehicle_cavity"], "net": row["net"],
                             "jacket_end_x_mm": jacket_end, "entry_xyz_mm": list(entry),
                             "pre_bend_straight_mm": pre, "post_bend_straight_mm": post,
                             "modeled_wire_length_after_jacket_mm": round(length, 3),
                             "minimum_centerline_bend_radius_mm": round(radius, 4) if radius else None,
                             "insulation_od_mm": 1.6, "strip_length_mm": "6-7",
                             "cut_length_status": "routing length only; add termination and manufacturing allowance"})
    wire_items = list(wires.items())
    for i, (a, ashape) in enumerate(wire_items):
        for b, bshape in wire_items[i + 1:]:
            check(a + " versus " + b + " wire", ashape, bshape, .15)

    for ref, _, _, _, _ in design.TERMINALS:
        pins = [r for r in mapping if r["ref"] == ref]
        ys = [r["case_xy_mm"][1] for r in pins]
        body = min(terminal_bodies, key=lambda s: abs(s.BoundBox.Center.y - sum(ys) / 2))
        # The entire top of each body is accessible, covering uncertainty in the
        # screw-axis offset in the manufacturer family drawing.
        tool = ma.box(body.BoundBox.XMin - .4, min(ys) - 2.9, body.BoundBox.ZMax + .05,
                      body.BoundBox.XLength + .8, 10.9, 40)
        add_feature(doc, doc.Access, ref + "Driver", ref + " full-top driver-access reserve", tool,
                    "Conservative full-body vertical access; lid removed", (85, 174, 190))
        for label, obstacle in (("base", base), ("PCB", board), *fuses.items(), *wires.items()):
            check(ref + " vertical driver versus " + label, tool, obstacle)
    spec = json.loads((inputs / "mechanical-observation.json").read_text())
    g = {**spec["dimensions"], "width_mm": 180, "pcb_origin_xy_mm": [86, 11.33]}
    old_tools = json.loads((inputs / "gland-fit.json").read_text())["tool_axes"]
    lids = [r["position_mm"][:2] for r in old_tools if r["id"].startswith("lid")]
    mounts = [r["position_mm"][:2] for r in old_tools if not r["id"].startswith("lid")]
    mounts[0] = [45, 14]
    hardware, _ = tool_checks(g, base, lid, board, Part.Shape(), lids, mounts, [], fuses)
    checks.extend({"check": r["id"] + " insert and screw tools", "pass": r["pass"]} for r in hardware)
    insert_reference = ma.reopen(inputs / "ruthex_RX-M3x5_7.stp")
    installed = []
    for index, row in enumerate(hardware, 1):
        x, y, seat = row["position_mm"]
        is_lid = row["id"].startswith("lid")
        insert = ma.translated(insert_reference, x, y, seat)
        screw_seat = seat + (g["lid_mm"] if is_lid else g["pcb_thickness_mm"] + HARDWARE["washer_thickness_mm"])
        length = HARDWARE["lid_screw_length_mm" if is_lid else "board_screw_length_mm"]
        screw = socket_screw(x, y, screw_seat, length)
        add_feature(doc, doc.Hardware, "Insert" + str(index), row["id"] + " ruthex insert", insert,
                    "Manufacturer ruthex RX-M3x5.7 STEP; heat-set interference is intentional", (173, 122, 51))
        add_feature(doc, doc.Hardware, "Screw" + str(index), row["id"] + f" M3 x {length:g}", screw,
                    "Specification-based nominal screw with recessed hex drive", (137, 149, 157))
        installed.extend([(row["id"] + " insert", insert), (row["id"] + " screw", screw)])
        check(row["id"] + " insert versus PCB", insert, board)
        check(row["id"] + " screw versus PCB", screw, board)
        check(row["id"] + " screw versus base", screw, base)
        check(row["id"] + " screw versus lid", screw, lid)
        if not is_lid:
            washer = Part.makeCylinder(3.5, .5, V(x, y, screw_seat - .5)).cut(
                Part.makeCylinder(1.6, .7, V(x, y, screw_seat - .6)))
            add_feature(doc, doc.Hardware, "Washer" + str(index), row["id"] + " insulating washer", washer,
                        "7 mm OD x 3.2 mm ID x 0.5 mm", (181, 187, 187))
            installed.append((row["id"] + " washer", washer))
            check(row["id"] + " washer versus populated PCB", washer, board)
    for label, part in installed:
        for name, conductor in wires.items():
            check(label + " versus " + name + " wire", part, conductor, .15)
    for lift in (0, 2, 5, 10, 20, 32):
        loose = Part.makeCompound([panel, *gland_shapes])
        loose.translate(V(0, 0, lift))
        check(f"Unwired plate removal at {lift} mm versus PCB", loose, board, .8)
        check(f"Unwired plate removal at {lift} mm versus base", loose, base, .15)

    doc.recompute()
    native = out / "4Runner_RevI_Terminal_Assembly.FCStd"
    doc.saveAs(str(native))
    Part.makeCompound([o.Shape for group in (doc.Print, doc.PCB, doc.Hardware, doc.Loom) for o in group.Group]).exportStep(
        str(out / "4Runner_RevI_Terminal_Assembly.step"))
    with (out / "wire-cut-routing.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(cut_rows[0]))
        writer.writeheader()
        writer.writerows(cut_rows)
    report = {"contract": "vhos_revi_screw_terminal_gland_interface_H1", "parts": [base_info, lid_info, panel_info],
              "board_dimensions_mm": [133, 65], "populated_board_count": 1, "factory_terminal_count": 6,
              "wires": cut_rows, "checks": checks, "tool_axes": hardware,
              "geometry_provenance": "Native KiCad PCB; retained enclosure plus custom rails/pillar; KEFA drawing-based terminal model; ruthex manufacturer inserts and dimensioned fasteners",
              "installed_inserts": 8, "installed_screws": 8, "installed_insulating_washers": 4,
              "wire_entry_height_mm": 6, "wire_entry_height_status": "estimate, purchased-part measurement pending",
              "wire_bend_model": "Exact tangent circular arcs, >=5 mm centerline radius for 1.6 mm OD screening wire",
              "fanout_selection": fanout_rows,
              "native_terminal_body_bounds_mm": [[s.BoundBox.XMin, s.BoundBox.YMin, s.BoundBox.ZMin,
                                                   s.BoundBox.XMax, s.BoundBox.YMax, s.BoundBox.ZMax] for s in terminal_bodies],
              "physical_pull_torque_vibration_seal_electrical_or_vehicle_verified": False,
              "passed": all(row["pass"] for row in checks)}
    (out / "gland-fit.json").write_text(json.dumps(report, indent=2) + "\n")
    # Tessellate the actual saved solids for the presentation, with no replacement parts.
    mesh_rows = []
    for group in (doc.Print, doc.PCB, doc.Hardware, doc.Loom):
        for obj in group.Group:
            solids = list(obj.Shape.Solids) if obj.Name == "Shield" else [obj.Shape]
            for index, solid in enumerate(solids):
                points, triangles = solid.tessellate(.12)
                b = solid.BoundBox
                color = list(obj.ReferenceColor[:3])
                if obj.Name == "Shield":
                    if b.XLength > 100 and b.ZLength < 2:
                        color = [.025, .24, .16]
                    elif b.ZLength > 13.5 and b.XMin < 40:
                        color = [.06, .42, .25]
                    elif b.XLength > 17 and b.XMax > 140:
                        color = [.56, .59, .62]
                    elif b.ZLength < .4:
                        color = [.6, .45, .20]
                    else:
                        color = [.09, .11, .13]
                mesh_rows.append({"name": obj.Name + str(index), "role": obj.Name, "color": color,
                                  "vertices": [list(v) for v in points], "triangles": triangles})
    with gzip.open(out / "meshes.json.gz", "wt", encoding="utf-8") as stream:
        json.dump(mesh_rows, stream, separators=(",", ":"))
    App.closeDocument(doc.Name)
    App.closeDocument(old.Name)
    reopened = App.openDocument(str(native))
    for name in ("Base", "Lid", "GlandPlate", "Shield", *wires):
        if not reopened.getObject(name).Shape.isValid():
            raise ValueError("Saved assembly invalid: " + name)
    App.closeDocument(reopened.Name)
    if not report["passed"]:
        raise RuntimeError("Native terminal assembly findings in gland-fit.json")


def model(folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    # STEP -Y faces the wire entry; KiCad inverts Y into PCB coordinates.
    # A conservative rectangular body covers the drawing's tapered upper walls.
    V = App.Vector
    body = Part.makeBox(10.16, 10.70, 14.10, V(-2.54, -5.40, 0))
    pins, screws = [], []
    for x in (0, 5.08):
        hole = Part.makeCylinder(1.65, 2, V(x, -5.41, 6), V(0, 1, 0))
        body = body.cut(hole)
        pocket = Part.makeCylinder(1.95, 1.10, V(x, 0, 13.1))
        body = body.cut(pocket)
        screw = Part.makeCylinder(1.72, .7, V(x, 0, 13.15))
        screw = screw.cut(Part.makeBox(.65, 4, .4, V(x - .325, -2, 13.6)))
        screws.append(screw)
        pins.append(Part.makeBox(.9, .8, 4.3, V(x - .45, -.4, -4.3)))
    Part.makeCompound([body, *pins, *screws]).exportStep(str(folder / "KEFA_KF128_5.08_2P.step"))


if __name__ == "__main__":
    raise SystemExit("Use the bounded authenticated terminal job")
