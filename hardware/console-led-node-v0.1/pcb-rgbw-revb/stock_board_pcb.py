"""Apply Rev F parts and local routing to the checked Rev E native PCB."""

from collections import Counter
import csv
import json
from pathlib import Path
import shutil

from illumination_pcb import load, via_identity
from single_board_pcb import write_interfaces
import single_board as rev_e
import stock_board as rev_f


def stage(inputs, out):
    for ext in ("kicad_pcb", "kicad_pro"):
        shutil.copyfile(inputs / f"{rev_e.NAME}.{ext}", out / f"{rev_f.NAME}.{ext}")
    for name in ("VHOS_RevB.pretty", "models"):
        shutil.copytree(inputs / name, out / name)
    for component in rev_f.LAND_PATTERNS:
        footprint = component + ".kicad_mod"
        shutil.copyfile(Path(__file__).with_name(footprint), out / "VHOS_RevB.pretty" / footprint)
    shutil.copyfile(inputs / "fp-lib-table", out / "fp-lib-table")
    path = out / f"{rev_f.NAME}.kicad_pro"
    project = json.loads(path.read_text())
    project["meta"]["filename"] = path.name
    path.write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")


def segments(board):
    return Counter((str(track.GetNetname()), int(track.GetLayer()),
                    tuple(sorted((tuple(track.GetStart()), tuple(track.GetEnd())))), track.GetWidth())
                   for track in board.GetTracks() if track.GetClass() == "PCB_TRACK")


