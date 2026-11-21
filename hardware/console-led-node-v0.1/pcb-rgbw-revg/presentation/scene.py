"""Render the released Rev G geometry with studio lighting and a six-part explanation."""
import argparse
import gzip
import json
from math import cos, pi, radians, sin
from pathlib import Path
import sys
import time

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector


ap = argparse.ArgumentParser()
ap.add_argument("--stage", choices=("preview", "pictures", "film"), required=True)
ap.add_argument("--root", type=Path, required=True)
ap.add_argument("--output", type=Path, required=True)
args = ap.parse_args(sys.argv[sys.argv.index("--") + 1:])
ROOT, OUT = args.root, args.output
OUT.mkdir(parents=True, exist_ok=True)
with gzip.open(ROOT / "prepared/meshes.json.gz", "rt", encoding="utf-8") as stream:
    DATA = json.load(stream)
BOARD = json.loads((ROOT / "prepared/board-details.json").read_text())
STORY = json.loads((ROOT / "storyboard.json").read_text())
FPS = STORY["fps"]
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = "CYCLES" if args.stage == "pictures" else "BLENDER_EEVEE_NEXT"
scene.cycles.samples = 48 if args.stage == "pictures" else 12
scene.cycles.use_denoising = True
scene.cycles.preview_samples = 8
scene.cycles.max_bounces = 5
scene.cycles.diffuse_bounces = 2
scene.cycles.glossy_bounces = 3
if args.stage != "pictures":
    scene.eevee.taa_render_samples = 32
    scene.eevee.use_raytracing = True
scene.render.threads_mode = "FIXED"
scene.render.threads = 2
preferences = bpy.context.preferences.addons["cycles"].preferences
try:
    preferences.compute_device_type = "OPTIX"
    preferences.get_devices()
    gpu = [d for d in preferences.devices if d.type == "OPTIX"]
    if not gpu:
        raise RuntimeError("The Orion NVIDIA render device is unavailable")
    for device in preferences.devices:
        device.use = device.type == "OPTIX"
    scene.cycles.device = "GPU"
except Exception as exc:
    raise RuntimeError("GPU rendering is required for the Rev G film") from exc
scene.render.resolution_x = 2560 if args.stage == "pictures" else 1920
scene.render.resolution_y = 1440 if args.stage == "pictures" else 1080
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.film_transparent = False
scene.render.fps = FPS
scene.view_settings.view_transform = "AgX"
scene.world.color = (.07, .07, .07)
scene.world.use_nodes = True
scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (.045, .065, .09, 1)
scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = .08


def material(name, color, metal=0, rough=.4, transmission=0):
    value = bpy.data.materials.new(name)
    value.diffuse_color = (*color, 1)
    value.use_nodes = True
    bsdf = value.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Metallic"].default_value = metal
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Transmission Weight"].default_value = transmission
    return value


MATS = {
    "shell": material("Graphite polymer", (.025, .042, .058), rough=.53),
    "lid": material("Blue graphite lid", (.035, .060, .078), rough=.50),
    "plate": material("Gland plate", (.032, .060, .069), rough=.38),
    "substrate": material("Green solder mask", (.012, .095, .061), rough=.32),
    "chip": material("IC molding", (.018, .022, .027), rough=.48),
    "rf_metal": material("ESP32 shield", (.57, .63, .67), metal=.92, rough=.27),
    "solder": material("Lead free solder", (.48, .55, .59), metal=.9, rough=.28),
    "ceramic": material("Ceramic capacitor", (.30, .18, .085), rough=.43),
    "inductor": material("Magnetic components", (.065, .072, .074), metal=.2, rough=.5),
    "fuse": material("MINI fuse body", (.36, .09, .46), rough=.23, transmission=.15),
    "gland": material("Black nylon glands", (.019, .023, .026), rough=.29),
    "cable": material("Elastomer cable", (.014, .018, .022), rough=.5),
    "connector": material("Micro Fit nylon", (.022, .025, .029), rough=.36),
    "nylon": material("Natural nylon", (.75, .72, .59), rough=.43),
    "gold": material("Gold finish", (.65, .39, .095), metal=.85, rough=.25),
    "trace": material("Copper below solder mask", (.014, .125, .077), metal=.15, rough=.38),
    "mint": material("Mint annotation", (.14, .75, .59), metal=.15, rough=.25),
}
for key in ("shell", "lid", "plate"):
    nodes = MATS[key].node_tree.nodes
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 700
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = .12
    bump.inputs["Distance"].default_value = .0007
    MATS[key].node_tree.links.new(noise.outputs["Fac"], bump.inputs["Height"])
    MATS[key].node_tree.links.new(bump.outputs["Normal"], nodes.get("Principled BSDF").inputs["Normal"])

