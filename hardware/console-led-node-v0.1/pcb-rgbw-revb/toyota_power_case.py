"""Captive Toyota power and RGBW leads with enclosure-mounted strain relief."""

import json

import FreeCAD as App
import Part

import durable_case
from mechanical_audit import ROOT, box, cylinder, reopen, translated
from service_case import interference
from toyota_power import SPEC


V = App.Vector
CASE = SPEC["case"]
TOL = .015


def openings(g, port_data):
    width, height = CASE["loose_passage_mm"]
    _, origin_y = g["pcb_origin_xy_mm"]
    return [
        {"ref": ref, "purpose": label, "center_y_mm": round(
            origin_y + port_data[ref]["xy"][1] + sum(port_data[ref]["header_extent_mm"]["y_from_pad"]) / 2, 3),
         "width_mm": width, "floor_z_mm": g["body_height_mm"] - height, "top_open_to_lid": True}
        for ref, label in (("J1", "Toyota power lead"), ("J2", "RGBW lead"))
    ]


def jacket(y, diameter, x_start, x_end):
    center = CASE["lead_seat_z_mm"] + diameter / 2
    return Part.makeCylinder(diameter / 2, x_end - x_start, V(x_start, y, center), V(1, 0, 0))


def tie_slot(x, y, width):
    half = CASE["tie_slot_width_mm"] / 2
    bottom = CASE["tie_slot_floor_z_mm"]
    eave = CASE["tie_slot_eave_z_mm"]
    section = [V(x - half, y, bottom), V(x + half, y, bottom), V(x + half, y, eave),
               V(x, y, eave + half), V(x - half, y, eave)]
    return durable_case.profile(section, V(0, width, 0))


def enclosure_parts(base, g, lid_axes, leads):
    half = CASE["saddle_half_width_mm"]
    seat = CASE["lead_seat_z_mm"]
    end = CASE["saddle_end_x_mm"]
    face = g["wall_mm"] - g["front_wall_mm"] - CASE["front_doubler_mm"]
    h = g["body_height_mm"]

    # Build the front reinforcement from the wall on a 42-degree ramp,
    # above the front mounting ear and its washer.
    base = base.fuse(durable_case.profile(
        [V(-.30, 15, 10.5), V(face, 15, 13.5), V(face, 15, h), V(-.30, 15, h)],
        V(0, 51, 0))).removeSplitter()
    for port in leads:
        y = port["center_y_mm"]
        low = y - half
        root = g["wall_mm"] - .25
        support = durable_case.profile(
            [V(root, low, 24.85), V(end, low, 33.25),
             V(end, low, seat), V(root, low, seat)], V(0, 2 * half, 0))
        # Taper the outer corner of the power saddle away from the nearest iron axis.
        if port["ref"] == "J1":
            side_cut = [V(end - 3.2, y + half + .1, 24), V(end + .1, y + half + .1, 24),
                        V(end + .1, y + half - 1.8, 24)]
            support = support.cut(durable_case.profile(side_cut, V(0, 0, 14)))
        base = base.fuse(support).removeSplitter()
        for x in CASE["tie_slot_centers_x_mm"]:
            base = base.cut(tie_slot(x, low - .1, 2 * half + .2))
        base = base.cut(durable_case.port_cut(g, y, port["width_mm"] / 2, port["floor_z_mm"]))
        # The lid closes the top of each opening after the loom is dropped in.
    lid = durable_case.lid_shell(g, lid_axes, [])
    return base.removeSplitter(), lid.cut(durable_case.label_engraving(g, leads)).removeSplitter()


