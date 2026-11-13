"""Native KiCad assembly, routing interchange and pin reconciliation on Orion."""

import argparse
import csv
import importlib.util
import json
from pathlib import Path
import platform
import sys
import uuid


sys.path.insert(0, str(Path(__file__).resolve().parent))
from design import (CASE, FUSE_GEOMETRY, FUSE_HOLDER, FUSES, NAME, OUTLINE, PORTS,
                    REFERENCE, REV_C_NAME, UPPER_MOUNTS, design, minimum_width)


spec = importlib.util.spec_from_file_location("vhos_rev_a_kicad", REFERENCE / "native_pcb.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
base.NAME = NAME
base.NS = uuid.UUID("cc60c882-ff59-4abf-9a45-283f454ef8c0")
uid = base.uid
quote = base.quote
xy = base.xy
save_json = base.save_json


def schematic(parts, out):
    sheet_id = uid("sheet")
    symbols, items = [], []
    sections = {"power": (45, 54, "FUSED INPUT, PROTECTION AND 5 V SUPPLY"),
                "headers": (45, 302, "VEHICLE INPUT AND CONTROLLER STACK"),
                "outputs": (45, 421, "ONE COMMON-POSITIVE RGBW ZONE")}
    for section, (left, top, title) in sections.items():
        items.append(f'(text {quote(title)} (at 26 {top - 24} 0) (effects (font (size 2 2)) '
                     f'(justify left bottom)) (uuid "{uid(section)}"))')
        for i, part in enumerate(p for p in parts if p["section"] == section):
            x = round(round((left + i % 8 * 96) / 1.27) * 1.27, 4)
            y = round(round((top + i // 8 * 40) / 1.27) * 1.27, 4)
            definition, pins, height = base.symbol_definition(part)
            symbols.append(definition)
            ref = part["ref"]
            in_bom = "no" if ref.startswith(("TP", "MH")) else "yes"
            props = (("Reference", ref, y - height - 3), ("Value", part["value"], y + height + 3),
                     ("Footprint", part["footprint"], y), ("MPN", part["mpn"] or "PCB FEATURE", y))
            properties = ''.join(f'(property {quote(key)} {quote(value)} (at {x} {where} 0) '
                                 f'(effects (font (size .9 .9)){" hide" if j >= 2 else ""}))'
                                 for j, (key, value, where) in enumerate(props))
            pin_items = ''.join(f'(pin "{pin}" (uuid "{uid(ref + ".pin." + pin)}"))' for pin in pins)
            items.append(f'(symbol (lib_id "VHOS:{ref}") (at {x} {y} 0) (unit 1) (in_bom {in_bom}) '
                         f'(on_board yes) (dnp no) (uuid "{uid(ref)}") {properties}{pin_items} '
                         f'(instances (project "{NAME}" (path "/{sheet_id}" (reference "{ref}") (unit 1)))))')
            for pin, (px, py, side) in pins.items():
                gx, gy = round(x + px, 4), round(y - py, 4)
                key = f"{ref}.{pin}"
                net = part["nets"][pin]
                if net is None:
                    items.append(f'(no_connect (at {gx} {gy}) (uuid "{uid(key + "NC")}"))')
                    continue
                end = round(gx + side * 2.54, 4)
                items.append(f'(wire (pts (xy {gx} {gy}) (xy {end} {gy})) (stroke (width 0) (type default)) '
                             f'(uuid "{uid(key + "wire")}"))')
                items.append(f'(label "{net}" (at {end} {gy} {180 if side < 0 else 0}) '
                             f'(effects (font (size .8 .8)) (justify left bottom)) (uuid "{uid(key + "net")}"))')
    # Flags establish the intentional power sources on the input and converter.
    flag = '''(symbol "VHOS:PWR_FLAG" (power) (pin_names (offset 0) hide) (in_bom no) (on_board no)
      (property "Reference" "#FLG" (at 0 2.54 0) (effects (font (size 1 1)) hide))
      (property "Value" "PWR_FLAG" (at 0 3.81 0) (effects (font (size 1 1))))
      (symbol "PWR_FLAG_0_1" (polyline (pts (xy 0 0) (xy 0 1.27) (xy -.8 2) (xy 0 2.7) (xy .8 2) (xy 0 1.27)) (stroke (width .15) (type default)) (fill (type none))))
      (symbol "PWR_FLAG_1_1" (pin power_out line (at 0 0 90) (length 0) (name "pwr" (effects (font (size 1 1)))) (number "1" (effects (font (size 1 1)))))))'''
    symbols.append(flag)
    for i, net in enumerate(("GND", "VEH_ACC", "ACC_FUSED", "LED_POS", "VIN_PROT", "V5_LOGIC"), 1):
        ref, x, y = f"#FLG0{i}", round((29 + i * 57) * 1.27, 4), 251.46
        items.append(f'''(symbol (lib_id "VHOS:PWR_FLAG") (at {x} {y} 0) (unit 1) (in_bom no) (on_board no) (dnp no)
          (uuid "{uid(ref)}") (property "Reference" "{ref}" (at {x} {y + 2.54} 0) (effects (font (size 1 1)) hide))
          (property "Value" "PWR_FLAG" (at {x} {y - 3.81} 0) (effects (font (size 1 1))))
          (pin "1" (uuid "{uid(ref + 'pin')}"))
          (instances (project "{NAME}" (path "/{sheet_id}" (reference "{ref}") (unit 1)))))
          (label "{net}" (at {x} {y} 0) (effects (font (size 1 1)) (justify left bottom)) (uuid "{uid(ref + 'net')}"))''')
    items.append(f'(text "EVALUATION HARDWARE / VERIFY VEHICLE FEED, LED PINOUT AND USB ISOLATION" '
                 f'(at 26 578 0) (effects (font (size 1.5 1.5)) (justify left bottom)) (uuid "{uid("notice")}"))')
    sch = f'''(kicad_sch (version 20250114) (generator "eeschema") (generator_version "10.0")
      (uuid "{sheet_id}") (paper "A1")
      (title_block (title "4Runner two-connector RGBW shield") (rev "B"))
      (lib_symbols {''.join(symbols)}) {''.join(items)} (sheet_instances (path "/" (page "1"))) (embedded_fonts no))'''
    (out / (NAME + ".kicad_sch")).write_text(sch, encoding="utf-8")
    library = ''.join(s.replace('(symbol "VHOS:', '(symbol "', 1) for s in symbols)
    (out / "VHOS.kicad_sym").write_text(f'(kicad_symbol_lib (version 20250114) (generator "kicad_symbol_editor") {library})', encoding="utf-8")
    (out / "sym-lib-table").write_text('(sym_lib_table (lib (name "VHOS") (type "KiCad") '
                                       '(uri "${KIPRJMOD}/VHOS.kicad_sym") (options "") (descr "Rev B")))', encoding="utf-8")
    return sheet_id


def project(out):
    base.project(out)
    path = out / (NAME + ".kicad_pro")
    data = json.loads(path.read_text())
    data["board"]["design_settings"]["rules"].update(min_clearance=.16, min_track_width=.18)
    for row in data["net_settings"]["classes"]:
        row["clearance"] = .19
        if row["name"] == "Default":
            row["track_width"] = .20
    patterns = {"LED": [f"LED_{color}_NEG" for color in "RGBW"], "Power": ["SW", "V5_LOGIC", "VIN_PROT"]}
    data["net_settings"]["netclass_patterns"] = [
        {"pattern": "/" + net, "netclass": kind} for kind, names in patterns.items() for net in names]
    save_json(path, data)


def fuse_footprint(out):
    footprint = pcbnew.FOOTPRINT(None)
    lib, name = FUSE_HOLDER.split(":")
    footprint.SetFPID(pcbnew.LIB_ID(lib, name))
    footprint.SetLibDescription("Keystone 3568 vertical MINI holder; 9.91 x 3.40 mm hole matrix")
    footprint.SetAttributes(pcbnew.FP_THROUGH_HOLE)
    spec = FUSE_GEOMETRY
    for index, x in enumerate((-spec["pitch_x_mm"] / 2, spec["pitch_x_mm"] / 2), 1):
        for y in (-spec["pitch_y_mm"] / 2, spec["pitch_y_mm"] / 2):
            pad = pcbnew.PAD(footprint)
            pad.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
            pad.SetShape(pcbnew.PAD_SHAPE_CIRCLE)
            pad.SetNumber(str(index))
            pad.SetLayerSet(pad.PTHMask())
            pad.SetSize(pcbnew.VECTOR2I(pcbnew.FromMM(2.3), pcbnew.FromMM(2.3)))
            pad.SetDrillSize(pcbnew.VECTOR2I(pcbnew.FromMM(spec["drill_mm"]), pcbnew.FromMM(spec["drill_mm"])))
            pad.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(x), pcbnew.FromMM(y)))
            footprint.Add(pad)
    for layer, margin in ((pcbnew.F_Fab, 0), (pcbnew.F_CrtYd, .35)):
        box = pcbnew.PCB_SHAPE(footprint)
        box.SetShape(pcbnew.SHAPE_T_RECT)
        w = pcbnew.FromMM(spec["body_x_mm"] / 2 + margin)
        d = pcbnew.FromMM(spec["body_y_mm"] / 2 + margin)
        box.SetStart(pcbnew.VECTOR2I(-w, -d))
        box.SetEnd(pcbnew.VECTOR2I(w, d))
        box.SetLayer(layer)
        box.SetWidth(pcbnew.FromMM(.05 if margin else .1))
        footprint.Add(box)
    folder = out / (lib + ".pretty")
    folder.mkdir(exist_ok=True)
    pcbnew.PCB_IO_MGR.FindPlugin(pcbnew.PCB_IO_MGR.KICAD_SEXP).FootprintSave(str(folder), footprint)


def copper(board, net, points, width, layer):
    for start, end in zip(points, points[1:]):
        if start == end:
            continue
        track = pcbnew.PCB_TRACK(board)
        track.SetStart(start)
        track.SetEnd(end)
        track.SetWidth(pcbnew.FromMM(width))
        track.SetLayer(layer)
        track.SetNet(board.FindNet("/" + net))
        track.SetLocked(True)
        board.Add(track)


def via(board, net, point, diameter=.8, drill=.4):
    item = pcbnew.PCB_VIA(board)
    item.SetPosition(point)
    item.SetWidth(pcbnew.FromMM(diameter))
    item.SetDrill(pcbnew.FromMM(drill))
    item.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    item.SetNet(board.FindNet("/" + net))
    item.SetLocked(True)
    board.Add(item)


def main_power_routes(board, footprints):
    def pin(ref, number):
        return [p.GetPosition() for p in footprints[ref].Pads() if p.GetNumber() == str(number)][0]

    def fuse_pads(ref, number):
        return sorted((p.GetPosition() for p in footprints[ref].Pads() if p.GetNumber() == str(number)),
                      key=lambda pt: pt.y)

    top, back = pcbnew.F_Cu, pcbnew.B_Cu
    line, line_other = fuse_pads("F1", 1)
    load, load_other = fuse_pads("F1", 2)
    logic, logic_other = fuse_pads("F2", 1)
    copper(board, "VEH_ACC", [pin("J1", 2), line_other, line], 1.5, back)
    copper(board, "ACC_FUSED", [load, load_other, xy((-24.0, 40.0)), xy((-27.6, 38.3)), pin("Q5", 1)], 1.4, back)
    for net, ref in (("ACC_FUSED", "Q5"), ("LED_POS", "Q6")):
        copper(board, net, [pin(ref, num) for num in (1, 2, 3)], 1.2, top)
    # Parallel through vias take the full current between the PCB faces.
    for point in [xy((-28.7, 32.7)), xy((-28.7, 34.0)), xy((-28.7, 35.3))]:
        copper(board, "ACC_FUSED", [pin("Q5", 1), point], 1.2, top)
        copper(board, "ACC_FUSED", [pin("Q5", 1), point], 1.4, back)
        via(board, "ACC_FUSED", point)
    copper(board, "POWER_MID", [pin("Q5", 5), pin("Q6", 5)], 1.5, top)
    for point in [xy((-10, 30.5)), xy((-10, 31.7)), xy((-10, 32.9))]:
        copper(board, "LED_POS", [pin("Q6", 1), point], 1.2, top)
        copper(board, "LED_POS", [point, xy((-10.0, 31.7))], 1.4, back)
        via(board, "LED_POS", point)
    copper(board, "LED_POS", [xy((-10, 31.7)), xy((-13, 29.0)), xy((-39, 26.4)),
                              xy((-47.5, 26.4)), xy((-47.8, 23.6)), pin("J2", 4)], 1.4, back)
    copper(board, "LED_POS", [xy((-10, 31.7)), xy((-8.4, 39.5)), logic_other, logic], 1.0, back)
    # The controller's OUT reference is a short sense spur off the wide LED
    # supply. Route it independently of the load path to the fine-pitch pad.
    out_sense = xy((-15.6, 24.85))
    copper(board, "LED_POS", [pin("U4", 9), out_sense], .20, top)
    via(board, "LED_POS", out_sense, .7, .3)
    copper(board, "LED_POS", [out_sense, xy((-13, 29.0))], .25, back)
    copper(board, "ACC_FUSED", [load_other, xy((-17, 42.0)), pin("D1", 1)], 1.0, top)
    for driver, first, second, x in (("U2", "C9", "C10", 36.8), ("U3", "C11", "C12", 46.8)):
        middle = xy((x, 12.5))
        copper(board, "V5_LOGIC", [pin(driver, 6), pin(first, 1), middle, pin(second, 1)], .8, top)
        via(board, "V5_LOGIC", middle, .7, .3)
    logic_feed = xy((42.8, 24))
    copper(board, "V5_LOGIC", [pin("C5", 2), logic_feed], .8, top)
    via(board, "V5_LOGIC", logic_feed)
    copper(board, "V5_LOGIC", [xy((36.8, 12.5)), xy((46.8, 12.5))], .8, pcbnew.In2_Cu)
    copper(board, "V5_LOGIC", [xy((36.8, 12.5)), xy((36.8, 18)), logic_feed], .8, pcbnew.In2_Cu)


def load_footprint(part, out):
    lib, name = part.get("source_footprint", part["footprint"]).split(":")
    folder = (out if lib == "VHOS_RevB" else base.LIB) / (lib + ".pretty")
    footprint = pcbnew.FootprintLoad(str(folder), name)
    if footprint is None:
        raise RuntimeError(f"missing footprint {part['footprint']}")
    footprint.SetFPID(pcbnew.LIB_ID(lib, name))
    return footprint, folder / (name + ".kicad_mod")


def install_model(footprint, reference):
    # Connector and fuse-holder models come from the same dimensional inputs
    # as the enclosure. Keep the native installed footprints' pad coordinates.
    file = "MINI-3568" if reference in FUSES else reference
    model = pcbnew.FP_3DMODEL()
    model.m_Filename = "${KIPRJMOD}/models/" + file + ".step"
    footprint.Models().clear()
    footprint.Models().push_back(model)


def build(out):
    reference = json.loads((REFERENCE / "engineering-inputs.json").read_text())
    parts = design(reference["headers"])
    for part in parts:
        if part["ref"] in PORTS:
            part["source_footprint"] = part["footprint"]
            part["footprint"] = "VHOS_RevB:" + part["footprint"].split(":", 1)[1]
    project(out)
    fuse_footprint(out)
    sheet = schematic(parts, out)
    board = pcbnew.BOARD()
    board.SetCopperLayerCount(4)
    board.GetDesignSettings().SetBoardThickness(pcbnew.FromMM(1.6))
    nets = {}
    for name in sorted({net for part in parts for net in part["nets"].values() if net}):
        nets[name] = pcbnew.NETINFO_ITEM(board, "/" + name)
        board.Add(nets[name])
    footprints, libraries, provenance = {}, {}, []
    for part in parts:
        ref = part["ref"]
        footprint, source = load_footprint(part, out)
        lib = part["footprint"].split(":", 1)[0]
        prefix = "${KIPRJMOD}" if lib == "VHOS_RevB" else "${KICAD10_FOOTPRINT_DIR}"
        libraries[lib] = f"{prefix}/{lib}.pretty"
        provenance.append({"ref": ref, "id": part["footprint"], "sha256": base.sha(source)})
        footprint.SetReference(ref)
        footprint.SetValue(part["value"])
        footprint.SetPosition(xy(part["xy_mm"]))
        footprint.SetOrientationDegrees(part["angle_deg"])
        footprint.SetPath(pcbnew.KIID_PATH("/" + sheet + "/" + uid(ref)))
        mpn = pcbnew.PCB_FIELD(footprint, pcbnew.FIELD_T_USER, "MPN")
        mpn.SetText(part["mpn"] or "PCB FEATURE")
        mpn.SetVisible(False)
        mpn.SetLayer(pcbnew.F_Fab)
        footprint.Add(mpn)
        if part.get("absolute_pads_mm"):
            for angle in (0, 90, 180, 270):
                footprint.SetOrientationDegrees(angle)
                pads = {p.GetNumber(): p.GetPosition() for p in footprint.Pads()}
                if all(pads[p["eagle_pad"]] == xy((p["x_mm"], p["y_mm"])) for p in part["absolute_pads_mm"]):
                    break
            else:
                raise RuntimeError(f"nominal header position mismatch {ref}")
        found = set()
        for pad in footprint.Pads():
            key = pad.GetNumber()
            if key not in part["nets"]:
                continue
            found.add(key)
            name = part["nets"][key]
            if name is None:
                label = part["pin_names"].get(key)
                pin = f"{label}-Pad{key}" if label and label != key else f"Pad{key}"
                name = f"unconnected-({ref}-{pin})"
                if name not in nets:
                    nets[name] = pcbnew.NETINFO_ITEM(board, name)
                    board.Add(nets[name])
            pad.SetNet(nets[name])
        if found != part["nets"].keys():
            raise RuntimeError(f"{ref} pad mismatch: {set(part['nets']) - found}")
        if ref in PORTS or ref in FUSES:
            install_model(footprint, ref)
        if ref in PORTS:
            for graphic in footprint.GraphicalItems():
                if graphic.GetLayer() == pcbnew.F_SilkS:
                    graphic.SetLayer(pcbnew.F_Fab)
            pcbnew.PCB_IO_MGR.FindPlugin(pcbnew.PCB_IO_MGR.KICAD_SEXP).FootprintSave(
                str(out / "VHOS_RevB.pretty"), footprint)
            footprint.SetFPID(pcbnew.LIB_ID("VHOS_RevB", part["footprint"].split(":", 1)[1]))
        for field in (footprint.Reference(), footprint.Value()):
            field.SetLayer(pcbnew.F_Fab)
            field.SetVisible(True)
        board.Add(footprint)
        footprints[ref] = footprint
    for start, end in zip(OUTLINE, OUTLINE[1:] + OUTLINE[:1]):
        edge = pcbnew.PCB_SHAPE(board)
        edge.SetShape(pcbnew.SHAPE_T_SEGMENT)
        edge.SetStart(xy(start))
        edge.SetEnd(xy(end))
        edge.SetLayer(pcbnew.Edge_Cuts)
        edge.SetWidth(pcbnew.FromMM(.05))
        board.Add(edge)
    main_power_routes(board, footprints)
    base.ground_zone(board, pcbnew.In1_Cu, OUTLINE)
    base.text(board, "4RUNNER RGBW B", (-27, 5.4), .85)
    base.text(board, "J1 VEHICLE IN", (-43, 36.1), .9)
    base.text(board, "J2 RGBW OUT", (-41, 29.4), .9)
    for ref, text in (("F1", "F1 3A MAIN"), ("F2", "F2 1A LOGIC")):
        base.text(board, text, (FUSES[ref]["xy"][0], 51.4), .85)
    base.text(board, "5V RUN", (33, 9.1), .7, pcbnew.F_Fab)
    board_path = out / (NAME + ".kicad_pcb")
    pcbnew.SaveBoard(str(board_path), board, True)
    table = ''.join(f'(lib (name "{key}") (type "KiCad") (uri "{value}") (options "") (descr "Rev B"))'
                    for key, value in sorted(libraries.items()))
    (out / "fp-lib-table").write_text(f"(fp_lib_table {table})", encoding="utf-8")
    save_json(out / "circuit-design.json", parts)
    save_json(out / "footprint-sources.json", provenance)
    save_json(out / "pcb-outline.json", {"polygon_mm": OUTLINE, "mounts_mm": UPPER_MOUNTS})
    with (out / "PCB-BOM.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["ref", "value", "mpn", "footprint", "note"])
        writer.writeheader()
        writer.writerows({key: p[key] for key in writer.fieldnames} for p in parts)
    board = pcbnew.LoadBoard(str(board_path))
    manager = base.load_project(board, out)
    board.BuildConnectivity()
    effective = []
    for name, net in board.GetNetsByName().items():
        if not name:
            continue
        net_class = net.GetNetClassSlow()
        width = pcbnew.ToMM(net_class.GetTrackWidth())
        if abs(width - minimum_width(str(name).removeprefix("/"))) > 1e-5:
            raise RuntimeError(f"net class mismatch for {name}: {width}")
        effective.append({"net": str(name), "class": str(net_class.GetName()), "width_mm": width,
                          "clearance_mm": pcbnew.ToMM(net_class.GetClearance())})
    if not pcbnew.ExportSpecctraDSN(board, str(out / "shield.dsn")):
        raise RuntimeError("Specctra export failed")
    base.bind_dsn_rules(out, effective)
    dsn = out / "shield.dsn"
    native = dsn.read_text()
    dsn.write_text(native.replace("(clearance 270)", "(clearance 190)").replace("(width 250) (clearance 190)", "(width 200) (clearance 190)") + "\n")
    receipt = out / "dsn-rule-binding.json"
    binding = json.loads(receipt.read_text())
    binding.update(router_input_sha256=base.sha(dsn), router_clearance_mm=.19)
    save_json(receipt, binding)
    save_json(out / "locked-copper.json", locked_copper(board))


def locked_copper(board):
    return sorted([str(t.GetNetname()), t.GetLayer(), t.GetStart().x, t.GetStart().y,
                   t.GetEnd().x, t.GetEnd().y, t.GetWidth()]
                  for t in board.GetTracks() if t.IsLocked() and t.GetClass() == "PCB_TRACK")


def import_route(out):
    path = out / (NAME + ".kicad_pcb")
    board = pcbnew.LoadBoard(str(path))
    manager = base.load_project(board, out)
    before = base.observation(board)
    if not pcbnew.ImportSpecctraSES(board, str(out / "shield.ses")):
        raise RuntimeError("Specctra route import failed")
    if before != base.observation(board):
        raise RuntimeError("router changed footprint identities")
    # SES can reverse segment orientation and omit the lock flag. Compare the
    # original straight copper by centerline, layer, width and net instead.
    def identity(row):
        net, layer, x1, y1, x2, y2, width = row
        return net, layer, tuple(sorted(((x1, y1), (x2, y2)))), width

    routed = {identity([str(t.GetNetname()), t.GetLayer(), t.GetStart().x, t.GetStart().y,
                        t.GetEnd().x, t.GetEnd().y, t.GetWidth()])
              for t in board.GetTracks() if t.GetClass() == "PCB_TRACK"}
    original = {identity(r) for r in json.loads((out / "locked-copper.json").read_text())}
    missing = original - routed
    if missing:
        raise RuntimeError(f"router changed {len(missing)} protected copper segments")
    for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
        base.ground_zone(board, layer, OUTLINE)
    for zone in board.Zones():
        zone.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    pcbnew.SaveBoard(str(path), board, True)
    widths = {}
    for track in board.GetTracks():
        if track.GetClass() != "PCB_TRACK":
            continue
        net = str(track.GetNetname()).removeprefix("/")
        width = pcbnew.ToMM(track.GetWidth())
        widths[net] = min(width, widths.get(net, width))
    for net, width in widths.items():
        if width + 1e-5 < minimum_width(net):
            raise RuntimeError(f"undersized routed segment on {net}")
    save_json(out / "copper-audit.json", {"locked_segments_preserved": len(original),
              "minimum_by_net_mm": widths, "ground_planes": ["F.Cu", "In1.Cu", "B.Cu"],
              "thermal_and_fault_limits_measured": False})


def direct_lead_pads(out):
    """Convert the two connector footprints to wire terminations in place."""
    from toyota_power import DIRECT_LEADS, REVB_PADS, SPEC

    path = out / (REV_C_NAME + ".kicad_pcb")
    board = pcbnew.LoadBoard(str(path))
    plugin = pcbnew.PCB_IO_MGR.FindPlugin(pcbnew.PCB_IO_MGR.KICAD_SEXP)
    library = out / "VHOS_RevB.pretty"
    footprints = {fp.GetReference(): fp for fp in board.GetFootprints()}
    labels = {"GND": "GND", "VEH_ACC": "+12V", "LED_R_NEG": "R-", "LED_G_NEG": "G-",
              "LED_B_NEG": "B-", "LED_POS": "+12V", "LED_W_NEG": "W-"}
    receipt = {}
    for ref, (name, value) in DIRECT_LEADS.items():
        footprint = footprints[ref]
        if footprint.GetFPID().GetUniStringLibId() != REVB_PADS[ref]:
            raise ValueError(f"Unexpected {ref} source footprint")
        expected = SPEC["pad_assignments"][ref]
        pads = {p.GetNumber(): p for p in footprint.Pads() if p.GetNumber() in expected}
        if {pin: pad.GetNetname().lstrip('/') for pin, pad in pads.items()} != expected:
            raise ValueError(f"{ref} solder pad assignments changed")
        unused = [p for p in footprint.Pads() if p.GetNumber() not in expected]
        if len(unused) != {"J1": 1, "J2": 5}[ref] or any(
            not (p.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH or p.GetNetname().startswith(f"unconnected-({ref}-Pad"))
            for p in unused
        ):
            raise ValueError(f"{ref} has unexpected legacy pads")
        termination = pcbnew.FOOTPRINT(board)
        termination.SetFPID(pcbnew.LIB_ID("VHOS_RevB", name))
        termination.SetLibDescription("Direct-solder wire terminations with off-board strain relief")
        termination.SetKeywords("wire solder pad")
        termination.SetReference(ref)
        termination.SetValue(value)
        termination.SetPath(footprint.GetPath())
        termination.SetPosition(footprint.GetPosition())
        termination.SetLayer(pcbnew.F_Cu)
        termination.SetAttributes(pcbnew.FP_THROUGH_HOLE | pcbnew.FP_EXCLUDE_FROM_BOM | pcbnew.FP_EXCLUDE_FROM_POS_FILES)
        for field, offset in ((termination.Reference(), -2.5), (termination.Value(), 2.5)):
            anchor = footprint.GetPosition()
            field.SetPosition(pcbnew.VECTOR2I(anchor.x + pcbnew.FromMM(4), anchor.y + pcbnew.FromMM(offset)))
            field.SetLayer(pcbnew.F_Fab)
        for pad in pads.values():
            copy = pcbnew.PAD(pad)
            copy.SetParent(termination)
            copy.SetPosition(pad.GetPosition())
            termination.Add(copy)
        plugin.FootprintSave(str(library), termination)
        board.Remove(footprint)
        board.Add(termination)
        (library / (REVB_PADS[ref].split(":")[1] + ".kicad_mod")).unlink()
        receipt[ref] = {
            "function": "vehicle_power_input" if ref == "J1" else "rgbw_output",
            "legacy_holes_removed": len(unused),
            "pads": {},
        }
        for pin, pad in sorted(pads.items()):
            x, y = (pcbnew.ToMM(axis) for axis in pad.GetPosition())
            drill = pcbnew.ToMM(pad.GetDrillSize().x)
            receipt[ref]["pads"][pin] = {"net": expected[pin], "xy_mm": [x, y], "drill_mm": drill}
            dx, dy = (0, 2.6) if ref == "J1" else ((2.2, 0) if pin == "5" else (-3.0, 0))
            base.text(board, labels[expected[pin]], (x + dx - 100, 153.34 - y - dy), .85)

    new_labels = {"4RUNNER RGBW B": "4RUNNER RGBW C", "J1 VEHICLE IN": "TOYOTA POWER IN", "J2 RGBW OUT": "RGBW OUT"}
    for item in board.GetDrawings():
        if item.GetClass() == "PCB_TEXT" and item.GetText() in new_labels:
            item.SetText(new_labels.pop(item.GetText()))
    if new_labels:
        raise ValueError(f"Missing original board labels: {new_labels}")
    title = board.GetTitleBlock()
    title.SetTitle("4Runner Toyota-powered RGBW shield")
    title.SetRevision("C")
    board.SetTitleBlock(title)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(str(path), board, True)
    save_json(out / "harness-pads.json", receipt)


def main():
    if platform.system() != "Windows" or platform.node().split(".")[0].casefold() != "orion":
        raise RuntimeError("Orion native KiCad required")
    global pcbnew
    import pcbnew
    base.pcbnew = pcbnew
    if pcbnew.GetBuildVersion() != "10.0.6":
        raise RuntimeError("KiCad 10.0.6 required")
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["build", "import", "reconcile", "direct-lead-pads"])
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    {"build": build, "import": import_route, "reconcile": base.reconcile,
     "direct-lead-pads": direct_lead_pads}[args.action](args.out)


if __name__ == "__main__":
    main()
