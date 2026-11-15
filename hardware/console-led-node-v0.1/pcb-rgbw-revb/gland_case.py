"""Removable gland plate and wire-mount service volumes for the Rev G PCB."""

from dataclasses import asdict, dataclass
import json
from math import cos, pi, sin

import FreeCAD as App
import Part

import durable_case
from design import FUSE_GEOMETRY
from mechanical_audit import ROOT, box, export_printable, translated
from service_case import add_feature, depth_render, tool_checks

V = App.Vector
X = V(1, 0, 0)
Z = V(0, 0, 1)
EXTENSION = 30
PLATE_X = .6
PLATE_THICKNESS = 5
CONTRACT = "vhos_rgbw_revg_gland_plate_v1"


@dataclass(frozen=True)
class Gland:
    ref: str
    center_y_mm: float
    bore_mm: float
    nominal_thread_mm: float
    thread_length_mm: float
    body_width_mm: float
    exposed_length_mm: float
    nut_width_mm: float
    nut_corner_diameter_mm: float
    jacket_mm: float
    jacket_range_mm: tuple
    gland_mpn: str
    locknut_mpn: str
    plug_mpn: str
    receptacle_mpn: str
    mated_width_reserve_mm: float


GLANDS = (
    Gland("J2", 25, 12.5, 12, 15, 16.6, 22.5, 17, 18.7, 5.5, (3.5, 7),
          "53010000", "53119100", "430200601", "430250600", 16),
    Gland("J1", 52.0, 16.6, 16, 12, 21.1, 28, 22, 24.2, 7.2, (3.5, 8),
          "53017210", "53119110", "430200401", "430250400", 13),
)
CENTER_Z = 22
NUT_THICKNESS = 5


def axial(x, y, z, diameter, length):
    return Part.makeCylinder(diameter / 2, length, V(x, y, z), X)


def hex_envelope(x, y, z, diameter, length):
    return durable_case.profile(
        [V(x, y + diameter / 2 * cos(i * pi / 3), z + diameter / 2 * sin(i * pi / 3))
         for i in range(6)], X * length)


