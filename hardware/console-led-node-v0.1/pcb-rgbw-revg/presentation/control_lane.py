"""Run a private, temporary Orion lane for this CAD film and its native narration."""
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
    ap.add_argument("--lifetime", type=int, default=3500)
    args = ap.parse_args()
    if platform.system() != "Windows" or platform.node().lower().split(".")[0] != "orion":
        raise RuntimeError("Orion Windows is required")
    if not 120 <= args.lifetime <= 7200 or args.control_home.drive.upper() != "C:":
        raise ValueError("Use a bounded task on the available Orion C drive")
    home = args.control_home
    home.mkdir(parents=True, exist_ok=True)
    os.environ.update({
        "ORION_CONTROL_HOME": str(home),
        "ORION_WORKER_HOME": str(home / "workers"),
        "ORION_WORKER_INPUT_ROOT": str(home / "inputs"),
        "ORION_CONTROL_TOKEN_FILE": "C:/orion/control/token",
        "ORION_ISAIAH_VOICES_FILE": "C:/orion/control/isaiah-voices.json",
        "ORION_FOUNDRY_PROJECTS_FILE": "C:/orion/control/foundry-projects.json",
        "ORION_RECEIPTS_PATH": str(home / "receipts.jsonl"),
        "ORION_CONTROL_BIND": "127.0.0.1", "ORION_CONTROL_PORT": "8857",
        "ORION_CONSOLE_CONTROL_ROOT": "C:/orion/control-plane",
        "PYTHONDONTWRITEBYTECODE": "1",
    })
    for name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
        os.environ[name] = "2"
    sys.path.insert(0, "C:/orion/control-plane")
    # Reuse the currently running control release, which includes the consented
    # voice extension. Its worker storage is directed to this task's C drive.
    sys.path.insert(0, "C:/orion/releases/orion-control-plane-cad-prepare-20261110-09d1d473b5c5")
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from modeling import orion_modeling
    import film_job
    film_job.register(orion_modeling)
    orion_modeling.JOB_TYPES = {film_job.JOB_TYPE: orion_modeling.JOB_TYPES[film_job.JOB_TYPE]}

    def validate(kind, params):
        if kind != film_job.JOB_TYPE:
            raise ValueError("The registered Rev G film job is required")
        return film_job.validate(params)

    def command(kind, directory, params=None):
        validate(kind, params)
        return [sys.executable, "-I", "-B", str(Path(film_job.__file__)),
                "--params", str(directory / "params.json"), "--out", str(directory / "out")]

    orion_modeling.validate_params = validate
    orion_modeling.runtime_command = command
    orion_modeling.topic_capabilities = lambda _: {
        "device": "orion", "source_sha256": film_job.source_pin(),
        "job_types": {film_job.JOB_TYPE: {"stages": ["export", "preview", "pictures", "film"]}},
        "concurrency": 1,
    }
    # Import the active release's worker before the API adds its own source root.
    from workers import orion_workers
    if "audio.isaiah_tts" not in orion_workers.JOB_TYPES:
        raise RuntimeError("The registered Isaiah voice extension is missing")
    spec = importlib.util.spec_from_file_location(
        "revg_film_api", "C:/orion/control-plane/control-api/orion_control_api.py")
    api = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(api)
    allowed = {"health", "modeling.capabilities", "modeling.submit", "modeling.status",
               "modeling.artifacts", "modeling.cancel", "workers.capabilities",
               "workers.submit", "workers.status", "workers.logs", "workers.cancel", "workers.artifacts"}
    api.TOPICS = {name: handler for name, handler in api.TOPICS.items() if name in allowed}
    server = api.ThreadingHTTPServer(("127.0.0.1", 8857), api.Handler)
    timer = threading.Timer(args.lifetime, server.shutdown)
    timer.daemon = True
    timer.start()
    print("Rev G film lane listening on 127.0.0.1:8857", flush=True)
    try:
        server.serve_forever()
    finally:
        timer.cancel()
        server.server_close()
        pending = orion_modeling.worker().snapshot()["running"]
        if pending:
            orion_modeling.worker().cancel(pending, "revg-film-lifetime")


if __name__ == "__main__":
    main()
