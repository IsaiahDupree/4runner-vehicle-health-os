"""Support-free print geometry for the existing two-connector Rev B shield."""

import json
from math import hypot
from pathlib import Path

import FreeCAD as App
import Part

from design import PORTS
from mechanical_audit import box, cylinder, export_printable, reopen, rounded, translated
from service_case import GLYPHS, interference


ROOT = Path(__file__).resolve().parent
SPEC = json.loads((ROOT / "durable-case.json").read_text(encoding="utf-8"))
FIT = SPEC["fit"]
V = App.Vector


def dimensions(base):
    return {**base, **SPEC["dimensions"]}


def profile(points, vector):
    return Part.Face(Part.makePolygon(points + points[:1])).extrude(vector)


def ramp(x0, x1, y, width, low_z, high_z):
    """An X-facing ramp rising into its supported side."""
    return profile([V(x0, y, low_z), V(x1, y, low_z), V(x1, y, high_z)], V(0, width, 0))


def floor_gusset(x, y, angle, z, length, tip_height):
    points = [V(-.8, -1.6, z - .15), V(length, -1.6, z - .15),
              V(length, -1.6, z + .4), V(1.5, -1.6, z + tip_height),
              V(-.8, -1.6, z + tip_height)]
    gusset = profile(points, V(0, 3.2, 0))
    gusset.rotate(V(), V(0, 0, 1), angle)
    gusset.translate(V(x, y, 0))
    return gusset


def insert_pilot(x, y, seat, diameter, depth):
    radius = diameter / 2
    bore = cylinder(x, y, seat - depth, diameter, depth + .15)
    lead = Part.makeCone(radius, radius + .45, .65, V(x, y, seat - .5))
    return bore.fuse(lead)


def slot(x, y, length, width, height):
    half = (length - width) / 2
    return box(x - half, y - width / 2, -.1, 2 * half, width, height + .2).fuse(
        [cylinder(x + offset, y, -.1, width, height + .2) for offset in (-half, half)])


def base_shell(g, lid_axes, upper_axes, lower_axes, lower_fasteners):
    width, depth, height = (g[key] for key in ("width_mm", "depth_mm", "body_height_mm"))
    wall, floor, corner = (g[key] for key in ("wall_mm", "floor_mm", "outer_corner_mm"))
    lower_z = g["esp_pcb_bottom_mm"]
    shield_z = lower_z + g["stack_pitch_mm"]
    base = rounded(0, 0, 0, width, depth, height, corner).cut(
        rounded(wall, wall, floor, width - 2 * wall, depth - 2 * wall, height, corner - wall))
    # Extend the front wall outward. The shield's front edge is at X=3 mm.
    extension = g["front_wall_mm"] - wall
    additions = [box(-extension, 8, 0, extension + .2, depth - 16, height)]
    # Corner blocks remain vertical and wide where the heat-set inserts sit.
    for x, y in lid_axes:
        px = wall - .25 if x < width / 2 else width - 10.45
        py = wall - .25 if y < depth / 2 else depth - 10.45
        additions.append(box(px, py, floor - .15, 7.7, 7.7, height - floor + .15))
    for axes, top, diameter, length, rib_height in (
        (upper_axes, shield_z, g["shield_boss_diameter_mm"], 12.0, 11.0),
        (lower_axes, lower_z, g["lower_boss_diameter_mm"], 7.0, 3.0),
    ):
        for x, y in axes:
            additions.append(cylinder(x, y, floor - .15, diameter, top - floor + .15))
            additions.extend(floor_gusset(x, y, angle, floor, length, rib_height)
                             for angle in (0, 90, 180, 270)
                             if 0 < x + length * (1 if angle == 0 else -1 if angle == 180 else 0) < width
                             and 0 < y + length * (1 if angle == 90 else -1 if angle == 270 else 0) < depth)
    # Larger root fillets and taller washer lands with the original mounting centers.
    ear = g["ear_extension_mm"]
    ear_top = FIT["ear_pad_height_mm"]
    center = depth / 2
    for x in (-ear, width - 5.0):
        additions.append(rounded(x, center - 10.0, 0, ear + 5.0, 20.0, ear_top, FIT["ear_root_fillet_mm"]))
    # Leave a clear 10 mm washer land at the original chassis hole centers.
    additions.extend((ramp(1.6, 7.0, center - 10, 3.5, floor - .15, ear_top + 4.2),
                      ramp(1.6, 7.0, center + 6.5, 3.5, floor - .15, ear_top + 4.2)))
    base = base.fuse(additions).removeSplitter()
    cuts = [insert_pilot(x, y, top, g["insert_pilot_mm"], g["insert_depth_mm"])
            for axes, top in ((lid_axes, height), (upper_axes, shield_z), (lower_fasteners, lower_z))
            for x, y in axes]
    cuts.extend((cylinder(-ear / 2, center, -.1, FIT["ear_slot_width_mm"], ear_top + .3),
                 slot(width + ear / 2, center, FIT["ear_x_slot_length_mm"], FIT["ear_slot_width_mm"], ear_top)))
    return base.cut(cuts).removeSplitter()


