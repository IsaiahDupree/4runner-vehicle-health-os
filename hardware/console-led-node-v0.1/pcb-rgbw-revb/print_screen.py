"""Audit the oriented Rev B meshes and run one bounded, offline Cura slice per part."""

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from math import acos, degrees, isfinite, sqrt
import os
from pathlib import Path
import platform
import struct
import subprocess
import tempfile


CURA = Path("C:/Program Files/UltiMaker Cura 5.9.0")
ENGINE = CURA / "CuraEngine.exe"
RESOURCES = CURA / "share/cura/resources"
DEFINITION = RESOURCES / "definitions/flsun_v400.def.json"
PROFILE_REGISTRY = Path("C:/orion/control/v400-profiles.json")
PROFILE_ID = "v400-owner-current"
PROFILE_PIN = "f709f82daca287bc36b8ed4ccfd0b652794c97aecaab046259e0a908eb80285a"
RUNTIME_PINS = {
    ENGINE: "4980e6fed2e8e562699d15e14dae0ce02a323069d18d3a54b8ee56696fd83dd5",
    DEFINITION: "ee1611945a05136f311c449118648e46c4010d13ae484cda4435265e287a23e8",
    RESOURCES / "definitions/fdmprinter.def.json": "7c517d0f37616bb5abc442c7f4502da2adf87dc56f445ae966867ae4eadf873e",
    RESOURCES / "definitions/fdmextruder.def.json": "63b347eeb6d5b827b86c19f278010571e09ec6bca0e5030669e6d82be151d332",
    RESOURCES / "extruders/flsun_v400_extruder_0.def.json": "5113ed43f60f838f0d4ef8f0879644b1a476a0bb9c7c375a3cd8c49947d280ae",
}
PARTS = ("case_base", "case_lid", "front_ports_coupon", "front_lid_coupon", "m3_tolerance_coupon")
SETTINGS = {
    "layer_height": "0.2", "layer_height_0": "0.2", "machine_nozzle_size": "0.4",
    "line_width": "0.42", "wall_line_width_0": "0.42", "wall_line_width_x": "0.42",
    "wall_line_count": "5", "wall_thickness": "2.1", "top_layers": "5", "bottom_layers": "5",
    "support_enable": "false", "support_mesh": "false", "adhesion_type": "none",
    "infill_sparse_density": "25", "infill_line_distance": "1.68", "infill_pattern": "grid",
    "speed_print": "45", "speed_wall": "35", "speed_layer_0": "20",
    "material_diameter": "1.75", "material_flow": "100",
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mesh_report(path):
    data = path.read_bytes()
    count = struct.unpack_from("<I", data, 80)[0]
    if count <= 0 or len(data) != 84 + 50 * count:
        raise ValueError(f"invalid binary STL {path.name}")
    edges = defaultdict(list)
    duplicate = Counter()
    bed_z = min(point for row in struct.iter_unpack("<12fH", data[84:]) for point in row[5:12:3])
    bed_area = severe_area = 0.0
    severe_angle = 0.0
    bad_facets = []
    for i, row in enumerate(struct.iter_unpack("<12fH", data[84:])):
        vertices = tuple(tuple(round(value, 5) for value in row[j:j + 3]) for j in (3, 6, 9))
        if not all(isfinite(value) for point in vertices for value in point):
            raise ValueError(f"nonfinite vertex in {path.name}")
        duplicate[tuple(sorted(vertices))] += 1
        for a, b in zip(vertices, (*vertices[1:], vertices[0])):
            edge = tuple(sorted((a, b)))
            edges[edge].append((i, edge == (a, b)))
        a, b, c = vertices
        u, v = [tuple(point[j] - a[j] for j in range(3)) for point in (b, c)]
        nx, ny, nz = u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]
        mag = sqrt(nx * nx + ny * ny + nz * nz)
        if mag < 2e-9 or nz >= 0:
            continue
        area = mag / 2
        if max(abs(point[2] - bed_z) for point in vertices) <= .02:
            bed_area += area
            continue
        # The face's slope relative to the build axis is 0° for a wall.
        angle = 90 - degrees(acos(max(-1, min(1, -nz / mag))))
        severe_angle = max(severe_angle, angle)
        if angle > 45.5:
            severe_area += area
            bad_facets.append((area, [round(sum(p[j] for p in vertices) / 3, 3) for j in range(3)]))
    connected = [set() for _ in range(count)]
    for edge in edges.values():
        if len(edge) == 2:
            a, b = edge
            connected[a[0]].add(b[0])
            connected[b[0]].add(a[0])
    pending, seen = [0], {0}
    while pending:
        for neighbor in connected[pending.pop()] - seen:
            seen.add(neighbor)
            pending.append(neighbor)
    boundary = sum(len(edge) != 2 for edge in edges.values())
    winding = sum(len(edge) == 2 and edge[0][1] == edge[1][1] for edge in edges.values())
    duplicates = sum(n - 1 for n in duplicate.values())
    return {
        "sha256": sha(path), "facets": count, "bed_contact_area_mm2": round(bed_area, 3),
        "maximum_downward_overhang_deg_from_vertical": round(severe_angle, 3),
        "surface_over_45_5_deg_mm2": round(severe_area, 3),
        "largest_steep_facets": sorted(bad_facets, reverse=True)[:5],
        "bad_edge_count": boundary, "inconsistent_winding_edges": winding, "duplicate_facets": duplicates,
        "edge_connected": len(seen) == count,
        "pass": abs(bed_z) < .02 and bed_area > 25 and severe_area < .08 and boundary == winding == duplicates == 0
                and len(seen) == count,
    }


