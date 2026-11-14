"""Install the ESP32-S3 on the Rev E native four-layer board."""

import csv
import json
import re
import shutil

import illumination as rev_d
import illumination_pcb as inherited
import single_board as rev_e


BASELINE = "retained-copper.json"
MODULE_FILE = "ESP32-S3-WROOM-1.kicad_mod"


def stage(inputs, out, module):
    for ext in ("kicad_pcb", "kicad_pro"):
        shutil.copyfile(inputs / f"{rev_d.NAME}.{ext}", out / f"{rev_e.NAME}.{ext}")
    for name in ("VHOS_RevB.pretty", "models"):
        shutil.copytree(inputs / name, out / name)
    shutil.copyfile(module, out / "models" / module.name)
    path = out / (rev_e.NAME + ".kicad_pro")
    project = json.loads(path.read_text())
    project["meta"]["filename"] = path.name
    project["net_settings"]["classes"].append({
        **project["net_settings"]["classes"][0], "name": "Module supply", "track_width": .35, "priority": 2,
    })
    project["net_settings"]["netclass_patterns"].extend(
        {"pattern": "/" + name, "netclass": "Module supply"} for name in ("ESP_3V3", "SW_3V3"))
    path.write_text(json.dumps(project, indent=2) + "\n")


def build(native, out):
    pcbnew = native.pcbnew
    board, path = inherited.load(native, out, name=rev_e.NAME)
    definitions = rev_e.parts()
    # Retain the native land pattern and keepout. Move the optional 0.2 mm
    # thermal-via pad array out of this variant's footprint so it uses the
    # same standard drills as the rest of the board.
    footprint_path = native.base.LIB / "RF_Module.pretty" / MODULE_FILE
    if native.base.sha(footprint_path) != "04f2cf7af80a4ac5538c4f5e21cdb97dad4932e432a9f9c7938e50467d22cf4b":
        raise ValueError("Unexpected KiCad ESP32-S3 footprint source")
    footprint_text = footprint_path.read_text()
    footprint_text, removed = re.subn(r'\n\t\(pad "41" thru_hole circle\n.*?\n\t\)', '', footprint_text, flags=re.S)
    if removed != 12:
        raise ValueError("Unexpected ESP32-S3 manufacturer footprint via pattern")
    footprint_text = footprint_text.replace("${KICAD10_3DMODEL_DIR}/RF_Module.3dshapes/", "${KIPRJMOD}/models/")

    def antenna_graphic(match):
        shape = match[0]
        if re.search(r'\((start|end) [-.\d]+ -12\.9\)', shape):
            return shape.replace('"F.SilkS"', '"F.Fab"')
        return shape

    footprint_text = re.sub(r'\n\t\(fp_line\n.*?\n\t\)', antenna_graphic, footprint_text, flags=re.S)
    (out / "VHOS_RevB.pretty" / MODULE_FILE).write_text(footprint_text)
    sheet = native.schematic(definitions, out, name=rev_e.NAME, title=rev_e.TITLE, rev="E")
    run_jumper_escape = native.xy(rev_e.board_xy((133.5, 144.14)))
    run_jumper_pad = native.xy(rev_e.board_xy((133.5, 146.94)))
    for track in list(board.GetTracks()):
        name = str(track.GetNetname()).removeprefix("/")
        bounds = track.GetBoundingBox()
        jumper_stub = name == "V5_LOGIC" and track.GetClass() == "PCB_TRACK" and any(
            p in (run_jumper_escape, run_jumper_pad) for p in (track.GetStart(), track.GetEnd()))
        if name in rev_e.REROUTE or jumper_stub or (name == "GND" and bounds.GetRight() > pcbnew.FromMM(141)):
            board.Delete(track)
        else:
            track.SetLocked(True)
    for zone in list(board.Zones()):
        board.Delete(zone)
    for item in list(board.GetDrawings()):
        if item.GetLayer() == pcbnew.Edge_Cuts:
            board.Delete(item)
        elif item.GetClass() == "PCB_TEXT" and "4RUNNER RGBW" in item.GetText():
            item.SetText("4RUNNER RGBW E")
        elif item.GetClass() == "PCB_TEXT" and item.GetText() == "5V RUN":
            board.Delete(item)

    def xy(position):
        return native.xy(rev_e.board_xy(position))

    outline = [rev_e.board_xy(point) for point in rev_e.OUTLINE]
    for first, second in zip(outline, outline[1:] + outline[:1]):
        edge = pcbnew.PCB_SHAPE(board)
        edge.SetShape(pcbnew.SHAPE_T_SEGMENT)
        edge.SetLayer(pcbnew.Edge_Cuts)
        edge.SetStart(native.xy(first))
        edge.SetEnd(native.xy(second))
        edge.SetWidth(pcbnew.FromMM(.05))
        board.Add(edge)

    footprints = {}
    for fp in list(board.GetFootprints()):
        ref = fp.GetReference()
        if ref in rev_e.REMOVED:
            board.Delete(fp)
        else:
            footprints[ref] = fp

    def net(name):
        item = board.FindNet("/" + name)
        if item is None:
            item = pcbnew.NETINFO_ITEM(board, "/" + name)
            board.Add(item)
        return item

    libraries = {}
    for part in definitions:
        ref = part["ref"]
        lib = part["footprint"].split(":", 1)[0]
        path_var = "${KIPRJMOD}" if lib == "VHOS_RevB" else "${KICAD10_FOOTPRINT_DIR}"
        libraries[lib] = f"{path_var}/{lib}.pretty"
        if ref in footprints:
            footprint = footprints[ref]
        else:
            footprint, _ = native.load_footprint(part, out)
            footprint.SetReference(ref)
            footprint.SetValue(part["value"])
            footprint.SetLayer(pcbnew.F_Cu)
            footprint.SetPosition(native.xy(part["xy_mm"]))
            footprint.SetOrientationDegrees(part["angle_deg"])
            footprint.SetPath(pcbnew.KIID_PATH("/" + sheet + "/" + native.uid(ref)))
            for field in (footprint.Reference(), footprint.Value()):
                field.SetLayer(pcbnew.F_Fab)
            mpn = pcbnew.PCB_FIELD(footprint, pcbnew.FIELD_T_USER, "MPN")
            mpn.SetText(part["mpn"] or "PCB FEATURE")
            mpn.SetVisible(False)
            mpn.SetLayer(pcbnew.F_Fab)
            footprint.Add(mpn)
            board.Add(footprint)
            footprints[ref] = footprint
        for pad in footprint.Pads():
            name = part["nets"].get(pad.GetNumber())
            if name:
                pad.SetNet(net(name))
            elif ref == "U11" and pad.GetNumber():
                number = pad.GetNumber()
                no_connect = pcbnew.NETINFO_ITEM(board, f'unconnected-(U11-{part["pin_names"][number]}-Pad{number})')
                board.Add(no_connect)
                pad.SetNet(no_connect)

    module = footprints["U11"]
    valid_pads = {p.GetNumber() for p in module.Pads() if p.GetNumber()}
    if valid_pads != set(map(str, rev_e.PIN_NAMES)):
        raise RuntimeError("ESP32-S3 native footprint pad set differs from the datasheet")

    def pad(ref, number):
        return next(p for p in footprints[ref].Pads() if p.GetNumber() == str(number))

    def top(name, *refs, width=.35):
        native.copper(board, name, [pad(ref, pin).GetPosition() for ref, pin in refs], width, pcbnew.F_Cu)

    # Keep the 3.3 V switch node and regulator feedback local. One small
    # GND via below the module connects the exposed pad and ESP32 return.
    top("SW_3V3", ("U9", 3), ("L2", 1))
    top("ESP_3V3", ("L2", 2), ("C23", 1))
    top("FB_3V3", ("R35", 1), ("R34", 2), width=.2)
    gnd = pad("U11", 41).GetPosition()
    via_site = xy((158.8, 129.5))
    native.copper(board, "GND", [gnd, via_site], .45, pcbnew.F_Cu)
    native.via(board, "GND", via_site, .70, .30)

    for ref, text in (("TP9", "GND"), ("TP10", "TX"), ("TP11", "RX"),
                      ("TP12", "BOOT"), ("TP13", "EN"), ("TP14", "3V3")):
        _, (x, y) = rev_e.PROGRAM_PADS[ref]
        native.base.text(board, text, rev_e.board_xy((x, y + (-1.85 if ref != "TP14" else 1.85))), .80)
    native.base.text(board, "ESP32-S3", rev_e.board_xy((162.5, 101.3)), .85)
    title = board.GetTitleBlock()
    title.SetTitle(rev_e.TITLE)
    title.SetRevision("E")
    board.SetTitleBlock(title)
    for layer in (pcbnew.F_Cu, pcbnew.In1_Cu, pcbnew.B_Cu):
        native.base.ground_zone(board, layer, outline)
    for zone in board.Zones():
        zone.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)

    native.save_json(out / BASELINE, {"track_segments": native.locked_copper(board),
                                      "vias": inherited.via_identity(board)})
    write_interfaces(native, out, pcbnew, pad)
    table = ''.join(f'(lib (name "{lib}") (type "KiCad") (uri "{path}") (options "") (descr "Rev E"))'
                    for lib, path in sorted(libraries.items()))
    (out / "fp-lib-table").write_text(f"(fp_lib_table {table})", encoding="utf-8")
    with (out / "PCB-BOM.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["ref", "value", "mpn", "footprint", "note"])
        writer.writeheader()
        writer.writerows({key: part[key] for key in writer.fieldnames} for part in definitions if part["mpn"])

    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(str(path), board, True)
    for zone in list(board.Zones()):
        if not zone.GetIsRuleArea():
            board.Remove(zone)
    if not pcbnew.ExportSpecctraDSN(board, str(out / "shield.dsn")):
        raise RuntimeError("Could not export the Rev E routing input")
    board.BuildConnectivity()
    # Preserve the existing fused load routes. Size the new module feed at
    # 0.35 mm, including the new branch off the retained 5 V distribution.
    module_supply = {"/ESP_3V3", "/SW_3V3", "/V5_LOGIC"}
    effective = [{"net": name, "class": "ModuleSupply" if name in module_supply else "Default",
                  "width_mm": .35 if name in module_supply else .20, "clearance_mm": .19}
                 for name in sorted(map(str, board.GetNetsByName())) if name]
    native.base.bind_dsn_rules(out, effective)
    route = out / "shield.dsn"
    route.write_text(route.read_text().replace("(clearance 270)", "(clearance 190)")
                     .replace("(width 250) (clearance 190)", "(width 200) (clearance 190)"))


def write_interfaces(native, out, pcbnew, pad, *, nominal_3v3=.6 * (1 + 453 / 100)):
    receipt = {}
    for number, row in rev_d.BRANCH.items():
        p = pad("J1", number)
        centers = [round(pcbnew.ToMM(axis), 5) for axis in p.GetPosition()]
        if centers != row["xy_mm"] or str(p.GetNetname()) != "/" + row["net"]:
            raise ValueError(f"J1-{number} changed from the Rev D harness")
        receipt[number] = {**row, "drill_mm": pcbnew.ToMM(p.GetDrillSize().x)}
    native.save_json(out / "harness-pads.json", {"J1": {"pads": receipt},
                     "factory_loop": "1:1 through all six cavities", "vehicle_cavities_physically_verified": False})
    led_exit = {"1": "LED_R_NEG", "2": "LED_G_NEG", "3": "LED_B_NEG", "4": "LED_POS", "5": "LED_W_NEG"}
    output_pads = {number: {"net": str(pad("J2", number).GetNetname()).removeprefix("/"), "xy_mm": [
        round(pcbnew.ToMM(axis), 5) for axis in pad("J2", number).GetPosition()]} for number in led_exit}
    if {number: entry["net"] for number, entry in output_pads.items()} != led_exit:
        raise ValueError("J2 no longer matches the five-wire lighting interface")
    native.save_json(out / "wiring-interfaces.json", {
        "factory_tee": {str(number): {"through_to": number} for number in range(1, 7)},
        "reserve_tails": {"3": "IR1-3 TAIL", "4": "IR1-4 DIM"}, "J1": receipt, "J2": output_pads,
        "pod_contacts_physically_verified": False,
    })
    native.save_json(out / "controller-interface.json", {
        "board_outline_top_view_mm": rev_e.OUTLINE, "mounting_holes_top_view_mm": rev_e.MOUNTS,
        "module": rev_e.MODULE, "module_origin_top_view_mm": rev_e.MODULE_XY, "module_pin_nets": rev_e.MODULE_NETS,
        "service_pads": rev_e.PROGRAM_PADS, "3v3_nominal_v": nominal_3v3,
        "production_electrical_or_rf_verified": False,
    })

def import_route(native, out):
    board = inherited.import_route(native, out, name=rev_e.NAME, baseline_file=BASELINE)
    pcbnew = native.pcbnew
    if any(board.FindFootprintByReference(ref) is not None for ref in ("H1", "H2", "H3", "H4", "JP1")):
        raise RuntimeError("Rev E still includes a board interconnect")
    limits = (rev_e.BOARD_EDGE_X, *rev_e.MODULE_XY)
    edge_x, _, module_y = (pcbnew.FromMM(value) for value in limits)
    overhang_zone = pcbnew.BOX2I(pcbnew.VECTOR2I(edge_x, module_y - pcbnew.FromMM(24)),
                                pcbnew.VECTOR2I(pcbnew.FromMM(21), pcbnew.FromMM(48)))
    if any(track.GetBoundingBox().Intersects(overhang_zone) for track in board.GetTracks()):
        raise RuntimeError("Copper enters the ESP32 antenna overhang")
    widths = {}
    for track in board.GetTracks():
        if track.GetClass() == "PCB_TRACK":
            name = str(track.GetNetname()).removeprefix("/")
            width = pcbnew.ToMM(track.GetWidth())
            widths[name] = min(width, widths.get(name, width))
    native.save_json(out / "power-route-widths.json", {name: widths[name] for name in
                     ("VEH_ACC", "ACC_FUSED", "LED_POS", "V5_LOGIC", "ESP_3V3", "SW_3V3")})
