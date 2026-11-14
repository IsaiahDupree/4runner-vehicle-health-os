"""Place and route the integrated Rev G circuit against the checked Rev F interfaces."""

import csv
import json
import shutil

import illumination_pcb
import lean_board as design
import single_board
import stock_board
from single_board_pcb import write_interfaces

BASELINE = "revg-route-baseline.json"
LED_RETURNS = {f"LED_{channel}_NEG" for channel in "RGBW"}
RF_SENSE = {"VEH_ACC", "BOOT_N", "DOWNLOAD_STRAP", "UART_TX", "UART_RX", "CHIP_EN"}
WIDTH_CLASSES = {
    "Fused feed": (.46, {"ACC_FUSED", "LED_POS"}),
    "Buck input and rail": (.45, {"VIN_PROT", "SW", "ESP_3V3"}),
    "RGBW returns": (.42, LED_RETURNS),
}


def stage(inputs, out):
    for ext in ("kicad_pcb", "kicad_pro"):
        shutil.copyfile(inputs / f"{stock_board.NAME}.{ext}", out / f"{design.NAME}.{ext}")
    for folder in ("VHOS_RevB.pretty", "models"):
        shutil.copytree(inputs / folder, out / folder)
    shutil.copyfile(inputs / "fp-lib-table", out / "fp-lib-table")
    for name, (width, height) in design.EPACKAGES.values():
        p = out / "VHOS_RevB.pretty" / (name + ".kicad_mod")
        outline = []
        for index in range(8):
            y = (index - 3.5) * .65
            for pad, x in ((index + 1, -2.9), (16 - index, 2.9)):
                outline.append(f'(pad "{pad}" smd roundrect (at {x} {y:.3f}) (size 1.5 .45) '
                               '(layers "F.Cu" "F.Paste" "F.Mask") (roundrect_rratio .12))')
        p.write_text(f'''(footprint "{name}" (version 20240108) (generator "pcbnew") (layer "F.Cu")
          (descr "TI {name} example land pattern and 0.125 mm stencil aperture") (attr smd)
          (property "Reference" "REF**" (at 0 -4) (layer "F.SilkS") (effects (font (size 1 1))))
          (property "Value" "{name}" (at 0 4) (layer "F.Fab") (effects (font (size 1 1))))
          (fp_rect (start -2.2 -2.5) (end 2.2 2.5) (stroke (width .1) (type default)) (fill none) (layer "F.Fab"))
          (fp_line (start -2.2 -1.5) (end -1.2 -2.5) (stroke (width .1) (type default)) (layer "F.Fab"))
          (fp_line (start -3.72 -2.85) (end -2.38 -2.85) (stroke (width .14) (type default)) (layer "F.SilkS"))
          (fp_rect (start -3.9 -2.8) (end 3.9 2.8) (stroke (width .05) (type default)) (fill none) (layer "F.CrtYd"))
          {' '.join(outline)}
          (pad "17" smd roundrect (at 0 0) (size {width} {height})
            (layers "F.Cu" "F.Paste" "F.Mask") (roundrect_rratio .015))
          (model "${{KICAD10_3DMODEL_DIR}}/Package_SO.3dshapes/TSSOP-16_4.4x5mm_P0.65mm.step"
            (offset (xyz 0 0 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 0))))''', encoding="utf-8")

    project_file = out / f"{design.NAME}.kicad_pro"
    project = json.loads(project_file.read_text())
    project["meta"]["filename"] = project_file.name
    settings = project["net_settings"]
    default = settings["classes"][0]
    settings["classes"] = [default] + [
        {**default, "name": name, "track_width": width, "priority": index}
        for index, (name, (width, _)) in enumerate(WIDTH_CLASSES.items())
    ]
    settings["netclass_patterns"] = [
        {"pattern": "/" + net, "netclass": name} for name, (_, nets) in WIDTH_CLASSES.items() for net in sorted(nets)
    ]
    project_file.write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")


