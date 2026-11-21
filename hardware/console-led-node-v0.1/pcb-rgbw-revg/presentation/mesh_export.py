"""Read the released FreeCAD assembly and tessellate its exact solids."""
import gzip
import json
from pathlib import Path
import FreeCAD as App
import Part


source = Path(INPUT)
out = Path(OUT)
doc = App.openDocument(str(source / "assembly.FCStd"))
rows = []


def add(name, shape, material, group, provenance):
    vertices, triangles = shape.tessellate(.09)
    if not vertices or not triangles:
        raise ValueError("Empty mesh " + name)
    rows.append({
        "name": name, "material": material, "group": group, "provenance": provenance,
        "vertices": [[round(p.x, 5), round(p.y, 5), round(p.z, 5)] for p in vertices],
        "triangles": triangles,
        "bounds": [shape.BoundBox.XMin, shape.BoundBox.YMin, shape.BoundBox.ZMin,
                   shape.BoundBox.XMax, shape.BoundBox.YMax, shape.BoundBox.ZMax],
    })


board = doc.getObject("Shield").Shape
substrates = [s for s in board.Solids if s.BoundBox.XLength > 100 and 1.4 < s.BoundBox.ZLength < 1.8]
if len(substrates) != 1:
    raise ValueError("Expected one board substrate")
datum = substrates[0].BoundBox
for index, solid in enumerate(board.Solids):
    b = solid.BoundBox
    material = "substrate" if solid.isSame(substrates[0]) else "chip"
    if material == "chip":
        if b.XLength > 17 and b.XMax > datum.XMax - 26 and b.ZMax > datum.ZMax + 1:
            material = "rf_metal"
        elif b.XLength > 6 and b.YLength > 6 and b.ZLength > 3.5:
            material = "inductor"
        elif b.ZLength < .38:
            material = "solder"
        elif b.XLength < 3 and b.YLength < 3:
            material = "ceramic" if b.XLength > 1.3 and b.ZLength > .65 else "chip"
    add("PCB_" + str(index), solid, material, "board", "Released KiCad assembly")
for group in (doc.Print, doc.Hardware, doc.WireMount):
    for obj in group.Group:
        name = obj.Name
        if name == "Shield" or name.endswith("Disconnect"):
            continue
        mat = "shell"
        role = "base"
        if name == "Lid":
            mat, role = "lid", "lid"
        elif name == "GlandPlate":
            mat, role = "plate", "plate"
        elif name.startswith("F"):
            mat, role = "fuse", "board"
        elif name.endswith(("Body", "Nut")):
            mat, role = "gland", "plate"
        elif name.endswith("Jacket"):
            mat, role = "cable", "plate"
        add(name, obj.Shape, mat, role, "Released FreeCAD assembly")
vendors = {}
for name in ("Molex_430200401.step", "Molex_430250400.step", "Molex_430200601.step",
             "Molex_430250600.step", "Yazaki_7282-1060.stp", "Yazaki_7183-6322.step",
             "ruthex_RX-M3x5_7.stp"):
    shape = Part.Shape()
    shape.read(str(source / name))
    if shape.isNull() or not shape.isValid():
        raise ValueError("Invalid reference geometry " + name)
    before = len(rows)
    add(name, shape, "connector" if name.startswith("Molex") else "nylon", "reference", "Manufacturer CAD")
    vendors[name] = before
payload = {
    "units": "mm", "physical_validation": False, "parts": rows, "vendor_index": vendors,
    "board_bounds": [datum.XMin, datum.YMin, datum.ZMin, datum.XMax, datum.YMax, datum.ZMax],
    "tools": json.loads((source / "gland-fit.json").read_text())["tool_axes"],
    "glands": json.loads((source / "gland-fit.json").read_text())["glands"],
}
with gzip.open(str(out / "meshes.json.gz"), "wt", encoding="utf-8") as stream:
    json.dump(payload, stream, separators=(",", ":"))
App.closeDocument(doc.Name)
print(len(rows), "CAD meshes exported")