def resolved_profile():
    registry = json.loads(PROFILE_REGISTRY.read_text(encoding="utf-8"))
    record = registry["profiles"][PROFILE_ID]
    path = Path(record["profile"])
    if not path.is_absolute() or path.is_symlink() or sha(path) != PROFILE_PIN or record["profile_sha256"] != PROFILE_PIN:
        raise ValueError("the pinned V400 settings snapshot is required")
    snapshot = json.loads(path.read_text(encoding="utf-8"))
    if snapshot["cura"]["engine_version"] != "5.9.0":
        raise ValueError("the V400 settings do not target CuraEngine 5.9.0")
    return snapshot["resolved_settings"]


def slice_once(path, temp, log, profile):
    from modeling.v400_slice_engine import center_stl_for_delta

    staged = temp / (path.stem + ".gcode")
    centered = temp / path.name
    center_stl_for_delta(path, centered)
    resolved = temp / (path.stem + "-settings.json")
    scopes = {
        "global": {**profile["global"], **SETTINGS, "machine_start_gcode": "", "machine_end_gcode": ""},
        "extruder.0": {**profile["extruders"]["0"], **SETTINGS},
        centered.name: {**profile["model"], **SETTINGS, "extruder_nr": "0"},
    }
    resolved.write_text(json.dumps(scopes), encoding="utf-8")
    resource_paths = os.pathsep.join(str(RESOURCES / name) for name in ("definitions", "extruders"))
    command = [str(ENGINE), "slice", "-m2", "-p", "-d", resource_paths, "-j", str(DEFINITION),
               "-o", str(staged), "-r", str(resolved)]
    result = subprocess.run(command, cwd=temp, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=27)
    log.write_bytes(result.stdout)
    if result.returncode or not staged.is_file():
        return {"exit_code": result.returncode, "pass": False}
    text = staged.read_text(encoding="utf-8")
    types = Counter(line[6:].strip() for line in text.splitlines() if line.startswith(";TYPE:"))
    layers = sum(line.startswith(";LAYER:") for line in text.splitlines())
    support = sum(count for name, count in types.items() if "SUPPORT" in name.upper())
    return {"exit_code": result.returncode, "layer_count": layers, "support_segments": support,
            "wall_segments": types["WALL-OUTER"], "pass": layers > 2 and types["WALL-OUTER"] > 2 and support == 0}


def main(out):
    if platform.system() != "Windows" or platform.node().split(".")[0].casefold() != "orion":
        raise RuntimeError("Orion native print screen required")
    import sys
    sys.path.insert(0, os.environ["ORION_CONSOLE_CONTROL_ROOT"])
    for path, pin in RUNTIME_PINS.items():
        if sha(path) != pin:
            raise ValueError(f"Unexpected Cura geometry screen input {path.name}")
    meshes = {name: mesh_report(out / (name + ".stl")) for name in PARTS}
    observations = out / "mechanical-observation.json"
    subject = json.loads(observations.read_text(encoding="utf-8")).get("contract") if observations.exists() else None
    fit_path = out / "toyota-leads-fit.json"
    if subject is None:
        subject = json.loads(fit_path.read_text(encoding="utf-8"))["contract"] if fit_path.exists() else "vhos_rgbw_revb_durable_case_v1"
    report = {"contract": "vhos_rgbw_revb_support_free_geometry_v1", "subject": subject, "mesh_checks": meshes,
              "printer": "FLSUN V400", "cura_engine": "5.9.0", "settings": SETTINGS,
              "reference_profile_id": PROFILE_ID, "reference_profile_sha256": PROFILE_PIN,
              "runtime_pins": {path.name: pin for path, pin in RUNTIME_PINS.items()},
              "physical_print_verified": False, "gcode_released": False}
    receipt = out / "support-free.json"
    receipt.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if not all(mesh["pass"] for mesh in meshes.values()):
        raise RuntimeError("steep unsupported surfaces or mesh findings; see support-free.json")
    profile = resolved_profile()
    with tempfile.TemporaryDirectory(prefix="vhos-cura-screen-") as name:
        temp = Path(name)
        report["offline_slices"] = {part: slice_once(out / (part + ".stl"), temp, out / (part + "-cura.log"), profile)
                                    for part in PARTS}
    report["supports_disabled_all_parts_passed"] = all(row["pass"] for row in report["offline_slices"].values())
    receipt.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if not report["supports_disabled_all_parts_passed"]:
        raise RuntimeError("Cura failed the bounded supports-off slice; see support-free.json and per-part logs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    main(parser.parse_args().out.resolve())