def build(native, out):
    pcbnew = native.pcbnew
    board, path = illumination_pcb.load(native, out, name=design.NAME)
    definitions = {part["ref"]: part for part in design.parts()}
    sheet = native.schematic(definitions.values(), out, name=design.NAME, title=design.TITLE, rev="G")
    report = design.electrical_screen()
    footprints = {}
    selected = design.selection()

    def vector(pos):
        return native.xy(single_board.board_xy(pos))

    def pos(point):
        return pcbnew.ToMM(point.x), pcbnew.ToMM(point.y)

    def pad(ref, number):
        return next(p for p in footprints[ref].Pads() if p.GetNumber() == str(number))

    def net(name):
        item = board.FindNet(name)
        if item is None:
            item = pcbnew.NETINFO_ITEM(board, name)
            board.Add(item)
        return item

    for track in list(board.GetTracks()):
        name = str(track.GetNetname()).removeprefix("/")
        bbox = track.GetBoundingBox()
        x1, y1 = pos(bbox.GetOrigin())
        x2, y2 = pos(bbox.GetEnd())
        unchanged_ground = name == "GND" and (
            (x2 < 72.6 and y1 > 117 and y2 < 137)
            or (x1 > 150 and y1 > 121)
            or (x1 > 161 and 103 < y1 <= y2 < 114)
        )
        unchanged_sense = name.startswith(("TAIL_", "DIM_")) and name != "DIM_SW"
        if name in RF_SENSE or unchanged_sense or unchanged_ground:
            track.SetLocked(True)
        else:
            board.Delete(track)

    for fp in list(board.GetFootprints()):
        ref = fp.GetReference()
        if ref in design.REMOVED or ref not in definitions:
            board.Delete(fp)
        else:
            footprints[ref] = fp

    table = {}
    for ref, part in definitions.items():
        lib = part["footprint"].split(":", 1)[0]
        origin = "${KIPRJMOD}" if lib == "VHOS_RevB" else "${KICAD10_FOOTPRINT_DIR}"
        table[lib] = f"{origin}/{lib}.pretty"
        is_new = ref not in footprints
        if not is_new:
            fp = footprints[ref]
        else:
            fp, _ = native.load_footprint(part, out)
            fp.SetReference(ref)
            fp.SetPath(pcbnew.KIID_PATH("/" + sheet + "/" + native.uid(ref)))
            for field in (fp.Reference(), fp.Value()):
                field.SetLayer(pcbnew.F_Fab)
            board.Add(fp)
            footprints[ref] = fp
        if is_new or ref in design.MOVED:
            fp.SetPosition(native.xy(part["xy_mm"]))
            fp.SetOrientationDegrees(part["angle_deg"])
        fp.SetValue(part["value"])
        if part["mpn"] or is_new and ref.startswith("TP"):
            mpn = fp.GetField("MPN")
            if mpn is None:
                mpn = pcbnew.PCB_FIELD(fp, pcbnew.FIELD_T_USER, "MPN")
                mpn.SetVisible(False)
                mpn.SetLayer(pcbnew.F_Fab)
                fp.Add(mpn)
            mpn.SetText(part["mpn"] or "PCB FEATURE")
        actual_pins = {p.GetNumber() for p in fp.Pads() if p.GetNumber()}
        if actual_pins != part["nets"].keys():
            raise ValueError(f"{ref} footprint pads {actual_pins} differ from the schematic")
        for p in fp.Pads():
            number = p.GetNumber()
            if not number:
                continue
            name = part["nets"][number]
            if name:
                p.SetNet(net("/" + name))
            else:
                pin = part["pin_names"][number]
                p.SetNet(net(f"unconnected-({ref}-{pin}-Pad{number})"))

    for drawing in board.GetDrawings():
        if drawing.GetClass() == "PCB_TEXT":
            if drawing.GetText() == "4RUNNER RGBW F":
                drawing.SetText("4RUNNER RGBW G")
                drawing.SetPosition(vector((108, 148)))
            elif drawing.GetText() == "RGBW OUT":
                drawing.SetPosition(vector((95, 144)))
    title = board.GetTitleBlock()
    title.SetRevision("G")
    title.SetTitle(design.TITLE)
    board.SetTitleBlock(title)
    (out / "fp-lib-table").write_text("(fp_lib_table " + "".join(
        f'(lib (name "{lib}") (type "KiCad") (uri "{value}") (options "") (descr "Rev G"))'
        for lib, value in sorted(table.items())) + ")", encoding="utf-8")

    def line(name, *points, width):
        native.copper(board, name, points, width, pcbnew.F_Cu)

    def fan(ref, name, sites):
        center = pad(ref, 17).GetPosition()
        x, y = pos(center)
        for dx, dy in sites:
            via_site = vector((x + dx, y + dy))
            line(name, center, via_site, width=.70)
            native.via(board, name, via_site, .65, .30)

    # Offset thermal drills outside the stencil openings. The two isolated RTN
    # vias also take the eFuse PowerPAD heat into its own internal copper island.
    fan("U4", "EFUSE_RTN", ((0, -2.25), (0, 2.25)))
    fan("U2", "GND", ((0, -2.4), (0, 2.4)))
    island = pcbnew.ZONE(board)
    island.SetLayer(pcbnew.In2_Cu)
    island.SetNet(net("/EFUSE_RTN"))
    island.SetLocalClearance(pcbnew.FromMM(.30))
    island.SetMinThickness(pcbnew.FromMM(.2))
    island.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    island.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    outline = island.Outline()
    outline.NewOutline()
    for xy in ((75, 115), (98, 115), (98, 133), (75, 133)):
        point = vector(xy)
        outline.Append(point.x, point.y)
    board.Add(island)

    def pads(name, source, target, width):
        line(name, pad(*source).GetPosition(), pad(*target).GetPosition(), width=width)

    # Route MODE straight to the PowerPAD on the inside of the lead row.
    # Pin 7 remains open per Figure 69 of the TI application circuit.
    line("EFUSE_RTN", pad("U4", 6).GetPosition(), vector((79.1, 120.975)), width=.28)
    pads("SW", ("U1", 6), ("L1", 1), .45)
    pads("LED_POS", ("U4", 15), ("U4", 16), .46)
    pads("ACC_FUSED", ("U4", 1), ("U4", 2), .46)
    pads("LED_POS", ("U2", 1), ("U2", 2), .46)
    pads("VIN_PROT", ("U1", 4), ("U1", 5), .45)
    for ref, pin, offset in (("U1", 2, -.9), ("C29", 2, -1.05)):
        point = pad(ref, pin).GetPosition()
        x, y = pos(point)
        dest = vector((x + offset, y))
        line("GND", point, dest, width=.36)
        native.via(board, "GND", dest, .65, .30)

    measurements = {}
    for ref, (package, size) in design.EPACKAGES.items():
        loaded = pad(ref, 17).GetSize()
        if pos(loaded) != size:
            raise ValueError(f"{ref} exposed pad differs from TI {package}")
        if any(pos(pad(ref, pin).GetSize()) != (1.5, .45) for pin in range(1, 17)):
            raise ValueError(f"{ref} lead pads differ from TI {package}")
        measurements[ref] = {"package": package, "exposed_pad_xy_mm": size, "lead_pad_xy_mm": [1.5, .45]}
    report["native_packages"] = measurements
    report["native_thermal_vias_per_powerpad"] = 2
    report["native_pin_checks"] = {ref: part["nets"] for ref, part in definitions.items()
                                   if ref in {"J1", "J2", "U1", "U2", "U4", "F1", "F2", "U11", "D9"}}
    write_interfaces(native, out, pcbnew, pad, nominal_3v3=report["three_volt_nominal_v"], module=design.MODULE)
    native.save_json(out / "electrical-screen.json", report)
    native.save_json(out / BASELINE, {"track_segments": native.locked_copper(board),
                                      "vias": illumination_pcb.via_identity(board)})
    with (out / "PCB-BOM.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["ref", "value", "mpn", "footprint", "note", "jlcpcb_part"])
        writer.writeheader()
        for ref, part in definitions.items():
            if part["mpn"]:
                writer.writerow({**{key: part[key] for key in writer.fieldnames[:-1]},
                                 "jlcpcb_part": selected.get(ref, {}).get("code", "")})

    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(str(path), board, True)
    for zone in list(board.Zones()):
        if not zone.GetIsRuleArea():
            board.Remove(zone)
    if not pcbnew.ExportSpecctraDSN(board, str(out / "shield.dsn")):
        raise RuntimeError("Could not export Rev G routing input")
    board.BuildConnectivity()
    classes = {"/" + net: (name, width)
               for name, (width, nets) in WIDTH_CLASSES.items() for net in nets}
    effective = []
    for name in sorted(map(str, board.GetNetsByName())):
        if name:
            class_name, width = classes.get(name, ("Default", .20))
            effective.append({"net": name, "class": class_name, "width_mm": width, "clearance_mm": .19})
    native.base.bind_dsn_rules(out, effective)
    route = out / "shield.dsn"
    route.write_text(route.read_text().replace("(clearance 270)", "(clearance 190)")
                     .replace("(width 250) (clearance 190)", "(width 200) (clearance 190)"))


def import_route(native, out):
    board = illumination_pcb.import_route(native, out, name=design.NAME, baseline_file=BASELINE)
    pcbnew = native.pcbnew
    widths = {}
    lengths = {}
    for t in board.GetTracks():
        if t.GetClass() != "PCB_TRACK":
            continue
        name = t.GetNetname().removeprefix("/")
        width = pcbnew.ToMM(t.GetWidth())
        widths[name] = min(widths.get(name, width), width)
        lengths[name] = lengths.get(name, 0) + pcbnew.ToMM(t.GetLength())
    floors = {net: width for width, nets in WIDTH_CLASSES.values() for net in nets} | {"VEH_ACC": 1.5}
    if any(widths.get(net, 0) + .001 < limit for net, limit in floors.items()):
        raise ValueError(f"Rev G current-carrying trace below design width: {widths}")
    native.save_json(out / "power-route-widths.json",
                     {net: {"min_track_mm": widths[net], "total_track_mm": round(lengths[net], 3)} for net in sorted(floors)})