root = bpy.data.objects.new("REV_G", None)
scene.collection.objects.link(root)
root.scale = (.01, .01, .01)
root.location = (-.85, -.38, 0)
groups = {}
for name in ("board", "base", "lid", "plate", "reference", "loom", "graphics"):
    obj = bpy.data.objects.new(name, None)
    scene.collection.objects.link(obj)
    obj.parent = root
    groups[name] = obj
parts = {}
for row in DATA["parts"]:
    mesh = bpy.data.meshes.new(row["name"])
    mesh.from_pydata(row["vertices"], [], row["triangles"])
    mesh.update()
    obj = bpy.data.objects.new(row["name"], mesh)
    scene.collection.objects.link(obj)
    obj.parent = groups[row["group"]]
    obj.data.materials.append(MATS[row["material"]])
    obj["geometry_source"] = row["provenance"]
    parts[row["name"]] = obj
    if row["group"] == "reference":
        obj.hide_render = True
    if row["material"] in ("shell", "lid", "plate", "gland"):
        bevel = obj.modifiers.new("Microscopic edge highlights", "BEVEL")
        bevel.width = .12
        bevel.segments = 2
        bevel.limit_method = "ANGLE"
        bevel.angle_limit = .5


def tube(name, points, width, mat, parent, *, resolution=3):
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.resolution_u = 12
    curve.bevel_depth = width / 2
    curve.bevel_resolution = resolution
    segment = curve.splines.new("BEZIER")
    segment.bezier_points.add(len(points) - 1)
    for point, xyz in zip(segment.bezier_points, points):
        point.co = xyz
        point.handle_left_type = point.handle_right_type = "AUTO"
    obj = bpy.data.objects.new(name, curve)
    scene.collection.objects.link(obj)
    obj.parent = parent
    obj.data.materials.append(mat)
    return obj


def cube(name, center, size, mat, parent, bevel=0):
    bpy.ops.mesh.primitive_cube_add(size=1)
    obj = bpy.context.object
    obj.name = name
    obj.parent = parent
    obj.location = center
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    if bevel:
        modifier = obj.modifiers.new("Rounded edges", "BEVEL")
        modifier.width = bevel
        modifier.segments = 2
    return obj


def position(xy, z):
    # KiCad's original board coordinates map to the released gland enclosure.
    return (xy[0] - 14, 164.67 - xy[1], z)


for index, pad in enumerate(BOARD["pads"]):
    if pad["size"][0] <= 0 or pad["size"][1] <= 0:
        continue
    obj = cube("Pad_" + str(index), position(pad["xy"], 14.64),
               (pad["size"][0], pad["size"][1], .035), MATS["gold"], groups["board"], .06)
    obj.rotation_euler.z = -radians(pad["rotation"])
for index, track in enumerate(BOARD["tracks"]):
    start, stop = position(track["start"], 14.615), position(track["end"], 14.615)
    tube("Track_" + str(index), [start, stop], track["width"], MATS["trace"], groups["board"], resolution=1)

