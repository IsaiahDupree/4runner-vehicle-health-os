"""Native KiCad change limited to the external termination interface."""
import csv
import json
from pathlib import Path
import shutil
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import terminal_design as design
import native_pcb as native
import illumination_pcb
import lean_board_pcb
import pcbnew
native.pcbnew = pcbnew
native.base.pcbnew = pcbnew


def build(out):
    pcbnew = native.pcbnew
    inputs = design.ROOT / "inputs"
    for ext in ("kicad_pcb", "kicad_pro"):
        shutil.copyfile(inputs / f"vhos_rgbw_revg.{ext}", out / f"{design.NAME}.{ext}")
    for name in ("VHOS_RevB.pretty", "models"):
        shutil.copytree(inputs / name, out / name)
    shutil.copyfile(inputs / "fp-lib-table", out / "fp-lib-table")
    shutil.copyfile(design.ROOT / "prepared/KEFA_KF128_5.08_2P.step",
                    out / "models/KEFA_KF128_5.08_2P.step")
    (out / "VHOS_RevB.pretty/KEFA_KF128_5.08_2P.kicad_mod").write_text(design.footprint_text())
    project = out / f"{design.NAME}.kicad_pro"
    data = json.loads(project.read_text())
    data["meta"]["filename"] = project.name
    project.write_text(json.dumps(data, indent=2) + "\n")
    board, path = illumination_pcb.load(native, out, name=design.NAME)
    print("Native KiCad", pcbnew.GetBuildVersion(), pcbnew.__file__, type(board), flush=True)
    print("Original tracks", len(board.GetTracks()), flush=True)
    # Enlarge only the bare board outline into the existing front service bay.
    # The main circuit and antenna edge retain their positions.
    for drawing in list(board.GetDrawings()):
        if drawing.GetLayer() == pcbnew.Edge_Cuts:
            board.Delete(drawing)
    vertices = [(36, 94.17), (169, 94.17), (169, 159.17), (36, 159.17)]
    for a, b in zip(vertices, vertices[1:] + vertices[:1]):
        edge = pcbnew.PCB_SHAPE(board)
        edge.SetShape(pcbnew.SHAPE_T_SEGMENT)
        edge.SetLayer(pcbnew.Edge_Cuts)
        edge.SetStart(native.xy(design.single_board.board_xy(a)))
        edge.SetEnd(native.xy(design.single_board.board_xy(b)))
        edge.SetWidth(pcbnew.FromMM(.05))
        board.Add(edge)
    print("Tracks after outline", len(board.GetTracks()), flush=True)
    definitions = {p["ref"]: p for p in design.parts()}
    # Reuse the exact G page structure; its electrical net labels are unchanged.
    sheet = native.schematic(definitions.values(), out, name=design.NAME, title=design.TITLE, rev="G")
    sch = out / f"{design.NAME}.kicad_sch"
    sch.write_text(sch.read_text().replace('(rev "G")', '(rev "H")'))
    changed = {"/" + net for net in design.CONNECTOR_NETS} | {"/TAIL_CLAMP"}
    removed = []
    for track in list(board.GetTracks()):
        name = str(track.GetNetname())
        old_ground_entry = name == "/GND" and track.GetClass() == "PCB_TRACK" and any(
            (pcbnew.ToMM(point.x) < 70 and pcbnew.ToMM(point.y) < 117) or
            ((pcbnew.ToMM(point.x) - 53.7) ** 2 + (pcbnew.ToMM(point.y) - 128.7) ** 2 < 2.6 ** 2)
            for point in (track.GetStart(), track.GetEnd()))
        # Preserve local ground and both PowerPAD thermal vias; only detach the
        # old ground wire-entry stub. Other affected interface nets are rerouted.
        if name in changed and (name != "/GND" or old_ground_entry):
            removed.append(track.GetNetname())
            board.Delete(track)
        else:
            track.SetLocked(True)
    baseline = {"track_segments": native.locked_copper(board),
                "vias": illumination_pcb.via_identity(board)}
    for fp in list(board.GetFootprints()):
        if fp.GetReference() in {"J1", "J2"}:
            board.Delete(fp)
    footprints = {fp.GetReference(): fp for fp in board.GetFootprints()}
    for ref in ("F1", "F2"):
        footprints[ref].GetField("MPN").SetText("3568-10")
    # Move the front PCB fastener to clear the staggered LED bank; its case pillar is rebuilt
    # in the same revision so the washer clears the terminal bank.
    footprints["MH1"].SetPosition(native.xy((-41, 2.67)))
    definitions["MH1"]["xy_mm"] = [-41, 2.67]
    footprints["D7"].SetPosition(native.xy(definitions["D7"]["xy_mm"]))
    rows = []
    for ref, xy, nets, labels, cavities in design.TERMINALS:
        part = definitions[ref]
        fp, _ = native.load_footprint(part, out)
        fp.SetReference(ref)
        fp.SetValue(part["value"])
        mpn = pcbnew.PCB_FIELD(fp, pcbnew.FIELD_T_USER, "MPN")
        mpn.SetText(design.MPN)
        mpn.SetVisible(False)
        mpn.SetLayer(pcbnew.F_Fab)
        fp.Add(mpn)
        fp.SetPosition(native.xy(part["xy_mm"]))
        fp.SetOrientationDegrees(-90)
        fp.SetPath(pcbnew.KIID_PATH("/" + sheet + "/" + native.uid(ref)))
        for field in (fp.Reference(), fp.Value()):
            field.SetLayer(pcbnew.F_Fab)
        board.Add(fp)
        for number, net_name in enumerate(nets, 1):
            p = next(p for p in fp.Pads() if p.GetNumber() == str(number))
            name = "/" + net_name if net_name else f"unconnected-({ref}-{labels[number - 1]}-Pad{number})"
            net = board.FindNet(name)
            if net is None:
                net = pcbnew.NETINFO_ITEM(board, name)
                board.Add(net)
            p.SetNet(net)
            coords = [pcbnew.ToMM(p.GetPosition().x), pcbnew.ToMM(p.GetPosition().y)]
            rows.append({"ref": ref, "pin": number, "label": labels[number - 1],
                         "vehicle_cavity": cavities[number - 1], "net": net_name,
                         "pcb_xy_mm": coords, "case_xy_mm": design.case_xy(coords),
                         "drill_mm": pcbnew.ToMM(p.GetDrillSize().x)})
        # Keep labels visible behind each two-position body, away from its wire opening.
        native.base.text(board, ref + " " + " / ".join(labels),
                         (37.7 - 100, 153.34 - xy[1] - 2.54), .8)
        label_item = next(t for t in board.GetDrawings() if t.GetClass() == "PCB_TEXT" and t.GetText() == ref + " " + " / ".join(labels))
        label_item.SetTextAngle(pcbnew.EDA_ANGLE(90, pcbnew.DEGREES_T))
    # Remove obsolete wire-pad labels; retain every test point label.
    for item in list(board.GetDrawings()):
        if item.GetClass() == "PCB_TEXT":
            label = item.GetText()
            if label in {"TOYOTA IR1 IN", "RGBW OUT", "GND", "ACC", "TAIL", "DIM", "+12V", "R", "G", "B", "W", "R-", "G-", "B-", "W-"}:
                board.Delete(item)
            elif label == "4RUNNER RGBW G":
                item.SetText("4RUNNER RGBW H")
                item.SetPosition(native.xy((6, 5)))
    title = board.GetTitleBlock()
    title.SetRevision("H")
    title.SetTitle(design.TITLE)
    board.SetTitleBlock(title)
    # Prove all retained parts still have the exact schematic pad net assignments.
    for ref, part in definitions.items():
        if ref.startswith("JT"):
            continue
        fp = footprints[ref]
        for pad in fp.Pads():
            n = part["nets"].get(pad.GetNumber())
            if n and pad.GetNetname() != "/" + n:
                raise ValueError(f"Changed existing circuit: {ref}.{pad.GetNumber()}")
    native.save_json(out / "terminal-map.json", {"terminals": rows, "jlcpcb": design.CODE,
                                                 "mpn": design.MPN, "board_count": 1})
    native.save_json(out / "regh-route-baseline.json", baseline)
    native.save_json(out / "electrical-screen.json", design.lean_board.electrical_screen())
    native.save_json(out / "interface-change.json", {
        "removed_wire_pad_footprints": ["J1", "J2"], "added_factory_terminal_blocks": 6,
        "only_rerouted_nets": sorted(changed), "retained_circuit_parts": len(footprints),
        "protected_copper_segments": len(baseline["track_segments"]),
        "protected_vias": len(baseline["vias"]), "removed_interface_segments_and_vias": len(removed)})
    # Capture native pad-net identities before removing zones for the router.
    # Removing zone objects invalidates KiCad's cached NETINFO_LIST wrappers.
    native_nets = {str(p.GetNetname()) for fp in board.GetFootprints() for p in fp.Pads() if p.GetNetname()}
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(str(path), board, True)
    for zone in list(board.Zones()):
        if not zone.GetIsRuleArea():
            board.Remove(zone)
    if not pcbnew.ExportSpecctraDSN(board, str(out / "shield.dsn")):
        raise RuntimeError("Cannot export routing input")
    widths = {"/" + net: width for width, names in lean_board_pcb.WIDTH_CLASSES.values() for net in names}
    widths["/VEH_ACC"] = 1.5
    rules = [{"net": str(n), "class": "Width_" + str(widths.get(str(n), .2)),
              "width_mm": widths.get(str(n), .2), "clearance_mm": .19}
             for n in sorted(native_nets)]
    native.base.bind_dsn_rules(out, rules)
    route = out / "shield.dsn"
    route.write_text(route.read_text().replace("(clearance 270)", "(clearance 190)")
                     .replace("(width 250) (clearance 190)", "(width 200) (clearance 190)"))


