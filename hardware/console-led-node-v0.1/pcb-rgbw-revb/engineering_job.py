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
from design import CONTRACT, NAME, REFERENCE, REV_C_NAME
import illumination as rev_d
import single_board as rev_e


JOB_TYPE = "pcb.vhos_rgbw_two_connector"
KICAD = Path("C:/Program Files/KiCad/10.0/bin")
CLI = KICAD / "kicad-cli.exe"
PYTHON = KICAD / "python.exe"
JAVA = Path("C:/PCBToolchains/java25/jdk-25.0.4.1+1-jre/bin/java.exe")
ROUTER = Path("C:/PCBToolchains/freerouting/2.5.0/freerouting-2.5.0.jar")
MODULE = "ESP32-S3-WROOM-1.step"
MODULE_SHA = "02e192087a1a2268ccbe7bf667ef04884370fc76c994484bf85654dfa7407ef6"
KICAD_MODULE = KICAD.parent / "share/kicad/3dmodels/RF_Module.3dshapes/ESP32-S3-WROOM-1.step"
KICAD_MODULE_SHA = "3e35bb7ba7d030d88855fcf968398c8670934c7dca08b4e30b2c578bc1e13954"
ROUTED_SHIELD = "routed_shield.step"
ROUTED_SHIELD_SHA = "3ec61f463fe32eb3731628f4442ddb74d17c380db6bf20c91a8dc4dba24a3bc5"
INSERT_MODEL = "ruthex_RX-M3x5_7.stp"
INSERT_MODEL_SHA = "3686e4730b18fa3f0a83585da28dc7eca70e5da21cedd3f75f3205c5ad11b917"
TOYOTA_POWER_STAGE = "toyota-power-case"
TOYOTA_REV_C_STAGE = "toyota-rev-c"
TOYOTA_WIRE_STAGE = "toyota-wire-route"
ILLUMINATION_STAGE = "toyota-rev-d"
ILLUMINATION_PCB_STAGE = "toyota-rev-d-pcb"
ILLUMINATION_STAGES = (ILLUMINATION_STAGE, ILLUMINATION_PCB_STAGE)
SINGLE_BOARD_STAGE = "toyota-rev-e"
SINGLE_BOARD_PCB_STAGE = "toyota-rev-e-pcb"
SINGLE_BOARD_STAGES = (SINGLE_BOARD_STAGE, SINGLE_BOARD_PCB_STAGE)
TOYOTA_STAGES = (TOYOTA_POWER_STAGE, TOYOTA_REV_C_STAGE)
SERVICE_STAGES = ("service-case", "durable-case", *TOYOTA_STAGES)
CASE_STAGES = ("jlc-case", "jlc-lite-case", *SERVICE_STAGES)
STAGES = ("fit", "finish", *CASE_STAGES, TOYOTA_WIRE_STAGE, *ILLUMINATION_STAGES, *SINGLE_BOARD_STAGES)
TOYOTA_WIRE_INPUTS = {
    "4Runner_Service_Assembly.FCStd": "84002c5af565bca797f26163f6fd9ad3397c3ce5a11e3b6dd848b5ad0df542bd",
    "mechanical-observation.json": "aa3b2e89732137c8a1d4c2c704ca51abe5f78918afa115f2fd0c60797c0e4e33",
    "harness-pads.json": "1d5c0659ea3913635e00d4842bff13b3f041e8bc4d713b9637d2c5a39bae3c81",
}
TOYOTA_INPUTS = {
    f"{NAME}.kicad_pcb": "87f9f5e0db2bc6084c099ba96d07285ab6fa8b7da0584c1f6a04517f3bc1f79b",
    f"{NAME}.kicad_sch": "054ab60e01cb183434d4a7097e09080d37df221d8a45aaa84a5ed9ad65bcae3f",
    f"{NAME}.kicad_pro": "a57a07e4fa134657c4b0aef95275871c4afa2ed8779fca6fc0c90b4c49489b5e",
    "models/MINI-3568.step": "66526bf041e5a75d96b72a060ffd766633e7abbaa5696d8b27927e055e6808fa",
    "fp-lib-table": "db27f0aad0ed086de92cbfd621762e5058981f5f2b6e842ec148ec110845c280",
    "sym-lib-table": "5a80d57842424b2909cd984fb09651532180d1d8f31a7005f05e4b4dbb2760bf",
    "VHOS.kicad_sym": "401a907a358c3b5d0887b80b4d883a8103bbe91b690f7bdac37b2a100102962a",
    "VHOS_RevB.pretty/Keystone_3568_MINI_Vertical.kicad_mod": "07b7893b9ab9268c1d536c3374d2d3ff0bde9437766565bb83e67cd462057c98",
    "VHOS_RevB.pretty/Molex_Mega-Fit_76825-0002_2x01_P5.70mm_Horizontal.kicad_mod": "b1057767ac1304a69ed7dccc05811cc2d52a172e0df05316a5b7f479a376eb46",
    "VHOS_RevB.pretty/Molex_Micro-Fit_3.0_43045-0800_2x04_P3.00mm_Horizontal.kicad_mod": "081204a5e6b56b9e233c1e3e6af8040072907a80856bb5ab65a831cf0ebde8f9",
    "Yazaki_7282-1060.stp": "3a395c88b0391df2321a68c37f330d390038b7a9a3875ca3417d1235ee711eb5",
}
ILLUMINATION_PCB_INPUTS = {
    f"{REV_C_NAME}.kicad_pcb": "9e01cb47235a15026c800d11aab8909cbcd61462a88d20f5b9ebbf30e6172835",
    f"{REV_C_NAME}.kicad_pro": "77f51773a3f8315bbf246fc3e66ccf7a0b9f1afa55ace4a3f21aec9179e29652",
    "models/MINI-3568.step": TOYOTA_INPUTS["models/MINI-3568.step"],
    "fp-lib-table": TOYOTA_INPUTS["fp-lib-table"],
    "VHOS_RevB.pretty/Keystone_3568_MINI_Vertical.kicad_mod":
        TOYOTA_INPUTS["VHOS_RevB.pretty/Keystone_3568_MINI_Vertical.kicad_mod"],
    "VHOS_RevB.pretty/RGBW_Output_5_Pads.kicad_mod":
        "832d5c703394719075d69fd7fed317f9b8af18222cff463a8d45a733a95a0505",
    "VHOS_RevB.pretty/Toyota_Power_2_Pads.kicad_mod":
        "d1ba564d9de134fdd7c9fc474880ecce98e11b85b996d3378fbac6ec8e7b775d",
}
ILLUMINATION_INPUTS = {
    **ILLUMINATION_PCB_INPUTS,
    MODULE: MODULE_SHA,
    INSERT_MODEL: INSERT_MODEL_SHA,
    "Yazaki_7282-1060.stp": TOYOTA_INPUTS["Yazaki_7282-1060.stp"],
}
SINGLE_BOARD_PCB_INPUTS = {
    f"{rev_d.NAME}.kicad_pcb": "a0f432620f3d2c502aeefb9301cbea0605b3eb5af8d814238dcc6efa6ed30335",
    f"{rev_d.NAME}.kicad_pro": "3ec71d6f579033b0ea8f5d085a3a495d6f46720c45895205c6d159911ca56f1b",
    "models/MINI-3568.step": TOYOTA_INPUTS["models/MINI-3568.step"],
    "VHOS_RevB.pretty/Keystone_3568_MINI_Vertical.kicad_mod":
        TOYOTA_INPUTS["VHOS_RevB.pretty/Keystone_3568_MINI_Vertical.kicad_mod"],
    "VHOS_RevB.pretty/RGBW_Output_5_Pads.kicad_mod":
        ILLUMINATION_PCB_INPUTS["VHOS_RevB.pretty/RGBW_Output_5_Pads.kicad_mod"],
    "VHOS_RevB.pretty/Toyota_IR1_4_Pads.kicad_mod":
        "a89e25110696637109c5c615417f5271095144ad5eb4b18aa5069db2139b001a",
}
SINGLE_BOARD_INPUTS = {**SINGLE_BOARD_PCB_INPUTS, INSERT_MODEL: INSERT_MODEL_SHA,
                       "Yazaki_7282-1060.stp": TOYOTA_INPUTS["Yazaki_7282-1060.stp"]}