# The two connector pairs are placed for a catalog close-up. Installed clearances
# continue to use the released service envelopes recorded in gland-fit.json.
references = []
for row in DATA["parts"]:
    if row["group"] != "reference":
        continue
    obj = parts[row["name"]]
    bounds = row["bounds"]
    obj.location = (-sum(bounds[0::3]) / 2, -sum(bounds[1::3]) / 2, -bounds[2])
    references.append(obj)
parked = []
for names, bay_y in ((("Molex_430200401.step", "Molex_430250400.step"), 54),
                     (("Molex_430200601.step", "Molex_430250600.step"), 22)):
    for index, name in enumerate(names):
        original = parts[name]
        obj = original.copy()
        obj.data = original.data
        scene.collection.objects.link(obj)
        obj.name = "Parked_" + name
        obj.parent = groups["loom"]
        bounds = next(row["bounds"] for row in DATA["parts"] if row["name"] == name)
        length = bounds[4] - bounds[1]
        center_y = bay_y + (1 if index == 0 else -1) * (24.77 - length) / 2
        obj.location = (22.45 - (bounds[0] + bounds[3]) / 2,
                        center_y - (bounds[1] + bounds[4]) / 2, 13 - bounds[2])
        obj.hide_render = False
        obj["placement_status"] = "Presentation placement within released service volume; mating alignment pending"
        parked.append(obj)
for key in ("J1", "J2"):
    y = 54 if key == "J1" else 22
    # Two short, round, continuous jackets visualize the captive cable entries.
    tube(key + " outer lead", [(-20, y, 22), (-46, y, 22), (-63, y - 4, 15), (-75, y - 9, 10)],
         7.2 if key == "J1" else 5.5, MATS["cable"], groups["loom"])
wire_colors = {
    "/GND": (.018, .02, .024), "/VEH_ACC": (.56, .025, .035),
    "/TAIL_12V": (.04, .30, .13), "/DIM_RETURN": (.19, .16, .28),
    "/LED_R_NEG": (.56, .025, .035), "/LED_G_NEG": (.035, .3, .11),
    "/LED_B_NEG": (.035, .12, .5), "/LED_POS": (.25, .16, .06), "/LED_W_NEG": (.65, .68, .65),
}
for pad in BOARD["pads"]:
    if pad["ref"] not in ("J1", "J2"):
        continue
    number = int(pad["number"])
    end = position(pad["xy"], 14.9)
    bay = 54 if pad["ref"] == "J1" else 22
    mat = material("Wire " + pad["net"], wire_colors[pad["net"]], rough=.4)
    # Loom curves are illustrative service loops, anchored at the real PCB pads.
    tube("Wire_" + pad["ref"] + "_" + str(number),
         [(22 + .8 * number, bay + 12, 16), (31, bay + 13, 26),
          (end[0] - 3, end[1] + 2, 22), end], 1.35, mat, groups["loom"])

for axis in DATA["tools"]:
    x, y, z = axis["position_mm"]
    if axis["id"].startswith("lid_"):
        z = 39.2
        parent = groups["lid"]
    else:
        z = 14.7
        parent = groups["board"]
    bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=2.65, depth=2.7)
    screw = bpy.context.object
    screw.name = "M3_" + axis["id"]
    screw.parent = parent
    screw.location = (x, y, z + 1.35)
    screw.data.materials.append(MATS["solder"])
    bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=1.15, depth=.07)
    socket = bpy.context.object
    socket.name = "Socket_" + axis["id"]
    socket.parent = parent
    socket.location = (x, y, z + 2.73)
    socket.data.materials.append(MATS["chip"])

bpy.ops.mesh.primitive_plane_add(size=200)
floor = bpy.context.object
floor.name = "Studio floor"
floor.location.z = -.022
floor.data.materials.append(material("Studio slate", (.012, .019, .03), metal=.05, rough=.58))