def finish(out):
    board = illumination_pcb.import_route(native, out, name=design.NAME, baseline_file="regh-route-baseline.json")
    p = native.pcbnew
    rows = []
    for fp in board.GetFootprints():
        ref = fp.GetReference()
        if not ref.startswith("JT"):
            continue
        for pad in fp.Pads():
            isolated = pad.GetNetname().startswith("unconnected-")
            tracks = [t for t in board.GetTracks() if t.GetNetCode() == pad.GetNetCode()]
            rows.append({"ref": ref, "pin": pad.GetNumber(), "isolated": isolated,
                         "track_and_via_count": len(tracks),
                         "pass": not isolated or len(tracks) == 0})
    widths = {}
    for track in board.GetTracks():
        if track.GetClass() == "PCB_TRACK":
            n = str(track.GetNetname())
            widths[n] = min(widths.get(n, 100), p.ToMM(track.GetWidth()))
    required = {"/" + n: w for w, names in lean_board_pcb.WIDTH_CLASSES.values() for n in names}
    required["/VEH_ACC"] = 1.5
    if any(widths.get(n, 0) + .001 < w for n, w in required.items()) or not all(r["pass"] for r in rows):
        native.save_json(out / "failed-width-isolation.json", {"minimums": widths, "required": required, "pads": rows})
        raise RuntimeError("Power-width or reserve-isolation audit failed")
    native.save_json(out / "terminal-electrical-audit.json", {"pads": rows, "minimum_track_widths_mm": widths,
                                                            "required_minimums_mm": required, "passed": True})


