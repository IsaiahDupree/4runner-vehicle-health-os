"""Build the Rev G ESP32-S3 image in the authenticated Orion engineering job."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time


TAG = "v16.0.1"
COMMIT = "29b389df1c1aaec6ff53aea742d17063b985906c"
TARGET = "vhos_revi_n16r2"
TOOLS = Path("C:/orion/projects/revg-wled-16-0-1")
SOURCE = Path(__file__).resolve().parent


def replace_once(path, old, new):
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise RuntimeError(f"Upstream hook changed in {path.name}")
    path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build(out):
    if platform.system() != "Windows" or platform.node().split(".")[0].lower() != "orion":
        raise RuntimeError("This cross-build executes on Orion Windows")
    venv = TOOLS / "venv" / "Scripts"
    pio = venv / "pio.exe"
    python = venv / "python.exe"
    if not pio.is_file():
        raise FileNotFoundError("Orion Windows PlatformIO 6.1.19 task venv")
    if "version 6.1.19" not in subprocess.check_output([pio, "--version"], timeout=10, text=True):
        raise RuntimeError("Unexpected PlatformIO version")
    source = out.parent / "wled"
    subprocess.run(["git", "clone", "--depth", "1", "--branch", TAG,
                    "https://github.com/wled/WLED.git", str(source)], timeout=120, check=True)
    if subprocess.check_output(["git", "-C", source, "rev-parse", "HEAD"], timeout=10, text=True).strip() != COMMIT:
        raise RuntimeError("WLED source pin mismatch")
    usermod = source / "usermods/vhos_revg"
    usermod.mkdir()
    for name in ("library.json", "revg_policy.h", "revg_relay.h", "revg_inputs.h", "revg_control.h",
                 "revg_voltage.h", "revg_ui.h", "revg_usermod.cpp"):
        shutil.copyfile(SOURCE / name, usermod / name)
    shutil.copyfile(SOURCE / "platformio_override.ini", source / "platformio_override.ini")
    wled = source / "wled00"
    replace_once(wled / "wled.cpp", "void WLED::setup()\n{",
                 "void WLED::setup()\n{\n  extern void revgInitPins();\n  revgInitPins();")
    replace_once(wled / "wled.cpp", "IPAddress(4, 3, 2, 1), IPAddress(4, 3, 2, 1)",
                 "IPAddress(192, 168, 88, 1), IPAddress(192, 168, 88, 1)")
    replace_once(wled / "wled_server.cpp", 'F("http://4.3.2.1")', 'F("http://192.168.88.1")')
    replace_once(wled / "wled.cpp", "  if (turnOnAtBoot) {",
                 "  turnOnAtBoot = false;\n  bootPreset = 0;\n  if (turnOnAtBoot) {")
    replace_once(wled / "json.cpp", "bool deserializeState(JsonObject root, byte callMode, byte presetId)\n{",
                 """bool deserializeState(JsonObject root, byte callMode, byte presetId)
{
  if (root.containsKey("on") || root.containsKey("bri") || root.containsKey("seg") ||
      root.containsKey("ps") || root.containsKey("pl")) {
    extern void revgRequestManual();
    revgRequestManual();
  }""")
    replace_once(wled / "bus_manager.cpp", "  [[maybe_unused]] unsigned hPoint = 0;",
                 """  // Rev G evaluation bound. Final current and timer alignment need bench checks.
  if (_type == TYPE_ANALOG_4CH && pwmBri > maxBri / 4) pwmBri = maxBri / 4;
  [[maybe_unused]] unsigned hPoint = 0;""")
    compile_image(source, out, pio, python)


def compile_image(source, out, pio, python):
    """Compile the patched WLED tree and package its application and factory images."""
    core = TOOLS / "pio"
    env = {**os.environ, "PLATFORMIO_CORE_DIR": str(core), "PLATFORMIO_SETTING_ENABLE_TELEMETRY": "no"}
    started = time.monotonic()
    with (out / "platformio.log").open("wb") as log:
        subprocess.run([pio, "run", "-e", TARGET, "-j", "2"], cwd=source, env=env, stdin=subprocess.DEVNULL,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=680)
    built = source / ".pio/build" / TARGET
    packages = core / "packages"
    pieces = {
        "0x0": built / "bootloader.bin",
        "0x8000": built / "partitions.bin",
        "0xe000": packages / "framework-arduinoespressif32/tools/partitions/boot_app0.bin",
        "0x10000": built / "firmware.bin",
    }
    esptool = packages / "tool-esptoolpy/esptool.py"
    for path in (esptool, *pieces.values()):
        if not path.is_file():
            raise FileNotFoundError(path)
    app = out / "vhos-revi-wled-n16r2-app.bin"
    merged = out / "vhos-revi-wled-n16r2-factory.bin"
    shutil.copyfile(pieces["0x10000"], app)
    with (out / "image-info.log").open("wb") as log:
        subprocess.run([python, esptool, "--chip", "esp32s3", "image_info", app], check=True,
                       stdout=log, stderr=subprocess.STDOUT, timeout=30)
        args = [arg for offset, path in pieces.items() for arg in (offset, str(path))]
        subprocess.run([python, esptool, "--chip", "esp32s3", "merge_bin", "-o", merged,
                        "--flash_mode", "qio", "--flash_size", "16MB", *args], check=True,
                       stdout=log, stderr=subprocess.STDOUT, timeout=30)
    shutil.copyfile(source / "LICENSE", out / "WLED-EUPL-1.2.txt")
    (out / "firmware-build.json").write_text(json.dumps({
        "upstream": "https://github.com/wled/WLED",
        "tag": TAG, "commit": COMMIT, "platformio": "6.1.19", "environment": TARGET,
        "module": "ESP32-S3-WROOM-1-N16R2", "flash_mb": 16, "psram_mb": 2,
        "pcb_target": "Rev I with GPIO1 protected ACC sense; do not fit to Rev H without that circuit",
        "usermod_sha256": {p.name: sha256(p) for p in SOURCE.glob("revg_*") if p.is_file()},
        "flash_offset": "0x0", "duration_s": round(time.monotonic() - started, 2),
        "hardware_flashing_or_vehicle_validation": False,
        "images": {path.name: {"bytes": path.stat().st_size, "sha256": sha256(path)} for path in (app, merged)},
    }, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    build(Path(sys.argv[1]).resolve())
