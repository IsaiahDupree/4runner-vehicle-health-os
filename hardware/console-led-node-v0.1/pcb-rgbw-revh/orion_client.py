"""Stage a fixed Rev H job; use short authenticated SSH/API exchanges for status."""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
ARTIFACTS = REPO.parent / "artifacts/4runner-revh-terminals-2026-11-21"


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def remote(code, timeout=30):
    code = "$ProgressPreference='SilentlyContinue'; " + code
    encoded = base64.b64encode(code.encode("utf-16le")).decode()
    return subprocess.check_output(["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=7", "orion",
                                    "powershell", "-NoProfile", "-EncodedCommand", encoded], text=True, timeout=timeout)


def stage(identity, operation, extra=None):
    folder = ARTIFACTS / identity
    folder.mkdir(parents=True, exist_ok=False)
    staging = folder / "stage"
    staging.mkdir()
    legacy = ROOT.parent / "pcb-rgbw-revb"
    sys.path.insert(0, str(legacy))
    spec = importlib.util.spec_from_file_location("legacy_engineering_job", legacy / "engineering_job.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    files = {"legacy/" + name: p for name, p in mod.source_files().items()}
    for path in ROOT.glob("*.py"):
        files[path.name] = path
    for path in (ROOT / "references").iterdir():
        files["references/" + path.name] = path
    revg = ROOT.parent / "pcb-rgbw-revg/generated"
    for ext in ("kicad_pcb", "kicad_pro"):
        files["inputs/vhos_rgbw_revg." + ext] = revg / ("vhos_rgbw_revg." + ext)
    for directory in ("VHOS_RevB.pretty", "models"):
        for path in (revg / directory).rglob("*"):
            if path.is_file():
                files["inputs/" + path.relative_to(revg).as_posix()] = path
    files["inputs/fp-lib-table"] = revg / "fp-lib-table"
    files["inputs/mechanical-observation.json"] = revg / "mechanical-observation.json"
    files["inputs/ruthex_RX-M3x5_7.stp"] = ROOT / "references/ruthex_RX-M3x5_7.stp"
    gland = ROOT.parent / "pcb-rgbw-revg/glands/generated"
    for name in ("4Runner_RevG_Gland_Assembly.FCStd", "gland-fit.json"):
        files["inputs/" + name] = gland / name
    for name, path in (extra or {}).items():
        files[name] = Path(path)
    manifest = {}
    for name, source in files.items():
        target = staging / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if not name.endswith(".py") or name.startswith("legacy/"):
            manifest[name] = sha(target)
    (staging / "job-inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
    spec = importlib.util.spec_from_file_location("revh_job", staging / "terminal_job.py")
    job = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(job)
    pin = job.source_pin()
    work = "C:/orion/projects/revh-" + identity
    home = "C:/orion/control/revh-" + identity
    params = {"operation": operation, "source_sha256": pin, "evaluation_only": True, "timeout_sec": 1500}
    (staging / "request.json").write_text(json.dumps({"actor": "4runner-revh-terminals",
        "request_id": "revh-" + identity, "params": {"job_type": job.JOB_TYPE, "params": params}}))
    archive = folder / "stage.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_STORED) as z:
        for path in staging.rglob("*"):
            if path.is_file():
                z.write(path, path.relative_to(staging))
    remote(f"if(Test-Path '{work}'){{throw 'Existing project'}}; New-Item -ItemType Directory -Force '{work}','{home}' | Out-Null")
    subprocess.run(["scp", "-O", "-q", str(archive), "orion:" + work + "/stage.zip"], check=True, timeout=90)
    remote(f"Expand-Archive -Path '{work}/stage.zip' -DestinationPath '{work}'")
    lane = {"work": work, "control": home, "source_sha256": pin, "operation": operation}
    (folder / "lane.json").write_text(json.dumps(lane, indent=2) + "\n")
    print(json.dumps(lane), flush=True)
    return lane


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("identity")
    ap.add_argument("--operation", choices=["pcb", "factory-metadata", "case", "pictures", "archives"], default="pcb")
    ap.add_argument("--extra", type=Path)
    args = ap.parse_args()
    if not args.identity.replace("-", "").isalnum() or len(args.identity) > 40:
        raise ValueError("Short task identity required")
    stage(args.identity, args.operation, json.loads(args.extra.read_text()) if args.extra else None)