def world(xyz):
    return Vector(((xyz[0] - 85) * .01, (xyz[1] - 38) * .01, xyz[2] * .01))


def area(name, xyz, energy, size, color, target=(75, 38, 15)):
    data = bpy.data.lights.new(name, "AREA")
    data.energy, data.shape, data.size, data.color = energy, "DISK", size, color
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.location = world(xyz)
    obj.rotation_euler = (world(target) - obj.location).to_track_quat("-Z", "Y").to_euler()
    return obj


area("Large softbox", (25, -160, 250), 180, 4.0, (.82, .91, 1))
area("Warm rim", (200, 140, 190), 230, 3.5, (1, .77, .53))
area("Strip reflection", (-130, 75, 100), 140, 2.8, (.33, .82, .91))
area("Board fill", (80, 60, 270), 110, 3, (.85, 1, .93))
camera_data = bpy.data.cameras.new("Product lens")
camera = bpy.data.objects.new("Product lens", camera_data)
scene.collection.objects.link(camera)
scene.camera = camera
camera_data.lens = 60
camera_data.clip_end = 80
camera_data.dof.use_dof = False

# Camera-attached typography keeps the explanatory labels readable during orbits.
font_path = ROOT / "inputs/Barlow-Regular.ttf"
font = bpy.data.fonts.load(str(font_path))
font.pack()
overlays = []
framing_records = []


def label(name, body, xy, size, color, align="LEFT"):
    data = bpy.data.curves.new(name, "FONT")
    data.body = body
    data.size = size
    data.font = font
    data.align_x = align
    data.space_character = 1.05
    data.resolution_u = 12
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.parent = camera
    obj.location = (xy[0], xy[1], -1)
    mat = bpy.data.materials.new(name + " emission")
    mat.use_nodes = True
    tree = mat.node_tree
    tree.nodes.clear()
    output = tree.nodes.new("ShaderNodeOutputMaterial")
    emission = tree.nodes.new("ShaderNodeEmission")
    emission.inputs["Color"].default_value = (*color, 1)
    tree.links.new(emission.outputs[0], output.inputs[0])
    obj.data.materials.append(mat)
    obj.visible_shadow = False
    overlays.append((obj, xy, size))
    return obj


topline = label("Topline", "4RUNNER    /    REV G", (-.264, .137), .007, (.35, .88, .74))
headline = label("Headline", "", (-.264, .110), .019, (.9, .96, 1))
subline = label("Subline", "", (-.264, -.133), .0067, (.61, .72, .80))
status = label("Status", "DESIGN VISUALIZATION", (.264, .137), .005, (.64, .73, .79), "RIGHT")
caption = label("Caption", "", (0, -.148), .0061, (.83, .90, .94), "CENTER")
control_labels = [
    label("Manual client", "iPhone / Android", (-.254, .045), .008, (.92, .96, 1)),
    label("WiFi control", "WLED over Wi-Fi", (-.254, .025), .0066, (.35, .88, .74)),
    label("Telemetry source", "CAN gateway > app relay", (-.254, -.005), .0067, (.92, .96, 1)),
    label("Telemetry rule", "Selected signal > color rule", (-.254, -.025), .0062, (.35, .88, .74)),
    label("Output behavior", "R     G     B     W", (-.254, -.067), .009, (.92, .96, 1)),
]
for obj in control_labels:
    obj.hide_render = True
color_indicators = []
for index, color in enumerate(((1, .025, .018), (.03, .85, .18), (.025, .16, 1), (.82, .9, 1))):
    light_mat = material("Illustrated RGBW channel " + str(index), color, rough=.3)
    bsdf = light_mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Emission Color"].default_value = (*color, 1)
    bsdf.inputs["Emission Strength"].default_value = 0
    x = -.249 + index * .016
    lamp = cube("Illustration channel " + str(index), (x, -.083, -1),
                (.010, .007, .001), light_mat, camera, .001)
    lamp.hide_render = True
    lamp["illustration_only"] = True
    overlays.append((lamp, (x, -.083), .010))
    color_indicators.append((lamp, bsdf))