def port_cut(g, center, half_width, sill):
    """Cut a top-open notch with 45 degree corners at the sill."""
    corner = g["port_lower_corner_mm"]
    lo, hi = center - half_width, center + half_width
    top = g["body_height_mm"] + 1.0
    x = -FIT["cable_guide_axial_ramp_mm"] - .3
    section = [V(x, lo + corner, sill), V(x, hi - corner, sill), V(x, hi, sill + corner),
               V(x, hi, top), V(x, lo, top), V(x, lo, sill + corner)]
    return profile(section, V(g["wall_mm"] - x + .08, 0, 0))


def front_details(base, g, ports):
    """Guide the cable body and provide a front landing on each rigid header flank."""
    additions = []
    for port in ports:
        y = port["center_y_mm"]
        half = port["width_mm"] / 2
        sill = port["floor_z_mm"]
        run = FIT["cable_guide_axial_ramp_mm"]
        guide_height = FIT["cable_guide_height_mm"]
        # The lower shoe grows from the outside wall by at most one mm per mm.
        ramp_bottom = sill - run - .7
        additions.append(profile([V(.2, y - half + .6, ramp_bottom),
                                  V(-run, y - half + .6, sill),
                                  V(.2, y - half + .6, sill)],
                                 V(0, 2 * half - 1.2, 0)))
        for side in (-1, 1):
            inner = y + side * half
            start = inner if side > 0 else inner - 2.0
            additions.append(profile([V(.2, start, ramp_bottom), V(-run, start, sill),
                                      V(-run, start, sill + guide_height - 1.6),
                                      V(-run + 1.6, start, sill + guide_height),
                                      V(.2, start, sill + guide_height)], V(0, 2.0, 0)))
    # Contact pads sit inside the mating plane and above the PCB.
    additions.extend(outer_header_shoes(g, ports))
    return base.fuse(additions).removeSplitter()


def outer_header_shoes(g, ports):
    top = g["esp_pcb_bottom_mm"] + g["stack_pitch_mm"] + g["pcb_thickness_mm"]
    gap = FIT["connector_side_gap_mm"]
    x0, x1 = FIT["connector_contact_band_x_mm"]
    shoes = []
    front = g["wall_mm"]
    z1 = top + 5.4
    for port in ports:
        center = port["center_y_mm"]
        half = port["width_mm"] / 2
        if port["ref"] == "J2":
            # Land the root in the solid web between the two cable openings.
            y0 = center + (15.65 / 2) + gap
            y1 = center + half + .68
            outside = y1 + .9
            root = center + half + .08
        else:
            y0 = center - half - .68
            y1 = center - 9.35 / 2 - gap
            outside = y0 - .9
            root = center - half - .08
        inner = y0 if port["ref"] == "J2" else y1
        # Intersect axial and lateral ramps so the pad grows from the wall
        # in both directions while leaving the PCB and its copper free.
        x_start = front - .25
        web_height = z1 - (x1 - x_start) - .1
        low, high = sorted((outside, inner))
        lateral_z = z1 - abs(inner - root) - .1
        if lateral_z < top + .15:
            raise ValueError("side guide drops into the PCB clearance")
        axial = profile([V(x_start, low, web_height), V(x1, low, z1 - .1),
                         V(x1, low, z1), V(x_start, low, z1)], V(0, high - low, 0))
        lateral = profile([V(x_start, outside, web_height), V(x_start, root, web_height),
                            V(x_start, root, lateral_z),
                            V(x_start, inner, z1 - .1), V(x_start, inner, z1),
                            V(x_start, outside, z1)], V(x1 - x_start, 0, 0))
        pad = axial.common(lateral)
        pad = pad.cut(box(x_start - .1, center - half, top, x0 - x_start + .1, 2 * half, z1 - top + .2))
        shoes.append(pad)
    return shoes


