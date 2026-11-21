"""Studio stills of the exact exported Rev I assembly, rendered only on Orion."""
import argparse
import gzip
import json
from pathlib import Path
import sys
import bpy
from mathutils import Vector


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args(sys.argv[sys.argv.index("--") + 1:])
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    preferences = bpy.context.preferences.addons["cycles"].preferences
    preferences.compute_device_type = "OPTIX"
    preferences.get_devices()
    devices = [device for device in preferences.devices if device.type == "OPTIX"]
    if not devices:
        raise RuntimeError("The installed Orion OptiX GPU is required for studio stills")
    for device in preferences.devices:
        device.use = device.type == "OPTIX"
    scene.cycles.device = "GPU"
    scene.cycles.samples = 32
    scene.cycles.use_denoising = True
    scene.render.resolution_x, scene.render.resolution_y = 1920, 1200
    scene.render.resolution_percentage = 100
    scene.world.color = (.13, .13, .13)
    scene.view_settings.view_transform = "AgX"
    objects = []
    materials = {}
    with gzip.open(args.root / "inputs/meshes.json.gz", "rt") as stream:
        rows = json.load(stream)
    for row in rows:
        mesh = bpy.data.meshes.new(row["name"])
        mesh.from_pydata([[v * .01 for v in p] for p in row["vertices"]], [], row["triangles"])
        mesh.update()
        obj = bpy.data.objects.new(row["name"], mesh)
        bpy.context.collection.objects.link(obj)
        obj["role"] = row["role"]
        key = tuple(row["color"])
        if key not in materials:
            mat = bpy.data.materials.new(str(key))
            mat.diffuse_color = (*key, 1)
            mat.use_nodes = True
            bsdf = mat.node_tree.nodes.get("Principled BSDF")
            linear = tuple(c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4 for c in key)
            bsdf.inputs["Base Color"].default_value = (*linear, 1)
            bsdf.inputs["Roughness"].default_value = .34
            materials[key] = mat
        obj.data.materials.append(materials[key])
        objects.append(obj)
    # Floor is presentation scenery, excluded from assembly framing checks.
    bpy.ops.mesh.primitive_plane_add(size=200, location=(.8, .38, -.015))
    floor = bpy.context.object
    mat = bpy.data.materials.new("Studio charcoal")
    mat.diffuse_color = (.019, .027, .038, 1)
    floor.data.materials.append(mat)
    for loc, power, size in (((.2, -.7, 2.7), 280, 2.5), ((1.8, .7, 2.0), 200, 1.8), ((-.8, 1.3, 1.3), 130, 1.6)):
        bpy.ops.object.light_add(type="AREA", location=loc)
        light = bpy.context.object
        light.data.energy, light.data.shape, light.data.size = power, "DISK", size
        light.rotation_euler = (Vector((.85, .38, .15)) - light.location).to_track_quat("-Z", "Y").to_euler()
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    scene.camera = camera
    camera.data.type = "ORTHO"
    evidence = []
    from bpy_extras.object_utils import world_to_camera_view
    for name, roles, direction in (
        ("01-exterior", {"Lid", "Base", "GlandPlate", "J1Body", "J2Body", "J1Nut", "J2Nut", "J1Jacket", "J2Jacket",
                          "Screw1", "Screw2", "Screw3", "Screw4"}, (-1, -1.35, 1.0)),
        ("02-wired-inside", None, (-1.0, -1.15, 1.8)),
        ("03-board", {"Shield"}, (0, -.12, 2)),
    ):
        visible = []
        for obj in objects:
            show = obj["role"] in roles if roles else obj["role"] not in {"Lid", "Screw1", "Screw2", "Screw3", "Screw4"}
            obj.hide_render = not show
            if show:
                visible.append(obj)
        vertices = [obj.matrix_world @ Vector(corner) for obj in visible for corner in obj.bound_box]
        low = Vector(tuple(min(p[i] for p in vertices) for i in range(3)))
        high = Vector(tuple(max(p[i] for p in vertices) for i in range(3)))
        center = (low + high) / 2
        camera.location = center + Vector(direction).normalized() * 6
        camera.rotation_euler = (center - camera.location).to_track_quat("-Z", "Y").to_euler()
        bpy.context.view_layer.update()
        local = [camera.matrix_world.inverted() @ p for p in vertices]
        span_x = max(p.x for p in local) - min(p.x for p in local)
        span_y = max(p.y for p in local) - min(p.y for p in local)
        camera.data.ortho_scale = max(span_x, span_y * 1.6) * 1.18
        bpy.context.view_layer.update()
        projected = [world_to_camera_view(scene, camera, p) for p in vertices]
        bounds = [min(p.x for p in projected), min(p.y for p in projected),
                  max(p.x for p in projected), max(p.y for p in projected)]
        passed = all(.025 <= value <= .975 for value in bounds)
        evidence.append({"image": name, "bounds_normalized": bounds, "pass": passed})
        if not passed:
            raise RuntimeError("Clipped assembly bounds")
        scene.render.filepath = str(args.out / (name + ".png"))
        bpy.ops.render.render(write_still=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(args.out / "RevI-Studio.blend"))
    (args.out / "picture-checks.json").write_text(json.dumps({"views": evidence,
        "gpu": [device.name for device in devices], "cad_source": "source-pinned reopened FreeCAD assembly",
        "design_visualization": True}, indent=2) + "\n")


if __name__ == "__main__":
    main()