def aim(eye, target, lens=60):
    camera.location = world(eye)
    camera.rotation_euler = (world(target) - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera_data.lens = lens
    # Use the same screen margins at every focal length.
    scale = 60 / lens
    for obj, xy, _ in overlays:
        obj.location.x, obj.location.y = xy[0] * scale, xy[1] * scale
        obj.scale = (scale, scale, scale)


def fit_visible_parts(bounds=(.09, .91, .16, .76)):
    """Keep the complete assembly between typography margins during explosion."""
    bpy.context.view_layer.update()
    points = [obj.matrix_world @ Vector(corner) for obj in parts.values()
              if not obj.hide_render for corner in obj.bound_box]
    center = sum(points, Vector()) / len(points)
    left, right, bottom, top = bounds
    desired_x, desired_y = (left + right) / 2, (bottom + top) / 2
    axes = camera.rotation_euler.to_matrix()
    x_axis, y_axis, forward = (axes @ Vector(axis) for axis in ((1, 0, 0), (0, 1, 0), (0, 0, -1)))
    for _ in range(5):
        bpy.context.view_layer.update()
        projected = [world_to_camera_view(scene, camera, point) for point in points]
        lo_x, hi_x = min(p.x for p in projected), max(p.x for p in projected)
        lo_y, hi_y = min(p.y for p in projected), max(p.y for p in projected)
        depth = (center - camera.location).dot(forward)
        width = depth * camera_data.sensor_width / camera_data.lens
        height = width * scene.render.resolution_y / scene.render.resolution_x
        camera.location += x_axis * (((lo_x + hi_x) / 2 - desired_x) * width)
        camera.location += y_axis * (((lo_y + hi_y) / 2 - desired_y) * height)
        bpy.context.view_layer.update()
        projected = [world_to_camera_view(scene, camera, point) for point in points]
        factor = max(1, (desired_x - min(p.x for p in projected)) / (desired_x - left),
                     (max(p.x for p in projected) - desired_x) / (right - desired_x),
                     (desired_y - min(p.y for p in projected)) / (desired_y - bottom),
                     (max(p.y for p in projected) - desired_y) / (top - desired_y))
        if factor > 1.001:
            camera.location += (camera.location - center) * (factor * 1.01 - 1)
    bpy.context.view_layer.update()
    projected = [world_to_camera_view(scene, camera, point) for point in points]
    measured = (min(p.x for p in projected), max(p.x for p in projected),
                min(p.y for p in projected), max(p.y for p in projected))
    passed = (measured[0] >= left - .005 and measured[1] <= right + .005
              and measured[2] >= bottom - .005 and measured[3] <= top + .005)
    framing_records.append({"frame": scene.frame_current, "measured": measured,
                            "limits": bounds, "passed": passed})
    if not passed:
        raise RuntimeError("The assembly exceeds its camera margins")


def set_pose(kind):
    for group in groups.values():
        group.location = (0, 0, 0)
    for ref in references:
        ref.hide_render = True
    for key in ("base", "lid", "plate", "board", "loom"):
        for obj in groups[key].children:
            obj.hide_render = False
    if kind == "open":
        for obj in groups["lid"].children:
            obj.hide_render = True
    if kind == "board":
        for key in ("base", "lid", "plate", "loom"):
            for obj in groups[key].children:
                obj.hide_render = True
    if kind == "exploded":
        groups["lid"].location = (-12, 14, 74)
        groups["board"].location = (0, 0, 28)
        groups["plate"].location = (-15, 0, 15)
        groups["loom"].location = (0, 0, 13)
    if kind == "connectors":
        for key in ("base", "lid", "plate", "board", "loom"):
            for obj in groups[key].children:
                obj.hide_render = True
        listed = ("Molex_430200401.step", "Molex_430250400.step",
                  "Molex_430200601.step", "Molex_430250600.step")
        for name, xy in zip(listed, ((45, 54), (65, 54), (95, 54), (117, 54))):
            obj = parts[name]
            row = next(r for r in DATA["parts"] if r["name"] == name)
            lo = row["bounds"]
            obj.location = (xy[0] - (lo[0] + lo[3]) / 2, xy[1] - (lo[1] + lo[4]) / 2, 4 - lo[2])
            obj.hide_render = False


def still(filename, pose, title, detail, eye, target, lens=60):
    set_pose(pose)
    headline.data.body = title
    subline.data.body = ""
    caption.data.body = ""
    aim(eye, target, lens)
    if pose == "exploded":
        fit_visible_parts()
    scene.render.filepath = str(OUT / filename)
    bpy.ops.render.render(write_still=True)
    print("Saved", filename, flush=True)


if args.stage == "pictures":
    shots = [
        ("01-exterior.png", "closed", "One power input. Four colors.", "Toyota power enters through M16. RGBW leaves through M12.",
         (-255, -250, 255), (60, 38, 20), 60),
        ("02-inside.png", "open", "One board, fully integrated.", "Power protection, processor, sensing and output driver on a 122 × 53.34 mm PCB.",
         (-70, -150, 245), (80, 38, 10), 60),
        ("03-board.png", "board", "The complete Rev G controller.", "ESP32-S3 • F1 and F2 • input eFuse • 3.3 V regulator • four-channel driver",
         (30, -120, 210), (93, 38, 13), 65),
        ("04-exploded.png", "exploded", "Designed to open. Designed to service.", "Removable gland plate, threaded inserts and a single populated board.",
         (-205, -265, 300), (80, 38, 58), 55),
        ("05-connectors.png", "connectors", "Latching wire connections.", "Molex 43020/43025 • 4 positions for the Toyota branch • 6 positions for RGBW",
         (37, -64, 107), (80, 54, 6), 70),
        ("06-components.png", "board", "Every function has a place.", "Actual KiCad component geometry and pad positions. Evaluation prototype.",
         (58, -42, 82), (84, 37, 16), 62),
    ]
    shots = shots[:STORY.get("picture_count", len(shots))]
    for shot in shots:
        still(*shot)
    (OUT / "framing-checks.json").write_text(json.dumps(framing_records, indent=2) + "\n")
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "RevG-Studio.blend"))
    print(json.dumps({"pictures": len(shots), "engine": "Cycles", "samples": scene.cycles.samples,
                      "geometry_units": "millimetres", "render_device": "OPTIX"}))
    raise SystemExit(0)

