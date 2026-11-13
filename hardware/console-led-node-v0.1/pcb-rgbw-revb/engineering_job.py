"""Source-pinned two-connector shield build, routing and enclosure job."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from design import CONTRACT, NAME, REFERENCE


JOB_TYPE = "pcb.vhos_rgbw_two_connector"
KICAD = Path("C:/Program Files/KiCad/10.0/bin")
CLI = KICAD / "kicad-cli.exe"
PYTHON = KICAD / "python.exe"
JAVA = Path("C:/PCBToolchains/java25/jdk-25.0.4.1+1-jre/bin/java.exe")
ROUTER = Path("C:/PCBToolchains/freerouting/2.5.0/freerouting-2.5.0.jar")
MODULE = "ESP32-S3-WROOM-1.step"
MODULE_SHA = "02e192087a1a2268ccbe7bf667ef04884370fc76c994484bf85654dfa7407ef6"
ROUTED_SHIELD = "routed_shield.step"
ROUTED_SHIELD_SHA = "3ec61f463fe32eb3731628f4442ddb74d17c380db6bf20c91a8dc4dba24a3bc5"


def source_files():
    return {**{name: ROOT / name for name in ("design.py", "native_pcb.py", "mechanical_audit.py", "engineering_job.py", "engineering-inputs.json")},
            "run_isolated_engineering.py": (ROOT / "run_isolated_engineering.py") if (ROOT / "run_isolated_engineering.py").exists()
            else REFERENCE / "run_isolated_engineering.py",
            **{f"reference/{name}": REFERENCE / name for name in ("circuit.py", "native_pcb.py", "engineering-inputs.json")}}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_pin():
    pins = {key: sha(path) for key, path in source_files().items()}
    return hashlib.sha256(json.dumps(pins, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def validate(params):
    if set(params) != {"stage", "expected_source_set_sha256", "timeout_sec", "evaluation_only"}:
        raise ValueError("exact two-connector job parameters required")
    if params["expected_source_set_sha256"] != source_pin() or params["evaluation_only"] is not True:
        raise ValueError("source pin or evaluation flag mismatch")
    if params["stage"] not in {"fit", "finish", "jlc-case"} or type(params["timeout_sec"]) is not int or not 60 <= params["timeout_sec"] <= 900:
        raise ValueError("unsupported stage or deadline")
    inputs = {MODULE: MODULE_SHA}
    if params["stage"] == "jlc-case":
        inputs[ROUTED_SHIELD] = ROUTED_SHIELD_SHA
    for name, expected in inputs.items():
        asset = ROOT / "inputs" / name
        if asset.is_symlink() or not asset.is_file() or sha(asset) != expected:
            raise ValueError(f"{name} reference STEP hash mismatch")
    return dict(params)


def register(modeling):
    modeling.JOB_TYPES[JOB_TYPE] = {
        "runtime": "python", "script": Path(__file__),
        "description": "Native KiCad Rev B and two-port FreeCAD enclosure fit evaluation",
        "params": {"stage": "fit/finish/jlc-case", "expected_source_set_sha256": "source pin",
                   "timeout_sec": "60..900", "evaluation_only": "true"},
    }


def execute(params, out):
    if platform.system() != "Windows" or platform.node().split(".")[0].casefold() != "orion":
        raise RuntimeError("Orion Windows required")
    validate(params)
    out.mkdir(parents=True, exist_ok=True)
    for name, source in source_files().items():
        destination = out / "source" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    started, commands = time.monotonic(), []
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", OMP_NUM_THREADS="2", OPENBLAS_NUM_THREADS="2")

    def run(label, *args, limit=120):
        remain = params["timeout_sec"] - (time.monotonic() - started)
        if remain <= 0:
            raise TimeoutError("Rev B job deadline")
        path = out / (label + ".log")
        with path.open("wb") as log:
            process = subprocess.run(list(map(str, args)), cwd=out, env=env, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=subprocess.STDOUT, timeout=min(remain, limit))
        commands.append({"name": label, "exit": process.returncode, "log_sha256": sha(path)})
        (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n", encoding="utf-8")
        if process.returncode != 0:
            raise RuntimeError(f"{label} exited {process.returncode}")

    pcb, sch = out / (NAME + ".kicad_pcb"), out / (NAME + ".kicad_sch")
    pcb_tool = [PYTHON, "-I", "-B", ROOT / "native_pcb.py"]
    cad_tool = [sys.executable, "-I", "-B", ROOT / "mechanical_audit.py"]
    try:
        if params["stage"] == "jlc-case":
            shutil.copyfile(ROOT / "inputs" / ROUTED_SHIELD, out / ROUTED_SHIELD)
            run("manufacturing-case", *cad_tool, "jlc-case", "--out", out, limit=155)
            return {"stage": params["stage"], "physical_fit_verified": False, "manufacturing_released": False}
        run("part-models", *cad_tool, "models", "--out", out, limit=155)
        run("native-build", *pcb_tool, "build", "--out", out)
        run("netlist", CLI, "sch", "export", "netlist", "--format", "kicadxml", "-o", out / "schematic.net.xml", sch)
        run("reconcile-placement", *pcb_tool, "reconcile", "--out", out)
        run("erc", CLI, "sch", "erc", "--format", "json", "--severity-all", "-o", out / "erc.json", sch)
        run("schematic-pdf", CLI, "sch", "export", "pdf", "-o", out / "schematic.pdf", sch)
        if params["stage"] == "finish":
            run("router", JAVA, "-Xmx2g", "-XX:ActiveProcessorCount=2", "-Djava.awt.headless=true", "-jar", ROUTER,
                "-de", out / "shield.dsn", "-do", out / "shield.ses", "--router.autorouter.max_passes=85",
                "--router.copper_to_edge_clearance_um=350", "--router.automatic_neckdown=false",
                "--router.neck_width_um=0", "--router.fanout.enabled=false", "--router.strict_drc=true",
                "--router.optimizer.max_passes=2", "-mt", "1", "-da", "-dl", "--gui.enabled=false",
                "--api_server.enabled=false", "--router.result_json=" + str(out / "router-result.json"),
                "--user_data_path=" + str(out / "router-state"), limit=300)
            run("import-route", *pcb_tool, "import", "--out", out)
            run("reconcile-route", *pcb_tool, "reconcile", "--out", out)
        run("drc", CLI, "pcb", "drc", "--format", "json", "--severity-all", "--schematic-parity", "-o", out / "drc.json", pcb)
        run("shield-step", CLI, "pcb", "export", "step", "--subst-models", "--no-dnp", "--user-origin", "100x153.34mm",
            "-f", "-o", out / "routed_shield.step", pcb, limit=160)
        run("shield-render", CLI, "pcb", "render", "--width", "1600", "--height", "1100", "--quality", "basic",
            "--background", "opaque", "--rotate", "35,0,30", "-o", out / "shield.png", pcb)
        run("case-fit", *cad_tool, "assembly", "--out", out, limit=155)
        erc = json.loads((out / "erc.json").read_text())
        drc = json.loads((out / "drc.json").read_text())
        findings = {"erc": sum(len(sheet["violations"]) for sheet in erc["sheets"]),
                    **{key: len(drc.get(key, [])) for key in ("violations", "unconnected_items", "schematic_parity")}}
        if params["stage"] == "finish" and not any(findings.values()):
            fab = out / "prototype-fabrication"
            gerbers = fab / "gerbers"
            gerbers.mkdir(parents=True)
            run("gerber", CLI, "pcb", "export", "gerbers", "-o", gerbers,
                "-l", "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,F.Paste,Edge.Cuts", pcb)
            run("drill", CLI, "pcb", "export", "drill", "--format", "excellon", "--excellon-separate-th", "--generate-map",
                "--map-format", "pdf", "-o", gerbers, pcb)
            run("placement", CLI, "pcb", "export", "pos", "--format", "csv", "--units", "mm",
                "--side", "front", "--smd-only", "-o", fab / "SMT-placement.csv", pcb)
            shutil.copyfile(out / "PCB-BOM.csv", fab / "PCB-BOM.csv")
        return {"stage": params["stage"], "pcb_findings": findings,
                "physical_fit_verified": False, "manufacturing_released": False}
    finally:
        validate(params)
        artifacts = [{"name": f.relative_to(out).as_posix(), "bytes": f.stat().st_size, "sha256": sha(f)}
                     for f in sorted(out.rglob("*")) if f.is_file() and f.name != "engineering-manifest.json"]
        report = {"contract": CONTRACT, "device": "orion", "params": params,
                  "sources": {key: sha(path) for key, path in source_files().items()},
                  "esp_module_reference_sha256": MODULE_SHA, "artifacts": artifacts,
                  "manufacturing_released": False, "vehicle_fit_or_electrical_qualified": False}
        if params["stage"] == "jlc-case":
            report["published_routed_shield_sha256"] = ROUTED_SHIELD_SHA
        (out / "engineering-manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--params", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(execute(json.loads(args.params.read_text()), args.out.resolve())))
