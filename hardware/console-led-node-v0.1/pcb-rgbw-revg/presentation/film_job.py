"""Source-pinned FreeCAD export and Blender rendering on owned Orion hardware."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
JOB_TYPE = "cad.revg_product_film"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_pin():
    files = ("film_job.py", "mesh_export.py", "board_details.py", "scene.py", "storyboard.json")
    pin = hashlib.sha256()
    for name in files:
        pin.update(name.encode() + b"\0" + (ROOT / name).read_bytes())
    return pin.hexdigest()


def validate(params):
    if set(params) != {"stage", "expected_source_sha256", "timeout_sec"}:
        raise ValueError("Stage, source hash and timeout are required")
    if params["stage"] not in {"export", "preview", "pictures", "film"}:
        raise ValueError("Unknown film stage")
    if params["expected_source_sha256"] != source_pin():
        raise ValueError("Film source changed")
    if type(params["timeout_sec"]) is not int or not 60 <= params["timeout_sec"] <= 6400:
        raise ValueError("Use a bounded stage timeout")
    manifest = json.loads((ROOT / "inputs.json").read_text())
    for name, pin in manifest.items():
        if digest(ROOT / "inputs" / name) != pin:
            raise ValueError("Input mismatch " + name)
    return params


def register(module):
    module.JOB_TYPES[JOB_TYPE] = {"runtime": "python", "script": Path(__file__),
        "description": "Rev G pinned CAD export, studio pictures and narrated product film",
        "params": {"stage": "export|preview|pictures|film", "expected_source_sha256": "source hash",
                   "timeout_sec": "60..6400"}}


def run(params, out):
    if platform.system() != "Windows" or platform.node().split(".")[0].lower() != "orion":
        raise RuntimeError("The film renders on Orion")
    validate(params)
    out.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, "C:/orion/control-plane")
    from modeling.jobs.ac_diagnostic_enclosure import find_freecad, find_blender
    from modeling.jobs.ac_handheld import run_freecad
    stage = params["stage"]
    if stage == "export":
        kpython = Path("C:/Program Files/KiCad/10.0/bin/python.exe")
        with (out / "kicad.log").open("wb") as log:
            subprocess.run([kpython, "-B", ROOT / "board_details.py", ROOT / "inputs/board.kicad_pcb",
                            out / "board-details.json"], check=True, timeout=45, stdout=log, stderr=subprocess.STDOUT)
        code = (ROOT / "mesh_export.py").read_text()
        code = "INPUT=" + repr(str(ROOT / "inputs")) + "\nOUT=" + repr(str(out)) + "\n" + code
        run_freecad(find_freecad(), code, out, 160)
    else:
        required = ("meshes.json.gz", "board-details.json")
        for name in required:
            if not (ROOT / "prepared" / name).is_file():
                raise FileNotFoundError("Run and stage the CAD export first " + name)
        cmd = [find_blender(), "--factory-startup", "--disable-autoexec", "-b", "--threads", "2",
               "--python-exit-code", "1", "--python", str(ROOT / "scene.py"), "--",
               "--stage", stage, "--root", str(ROOT), "--output", str(out)]
        with (out / "blender.log").open("wb") as log:
            subprocess.run(cmd, check=True, timeout=params["timeout_sec"] - 15,
                           stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        if stage == "film":
            finalize(out)
        elif stage == "pictures":
            images = sorted(out.glob("0*.png"))
            if len(images) == 6:
                ffmpeg = shutil.which("ffmpeg")
                command = [ffmpeg, "-y", "-v", "error", "-threads", "2"]
                for image in images:
                    command.extend(["-i", str(image)])
                filters = ";".join(f"[{i}:v]scale=640:360[p{i}]" for i in range(6))
                filters += ";" + "".join(f"[p{i}]" for i in range(6))
                filters += "xstack=inputs=6:layout=0_0|640_0|1280_0|0_360|640_360|1280_360[grid]"
                command.extend(["-filter_complex", filters, "-map", "[grid]", "-frames:v", "1",
                                "-q:v", "2", str(out / "RevG-Studio-Gallery.jpg")])
                subprocess.run(command, check=True, timeout=45, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    validate(params)
    files = {}
    for path in sorted(out.rglob("*")):
        if path.is_file():
            files[str(path.relative_to(out))] = {"bytes": path.stat().st_size, "sha256": digest(path)}
    (out / "film-receipt.json").write_text(json.dumps({
        "source_sha256": source_pin(), "input_sha256": json.loads((ROOT / "inputs.json").read_text()),
        "prepared_sha256": {file.name: digest(file) for file in sorted((ROOT / "prepared").glob("*")) if file.is_file()},
        "stage": stage, "host": platform.node(), "artifacts": files, "physical_validation": False,
    }, indent=2) + "\n")
    return {"stage": stage, "artifacts": len(files)}


def finalize(out):
    """Encode and inspect the finished film on Orion with the accepted voice."""
    import numpy as np
    import wave
    fps = json.loads((ROOT / "storyboard.json").read_text())["fps"]
    timeline = json.loads((ROOT / "prepared/timeline.json").read_text())
    frames = timeline[-1]["end_frame"]
    duration = frames / fps
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise FileNotFoundError("Orion FFmpeg and FFprobe are required")
    rate = 24000
    t = np.arange(round(duration * rate), dtype=np.float64) / rate
    score = np.zeros_like(t)
    # Original quiet harmonic bed, synthesized for this explanation.
    for frequency, amplitude in ((65.406, .004), (98, .003), (130.812, .0016), (155.563, .0015)):
        score += amplitude * np.sin(2 * np.pi * frequency * t) * (.7 + .3 * np.sin(2 * np.pi * .07 * t))
    envelope = np.minimum(1, t / 2) * np.minimum(1, np.maximum(0, duration - t) / 2)
    for chapter in timeline:
        offset = chapter["start_frame"] / fps
        s = t - offset
        hit = (s >= 0) & (s < .6)
        score[hit] += .004 * np.sin(2 * np.pi * 392 * s[hit]) * np.exp(-9 * s[hit])
    score = (np.clip(score * envelope, -.95, .95) * 32767).astype("<i2")
    bed = out / "original-score.wav"
    with wave.open(str(bed), "wb") as audio:
        audio.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        audio.writeframes(score.tobytes())
    target = out / "4Runner_RevG_3D_Demonstrator.mp4"
    filters = (
        "[1:a]loudnorm=I=-16:TP=-1.5:LRA=9,aformat=channel_layouts=stereo[voice];"
        "[2:a]aformat=channel_layouts=stereo[bed];"
        "[voice][bed]amix=inputs=2:normalize=0,alimiter=limit=0.84:level=0[mix]"
    )
    command = [ffmpeg, "-y", "-hide_banner", "-threads", "2",
               "-framerate", str(fps), "-start_number", "1", "-i", str(out / "frames/frame-%05d.png"),
               "-i", str(ROOT / "prepared/narration.wav"), "-i", str(bed),
               "-filter_complex", filters, "-map", "0:v", "-map", "[mix]",
               "-c:v", "h264_nvenc", "-preset", "p5", "-tune", "hq", "-cq", "19", "-b:v", "0",
               "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
               "-t", f"{duration:.6f}", "-movflags", "+faststart", str(target)]
    with (out / "encode.log").open("wb") as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=240)
    probe = subprocess.check_output(
        [ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", target],
        timeout=20, text=True)
    measured = json.loads(probe)
    (out / "ffprobe.json").write_text(json.dumps(measured, indent=2) + "\n")
    video = next(row for row in measured["streams"] if row["codec_type"] == "video")
    audio = next(row for row in measured["streams"] if row["codec_type"] == "audio")
    if (video["width"], video["height"], video["r_frame_rate"]) != (1920, 1080, f"{fps}/1"):
        raise RuntimeError("Unexpected video dimensions or rate")
    if int(video["nb_frames"]) != frames or audio["channels"] != 2:
        raise RuntimeError("Missing rendered frames or stereo narration")
    with (out / "decode-check.log").open("wb") as log:
        subprocess.run([ffmpeg, "-v", "error", "-threads", "2", "-i", target,
                        "-f", "null", "-"], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    if (out / "decode-check.log").stat().st_size:
        raise RuntimeError("Decoder reported a media error")
    with (out / "loudness.log").open("wb") as log:
        subprocess.run([ffmpeg, "-hide_banner", "-threads", "2", "-i", target,
                        "-af", "loudnorm=I=-16:TP=-1.5:LRA=9:print_format=json",
                        "-f", "null", "-"], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=90)
    shutil.copyfile(ROOT / "prepared/captions.srt", out / "4Runner_RevG_Captions.srt")
    moments = [(row["start_frame"] + row["end_frame"]) / (2 * fps) for row in timeline]
    for i, at in enumerate(moments, 1):
        subprocess.run([ffmpeg, "-y", "-v", "error", "-ss", f"{at:.3f}", "-i", target,
                        "-frames:v", "1", str(out / f"review-{i:02d}.png")], check=True, timeout=15)
    print(json.dumps({"mp4": target.name, "frames": frames, "duration": duration,
                      "sha256": digest(target), "decode_passed": True}), flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    print(json.dumps(run(json.loads(args.params.read_text()), args.out)))