def build(out):
    inputs = ROOT / "inputs"
    spec = json.loads((inputs / "mechanical-observation.json").read_text())
    base_source = App.openDocument(str(inputs / "4Runner_RevG_Assembly.FCStd"))
    board = translated(base_source.Shield.Shape, EXTENSION, 0, 0)
    fuses = {ref: translated(base_source.getObject(ref).Shape, EXTENSION, 0, 0) for ref in ("F1", "F2")}
    dims = spec["dimensions"]
    g = {**dims, "width_mm": dims["width_mm"] + EXTENSION,
         "pcb_origin_xy_mm": [dims["pcb_origin_xy_mm"][0] + EXTENSION, dims["pcb_origin_xy_mm"][1]]}
    lid_axes = [(x + (EXTENSION if x > dims["width_mm"] / 2 else 0), y) for x, y in spec["lid_mounts_xy_mm"]]
    # Move the right front insert away from the upper rail cut.
    lid_axes[1] = (10.7, lid_axes[1][1])
    pcb_axes = [(x + EXTENSION, y) for x, y in spec["pcb_mounts_xy_mm"]]
    h = g["body_height_mm"]

    # A broad front reinforcement transfers pull into both vertical guides and the floor.
    # The open roof lets the preassembled plate drop in from the top.
    shell = durable_case.base_shell(g, lid_axes, pcb_axes, [], [])
    front_boss = durable_case.cylinder(*lid_axes[1], 0, 8.8, h)
    shell = shell.fuse([box(2.9, 10.9, 0, 4.9, 59.6, h), front_boss]).removeSplitter()
    pass_through = box(-1, 14.2, 7.5, 9.1, 52.6, h - 7.4)
    rail_slot = box(.35, 11.5, 5, 5.5, 58.5, h - 4.9)
    front_pilots = [durable_case.insert_pilot(x, y, h, g["insert_pilot_mm"], g["insert_depth_mm"])
                    for x, y in lid_axes[:2]]
    shell = shell.cut([pass_through, rail_slot, *front_pilots]).removeSplitter()
    lid_blank = durable_case.lid_shell(g, lid_axes, [])
    plate = box(PLATE_X, 11.8, 5.2, PLATE_THICKNESS, 57.9, h - 5.45)
    for gland in GLANDS:
        plate = plate.cut(axial(PLATE_X - .1, gland.center_y_mm, CENTER_Z, gland.bore_mm, PLATE_THICKNESS + .2))

    base, base_info = export_printable(shell, "case_base", out)
    lid_raw, lid_info = export_printable(lid_blank, "case_lid", out, flip=True)
    lid = translated(lid_raw, 0, 0, h)
    # Flat down on the 5 mm face: both round bores are vertical in the slicer.
    plate.rotate(V(), V(0, 1, 0), -90)
    panel, plate_info = export_printable(plate, "gland_plate", out)
    panel.rotate(V(), V(0, 1, 0), 90)

    checks = []

    def clear(name, part, obstacle, minimum=0):
        distance = part.distToShape(obstacle)[0] if minimum else None
        overlap = part.common(obstacle).Volume if part.BoundBox.intersect(obstacle.BoundBox) else 0
        checks.append({"check": name, "overlap_mm3": round(overlap, 5),
                       "clearance_mm": round(distance, 3) if distance is not None else None,
                       "minimum_mm": minimum, "pass": overlap < .012 and (distance is None or distance >= minimum - .001)})

    clear("Plate and shell seated", panel, base, .18)
    clear("Closed lid retains plate with assembly allowance", panel, lid, .24)
    clear("Populated PCB against base", board, base)
    clear("Populated PCB against closed lid", board, lid, .5)
    clear("Lid against shell", lid, base)
    pullers = []
    for ref, fuse in fuses.items():
        b = fuse.BoundBox
        w, d, travel = (FUSE_GEOMETRY[key] for key in ("puller_width_mm", "puller_depth_mm", "puller_travel_mm"))
        puller = box(b.Center.x - w / 2, b.Center.y - d / 2, b.ZMin + .4, w, d, b.ZLength + travel)
        pullers.append(puller)
        clear(ref + " puller against new front walls", puller, base)
        clear(ref + " pulls clear of plate", puller, panel, 1)

    fits, visuals = {}, []
    assemblies, handles, tool_sweeps, disconnects, releases = [], [], [], [], []
    inner_face = PLATE_X + PLATE_THICKNESS
    for gland in GLANDS:
        y, z = gland.center_y_mm, CENTER_Z
        shank = axial(PLATE_X, y, z, gland.nominal_thread_mm, gland.thread_length_mm)
        body = hex_envelope(PLATE_X - gland.exposed_length_mm, y, z, gland.body_width_mm, gland.exposed_length_mm)
        nut_gauge = axial(inner_face, y, z, gland.nut_corner_diameter_mm, NUT_THICKNESS)
        nut = hex_envelope(inner_face, y, z, gland.nut_corner_diameter_mm, NUT_THICKNESS)
        jacket = axial(PLATE_X - gland.exposed_length_mm - 10, y, z, gland.jacket_mm,
                       gland.exposed_length_mm + 25)
        backing = axial(inner_face - .01, y, z, gland.nut_corner_diameter_mm, .01).cut(
            axial(inner_face - .02, y, z, gland.bore_mm, .03))
        backed = panel.common(backing).Volume
        clearance = (gland.bore_mm - gland.nominal_thread_mm) / 2
        capture = gland.thread_length_mm - PLATE_THICKNESS - NUT_THICKNESS
        fits[gland.ref] = {**asdict(gland), "plate_radial_allowance_mm": clearance,
                           "thread_beyond_nut_mm": capture}
        checks.append({"check": gland.ref + " full annular nut bearing and usable thread",
                       "pass": backed > .99 * backing.Volume and capture >= 1.5
                       and gland.jacket_range_mm[0] <= gland.jacket_mm <= gland.jacket_range_mm[1]})
        clear(gland.ref + " shank in exported bore", shank, panel, .24)
        clear(gland.ref + " locknut without clocking dependency", nut_gauge, base, .8)
        clear(gland.ref + " gland and locknut against populated PCB", Part.makeCompound([shank, nut_gauge]), board, 1)
        clear(gland.ref + " gland and locknut against lid", Part.makeCompound([body, nut_gauge]), lid, 1)
        clear(gland.ref + " jacket to connector entry", jacket, base)
        hardware = (shank, body, nut_gauge)
        assemblies.extend(hardware)
        handles.append(Part.makeCompound(list(hardware)))
        # With the plate outside the case, only the neighboring gland limits socket access.
        tool_sweeps.append(axial(inner_face + .02, y, z, gland.nut_corner_diameter_mm + 5, 15))

        # Lift the mated crimp pair on its service loop. Separate above the rim.
        width, length = gland.mated_width_reserve_mm, 29
        parking_y = 22.0 if gland.ref == "J2" else 54.0
        connector = box(15.95, parking_y - length / 2, 13, width, length, 12)
        release = box(15.85, parking_y - length / 2 - .35, 13, width + .20, length + .70, h + 3)
        clear(gland.ref + " wire-mount socket against PCB", connector, board, .65)
        clear(gland.ref + " wire-mount socket and closed lid", connector, lid, .5)
        for obstacle, label in ((base, "case"), (board, "PCB"), (panel, "plate"),
                                *((p, "fuse puller") for p in pullers)):
            clear(gland.ref + " release access against " + label, release, obstacle)
        clear(gland.ref + " lift path clears gland shank", release, shank, .2)
        disconnects.append(connector)
        releases.append(release)
        visuals.extend(((gland.ref + "Body", body, (52, 57, 61)), (gland.ref + "Nut", nut, (69, 75, 78)),
                        (gland.ref + "Jacket", jacket, (34, 111, 107) if gland.ref == "J2" else (88, 92, 95)),
                        (gland.ref + "Disconnect", connector, (27, 41, 47))))

    clear("Gland pair at rest", handles[0], handles[1], 1.5)
    clear("M12 tool clears M16 nut on loose plate", tool_sweeps[0], handles[1], 1.0)
    clear("M16 tool clears M12 nut on loose plate", tool_sweeps[1], handles[0], 1.0)
    clear("J1 release clears mated J2 body", releases[1], disconnects[0], 1)
    clear("J2 release clears mated J1 body", releases[0], disconnects[1], 1)
    # Vertical rails have constant cross-section up to the roof. Check final seating
    # and stepped hardware clearance across the full insertion/removal stroke.
    slide = Part.makeCompound([panel, *assemblies])
    for lift in (0, 2, 5, 10, 20, 32):
        pose = translated(slide, 0, 0, lift)
        clear(f"Plate withdrawal at {lift} mm against base", pose, base, .15)
        clear(f"Plate withdrawal at {lift} mm against PCB", pose, board, 1)
    tool_rows, _ = tool_checks(g, base, lid, board, Part.Shape(), lid_axes, pcb_axes, [], fuses)

    doc = App.newDocument("RevG_GlandCase")
    for group in ("Print", "PCB", "Hardware", "WireMount"):
        doc.addObject("App::DocumentObjectGroup", group)
    add_feature(doc, doc.Print, "Base", "Extended enclosure base", base, "Reopened STEP", (79, 97, 109))
    add_feature(doc, doc.Print, "Lid", "Removable lid", lid, "Reopened STEP", (133, 150, 158))
    add_feature(doc, doc.Print, "GlandPlate", "Drop-in gland plate", panel, "Reopened STEP", (111, 149, 143))
    add_feature(doc, doc.PCB, "Shield", "Populated Rev G control board", board, "Pinned Rev G native assembly", (46, 107, 87))
    for ref, fuse in fuses.items():
        add_feature(doc, doc.Hardware, ref, "MINI fuse " + ref, fuse, "Pinned Rev G native assembly", (123, 78, 127))
    for name, shape, color in visuals:
        add_feature(doc, doc.WireMount, name, name, shape, "Dimensioned service envelope", color)
    doc.recompute()
    native = out / "4Runner_RevG_Gland_Assembly.FCStd"
    doc.saveAs(str(native))
    Part.makeCompound([base, lid, panel, board, *fuses.values(), *(shape for _, shape, _ in visuals)]).exportStep(
        str(out / "4Runner_RevG_Gland_Assembly.step"))
    App.closeDocument(doc.Name)
    App.closeDocument(base_source.Name)
    doc = App.openDocument(str(native))
    for name in ("Base", "Lid", "GlandPlate", "Shield", "J1Disconnect", "J2Disconnect"):
        checks.append({"check": name + " retained in reopened assembly", "pass": doc.getObject(name).Shape.isValid()})
    report = {"contract": CONTRACT, "parts": [base_info, lid_info, plate_info], "glands": fits,
              "gland_center_spacing_mm": GLANDS[1].center_y_mm - GLANDS[0].center_y_mm,
              "front_extension_mm": EXTENSION,
              "slide_side_clearance_mm": .30, "slide_axial_clearance_mm": .25,
              "plate_thickness_mm": PLATE_THICKNESS,
              "connector_envelopes": {"mated_length_mm": 29, "latch_up": True, "release_above_rim": True, "min_free_service_loop_mm": 45},
              "checks": checks, "tool_axes": tool_rows,
              "physical_pull_seal_or_vehicle_fit_verified": False,
              "passed": all(row["pass"] for row in checks) and all(row["pass"] for row in tool_rows)}
    (out / "gland-fit.json").write_text(json.dumps(report, indent=2) + "\n")
    preview(out, doc)
    App.closeDocument(doc.Name)
    if not report["passed"]:
        raise RuntimeError("Gland or service interference in gland-fit.json")


