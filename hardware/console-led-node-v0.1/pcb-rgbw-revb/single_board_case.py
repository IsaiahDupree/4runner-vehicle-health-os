"""One-board case and service checks against exported PCB hardware."""

import json

import FreeCAD as App
import Part

import durable_case
import illumination_cad
import single_board as rev_e
import stock_board as rev_f
import toyota_power_case
from design import FUSE_GEOMETRY, FUSES, PORTS
from mechanical_audit import ROOT, box, cylinder, export_printable, reopen, rounded, translated
from service_case import HARDWARE, add_feature, socket_screw, tool_checks


V = App.Vector


def build(out, *, revision="E"):
    is_f = revision == "F"
    contract = rev_f.CONTRACT if is_f else rev_e.CONTRACT
    g = durable_case.dimensions(rev_e.CASE_DIMS)
    lid_skin = g["lid_mm"]
    if is_f:
        g["floor_mm"] = rev_f.CASE_FLOOR_MM
        lid_skin -= rev_f.LID_RECESS_DEPTH_MM
    width, depth, height = (g[key] for key in ("width_mm", "depth_mm", "body_height_mm"))
    board_z = g["esp_pcb_bottom_mm"]
    board_top = board_z + g["pcb_thickness_mm"]
    offset = g["lid_insert_pitch_offset_mm"]
    ox, oy = g["pcb_origin_xy_mm"]
    lid_axes = [(x, y) for x in (offset, width - offset) for y in (offset, depth - offset)]
    axes = [(ox + x, oy + y) for x, y in map(rev_e.board_xy, rev_e.MOUNTS.values())]
    case = toyota_power_case.CASE | {key: toyota_power_case.CASE[key] - 10 for key in
                                    ("lead_seat_z_mm", "tie_slot_floor_z_mm", "tie_slot_eave_z_mm")}
    shell = durable_case.base_shell(g, lid_axes, axes, [], [])
    ports = toyota_power_case.openings(g, PORTS)
    shell, lid = toyota_power_case.enclosure_parts(shell, g, lid_axes, ports, case=case)
    if is_f:
        recesses = [rounded(x, y, -.05, w, d, rev_f.LID_RECESS_DEPTH_MM + .05, 3.5)
                    for x, y, w, d in rev_f.LID_RECESSES]
        lid = lid.cut(recesses).removeSplitter()
    base, base_report = export_printable(shell, "case_base", out)
    raw_lid, lid_report = export_printable(lid, "case_lid", out, flip=True)
    lid = translated(raw_lid, 0, 0, height)

    native = reopen(out / "routed_shield.step")
    board_width = rev_e.BOARD_EDGE_X - 47
    datums = [solid.BoundBox for solid in native.Solids if abs(solid.BoundBox.XLength - board_width) < .12
              and abs(solid.BoundBox.YLength - 53.34) < .12 and abs(solid.BoundBox.ZLength - 1.6) < .12]
    if len(datums) != 1 or abs(datums[0].XMin + 53) > .1 or abs(datums[0].YMin) > .1:
        raise RuntimeError(f"Could not find the Rev {revision} board datum in the reopened STEP")
    board = translated(native, ox, oy, board_top - datums[0].ZMax)
    if is_f:
        for part, bounds in rev_f.PACKAGE_ENVELOPES.items():
            if not any(all(abs(a - b) <= .025 for a, b in zip(
                    (solid.BoundBox.XLength, solid.BoundBox.YLength, solid.BoundBox.ZLength), bounds))
                    for solid in board.Solids):
                raise RuntimeError(f"Missing Rev F package envelope {part} in PCB STEP")
    modules = [solid for solid in board.Solids if solid.BoundBox.XMax > ox + rev_e.BOARD_EDGE_X - 99]
    if not modules or max(solid.BoundBox.XMax for solid in modules) > width - g["wall_mm"] - 14:
        raise RuntimeError("ESP32-S3 model missing, misplaced or too close to the rear")

    fuses, pullers = {}, {}
    for ref, spec in FUSES.items():
        x, y = (coord + origin for coord, origin in zip(spec["xy"], (ox, oy)))
        holder_top = board_top + FUSE_GEOMETRY["holder_z_mm"]
        installed_height = FUSE_GEOMETRY["installed_height_reserve_mm"] - FUSE_GEOMETRY["holder_z_mm"]
        fuses[ref] = rounded(x - 5.5, y - 1.9, holder_top, 11, 3.8, installed_height, .55)
        w, d, travel = (FUSE_GEOMETRY[key] for key in ("puller_width_mm", "puller_depth_mm", "puller_travel_mm"))
        pullers[ref] = box(x - w / 2, y - d / 2, holder_top + .4, w, d, installed_height + travel)

    checks = []
    skin_checks = {}
    if is_f:
        for i, (x, y, w, d) in enumerate(rev_f.LID_RECESSES, 1):
            # Verify the 2.3 mm panel and the open recess in the reopened solid.
            gauge = box(x + 4, y + 4, rev_f.LID_RECESS_DEPTH_MM, w - 8, d - 8, lid_skin)
            cut = box(x + 4, y + 4, 0, w - 8, d - 8, rev_f.LID_RECESS_DEPTH_MM)
            skin_checks[f"lid_recess_{i}"] = abs(raw_lid.common(gauge).Volume - gauge.Volume) < .01 and (
                raw_lid.common(cut).Volume < .01)
        for i, (x, y) in enumerate(axes, 1):
            gauge = cylinder(x, y, 0, 7.0, g["floor_mm"])
            skin_checks[f"pcb_mount_floor_{i}"] = abs(base.common(gauge).Volume - gauge.Volume) < .01
        if not all(skin_checks.values()):
            raise ValueError(f"Rev F case material checks failed: {skin_checks}")

    def record(name, a, b, *, clearance=0):
        overlap = a.common(b).Volume if a.BoundBox.intersect(b.BoundBox) else 0.0
        distance = a.distToShape(b)[0] if clearance else None
        checks.append({"check": name, "interference_mm3": round(overlap, 6),
                       "min_clearance_mm": clearance, "clearance_mm": round(distance, 4) if clearance else None,
                       "pass": overlap <= .015 and (distance is None or distance + .0001 >= clearance)})

    for label, shape in (("populated PCB", board), *fuses.items()):
        record(label + " against base", shape, base)
        record(label + " against closed lid", shape, lid, clearance=.55)
    record("lid seats on base", lid, base)
    for ref, puller in pullers.items():
        record(ref + " puller with lid removed against case", puller, base)
        record(ref + " puller with lid removed against populated PCB", puller, board)
        record(ref + " puller against neighboring fuse", puller, fuses["F2" if ref == "F1" else "F1"])
    for step in (.4, 4, 12):
        raised = translated(lid, 0, 0, step)
        record(f"Populated PCB at {step:g} mm lid lift", board, raised)
    # Vertical probe envelopes from the actual test pad positions. The
    # opening is deliberate inside the screw lid and keeps the cable count at two.
    for ref, (name, site) in rev_e.PROGRAM_PADS.items():
        local_x, local_y = rev_e.board_xy(site)
        gauge = cylinder(ox + local_x, oy + local_y, board_top + .18, 2.0, height + 4 - board_top)
        record(f"Open-lid probe {ref} {name} against case", gauge, base)
        record(f"Open-lid probe {ref} {name} against PCB parts", gauge, board)
    for offset_y in (-case["lateral_allowance_mm"], case["lateral_allowance_mm"]):
        y = next(row["center_y_mm"] for row in ports if row["ref"] == "J2") + offset_y
        radius = case["lead_max_screen_od_mm"] / 2
        gauge = Part.makeCylinder(radius, case["saddle_end_x_mm"] + 6,
                                  V(-5, y, case["lead_seat_z_mm"] + radius), V(1, 0, 0))
        for label, shape in (("base", base), ("lid", lid), ("PCB", board)):
            record(f"J2 sleeve offset {offset_y:+g} against {label}", gauge, shape)
    hardware_rows, _ = tool_checks(g, base, lid, board, Part.Shape(), lid_axes, axes, [], fuses)
    tool_report = {"contract": contract, "axes": hardware_rows,
                   "cavity_checks_passed": len(hardware_rows) == 8 and all(row["pass"] for row in hardware_rows),
                   "physical_tools_and_fit_verified": False}
    (out / "tool-access.json").write_text(json.dumps(tool_report, indent=2) + "\n")

    coupons = durable_case.fit_coupons(out, g, base, raw_lid, front_x_max=12.6, front_span=(14.8, 51.4))
    report = {"contract": contract, "dimensions": g, "port_windows": ports, "pcb_mounts_xy_mm": axes,
              "lid_mounts_xy_mm": lid_axes, "checks": checks, "printable": [base_report, lid_report, *coupons],
              "passed_nominal_interference": all(row["pass"] for row in checks), "populated_board_count": 1,
              "module_geometry": "KiCad module STEP matched to the native footprint origin and Espressif package drawing",
              "physical_fit_and_rf_verified": False}
    if is_f:
        report["case_material"] = {"floor_mm": g["floor_mm"], "lid_recess_skin_mm": lid_skin,
                                   "lid_rim_mm": g["lid_mm"], "reopened_solid_checks": skin_checks,
                                   "dimensioned_package_envelopes_mm": rev_f.PACKAGE_ENVELOPES}
    (out / "mechanical-observation.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["passed_nominal_interference"] or not tool_report["cavity_checks_passed"]:
        raise RuntimeError(f"Rev {revision} case or tool access findings in mechanical-observation.json and tool-access.json")

    doc = App.newDocument(f"FourRunnerRGBW_Rev{revision}")
    for name, label in (("Print", "Printable case"), ("PCB", "One populated PCB"),
                        ("Hardware", "Inserts, screws and fuses"), ("Loom", "Captive vehicle and RGBW cables")):
        doc.addObject("App::DocumentObjectGroup", name).Label = label
    add_feature(doc, doc.Print, "Base", "Printed base", base, "Reopened printable STEP", (85, 105, 118))
    add_feature(doc, doc.Print, "Lid", "Screw lid", lid, "Reopened printable STEP", (105, 121, 136))
    add_feature(doc, doc.PCB, "Shield", f"Rev {revision} single-board controller", board, "Reopened KiCad STEP", (43, 104, 86))
    for ref, solid in fuses.items():
        add_feature(doc, doc.Hardware, ref, f"{ref} · {FUSES[ref]['amps']} A MINI fuse", solid,
                    "Installed fuse height envelope", (132, 80, 152) if ref == "F1" else (85, 88, 99))
    insert = reopen(ROOT / "inputs" / "ruthex_RX-M3x5_7.stp")
    for i, entry in enumerate(hardware_rows, 1):
        x, y, seat = entry["position_mm"]
        is_lid = entry["id"].startswith("lid_")
        length = HARDWARE["lid_screw_length_mm" if is_lid else "board_screw_length_mm"]
        screw_top = height + g["lid_mm"] if is_lid else board_top + HARDWARE["washer_thickness_mm"]
        add_feature(doc, doc.Hardware, f"Insert{i}", "RX-M3x5.7 insert", translated(insert, x, y, seat),
                    "Ruthex manufacturer STEP", (213, 157, 73))
        add_feature(doc, doc.Hardware, f"Screw{i}", f"M3 × {length:g} screw", socket_screw(x, y, screw_top, length),
                    "Nominal fastener envelope", (162, 176, 183))
        if not is_lid:
            washer = cylinder(x, y, board_top, 7, .5).cut(cylinder(x, y, board_top - .05, 3.2, .6))
            add_feature(doc, doc.Hardware, f"Washer{i}", "Insulating washer", washer, "7 mm OD × 0.5 mm", (219, 226, 226))
    for name, label, shape, source, color in toyota_power_case.loom(ports, case=case):
        add_feature(doc, doc.Loom, name, label, shape, source, color)
    illumination_cad.build(out, doc=doc, revision=revision, case=case, contract=contract)
