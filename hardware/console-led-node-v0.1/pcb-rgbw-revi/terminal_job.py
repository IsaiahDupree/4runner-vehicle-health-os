"""Source-pinned Orion native jobs for the Rev I termination revision."""
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
JOB_TYPE = "pcb.vhos_revi_voltage"
CLI = Path("C:/Program Files/KiCad/10.0/bin/kicad-cli.exe")
KPY = CLI.with_name("python.exe")
JAVA = Path("C:/PCBToolchains/java25/jdk-25.0.4.1+1-jre/bin/java.exe")
ROUTER = Path("C:/PCBToolchains/freerouting/2.5.0/freerouting-2.5.0.jar")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_pin():
    manifest = json.loads((ROOT / "job-inputs.json").read_text())
    for name, digest in manifest.items():
        if sha(ROOT / name) != digest:
            raise ValueError("Input changed: " + name)
    own = {p.name: sha(p) for p in sorted(ROOT.glob("*.py"))}
    return hashlib.sha256(json.dumps({"source": own, "inputs": manifest}, sort_keys=True).encode()).hexdigest()


def validate(params):
    if set(params) != {"operation", "source_sha256", "evaluation_only", "timeout_sec"}:
        raise ValueError("Fixed terminal engineering parameters required")
    if params["operation"] not in {"pcb", "case", "pictures"} or params["evaluation_only"] is not True:
        raise ValueError("Evaluation terminal revision required")
    if type(params["timeout_sec"]) is not int or not 120 <= params["timeout_sec"] <= 1500:
        raise ValueError("Bounded deadline required")
    if params["source_sha256"] != source_pin():
        raise ValueError("Source pin differs")
    return params


def register(modeling):
    modeling.JOB_TYPES[JOB_TYPE] = {"runtime": "python", "description": "4Runner Rev I native terminal interface",
                                   "script": Path(__file__), "params": {"operation": "pcb/case/pictures/archives"}}


