"""Export actual Rev G KiCad pad, track and component positions for presentation."""
import json
from pathlib import Path
import sys
import pcbnew


board = pcbnew.LoadBoard(sys.argv[1])
footprints, pads, tracks = [], [], []


def xy(vector):
    return [pcbnew.ToMM(vector.x), pcbnew.ToMM(vector.y)]


for fp in board.GetFootprints():
    ref = fp.GetReference()
    footprints.append({"ref": ref, "value": fp.GetValue(), "xy": xy(fp.GetPosition()),
                       "rotation": fp.GetOrientationDegrees()})
    for pad in fp.Pads():
        pads.append({"ref": ref, "number": pad.GetNumber(), "net": pad.GetNetname(),
                     "xy": xy(pad.GetPosition()), "size": xy(pad.GetSize()),
                     "rotation": pad.GetOrientationDegrees(), "shape": int(pad.GetShape()),
                     "drill": xy(pad.GetDrillSize())})
for track in board.GetTracks():
    if track.GetLayerName() != "F.Cu":
        continue
    if isinstance(track, pcbnew.PCB_VIA):
        continue
    tracks.append({"start": xy(track.GetStart()), "end": xy(track.GetEnd()),
                   "width": pcbnew.ToMM(track.GetWidth()), "net": track.GetNetname()})
Path(sys.argv[2]).write_text(json.dumps({"footprints": footprints, "pads": pads, "tracks": tracks}) + "\n")