def audit(out, g, base, raw_lid, lid, shield, lower, fuses, leads, axes, results):
    def record(name, volume, maximum=TOL):
        rows.append({"check": name, "interference_mm3": round(volume, 6), "pass": volume <= maximum})

    rows = []
    h = g["body_height_mm"]
    face = g["wall_mm"] - g["front_wall_mm"] - CASE["front_doubler_mm"]
    seat = CASE["lead_seat_z_mm"]
    half = CASE["saddle_half_width_mm"]
    end = CASE["saddle_end_x_mm"]
    max_od = CASE["lead_max_screen_od_mm"]
    for port in leads:
        ref, y = port["ref"], port["center_y_mm"]
        for offset in (-CASE["lateral_allowance_mm"], CASE["lateral_allowance_mm"]):
            gauge = jacket(y + offset, max_od, face - 1, end + 1)
            record(f"{ref}_8mm_sleeve_offset_{offset:g}", sum(interference(s, gauge) for s in (base, lid, shield)))
        # Continuous drop-in envelope above the jacket's full cylinder, with the lid off.
        drop = box(face - .2, y - max_od / 2, seat + max_od / 2, end - face + .3, max_od, h - seat + 1)
        record(f"{ref}_vertical_cable_loading", interference(base, drop))
        anchor = box(2.84, y - half + .5, 28.1, .36, 2 * half - 1, 4.6)
        record(f"{ref}_continuous_wall_anchor", abs(anchor.Volume - interference(base, anchor)))
        for index, x in enumerate(CASE["tie_slot_centers_x_mm"], 1):
            strap = CASE["tie_strap_width_mm"]
            thickness = CASE["tie_strap_thickness_screen_mm"]
            passage = box(x - strap / 2, y - half - 2, CASE["tie_slot_floor_z_mm"] + .04,
                          strap, 2 * half + 4, thickness)
            record(f"{ref}_tie_{index}_strap_through", interference(base, passage))
            roof_half = half - (1.1 if ref == "J1" and index == 2 else .4)
            roof = box(x - 1, y - roof_half, seat - .74, 2, 2 * roof_half, .70)
            record(f"{ref}_tie_{index}_roof_continuity", abs(roof.Volume - interference(base, roof)))
        head_bays = (y - half - 5.8, y + half + .4)
        for index, (x, head_y) in enumerate(zip(CASE["tie_slot_centers_x_mm"], head_bays), 1):
            head = box(x - 1.9, head_y, 36.7, 4.9, 5.2, 5.2)
            record(f"{ref}_tie_{index}_head_service", sum(interference(s, head) for s in (base, shield, lid)))
        web = box(face + .05, y - 2, 17, g["wall_mm"] - face - .1, 4, 9)
        record(f"{ref}_reinforced_exit_wall", abs(web.Volume - interference(base, web)))
    for i, (x, y) in enumerate(axes, 1):
        gauge = cylinder(x, y, h, g["lid_screw_clearance_diameter_mm"] - .04, g["lid_mm"])
        record(f"lid_screw_{i}_clearance", interference(lid, gauge))
    jackets = [jacket(row["center_y_mm"], max_od, face - 1, end + 1) for row in leads]
    for lift in (.4, 1.4, 4, 12, 18):
        moved = translated(lid, 0, 0, lift)
        record(f"lid_at_{lift:g}_mm_lift",
               sum(interference(shape, moved) for shape in (base, shield, lower, *fuses.values(), *jackets)))
    payload = {"contract": SPEC["definition"], "case": CASE, "checks": rows,
               "physical_harness_fit_verified": False, "tie_pull_or_vibration_verified": False}
    (out / "toyota-leads-fit.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    results.extend(rows)
    return durable_case.fit_coupons(out, g, base, raw_lid, front_x_max=12.6, front_span=(14.8, 51.4))


def loom(leads):
    """Straight jacket reserves and the manufacturer housing, for assembly previews."""
    parts = []
    for port in leads:
        ref, y = port["ref"], port["center_y_mm"]
        diameter = CASE["lead_nominal_od_mm"][ref]
        start = -CASE["cable_display_length_mm"]
        color = (63, 73, 87) if ref == "J1" else (49, 119, 114)
        cable = jacket(y, diameter, start, CASE["saddle_end_x_mm"] + 1.0)
        parts.append(("Lead" + ref[-1], port["purpose"], cable,
                      "Nominal jacket envelope. Check actual wire and sleeve.", color))
        for i, x in enumerate(CASE["tie_slot_centers_x_mm"], 1):
            strap = CASE["tie_strap_width_mm"]
            root_z = CASE["tie_slot_floor_z_mm"] + .04
            crown = CASE["lead_seat_z_mm"] + diameter
            side = CASE["saddle_half_width_mm"] + .25
            thickness = .65
            outer = [V(x - strap / 2, yy, z) for yy, z in (
                (y - side, root_z), (y + side, root_z), (y + side, crown - .7),
                (y + 1.4, crown + .3), (y - 1.4, crown + .3), (y - side, crown - .7))]
            inner = [V(x - strap / 2 - .1, yy, z) for yy, z in (
                (y - side + thickness, root_z + thickness), (y + side - thickness, root_z + thickness),
                (y + side - thickness, crown - 1.2), (y + 1.4, crown + .3 - thickness),
                (y - 1.4, crown + .3 - thickness), (y - side + thickness, crown - 1.2))]
            tie = durable_case.profile(outer, V(strap, 0, 0)).cut(
                durable_case.profile(inner, V(strap + .2, 0, 0))).removeSplitter()
            parts.append((f"{ref}Relief{i}", f"{port['purpose']} tie {i}", tie,
                          "Illustrative strap around the nominal sleeve and the printed saddle.", (45, 49, 56)))
        if ref == "J1":
            connector = reopen(ROOT / "inputs" / "Yazaki_7282-1060.stp")
            # Long axis of the native catalog model is Z. The contact opening
            # faces away from the box along -X in the installation illustration.
            connector.rotate(V(), V(0, 1, 0), 90)
            b = connector.BoundBox
            connector.translate(V(start - b.XMax + .1, y - (b.YMin + b.YMax) / 2,
                                  CASE["lead_seat_z_mm"] + diameter / 2 - (b.ZMin + b.ZMax) / 2))
            parts.append(("ToyotaMate", "Yazaki 7282-1060 candidate pin housing", connector,
                          "Yazaki manufacturer STEP. Cable orientation and vehicle fit require a dry-fit.",
                          (229, 222, 193)))
    return parts
