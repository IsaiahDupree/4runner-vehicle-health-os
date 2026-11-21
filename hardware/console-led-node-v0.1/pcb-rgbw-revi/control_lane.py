"""Task-scoped authenticated native-engineering lane, one bounded job at a time."""
import argparse
import importlib.util
import os
from pathlib import Path
import platform
import sys
import threading


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--control-home", type=Path, required=True)
    ap.add_argument("--lifetime", type=int, default=3600)
    args = ap.parse_args()
    if platform.system() != "Windows" or platform.node().split(".")[0].lower() != "orion":
        raise RuntimeError("Orion required")
    if not 120 <= args.lifetime <= 7200 or args.control_home.drive.upper() != "C:":
        raise ValueError("Bounded task on C drive required")
    root = Path(__file__).resolve().parent
    home = args.control_home
    home.mkdir(parents=True, exist_ok=True)
    os.environ.update(ORION_CONTROL_HOME=str(home), ORION_WORKER_HOME=str(home / "workers"),
                      ORION_CONTROL_TOKEN_FILE="C:/orion/control/token", ORION_CONTROL_BIND="127.0.0.1",
                      ORION_CONTROL_PORT="8860", ORION_CONSOLE_CONTROL_ROOT="C:/orion/control-plane",
                      ORION_RECEIPTS_PATH=str(home / "receipts.jsonl"), PYTHONDONTWRITEBYTECODE="1")
    for name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
        os.environ[name] = "2"
    sys.path.insert(0, "C:/orion/control-plane")
    sys.path.insert(0, str(root))
    import terminal_job as job
    from modeling import orion_modeling as modeling
    job.register(modeling)
    modeling.JOB_TYPES = {job.JOB_TYPE: modeling.JOB_TYPES[job.JOB_TYPE]}

    def validate(kind, params):
        if kind != job.JOB_TYPE:
            raise ValueError("Only Rev I engineering job permitted")
        return job.validate(params)

    def command(kind, directory, params=None):
        validate(kind, params)
        return [sys.executable, "-I", "-B", str(root / "terminal_job.py"),
                "--params", str(directory / "params.json"), "--out", str(directory / "out")]

    modeling.validate_params = validate
    modeling.runtime_command = command
    modeling.topic_capabilities = lambda _: {"device": "orion", "concurrency": 1,
                                             "source_sha256": job.source_pin(), "job_types": [job.JOB_TYPE]}
    spec = importlib.util.spec_from_file_location("revi_api", "C:/orion/control-plane/control-api/orion_control_api.py")
    api = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(api)
    allowed = {"health", "modeling.capabilities", "modeling.submit", "modeling.status", "modeling.cancel",
               "modeling.artifacts"}
    api.TOPICS = {k: v for k, v in api.TOPICS.items() if k in allowed}
    server = api.ThreadingHTTPServer(("127.0.0.1", 8860), api.Handler)
    timer = threading.Timer(args.lifetime, server.shutdown)
    timer.daemon = True
    timer.start()
    print("Rev I native lane 127.0.0.1:8860", flush=True)
    try:
        server.serve_forever()
    finally:
        timer.cancel()
        server.server_close()
        running = modeling.worker().snapshot()["running"]
        if running:
            modeling.worker().cancel(running, "revi-task-lifetime")


if __name__ == "__main__":
    main()
