"""Task-scoped authenticated Orion CAD lane using the existing control-plane worker."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
import platform
from pathlib import Path
import sys
import threading

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT))
import case_job as job


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control-root','control-home','token-file'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--port',type=int,default=8849)
    parser.add_argument('--lifetime-sec',type=int,default=1800)
    args=parser.parse_args()
    if platform.system()!='Windows' or args.port!=8849 or not 120<=args.lifetime_sec<=3600:
        raise ValueError('Orion Windows, private port 8849, bounded lifetime required')
    for path in (args.control_root,args.token_file):
        if not path.is_absolute() or path.is_symlink() or not path.exists():
            raise ValueError('existing absolute operator configuration required')
    if not args.control_home.is_absolute() or args.control_home.is_symlink():
        raise ValueError('absolute task control home required')
    args.control_home.mkdir(parents=True,exist_ok=True)
    os.environ.update(ORION_CONTROL_HOME=str(args.control_home),ORION_CONTROL_TOKEN_FILE=str(args.token_file),
                      ORION_CONTROL_BIND='127.0.0.1',ORION_CONTROL_PORT=str(args.port),
                      ORION_CONSOLE_CONTROL_ROOT=str(args.control_root),
                      ORION_RECEIPTS_PATH=str(args.control_home/'receipts.jsonl'),PYTHONDONTWRITEBYTECODE='1')
    os.environ.pop('ORION_CONTROL_TOKEN',None)
    for name in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','NUMEXPR_NUM_THREADS'):
        os.environ[name]='2'
    sys.path.insert(0,str(args.control_root))
    from modeling import orion_modeling as modeling
    job.register(modeling)
    def validate(kind,params):
        if kind!=job.JOB_TYPE: raise ValueError('only the fixed console fit-check job is admitted')
        return job.validate(params)
    def command(kind,directory,params=None):
        if kind!=job.JOB_TYPE: raise ValueError('dedicated console job only')
        return [sys.executable,'-I','-B',str(ROOT/'case_job.py'),'--params',str(directory/'params.json'),'--out',str(directory/'out')]
    def capabilities(_):
        return {'device':'orion','concurrency':1,'queue':modeling.worker().snapshot(),
                'job_types':{job.JOB_TYPE:{k:v for k,v in modeling.JOB_TYPES[job.JOB_TYPE].items() if k!='script'}},
                'source_sha256':job.sha(ROOT/'case_job.py'),'inputs_sha256':job.sha(ROOT/'design-inputs.json')}
    modeling.validate_params=validate
    modeling.runtime_command=command
    modeling.topic_capabilities=capabilities
    modeling.JOB_TYPES={job.JOB_TYPE:modeling.JOB_TYPES[job.JOB_TYPE]}
    spec=importlib.util.spec_from_file_location('vhos_console_private_api',args.control_root/'control-api/orion_control_api.py')
    api=importlib.util.module_from_spec(spec);spec.loader.exec_module(api)
    allowed={'health','modeling.capabilities','modeling.submit','modeling.status','modeling.artifacts','modeling.cancel'}
    api.TOPICS={k:v for k,v in api.TOPICS.items() if k in allowed}
    server=api.ThreadingHTTPServer(('127.0.0.1',args.port),api.Handler)
    timer=threading.Timer(args.lifetime_sec,server.shutdown);timer.daemon=True;timer.start()
    print(json.dumps({'event':'console_fitcheck_controller_started','pid':os.getpid(),'port':args.port,
                      'source_sha256':job.sha(ROOT/'case_job.py')}),flush=True)
    try:
        server.serve_forever()
    finally:
        timer.cancel();server.server_close()
        current=modeling.worker().snapshot()['running']
        if current: modeling.worker().cancel(current,'console-fitcheck-lifetime')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