def source_files():
    return {**{name: ROOT / name for name in ("design.py", "native_pcb.py", "mechanical_audit.py", "engineering_job.py",
                                             "engineering-inputs.json", "service_case.py", "service-case.json",
                                             "durable_case.py", "durable-case.json", "print_screen.py",
                                             "toyota_power.py", "toyota_power_case.py", "toyota-power.json",
                                             "wire_routing.py", "toyota-wire-route.json",
                                             "illumination.py", "illumination_pcb.py", "illumination_cad.py",
                                             "single_board.py", "single_board_pcb.py", "single_board_case.py")},
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
    if params["stage"] not in STAGES or type(params["timeout_sec"]) is not int or not 60 <= params["timeout_sec"] <= 900:
        raise ValueError("unsupported stage or deadline")
    inputs = {MODULE: MODULE_SHA}
    if params["stage"] in TOYOTA_STAGES:
        inputs.update(TOYOTA_INPUTS)
    elif params["stage"] in CASE_STAGES:
        inputs[ROUTED_SHIELD] = ROUTED_SHIELD_SHA
    if params["stage"] in SERVICE_STAGES:
        inputs[INSERT_MODEL] = INSERT_MODEL_SHA
    if params["stage"] == TOYOTA_WIRE_STAGE:
        inputs = TOYOTA_WIRE_INPUTS
    if params["stage"] in ILLUMINATION_STAGES:
        inputs = ILLUMINATION_INPUTS if params["stage"] == ILLUMINATION_STAGE else ILLUMINATION_PCB_INPUTS
    if params["stage"] in SINGLE_BOARD_STAGES:
        inputs = SINGLE_BOARD_INPUTS if params["stage"] == SINGLE_BOARD_STAGE else SINGLE_BOARD_PCB_INPUTS
    for name, expected in inputs.items():
        asset = ROOT / "inputs" / name
        if asset.is_symlink() or not asset.is_file() or sha(asset) != expected:
            raise ValueError(f"{name} reference input hash mismatch")
    return dict(params)


def register(modeling):
    modeling.JOB_TYPES[JOB_TYPE] = {
        "runtime": "python", "script": Path(__file__),
        "description": "Native KiCad Rev B and FreeCAD enclosure fit evaluation",
        "params": {"stage": "/".join(STAGES), "expected_source_set_sha256": "source pin",
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

    rev_c = params["stage"] == TOYOTA_REV_C_STAGE
    rev_d_stage = params["stage"] in ILLUMINATION_STAGES
    rev_e_stage = params["stage"] in SINGLE_BOARD_STAGES
    output_name = rev_e.NAME if rev_e_stage else rev_d.NAME if rev_d_stage else REV_C_NAME if rev_c else NAME
    pcb, sch = out / (output_name + ".kicad_pcb"), out / (output_name + ".kicad_sch")
    pcb_tool = [PYTHON, "-I", "-B", ROOT / "native_pcb.py"]
    cad_tool = [sys.executable, "-I", "-B", ROOT / "mechanical_audit.py"]

    def fabrication(fab):
        gerbers = fab / "gerbers"
        gerbers.mkdir(parents=True)
        run("gerber", CLI, "pcb", "export", "gerbers", "-o", gerbers,
            "-l", "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,F.Paste,Edge.Cuts", pcb)
        run("drill", CLI, "pcb", "export", "drill", "--format", "excellon", "--excellon-separate-th",
            "--generate-map", "--map-format", "pdf", "-o", gerbers, pcb)
        run("placement", CLI, "pcb", "export", "pos", "--format", "csv", "--units", "mm",
            "--side", "front", "--smd-only", "-o", fab / "SMT-placement.csv", pcb)

    try:
        if rev_d_stage or rev_e_stage:
            from toyota_power import check_reports

            if rev_e_stage:
                from single_board_pcb import stage

                if sha(KICAD_MODULE) != KICAD_MODULE_SHA:
                    raise ValueError("KiCad module model does not match the footprint-origin reference")
                stage(ROOT / "inputs", out, KICAD_MODULE)
            else:
                rev_d.stage_board(ROOT / "inputs", out)
            action = "single" if rev_e_stage else "illumination"
            run(action + "-pads", *pcb_tool, action + "-pads", "--out", out)
            run("erc", CLI, "sch", "erc", "--format", "json", "--severity-all", "-o", out / "erc.json", sch)
            run("before-routing-drc", CLI, "pcb", "drc", "--format", "json", "--severity-all",
                "--schematic-parity", "-o", out / "before-routing-drc.json", pcb)
            run(action + "-router", JAVA, "-Xmx2g", "-XX:ActiveProcessorCount=2", "-Djava.awt.headless=true",
                "-jar", ROUTER, "-de", out / "shield.dsn", "-do", out / "shield.ses",
                  "--router.autorouter.max_passes=30", "--router.copper_to_edge_clearance_um=350",
                "--router.automatic_neckdown=false", "--router.fanout.enabled=false", "--router.strict_drc=true",
                "--router.optimizer.enabled=false", "-mt", "1", "-da", "-dl", "--gui.enabled=false",
                "--api_server.enabled=false", "--router.result_json=" + str(out / "router-result.json"),
                  "--user_data_path=" + str(out / "router-state"), limit=210 if rev_e_stage else 160)
            run(action + "-route", *pcb_tool, action + "-route", "--out", out)
            run("drc", CLI, "pcb", "drc", "--format", "json", "--severity-all",
                "--schematic-parity", "-o", out / "drc.json", pcb)
            findings = check_reports(out)
            fabrication(out / "prototype-fabrication")
            run("schematic-pdf", CLI, "sch", "export", "pdf", "-o", out / "schematic.pdf", sch)
            run("shield-render", CLI, "pcb", "render", "--width", "1800", "--height", "1100",
                "--quality", "basic", "--background", "opaque", "--side", "top", "-o", out / "shield.png", pcb)
            run("shield-step", CLI, "pcb", "export", "step", "--subst-models", "--no-dnp",
                "--user-origin", "100x153.34mm", "-f", "-o", out / ROUTED_SHIELD, pcb, limit=160)
            if params["stage"] == ILLUMINATION_STAGE:
                run("toyota-power-case", *cad_tool, TOYOTA_POWER_STAGE, "--out", out, limit=350)
                run("illumination-wire-fit", *cad_tool, ILLUMINATION_STAGE, "--out", out, limit=220)
            if params["stage"] == SINGLE_BOARD_STAGE:
                run("single-board-case", *cad_tool, SINGLE_BOARD_STAGE, "--out", out, limit=480)
            if params["stage"] in (ILLUMINATION_STAGE, SINGLE_BOARD_STAGE):
                run("support-free-print-screen", sys.executable, "-I", "-B",
                    ROOT / "print_screen.py", "--out", out, limit=120)
            return {"stage": params["stage"], "pcb_findings": findings,
                    "physical_fit_verified": False, "manufacturing_released": False}
        if params["stage"] == TOYOTA_WIRE_STAGE:
            run("wire-routing", *cad_tool, TOYOTA_WIRE_STAGE, "--out", out, limit=300)
            return {"stage": TOYOTA_WIRE_STAGE, "physical_fit_verified": False,
                    "manufacturing_released": False}
        if params["stage"] in TOYOTA_STAGES:
            from toyota_power import check_reports, prepare_native

            prepare_native(ROOT / "inputs", out, NAME, dedicated_pads=rev_c)
            if rev_c:
                run("direct-lead-pads", *pcb_tool, "direct-lead-pads", "--out", out)
            run("erc", CLI, "sch", "erc", "--format", "json", "--severity-all", "-o", out / "erc.json", sch)
            run("drc", CLI, "pcb", "drc", "--format", "json", "--severity-all", "--schematic-parity", "-o", out / "drc.json", pcb)
            findings = check_reports(out)
            if rev_c:
                fabrication(out / "prototype-fabrication")
                run("schematic-pdf", CLI, "sch", "export", "pdf", "-o", out / "schematic.pdf", sch)
                run("shield-render", CLI, "pcb", "render", "--width", "1800", "--height", "1100",
                    "--quality", "basic", "--background", "opaque", "--side", "top", "-o", out / "shield.png", pcb)
            run("shield-step", CLI, "pcb", "export", "step", "--subst-models", "--no-dnp", "--user-origin", "100x153.34mm",
                "-f", "-o", out / ROUTED_SHIELD, pcb, limit=160)
            run("toyota-power-case", *cad_tool, TOYOTA_POWER_STAGE, "--out", out, limit=370)
            run("support-free-print-screen", sys.executable, "-I", "-B", ROOT / "print_screen.py", "--out", out, limit=195)
            return {"stage": params["stage"], "pcb_findings": findings,
                    "physical_fit_verified": False, "manufacturing_released": False}
        if params["stage"] in CASE_STAGES:
            shutil.copyfile(ROOT / "inputs" / ROUTED_SHIELD, out / ROUTED_SHIELD)
            durable = params["stage"] == "durable-case"
            run("manufacturing-case", *cad_tool, params["stage"], "--out", out, limit=370 if durable else 285)
            if durable:
                run("support-free-print-screen", sys.executable, "-I", "-B",
                    ROOT / "print_screen.py", "--out", out, limit=195)
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
            fabrication(fab)
            shutil.copyfile(out / "PCB-BOM.csv", fab / "PCB-BOM.csv")
        return {"stage": params["stage"], "pcb_findings": findings,
                "physical_fit_verified": False, "manufacturing_released": False}
    finally:
        validate(params)
        artifacts = [{"name": f.relative_to(out).as_posix(), "bytes": f.stat().st_size, "sha256": sha(f)}
                     for f in sorted(out.rglob("*")) if f.is_file() and f.name != "engineering-manifest.json"]
        report = {"contract": CONTRACT, "device": "orion", "params": params,
                  "sources": {key: sha(path) for key, path in source_files().items()},
                  "artifacts": artifacts,
                  "manufacturing_released": False, "vehicle_fit_or_electrical_qualified": False}
        if params["stage"] == TOYOTA_WIRE_STAGE:
            report["contract"] = "vhos_rgbw_revc_toyota_wire_routing_v1"
            report["assembly_inputs"] = TOYOTA_WIRE_INPUTS
        else:
            report["esp_module_reference_sha256"] = MODULE_SHA
        if params["stage"] in TOYOTA_STAGES:
            report["contract"] = {TOYOTA_POWER_STAGE: "vhos_rgbw_revb_toyota_power_v1",
                                  TOYOTA_REV_C_STAGE: "vhos_rgbw_revc_toyota_power_v1"}[params["stage"]]
            report["toyota_power_inputs"] = TOYOTA_INPUTS
        elif params["stage"] in CASE_STAGES:
            report["published_routed_shield_sha256"] = ROUTED_SHIELD_SHA
        if params["stage"] in SERVICE_STAGES:
            report["ruthex_reference_sha256"] = INSERT_MODEL_SHA
        if rev_d_stage:
            report["contract"] = rev_d.CONTRACT
            report["inputs"] = ILLUMINATION_INPUTS if params["stage"] == ILLUMINATION_STAGE else ILLUMINATION_PCB_INPUTS
        if rev_e_stage:
            report["contract"] = rev_e.CONTRACT
            report["inputs"] = SINGLE_BOARD_INPUTS if params["stage"] == SINGLE_BOARD_STAGE else SINGLE_BOARD_PCB_INPUTS
            report["esp_module_reference_sha256"] = KICAD_MODULE_SHA
        (out / "engineering-manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--params", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(execute(json.loads(args.params.read_text()), args.out.resolve())))