def execute(params, out):
    if platform.system() != "Windows" or platform.node().split(".")[0].lower() != "orion":
        raise RuntimeError("Owned Orion required")
    validate(params)
    out.mkdir(parents=True, exist_ok=True)
    snapshot = out / "source"
    for name in [*json.loads((ROOT / "job-inputs.json").read_text()),
                 *[p.name for p in ROOT.glob("*.py")], "job-inputs.json"]:
        if name.startswith("inputs/") or name.startswith("release-staged/"):
            continue
        target = snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
    started = time.monotonic()
    commands = []
    os.environ.update(OMP_NUM_THREADS="2", OPENBLAS_NUM_THREADS="2", PYTHONDONTWRITEBYTECODE="1")
    sys.path.insert(0, str(ROOT))
    import terminal_design as design

    def run(label, args, timeout=120):
        remaining = params["timeout_sec"] - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError("Terminal job deadline")
        log = out / (label + ".log")
        with log.open("wb") as stream:
            p = subprocess.run(list(map(str, args)), cwd=out, stdin=subprocess.DEVNULL,
                               stdout=stream, stderr=subprocess.STDOUT, timeout=min(timeout, remaining))
        commands.append({"operation": label, "exit": p.returncode, "log_sha256": sha(log)})
        (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if p.returncode:
            raise RuntimeError(label + " failed; inspect its log")

    def freecad(action, target, timeout=420):
        sys.path.insert(0, "C:/orion/control-plane")
        from modeling.jobs.ac_diagnostic_enclosure import find_freecad
        from modeling.jobs.ac_handheld import run_freecad
        runtime = find_freecad()
        if not runtime:
            raise RuntimeError("Registered native FreeCAD missing")
        code = (f"import sys\nsys.path.insert(0,{str(ROOT)!r})\n"
                f"import terminal_cad\nterminal_cad.{action}({str(target)!r})\n")
        run_freecad(runtime, code, out, timeout)

    op = params["operation"]
    pcb = out / (design.NAME + ".kicad_pcb")
    sch = out / (design.NAME + ".kicad_sch")
    if op == "factory-metadata":
        run("factory-metadata", [KPY, "-I", "-B", ROOT / "terminal_pcb.py", "metadata", out])
        run("erc", [CLI, "sch", "erc", "--format", "json", "--severity-all", "-o", out / "erc.json", sch])
        run("drc", [CLI, "pcb", "drc", "--format", "json", "--severity-all", "--schematic-parity",
                     "-o", out / "drc.json", pcb])
        from toyota_power import check_reports
        findings = check_reports(out)
        if any(findings.values()):
            raise RuntimeError("Native findings after metadata normalization")
        gerbers = out / "fabrication/gerbers"
        run("gerbers", [CLI, "pcb", "export", "gerbers", "-o", gerbers,
                         "-l", "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,F.Paste,Edge.Cuts", pcb])
        run("drill", [CLI, "pcb", "export", "drill", "--format", "excellon", "--excellon-separate-th", "-o", gerbers, pcb])
        run("schematic-pdf", [CLI, "sch", "export", "pdf", "-o", out / "schematic.pdf", sch])
        return {"operation": op, "native_findings": findings, "manufacturing_released": False}
    if op == "pcb":
        freecad("model", ROOT / "prepared", 90)
        run("pcb-build", [KPY, "-I", "-B", ROOT / "terminal_pcb.py", "build", out])
        run("erc", [CLI, "sch", "erc", "--format", "json", "--severity-all", "-o", out / "erc.json", sch])
        run("pre-route-drc", [CLI, "pcb", "drc", "--format", "json", "--severity-all", "--schematic-parity",
                               "-o", out / "pre-route-drc.json", pcb])
        run("route", [JAVA, "-Xmx2g", "-XX:ActiveProcessorCount=2", "-Djava.awt.headless=true", "-jar", ROUTER,
                       "-de", out / "shield.dsn", "-do", out / "shield.ses",
                       "--router.autorouter.max_passes=30", "--router.copper_to_edge_clearance_um=350",
                       "--router.automatic_neckdown=false", "--router.fanout.enabled=false",
                       "--router.strict_drc=true", "--router.optimizer.enabled=false", "-mt", "1", "-da", "-dl",
                       "--gui.enabled=false", "--api_server.enabled=false",
                       "--router.result_json=" + str(out / "router-result.json"),
                       "--user_data_path=" + str(out / "router-state")], 300)
        run("pcb-finish", [KPY, "-I", "-B", ROOT / "terminal_pcb.py", "finish", out])
        run("drc", [CLI, "pcb", "drc", "--format", "json", "--severity-all", "--schematic-parity",
                     "-o", out / "drc.json", pcb])
        from toyota_power import check_reports
        findings = check_reports(out)
        if any(findings.values()):
            raise RuntimeError("ERC/DRC/parity findings: " + str(findings))
        fab = out / "fabrication"
        gerbers = fab / "gerbers"
        gerbers.mkdir(parents=True)
        run("gerbers", [CLI, "pcb", "export", "gerbers", "-o", gerbers,
                         "-l", "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,F.Paste,Edge.Cuts", pcb])
        run("drill", [CLI, "pcb", "export", "drill", "--format", "excellon", "--excellon-separate-th", "-o", gerbers, pcb])
        run("placement", [CLI, "pcb", "export", "pos", "--format", "csv", "--units", "mm", "--side", "front",
                           "-o", fab / "all-front-placement.csv", pcb])
        run("schematic-pdf", [CLI, "sch", "export", "pdf", "-o", out / "schematic.pdf", sch])
        run("board-step", [CLI, "pcb", "export", "step", "--subst-models", "--no-dnp", "--user-origin", "100x153.34mm",
                            "-f", "-o", out / "routed_shield.step", pcb], 180)
        run("board-render", [CLI, "pcb", "render", "--width", "1800", "--height", "1100", "--quality", "basic",
                              "--background", "opaque", "--side", "top", "-o", out / "board.png", pcb], 150)
        return {"operation": op, "native_findings": findings, "manufacturing_released": False}
    if op == "case":
        freecad("build", out, 600)
        # Reuse the real fixed-profile supports-off slicer with H outputs.
        run("slice", [sys.executable, "-I", "-B", design.LEGACY / "print_screen.py", "--out", out,
                       "--gland-case"], 180)
        return {"operation": op, "physical_qualification": False}
    if op == "pictures":
        sys.path.insert(0, "C:/orion/control-plane")
        from modeling.jobs.ac_diagnostic_enclosure import find_blender
        run("studio", [find_blender(), "--factory-startup", "--disable-autoexec", "-b", "--threads", "2",
                        "--python-exit-code", "1", "--python", ROOT / "terminal_render.py", "--",
                        "--root", ROOT, "--out", out], 600)
        return {"operation": op, "design_visualization": True}
    if op == "archives":
        run("archives", [sys.executable, "-I", "-B", ROOT / "release_pack.py", "--plan", ROOT / "archive-plan.json",
                          "--staged", ROOT / "release-staged", "--output", out], 500)
        return {"operation": op, "archive_crc_checked": True}
    raise ValueError("Unknown operation")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--params", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = execute(json.loads(args.params.read_text()), args.out.resolve())
    (args.out / "job-result.json").write_text(json.dumps(result, indent=2) + "\n")
