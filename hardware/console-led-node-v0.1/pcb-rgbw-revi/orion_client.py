"""Stage a fixed Rev I job; use short authenticated SSH/API exchanges for status."""
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
ARTIFACTS = REPO.parent / "artifacts/4runner-revi-terminals-2026-11-21"


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
    for path in (ROOT.parent / "pcb-rgbw-revh" / "references").iterdir():
        files["references/" + path.name] = path
    revg = ROOT.parent / "pcb-rgbw-revh/generated"
    for ext in ("kicad_pcb", "kicad_pro"):
        files["inputs/vhos_rgbw_revh." + ext] = revg / ("vhos_rgbw_revh." + ext)
    for directory in ("VHOS_RevB.pretty", "models"):
        for path in (revg / directory).rglob("*"):
            if path.is_file():
                files["inputs/" + path.relative_to(revg).as_posix()] = path
    files["inputs/fp-lib-table"] = revg / "fp-lib-table"
    files["inputs/mechanical-observation.json"] = ROOT.parent / "pcb-rgbw-revg/generated/mechanical-observation.json"
    files["inputs/ruthex_RX-M3x5_7.stp"] = ROOT.parent / "pcb-rgbw-revh/references/ruthex_RX-M3x5_7.stp"
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
    spec = importlib.util.spec_from_file_location("revi_job", staging / "terminal_job.py")
    job = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(job)
    pin = job.source_pin()
    work = "C:/orion/projects/revi-" + identity
    home = "C:/orion/control/revi-" + identity
    params = {"operation": operation, "source_sha256": pin, "evaluation_only": True, "timeout_sec": 1500}
    (staging / "request.json").write_text(json.dumps({"actor": "4runner-revi-terminals",
        "request_id": "revi-" + identity, "params": {"job_type": job.JOB_TYPE, "params": params}}))
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


PORT = 8860
ACTOR = "4runner-revi-voltage"


def api(topic, params=None, request_id=None):
    from urllib.request import Request, urlopen
    token = (Path.home()/".orion-control/token").read_text().strip()
    body = {"actor": ACTOR, "params": params or {}}
    if request_id: body["request_id"] = request_id
    request = Request(f"http://127.0.0.1:{PORT}/api/services/orion/{topic}",
                      json.dumps(body).encode(), headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"})
    with urlopen(request,timeout=10) as r: result=json.load(r)
    if not result.get("ok",True) or "result" not in result: raise RuntimeError(str(result))
    return result["result"]


def submit(identity, operation, extra):
    import select, time
    lane=stage(identity,operation,extra)
    folder=ARTIFACTS/identity
    work,home=lane["work"],lane["control"]
    remote(f"if(Get-NetTCPConnection -State Listen -LocalPort {PORT} -ErrorAction SilentlyContinue){{throw 'Task port occupied'}}")
    boot=(f"$p=Start-Process -FilePath (Get-Command python.exe).Source -ArgumentList '-I -B {work}/control_lane.py --control-home {home} --lifetime 3600' "
          f"-WindowStyle Hidden -PassThru -RedirectStandardOutput '{home}/controller.log' -RedirectStandardError '{home}/controller.err'; "
          "$p.Id; Wait-Process -Id $p.Id")
    encoded=base64.b64encode(boot.encode('utf-16le')).decode()
    with (folder/'bootstrap.log').open('wb') as log:
        child=subprocess.Popen(['ssh','-T','-o','BatchMode=yes','orion','powershell','-NoProfile','-EncodedCommand',encoded],
           stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=log,start_new_session=True)
        if not select.select([child.stdout],[],[],15)[0]:
            child.terminate();raise TimeoutError('Controller PID not returned')
        lane['pid']=int(child.stdout.readline().strip());child.stdout.close()
    lane['socket']=f'/tmp/4runner-revi-{identity}.sock'
    (folder/'lane.json').write_text(json.dumps(lane,indent=2)+'\n')
    subprocess.run(['ssh','-T','-o','BatchMode=yes','-M','-S',lane['socket'],'-fN',
        '-o','ExitOnForwardFailure=yes','-L',f'127.0.0.1:{PORT}:127.0.0.1:{PORT}','orion'],check=True,timeout=20)
    for attempt in range(25):
        try:
            cap=api('modeling.capabilities');break
        except Exception:
            if attempt==24:raise
            time.sleep(.4)
    if cap['source_sha256']!=lane['source_sha256'] or cap['job_types']!=['pcb.vhos_revi_voltage']:
        raise RuntimeError('Source-pinned task capabilities differ')
    request=json.loads((folder/'stage/request.json').read_text())
    result=api('modeling.submit',request['params'],request['request_id'])
    (folder/'submission.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def status(identity):
    folder=ARTIFACTS/identity
    job=json.loads((folder/'submission.json').read_text())['job_id']
    result=api('modeling.status',{'job_id':job})
    (folder/'status.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def fetch(identity):
    result=status(identity)
    if result['status'] not in {'succeeded','failed','cancelled'}:raise RuntimeError('Wait for terminal state')
    output=ARTIFACTS/identity/'output';output.mkdir(exist_ok=True)
    path=result['job_dir'].replace('\\','/')+'/out/.'
    subprocess.run(['scp','-q','-r','orion:'+path,str(output)],check=True,timeout=60)
    for row in result['artifacts']:
        f=output/row['name']
        if f.stat().st_size!=row['bytes'] or sha(f)!=row['sha256']:raise RuntimeError('Artifact hash mismatch: '+row['name'])
    return result


def stop(identity):
    folder=ARTIFACTS/identity;lane=json.loads((folder/'lane.json').read_text())
    if (folder/'submission.json').exists() and status(identity)['status'] not in {'succeeded','failed','cancelled'}:
        raise RuntimeError('Job is still active')
    pid=int(lane['pid']);work=lane['work']
    outcome=remote(f"$p=Get-CimInstance Win32_Process -Filter 'ProcessId={pid}'; "
       f"if($p -and $p.CommandLine.Contains('{work}/control_lane.py')){{Stop-Process -Id {pid};'stopped'}} "
       "elseif(!$p){'already exited'}else{throw 'PID identity changed'}")
    subprocess.run(['ssh','-S',lane['socket'],'-O','exit','orion'],check=False,timeout=10)
    (folder/'cleanup.json').write_text(json.dumps({'controller_pid':pid,'result':outcome},indent=2)+'\n')
    return {'status':'stopped'}


if __name__ == "__main__":
    ap=argparse.ArgumentParser()
    ap.add_argument('identity')
    ap.add_argument('--action',choices=['stage','submit','status','fetch','stop'],default='stage')
    ap.add_argument('--operation',choices=['pcb','case','pictures'],default='pcb')
    ap.add_argument('--extra',type=Path)
    args=ap.parse_args()
    if not args.identity.replace('-','').isalnum() or len(args.identity)>40:raise ValueError('Short identity required')
    extra=json.loads(args.extra.read_text()) if args.extra else None
    if args.action=='stage':result=stage(args.identity,args.operation,extra)
    elif args.action=='submit':result=submit(args.identity,args.operation,extra)
    else:result={'status':status,'fetch':fetch,'stop':stop}[args.action](args.identity)
    print(json.dumps({k:result.get(k) for k in ('job_id','status','error','duration_sec')}))