def lid_shell(g, axes, ports):
    width, depth, thick = (g[key] for key in ("width_mm", "depth_mm", "lid_mm"))
    lid = rounded(0, 0, 0, width, depth, thick, g["outer_corner_mm"])
    gap = FIT["lid_locator_gap_per_side_mm"]
    # The exterior sits on the bed. Every rib projects up in the print pose.
    locator = 1.8
    additions = []
    for y in (g["wall_mm"] + gap, depth - g["wall_mm"] - gap - locator):
        for x in (20, 89):
            additions.append(rounded(x, y, -1.4, 23.0, locator, 1.5, .65))
    # A long underside spine shortens the flex span without exterior pockets.
    additions.extend((rounded(29, depth / 2 - 1.4, -1.7, 78, 2.8, 1.8, 1.1),
                      rounded(28, 16, -1.4, 2.6, 43, 1.5, 1.0)))
    for port in ports:
        additions.extend(header_backstop(g, port))
        additions.append(header_roof_pad(g, port))
    lid = lid.fuse(additions).removeSplitter()
    cuts = []
    bore = g["lid_screw_clearance_diameter_mm"]
    for x, y in axes:
        cuts.append(cylinder(x, y, -.2, bore, thick + .4))
        # Build-side flare helps keep first-layer swell out of the clearance hole.
        cuts.append(Part.makeCone(bore / 2, bore / 2 + .35, .4, V(x, y, thick - .35)))
    for port in ports:
        # Leave the rim continuous between slots and around the screw seats.
        cuts.append(rounded(-1.2, port["center_y_mm"] - 10.75, -.15, 4.2, 21.5, thick + .3, 1.25))
    cuts.extend(label_engraving(g, ports))
    return lid.cut(cuts).removeSplitter()


def label_engraving(g, ports):
    """Cut a tapered marking into the flat exterior print face."""
    thick = g["lid_mm"]
    stroke, depth = 1.1, .88
    cuts = []
    for port, title in zip(ports, ("12V IN", "RGBW")):
        rows = ["0".join(GLYPHS[letter][row] for letter in title) for row in range(5)]
        for row, pixels in enumerate(rows):
            first = None
            for col, pixel in enumerate(pixels + "0"):
                if pixel == "1" and first is None:
                    first = col
                if pixel == "0" and first is not None:
                    center = port["center_y_mm"]
                    left = center + (len(pixels) / 2 - col) * stroke
                    x = 8.2 + (4 - row) * stroke
                    bottom = thick - depth
                    half = stroke * .49
                    points = [V(x + half, left, bottom), V(x, left, thick + .08),
                              V(x + stroke, left, thick + .08)]
                    cuts.append(profile(points, V(0, (col - first) * stroke, 0)))
                    first = None
    return cuts


def header_backstop(g, port):
    ref = port["ref"]
    dims = PORTS[ref]["header_extent_mm"]
    center = port["center_y_mm"]
    top = g["esp_pcb_bottom_mm"] + g["stack_pitch_mm"] + g["pcb_thickness_mm"]
    if ref == "J1":
        # The housing's maximum rear extent is taken from the Rev B model.
        # Its upper molded area is ahead of the rear terminal keepout.
        x = port["face_x_mm"] - dims["face_from_pad"] + dims["back_from_pad"]
        z = top + 9.8
        half_y = 2.1
    else:
        x = port["face_x_mm"] - dims["face_from_pad"] + dims["back_from_pad"]
        z = top + 5.4
        half_y = 2.7
    x += FIT["connector_axial_gap_mm"]
    lower = z - g["body_height_mm"]
    thickness = 4.0
    wall = rounded(x, center - half_y, lower, thickness, 2 * half_y, .15 - lower, .8)
    # A deep diagonal web takes the reaction back into the lid over a broad root.
    brace = ramp(x + thickness + 8.5, x + thickness - .65, center - 1.15, 2.3,
                 .12, lower + 2.4)
    return [wall, brace]


def header_roof_pad(g, port):
    x0, x1 = FIT["connector_contact_band_x_mm"]
    center = port["center_y_mm"]
    dims = PORTS[port["ref"]]["header_extent_mm"]
    pcb_top = g["esp_pcb_bottom_mm"] + g["stack_pitch_mm"] + g["pcb_thickness_mm"]
    pad_bottom = pcb_top + dims["height"] + FIT["header_top_gap_mm"] - g["body_height_mm"]
    return rounded(x0, center - 2.0, pad_bottom, x1 - x0, 4.0, .15 - pad_bottom, .65)