def preview(out, doc):
    from PySide2 import QtGui, QtWidgets

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    camera = V(-1.15, -1.12, 2)
    camera.normalize()
    right = Z.cross(camera)
    right.normalize()
    up = camera.cross(right)
    triangles = []
    items = [obj for group in (doc.Print, doc.PCB, doc.Hardware, doc.WireMount) for obj in group.Group if obj.Name != "Lid"]
    for obj in items:
        nodes, faces = obj.Shape.tessellate(.28)
        color = tuple(round(ch * 255) for ch in obj.ReferenceColor[:3])
        for face in faces:
            a, b, c = [nodes[i] for i in face]
            normal = (b - a).cross(c - a)
            if normal.Length <= 1e-8 or normal.dot(camera) <= 0:
                continue
            normal.normalize()
            shade = .62 + .38 * max(0, normal.dot(V(-.38, -.5, .76)))
            pts = (a, b, c)
            triangles.append((tuple(p.dot(camera) for p in pts),
                              [(p.dot(right), -p.dot(up)) for p in pts], tuple(round(ch * shade) for ch in color)))
    xs = [x for _, points, _ in triangles for x, _ in points]
    ys = [y for _, points, _ in triangles for _, y in points]
    scale = min(1350 / (max(xs) - min(xs)), 730 / (max(ys) - min(ys)))
    canvas = depth_render(triangles, scale, (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, QtGui)
    painter = QtGui.QPainter(canvas)
    painter.setPen(QtGui.QColor("#112a35"))
    painter.setFont(QtGui.QFont("Segoe UI", 30, QtGui.QFont.Bold))
    painter.drawText(64, 82, "Rev G gland plate and wire disconnects")
    painter.setFont(QtGui.QFont("Segoe UI", 15))
    painter.drawText(64, 978, "M12 RGBW lead  ·  M16 Toyota lead  ·  Micro-Fit connector clearance envelopes")
    painter.end()
    if not canvas.save(str(out / "RevG-gland-service.png")):
        raise RuntimeError("Could not save the gland preview")
