"""Submit and retrieve one source-pinned owned-hardware engineering job."""

import argparse
import json
from pathlib import Path
import re
import select
import shutil
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from engineering_job import (CASE_STAGES, INSERT_MODEL, INSERT_MODEL_SHA, JOB_TYPE, MODULE,
                             MODULE_SHA, ROOT, ROUTED_SHIELD, ROUTED_SHIELD_SHA, SERVICE_STAGES, STAGES,
                             TOYOTA_INPUTS, TOYOTA_POWER_STAGE, sha, source_files, source_pin)


ARTIFACTS = ROOT.parents[3] / "artifacts/4runner-rgbw-shield-revb-2026-11-12"
PORT = 8853
ACTOR = "vhos-rgbw-revb"
SSH = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]


def remote(script):
    return subprocess.check_output([*SSH, "orion", script], text=True, timeout=20).strip()


def call(topic, params=None, request_id=None):
    token = (Path.home() / ".orion-control/token").read_text().strip()
    body = {"actor": ACTOR, "params": params or {}}
    if request_id:
        body["request_id"] = request_id
    req = Request(f"http://127.0.0.1:{PORT}/api/services/orion/{topic}", json.dumps(body).encode(),
                  headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    with urlopen(req, timeout=8) as response:
        result = json.load(response)
    if not result.get("ok", True) or "result" not in result:
        raise RuntimeError(str(result))
    return result["result"]


def record(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def start(identity, folder, stage):
    work = f"C:/orion/projects/{ACTOR}-{identity}"
    control = f"C:/orion/control/{ACTOR}-{identity}"
    socket = f"/tmp/{ACTOR}-{identity}.sock"
    inputs = {MODULE: (MODULE_SHA, ROOT.parents[3] / "artifacts/4runner-console-cad-2026-11-07" / MODULE)}
    if stage == TOYOTA_POWER_STAGE:
        inputs.update({name: (digest, ROOT / "generated" / name) for name, digest in TOYOTA_INPUTS.items()})
        toyota = "Yazaki_7282-1060.stp"
        inputs[toyota] = (TOYOTA_INPUTS[toyota],
                          ROOT.parents[3] / "artifacts/4runner-console-connector-map-2026-11-07/references" / toyota)
    elif stage in CASE_STAGES:
        inputs[ROUTED_SHIELD] = (ROUTED_SHIELD_SHA, ARTIFACTS / "finish-04" / "output" / ROUTED_SHIELD)
    if stage in SERVICE_STAGES:
        inputs[INSERT_MODEL] = (INSERT_MODEL_SHA, ROOT.parents[3] / "artifacts/4runner-console-cad-2026-11-07" / INSERT_MODEL)
    references = {}
    for name, (expected, fallback) in inputs.items():
        candidates = (ROOT / "inputs" / name, fallback)
        reference = next((path for path in candidates if path.is_file() and sha(path) == expected), None)
        if reference is None:
            raise FileNotFoundError(f"Source-pinned {name} required at one of {candidates}")
        references[name] = reference
    for path in source_files().values():
        if path.suffix == ".py":
            compile(path.read_text(), str(path), "exec")
    remote(f"if (Test-Path '{work}') {{ throw 'Existing task source directory' }}; "
           f"if (Get-NetTCPConnection -State Listen -LocalPort {PORT} -ErrorAction SilentlyContinue) "
           "{ throw 'Task port in use' }; "
           f"New-Item -ItemType Directory -Force '{work}/inputs','{control}' | Out-Null")
    with tempfile.TemporaryDirectory(prefix="vhos-revb-stage-") as tmp:
        staging = Path(tmp)
        for relative_path, source in source_files().items():
            target = staging / relative_path
            target.parent.mkdir(exist_ok=True, parents=True)
            shutil.copyfile(source, target)
        (staging / "inputs").mkdir()
        for name, reference in references.items():
            target = staging / "inputs" / name
            target.parent.mkdir(exist_ok=True, parents=True)
            shutil.copyfile(reference, target)
        subprocess.run(["scp", "-q", "-r", "-o", "BatchMode=yes", str(staging) + "/.", f"orion:{work}/"],
                       check=True, timeout=45)
    boot = (f"$taskArgs = '-I -B {work}/run_isolated_engineering.py --control-root C:/orion/control-plane "
            f"--control-home {control} --token-file C:/orion/control/token --port {PORT} --lifetime-sec 1500'; "
            f"$p = Start-Process -FilePath (Get-Command python.exe).Source -ArgumentList $taskArgs "
            f"-WindowStyle Hidden -PassThru -RedirectStandardOutput '{control}/controller.log' "
            f"-RedirectStandardError '{control}/controller.err'; $p.Id; Wait-Process -Id $p.Id")
    # The remote OpenSSH job owns its child process. Keep this SSH session
    # open until the task controller shuts down or stop verifies its PID.
    with (folder / "bootstrap.log").open("wb") as log:
        service = subprocess.Popen([*SSH, "orion", boot], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=log, start_new_session=True)
        if not select.select([service.stdout], [], [], 12)[0]:
            service.terminate()
            raise TimeoutError("Orion did not return a controller PID")
        pid = int(service.stdout.readline().strip())
        service.stdout.close()
    lane = {"pid": pid, "work": work, "control": control, "socket": socket}
    record(folder / "lane.json", lane)
    subprocess.run([*SSH, "-M", "-S", socket, "-fN", "-o", "ExitOnForwardFailure=yes",
                    "-L", f"127.0.0.1:{PORT}:127.0.0.1:{PORT}", "orion"], check=True, timeout=15)
    for attempt in range(22):
        try:
            capability = call("modeling.capabilities")
            break
        except HTTPError:
            raise
        except (URLError, ConnectionError):
            if attempt == 21:
                raise
            time.sleep(.4)
    if capability["source_sha256"] != source_pin() or set(capability["job_types"]) != {JOB_TYPE}:
        raise RuntimeError("task controller source pin mismatch")
    params = {"stage": stage, "expected_source_set_sha256": source_pin(), "evaluation_only": True,
              "timeout_sec": {"finish": 880, "durable-case": 660, TOYOTA_POWER_STAGE: 850}.get(stage, 360)}
    result = call("modeling.submit", {"job_type": JOB_TYPE, "params": params}, f"{ACTOR}-{identity}")
    record(folder / "submission.json", result)
    return result


def status(folder):
    submission = json.loads((folder / "submission.json").read_text())
    result = call("modeling.status", {"job_id": submission["job_id"]})
    record(folder / "status.json", result)
    return result


def fetch(folder, result):
    if result["status"] not in {"succeeded", "failed", "cancelled"}:
        raise RuntimeError("wait for the terminal job state")
    output = folder / "output"
    output.mkdir(exist_ok=True)
    path = result["job_dir"].replace("\\", "/") + "/out/."
    subprocess.run(["scp", "-q", "-r", "-o", "BatchMode=yes", "orion:" + path, str(output)],
                   check=True, timeout=60)
    for row in result["artifacts"]:
        file = output / row["name"]
        if file.stat().st_size != row["bytes"] or sha(file) != row["sha256"]:
            raise RuntimeError(f"corrupted artifact {row['name']}")
    print(f"Verified {len(result['artifacts'])} outputs in {output}")


def stop(folder):
    lane = json.loads((folder / "lane.json").read_text())
    if (folder / "submission.json").exists():
        result = status(folder)
        if result["status"] not in {"succeeded", "failed", "cancelled"}:
            raise RuntimeError("the task job is still active")
    pid = int(lane["pid"])
    work = lane["work"]
    outcome = remote(f"$p = Get-CimInstance Win32_Process -Filter 'ProcessId={pid}'; "
                     f"if ($p -and $p.CommandLine.Contains('{work}/run_isolated_engineering.py')) "
                     f"{{ Stop-Process -Id {pid} -ErrorAction Stop; 'stopped' }} "
                     "elseif (!$p) { 'already exited' } else { throw 'PID identity changed' }")
    subprocess.run([*SSH, "-S", lane["socket"], "-O", "exit", "orion"], timeout=10, check=False)
    record(folder / "cleanup.json", {"controller_pid": pid, "result": outcome})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "status", "fetch", "stop"])
    parser.add_argument("identity")
    parser.add_argument("--stage", choices=STAGES, default="fit")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,25}", args.identity):
        raise ValueError("invalid task identity")
    folder = ARTIFACTS / args.identity
    if args.action == "start":
        folder.mkdir(parents=True, exist_ok=False)
        try:
            result = start(args.identity, folder, args.stage)
        except Exception:
            if (folder / "lane.json").exists() and not (folder / "submission.json").exists():
                stop(folder)
            raise
    elif args.action == "stop":
        stop(folder)
        raise SystemExit(0)
    else:
        result = status(folder)
        if args.action == "fetch":
            fetch(folder, result)
    print(json.dumps({key: result.get(key) for key in ("job_id", "status", "error", "duration_sec")}))