timeline = json.loads((ROOT / "prepared/timeline.json").read_text())
total = timeline[-1]["end_frame"]
scene.frame_start, scene.frame_end = 1, total
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
frames = OUT / "frames"
frames.mkdir(exist_ok=True)
scene.render.filepath = str(frames / "frame-")
poses = ["closed", "open", "board", "board", "closed", "exploded"]
words = json.loads((ROOT / "prepared/captions.json").read_text()) if (ROOT / "prepared/captions.json").exists() else []
active_chapter = -1


def update(frame):
    global active_chapter
    chapter_index = next(i for i, row in enumerate(timeline) if frame <= row["end_frame"])
    chapter = timeline[chapter_index]
    p = (frame - chapter["start_frame"]) / max(1, chapter["end_frame"] - chapter["start_frame"])
    smooth = p * p * (3 - 2 * p)
    if chapter_index != active_chapter:
        set_pose(poses[chapter_index])
        headline.data.body = STORY["chapters"][chapter_index]["title"]
        subline.data.body = STORY["chapters"][chapter_index]["detail"]
        status.data.body = "ILLUSTRATED CONTROL SEQUENCE" if chapter_index == 3 else "DESIGN VISUALIZATION"
        for obj in control_labels:
            obj.hide_render = chapter_index != 3
        for obj, _ in color_indicators:
            obj.hide_render = chapter_index != 3
        active_chapter = chapter_index
    now = frame / FPS
    line = next((line["text"] for line in words if line["start"] <= now < line["end"]), "")
    if caption.data.body != line:
        caption.data.body = line
    if chapter_index == 3:
        selected = int(p * 12) % 4
        timed_out = p > .83
        control_labels[-1].data.body = "Telemetry timeout > automatic off" if timed_out else "R     G     B     W"
        for index, (_, bsdf) in enumerate(color_indicators):
            bsdf.inputs["Emission Strength"].default_value = 0 if timed_out else (1.7 if selected == index else .08)
            tint = bsdf.inputs["Emission Color"].default_value
            gain = .004 if timed_out else (.9 if selected == index else .035)
            bsdf.inputs["Base Color"].default_value = (tint[0] * gain, tint[1] * gain, tint[2] * gain, 1)
    if chapter_index in (4, 5):
        progress = min(1, max(0, p * 3))
        progress = progress * progress * (3 - 2 * progress)
        lift = progress if chapter_index == 4 else 1 - progress
        groups["lid"].location = (-12 * lift, 14 * lift, 74 * lift)
        groups["board"].location = (0, 0, 28 * lift)
        groups["plate"].location = (-15 * lift, 0, 15 * lift)
        groups["loom"].location = (0, 0, 13 * lift)
    if chapter_index in (0, 5):
        a = radians(213 + smooth * 18)
        lift = 0 if chapter_index == 0 else 1 - progress
        aim((65 + 410 * cos(a), 38 + 410 * sin(a), 215 - smooth * 18 + 45 * lift),
            (65, 38, 17 + 38 * lift), 60)
    elif chapter_index == 1:
        aim((-58 + smooth * 35, -142, 218 - smooth * 12), (75, 38, 12), 60)
        # A presentation lift exposes the board. This is an exploded display pose.
        groups["lid"].location = (-10, 18, 70)
    elif chapter_index == 2:
        aim((45 + smooth * 50, -102, 168 - smooth * 12), (93, 38, 15), 63)
    elif chapter_index == 3:
        aim((122 - smooth * 40, -130, 173), (80, 38, 16), 58)
    else:
        a = radians(222 + smooth * 15)
        aim((80 + 330 * cos(a), 38 + 330 * sin(a), 224), (80, 38, 55), 57)
    scene.frame_set(frame)
    if chapter_index in (4, 5):
        fit_visible_parts()
    elif chapter_index == 3:
        fit_visible_parts((.32, .94, .18, .76))


start = time.monotonic()
selected_frames = range(1, total + 1)
if args.stage == "preview":
    selected_frames = sorted(set([1, total] + [
        (row["start_frame"] + row["end_frame"]) // 2 for row in timeline
    ] + [timeline[4]["end_frame"], timeline[5]["start_frame"]]))
for frame in selected_frames:
    update(frame)
    target = ((OUT / ("preview-%05d.png" % frame)) if args.stage == "preview"
              else frames / ("frame-%05d.png" % frame))
    if target.is_file():
        continue
    scene.render.filepath = str(target)
    bpy.ops.render.render(write_still=True)
    if frame % FPS == 0:
        print(json.dumps({"frame": frame, "total": total, "elapsed": round(time.monotonic() - start, 2)}), flush=True)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "RevG-Film.blend"))
(OUT / "framing-checks.json").write_text(json.dumps(framing_records, indent=2) + "\n")
(OUT / "render-summary.json").write_text(json.dumps({
    "frames": total, "fps": FPS, "duration": total / FPS, "resolution": [1920, 1080],
    "elapsed_seconds": time.monotonic() - start, "engine": scene.render.engine, "render_device": "Orion GPU",
    "physical_validation": False,
}, indent=2) + "\n")