def build(native, out):
    pcbnew = native.pcbnew
    board, path = load(native, out, name=rev_f.NAME)
    before, vias_before = segments(board), via_identity(board)
    definitions = rev_f.parts()
    sheet = native.schematic(definitions, out, name=rev_f.NAME, title=rev_f.TITLE, rev="F")
    footprints = {str(fp.GetReference()): fp for fp in board.GetFootprints()}
    if set(footprints) != {part["ref"] for part in definitions}:
        raise ValueError("Rev E native footprint set changed")

    def pad(ref, number):
        return next(p for p in footprints[ref].Pads() if p.GetNumber() == str(number))

    replacements = {}
    for part in definitions:
        ref = part["ref"]
        footprint = footprints[ref]
        if ref in rev_f.FOOTPRINTS:
            new, _ = native.load_footprint(part, out)
            land = rev_f.LAND_PATTERNS[part["footprint"].split(":")[-1]]
            ordered = sorted(new.Pads(), key=lambda p: p.GetNumber())
            dimensions = [tuple(pcbnew.ToMM(axis) for axis in p.GetSize()) for p in ordered]
            centers = [tuple(pcbnew.ToMM(axis) for axis in p.GetPosition()) for p in ordered]
            if (tuple(centers) != tuple((x, 0) for x in land["centers_x_mm"])
                    or dimensions != [land["size_xy_mm"]] * len(ordered)):
                raise ValueError(f"{ref} does not match the manufacturer's land pattern")
            new.SetReference(ref)
            new.SetPosition(footprint.GetPosition())
            new.SetOrientationDegrees(footprint.GetOrientationDegrees())
            new.SetPath(pcbnew.KIID_PATH("/" + sheet + "/" + native.uid(ref)))
            for field in (new.Reference(), new.Value()):
                field.SetLayer(pcbnew.F_Fab)
            endpoints = {str(p.GetNumber()): p.GetPosition() for p in footprint.Pads()}
            footprints[ref] = new
            local_width = .8 if ref == "L1" else .2
            for replacement_pad in new.Pads():
                number = str(replacement_pad.GetNumber())
                net = part["nets"][number]
                replacement_pad.SetNet(board.FindNet("/" + net))
                native.copper(board, net, [endpoints[number], replacement_pad.GetPosition()], local_width, pcbnew.F_Cu)
            replacements[ref] = {
                "footprint": part["footprint"], "part_number": part["mpn"], "land_pattern": land,
                "pad_centers_xy_mm": {str(p.GetNumber()): [pcbnew.ToMM(axis) for axis in p.GetPosition()]
                                      for p in new.Pads()},
            }
            board.Delete(footprint)
            board.Add(new)
            footprint = new
        actual = {str(p.GetNumber()): str(p.GetNetname()).removeprefix("/") for p in footprint.Pads()}
        if any(net is not None and net != actual.get(pin) for pin, net in part["nets"].items()):
            raise ValueError(f"{ref} PCB pin assignment differs from the schematic")
        # The stock KiCad land pattern lacks a corresponding model in KiCad 10.
        if ref == "U4":
            model = pcbnew.FP_3DMODEL()
            model.m_Filename = "${KIPRJMOD}/models/TI_DRR0012E.step"
            footprint.Models().clear()
            footprint.Models().push_back(model)
        footprint.SetValue(part["value"])
        if part["mpn"]:
            mpn = footprint.GetField("MPN")
            if mpn is None:
                mpn = pcbnew.PCB_FIELD(footprint, pcbnew.FIELD_T_USER, "MPN")
                mpn.SetVisible(False)
                mpn.SetLayer(pcbnew.F_Fab)
                footprint.Add(mpn)
            mpn.SetText(part["mpn"])

    for drawing in board.GetDrawings():
        if drawing.GetClass() == "PCB_TEXT" and drawing.GetText() == "4RUNNER RGBW E":
            drawing.SetText("4RUNNER RGBW F")
    title = board.GetTitleBlock()
    title.SetRevision("F")
    board.SetTitleBlock(title)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    pcbnew.SaveBoard(str(path), board, True)

    # Audit the saved CAD files so that a successful change preserves the exact
    # routing and via stack outside the three component land patterns.
    saved, _ = load(native, out, name=rev_f.NAME)
    after, vias_after = segments(saved), via_identity(saved)
    if before - after or vias_before != vias_after or sum((after - before).values()) != 6:
        raise ValueError("Unexpected Rev F copper change")
    native.save_json(out / "copper-audit.json", {
        "existing_track_segments_preserved": sum(before.values()), "existing_vias_preserved": len(vias_before),
        "new_top_layer_pad_extensions": 6, "replaced_footprints": replacements,
    })

    expected = {
        "J1": {1: "GND", 2: "VEH_ACC", 3: "TAIL_12V", 4: "DIM_RETURN"},
        "F1": {1: "VEH_ACC", 2: "ACC_FUSED"}, "F2": {1: "LED_POS", 2: "VIN_PROT"},
        "Q5": {1: "ACC_FUSED", 5: "POWER_MID"}, "Q6": {1: "LED_POS", 5: "POWER_MID"},
        "U1": {2: "VIN_PROT"}, "U9": {4: "V5_LOGIC"}, "U11": {2: "ESP_3V3"},
        "D7": {1: "TAIL_CLAMP", 2: "GND"}, "D8": {1: "DIM_CLAMP", 2: "GND"},
    }
    for ref, pins in expected.items():
        if any(str(pad(ref, pin).GetNetname()) != "/" + net for pin, net in pins.items()):
            raise ValueError(f"{ref} failed Rev F safety-related pin check")
    widths = {}
    for name, _, _, width in after:
        net = name.removeprefix("/")
        widths[net] = min(width, widths.get(net, width))
    floors = {"VEH_ACC": 1.5, "VIN_PROT": .8, "SW": .8, "V5_LOGIC": .35, "ESP_3V3": .35, "SW_3V3": .35,
              **{f"LED_{channel}_NEG": 1.0 for channel in "RGBW"}}
    if any(widths[net] < pcbnew.FromMM(mm) for net, mm in floors.items()):
        raise ValueError("A power trace is narrower than the Rev F screen")
    native.save_json(out / "power-route-widths.json", {net: pcbnew.ToMM(widths[net]) for net in floors})
    report = rev_f.electrical_screen()
    report["native_pin_checks"] = expected
    write_interfaces(native, out, pcbnew, pad, nominal_3v3=report["three_volt_nominal_v"])
    native.save_json(out / "electrical-screen.json", report)

    selected = rev_f.selection()
    with (out / "PCB-BOM.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["ref", "value", "mpn", "footprint", "note", "jlcpcb_part"])
        writer.writeheader()
        for part in definitions:
            ref = part["ref"]
            if part["mpn"]:
                writer.writerow({**{key: part[key] for key in writer.fieldnames[:-1]},
                                 "jlcpcb_part": selected.get(ref, {}).get("code", "")})