def fit_coupons(out, g, base, lid, *, front_x_max=9.5, front_span=(15.5, 49.5)):
    """Reproduce the front-end fit and calibrate the insert and fastener holes."""
    highest = g["body_height_mm"]
    y, width = front_span
    band = box(-7, y, 0, front_x_max + 7, width, highest)
    front = base.common(band).removeSplitter()
    if len(front.Solids) != 1:
        raise ValueError("the front port coupon must be one printable solid")
    actual_front, ports_report = export_printable(front, "front_ports_coupon", out)
    # The mating section carries both actual cable exit closures.
    sample_lid = lid.common(box(0, y, -g["body_height_mm"], 13.0, width,
                                g["lid_mm"] + g["body_height_mm"] + .2)).removeSplitter()
    actual_lid, lid_report = export_printable(sample_lid, "front_lid_coupon", out, flip=True)
    ladder = rounded(0, 0, 0, 43, 14, 3.2, 2.5)
    holes = (3.85, 4.0, 4.15)
    for index, diameter in enumerate(holes):
        x = 6.5 + index * 11.0
        ladder = ladder.fuse(cylinder(x, 7, 3.05, 8.8, 5.95))
        ladder = ladder.cut(insert_pilot(x, 7, 9.0, diameter, g["insert_depth_mm"]))
    ladder = ladder.cut(cylinder(39.0, 7, -.1, g["lid_screw_clearance_diameter_mm"], 3.4))
    actual_insert, insert_report = export_printable(ladder.removeSplitter(), "m3_tolerance_coupon", out)
    for actual, target in ((actual_front, front), (actual_lid, sample_lid), (actual_insert, ladder)):
        if abs(actual.Volume - target.Volume) > .025:
            raise RuntimeError("reopened fit coupon differs from the construction solid")
    return [ports_report, lid_report, insert_report]