def metadata(out):
    """Correct the supplier's exact holder SKU without changing any geometry."""
    inputs = design.ROOT / "inputs/accepted-pcb"
    for path in inputs.iterdir():
        target = out / path.name
        if path.is_dir():
            shutil.copytree(path, target, dirs_exist_ok=True)
        else:
            shutil.copyfile(path, target)
    board, path = illumination_pcb.load(native, out, name=design.NAME)

    def physical_identity(b):
        tracks = sorted([str(t.GetClass()), str(t.GetNetname()), t.GetLayer(),
                         t.GetStart().x, t.GetStart().y, t.GetEnd().x, t.GetEnd().y,
                         t.GetWidth(t.TopLayer()) if t.GetClass() == "PCB_VIA" else t.GetWidth(),
                         t.GetDrillValue() if t.GetClass() == "PCB_VIA" else 0]
                        for t in b.GetTracks())
        return native.base.observation(b), tracks

    before = physical_identity(board)
    changes = []
    for fp in board.GetFootprints():
        if fp.GetReference() in {"F1", "F2"}:
            field = fp.GetField("MPN")
            if field.GetText() not in {"3568", "3568-10"}:
                raise ValueError("Unexpected fuse holder identity")
            changes.append({"ref": fp.GetReference(), "before": field.GetText(), "after": "3568-10"})
            field.SetText("3568-10")
    if len(changes) != 2:
        raise ValueError("Both factory holders required")
    native.schematic(design.parts(), out, name=design.NAME, title=design.TITLE, rev="G")
    sch = out / (design.NAME + ".kicad_sch")
    sch.write_text(sch.read_text().replace('(rev "G")', '(rev "H")'))
    pcbnew.SaveBoard(str(path), board, True)
    after = physical_identity(pcbnew.LoadBoard(str(path)))
    if before != after:
        raise RuntimeError("Metadata normalization changed copper, pads or components")
    import hashlib
    native.save_json(out / "factory-metadata-audit.json", {
        "changed_fields": changes, "all_tracks_vias_pads_and_footprint_poses_unchanged": True,
        "step_reused_exact_sha256": hashlib.sha256((out / "routed_shield.step").read_bytes()).hexdigest(),
        "part_identity": "3568-10 red MINI holder, JLCPCB C3205378", "manufacturing_released": False})


if __name__ == "__main__":
    action, folder = sys.argv[1:]
    {"build": build, "finish": finish, "metadata": metadata}[action](Path(folder))
