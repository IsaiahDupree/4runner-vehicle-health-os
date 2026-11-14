"""Install the Rev D sense circuit on the pinned Rev C KiCad board."""

import csv
import json

import illumination as rev_d


def load(native, out):
    pcbnew = native.pcbnew
    path = out / (rev_d.NAME + ".kicad_pcb")
    board = pcbnew.LoadBoard(str(path))
    manager = pcbnew.GetSettingsManager()
    if not manager.LoadProject(str(out / (rev_d.NAME + ".kicad_pro"))):
        raise RuntimeError("Could not load the Rev D KiCad project")
    board.SetProject(manager.Prj())
    return board, path


def build(native, out):
    pcbnew = native.pcbnew
    board, path = load(native, out)
    definitions = rev_d.parts()
    sheet = native.schematic(definitions, out, name=rev_d.NAME, title=rev_d.TITLE, rev="D")
    footprints = {fp.GetReference(): fp for fp in board.GetFootprints()}

    def net(name):
        item = board.FindNet("/" + name)
        if item is None:
            item = pcbnew.NETINFO_ITEM(board, "/" + name)
            board.Add(item)
        return item

    for part in definitions:
        ref = part["ref"]
        if part["section"] == "sense":
            if ref in footprints:
                raise ValueError(f"{ref} already exists on the Rev C source board")
            footprint, _ = native.load_footprint(part, out)
            footprint.SetReference(ref)
            footprint.SetValue(part["value"])
            footprint.SetLayer(pcbnew.F_Cu)
            footprint.SetPosition(native.xy(part["xy_mm"]))
            footprint.SetPath(pcbnew.KIID_PATH("/" + sheet + "/" + native.uid(ref)))
            for field in (footprint.Reference(), footprint.Value()):
                field.SetLayer(pcbnew.F_Fab)
            mpn = pcbnew.PCB_FIELD(footprint, pcbnew.FIELD_T_USER, "MPN")
            mpn.SetText(part["mpn"])
            mpn.SetVisible(False)
            mpn.SetLayer(pcbnew.F_Fab)
            footprint.Add(mpn)
            board.Add(footprint)
            footprints[ref] = footprint
        else:
            footprint = footprints[ref]
        for pad in footprint.Pads():
            name = part["nets"].get(pad.GetNumber())
            if name:
                pad.SetNet(net(name))

    j1 = footprints["J1"]
    j1.SetValue("TOYOTA IR1 IN")
    j1.SetFPID(pcbnew.LIB_ID("VHOS_RevB", rev_d.J1_NAME))
    for number in ("3", "4"):
        row = rev_d.BRANCH[number]
        pad = pcbnew.PAD(j1)
        pad.SetNumber(number)
        pad.SetPosition(pcbnew.VECTOR2I(*(pcbnew.FromMM(axis) for axis in row["xy_mm"])))
        pad.SetShape(pcbnew.PAD_SHAPE_CIRCLE)
        pad.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
        pad.SetLayerSet(pcbnew.PAD.PTHMask())
        pad.SetSize(pcbnew.VECTOR2I(pcbnew.FromMM(2.25), pcbnew.FromMM(2.25)))
        pad.SetDrillSize(pcbnew.VECTOR2I(pcbnew.FromMM(1.2), pcbnew.FromMM(1.2)))
        pad.SetNet(net(row["net"]))
        j1.Add(pad)
    library = out / "VHOS_RevB.pretty"
    pcbnew.PCB_IO_MGR.FindPlugin(pcbnew.PCB_IO_MGR.KICAD_SEXP).FootprintSave(str(library), j1)
    (library / "Toyota_Power_2_Pads.kicad_mod").unlink()
    for item in board.GetDrawings():
        if item.GetClass() == "PCB_TEXT":
            label = item.GetText()
            if label == "4RUNNER RGBW C":
                item.SetText("4RUNNER RGBW D")
            if label == "TOYOTA POWER IN":
                item.SetText("TOYOTA IR1 IN")
                item.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(65.3), pcbnew.FromMM(104.7)))
            if label == "RGBW OUT":
                item.SetPosition(pcbnew.VECTOR2I(pcbnew.FromMM(68.0), pcbnew.FromMM(140.3)))
            if label in ("+12V", "GND") and pcbnew.ToMM(item.GetPosition().y) < 120:
                item.SetText("ACC" if label == "+12V" else label)
                item.SetPosition(pcbnew.VECTOR2I(item.GetPosition().x, pcbnew.FromMM(108.45)))
    for row in (rev_d.BRANCH["3"], rev_d.BRANCH["4"]):
        px, py = row["xy_mm"]
        native.base.text(board, row["label"], (px - 100, 153.34 - py - 1.9), .8)
    title = board.GetTitleBlock()
    title.SetTitle(rev_d.TITLE)
    title.SetRevision("D")
    board.SetTitleBlock(title)
    for track in board.GetTracks():
        track.SetLocked(True)

    pins = {p.GetNumber(): p for p in j1.Pads()}
    receipt = {}
    for number, row in rev_d.BRANCH.items():
        pad = pins[number]
        centers = [round(pcbnew.ToMM(axis), 5) for axis in pad.GetPosition()]
        if centers != row["xy_mm"] or pad.GetNetname() != "/" + row["net"]:
            raise ValueError(f"J1-{number} does not match its harness definition")
        receipt[number] = {**row, "drill_mm": pcbnew.ToMM(pad.GetDrillSize().x)}
    native.save_json(out / "harness-pads.json", {
        "J1": {"pads": receipt}, "factory_loop": "1:1 through all six cavities",
        "vehicle_cavities_physically_verified": False,
    })
    native.save_json(out / "sense-electrical-screen.json", rev_d.electrical_screen())
    with (out / "PCB-BOM.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["ref", "value", "mpn", "footprint", "note"])
        writer.writeheader()
        writer.writerows({key: part[key] for key in writer.fieldnames} for part in definitions if part["mpn"])
    native.save_json(out / "revd-route-baseline.json", {
        "track_segments": native.locked_copper(board), "vias": via_identity(board),
    })
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(str(path), board, True)
    for zone in list(board.Zones()):
        if zone.GetLayer() in (pcbnew.F_Cu, pcbnew.B_Cu):
            board.Remove(zone)
    if not pcbnew.ExportSpecctraDSN(board, str(out / "shield.dsn")):
        raise RuntimeError("Could not export Rev D routing input")
    board.BuildConnectivity()
    effective = []
    for name, item in board.GetNetsByName().items():
        if not name:
            continue
        netclass = item.GetNetClassSlow()
        effective.append({"net": str(name), "class": str(netclass.GetName()),
                          "width_mm": pcbnew.ToMM(netclass.GetTrackWidth()),
                          "clearance_mm": pcbnew.ToMM(netclass.GetClearance())})
    native.base.bind_dsn_rules(out, effective)
    dsn = out / "shield.dsn"
    dsn.write_text(dsn.read_text().replace("(clearance 270)", "(clearance 190)")
                   .replace("(width 250) (clearance 190)", "(width 200) (clearance 190)"))


def via_identity(board):
    return sorted([str(t.GetNetname()), t.GetPosition().x, t.GetPosition().y, t.GetWidth(t.TopLayer()), t.GetDrillValue()]
                  for t in board.GetTracks() if t.GetClass() == "PCB_VIA")


def import_route(native, out):
    pcbnew = native.pcbnew
    board, path = load(native, out)
    geometry = native.base.observation(board)
    baseline = json.loads((out / "revd-route-baseline.json").read_text())
    if not pcbnew.ImportSpecctraSES(board, str(out / "shield.ses")) or geometry != native.base.observation(board):
        raise RuntimeError("Rev D route import changed footprint identities")

    def segment_key(row):
        net, layer, x1, y1, x2, y2, width = row
        return net, layer, tuple(sorted(((x1, y1), (x2, y2)))), width

    rows = [[str(t.GetNetname()), t.GetLayer(), t.GetStart().x, t.GetStart().y,
             t.GetEnd().x, t.GetEnd().y, t.GetWidth()]
            for t in board.GetTracks() if t.GetClass() == "PCB_TRACK"]
    misses = {segment_key(r) for r in baseline["track_segments"]} - {segment_key(r) for r in rows}
    missing_vias = {tuple(row) for row in baseline["vias"]} - {tuple(row) for row in via_identity(board)}
    if misses or missing_vias:
        raise RuntimeError(f"Router changed {len(misses)} existing tracks and {len(missing_vias)} vias")
    for zone in board.Zones():
        zone.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    pcbnew.SaveBoard(str(path), board, True)
    native.save_json(out / "copper-audit.json", {
        "existing_track_segments_preserved": len(baseline["track_segments"]),
        "existing_vias_preserved": len(baseline["vias"]),
    })