def check_and_export(out, g, base, raw_lid, lid, shield, lower, fuses, ports, axes, results):
    """Check service clearance, fit allowances, and solid load paths."""
    z_top = g["esp_pcb_bottom_mm"] + g["stack_pitch_mm"] + g["pcb_thickness_mm"]
    z_floor = g["floor_mm"]
    case_height = g["body_height_mm"]
    fit_report = []
    fits = []
    for port in ports:
        p = PORTS[port["ref"]]
        reserve = p["cable_allowance_mm"]
        side = g["port_side_clearance_mm"]
        floor = g["port_bottom_clearance_mm"]
        error = FIT["seat_tolerance_screen_mm"]
        width = 2 * (reserve["half_width"] + error)
        travel = box(-g["nominal_cable_bend_clearance_mm"], port["center_y_mm"] - width / 2,
                     z_top - reserve["below_pcb"] - error,
                     g["nominal_cable_bend_clearance_mm"] + port["face_x_mm"], width, reserve["height"] + 2 * error)
        overlap = interference(base, travel) + interference(lid, travel)
        root = box(-.08, port["center_y_mm"] - 3.0, port["floor_z_mm"] - 4.5, .3, 6, 2.0)
        contact_root = interference(base, root)
        h = p["header_extent_mm"]
        center = port["center_y_mm"]
        rear = port["face_x_mm"] - h["face_from_pad"] + h["back_from_pad"] + FIT["connector_axial_gap_mm"]
        stop_z = z_top + (9.8 if port["ref"] == "J1" else 5.4)
        rear_pad = box(rear + .05, center - 1.0, stop_z + .2, .4, 2.0, 2.5)
        band_x0, band_x1 = FIT["connector_contact_band_x_mm"]
        roof_z = z_top + h["height"] + FIT["header_top_gap_mm"]
        roof_pad = box(band_x0 + .5, center - .8, roof_z + .05, 3.4, 1.6, .35)
        side_y = (center - 9.35 / 2 - FIT["connector_side_gap_mm"] - .45
                  if port["ref"] == "J1" else center + 15.65 / 2 + FIT["connector_side_gap_mm"] + .1)
        side_pad = box(band_x0 + .55, side_y, z_top + 5.18, band_x1 - band_x0 - 1.05, .35, .14)
        pads = {"insertion_stop": (lid, rear_pad), "upper_stop": (lid, roof_pad), "side_shoe": (base, side_pad)}
        pad_checks = {name: round(interference(shape, gauge) / gauge.Volume, 5) for name, (shape, gauge) in pads.items()}
        fits.append({"port": port["ref"], "side_gap_per_side_mm": side, "sill_gap_mm": floor,
                     "mate_envelope_growth_mm": error, "expanded_sweep_interference_mm3": round(overlap, 6),
                     "front_guide_root_material_mm3": round(contact_root, 5),
                     "contact_regions_filled_fraction": pad_checks,
                     "header_side_gap_nominal_mm": FIT["connector_side_gap_mm"],
                     "header_rear_gap_nominal_mm": FIT["connector_axial_gap_mm"],
                     "header_top_gap_nominal_mm": FIT["header_top_gap_mm"],
                     "pass": overlap < .015 and contact_root >= .95 * root.Volume
                     and all(value >= .98 for value in pad_checks.values())})
    panels = {
        "flat_floor_3_2_mm": (base, box(84, 27, 0, 15, 14, z_floor)),
        "flat_lid_3_2_mm": (lid, box(84, 27, case_height, 15, 14, g["lid_mm"])),
        "sidewall_3_mm": (base, box(54, 0, 14, 21, g["wall_mm"], 18)),
        "front_web_3_6_mm": (base, box(g["wall_mm"] - g["front_wall_mm"], 41.4, 13, g["front_wall_mm"], 3.2, 6)),
    }
    for name, (shape, gauge) in panels.items():
        missing = gauge.Volume - interference(shape, gauge)
        fit_report.append({"check": name, "missing_material_mm3": round(missing, 6), "pass": abs(missing) < .015})
    # Screen the locators against a tighter opening while keeping screw bores centered.
    tight = FIT["seat_tolerance_screen_mm"]
    width, depth, wall = (g[key] for key in ("width_mm", "depth_mm", "wall_mm"))
    for i, y in enumerate((wall - .1, depth - wall - tight), 1):
        for j, x in enumerate((20, 89), 1):
            band = box(x + .5, y, case_height - 1.3, 22.0, tight + .1, 1.3)
            overlap = interference(lid, band)
            fit_report.append({"check": f"lid_locator_{i}_{j}_tighter_wall", "allowance_mm": tight,
                               "interference_mm3": round(overlap, 6), "pass": overlap < .015})
    for side, x, half_slot in (("front", -g["ear_extension_mm"] / 2, 0),
                               ("rear", width + g["ear_extension_mm"] / 2,
                                (FIT["ear_x_slot_length_mm"] - FIT["ear_slot_width_mm"]) / 2)):
        for offset in sorted({-half_slot, half_slot}):
            fastener = cylinder(x + offset, depth / 2, 0, 4.0, FIT["ear_pad_height_mm"])
            overlap = interference(base, fastener)
            fit_report.append({"check": f"{side}_M4_at_{offset:g}_mm", "interference_mm3": round(overlap, 6),
                               "pass": overlap < .015})
    for i, (x, y) in enumerate(axes, 1):
        gauge = cylinder(x, y, g["body_height_mm"], g["lid_screw_clearance_diameter_mm"] - .04, g["lid_mm"])
        amount = interference(lid, gauge)
        fit_report.append({"check": f"lid_bore_{i}_free_diameter", "interference_mm3": round(amount, 6), "pass": amount < .015})
    # The swept lid runs straight off the insert axes after the four screws are removed.
    for lift in (.4, 1.4, 4, 12, 18):
        moved = translated(lid, 0, 0, lift)
        overlap = sum(moved.common(shape).Volume for shape in (base, shield, lower, *fuses.values()))
        fit_report.append({"check": f"lid_at_{lift:g}_mm_lift", "interference_mm3": round(overlap, 6), "pass": overlap < .015})
    report = {"contract": SPEC["definition"], "process": SPEC["process"], "ports": fits, "checks": fit_report,
              "calibration": {"insert_pilot_diameters_mm": [3.85, 4.0, 4.15],
                              "flat_nonconductive_shim_stock_mm": FIT["fit_shim_thickness_mm"]},
              "physical_fit_verified": False, "mating_force_or_cycles_measured": False}
    (out / "durable-fit.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    results.extend(fit_report)
    results.extend({"check": f'{row["port"]}_expanded_mating_sweep_and_guide_root', "pass": row["pass"],
                    "interference_mm3": row["expanded_sweep_interference_mm3"]} for row in fits)
    return fit_coupons(out, g, base, raw_lid)
