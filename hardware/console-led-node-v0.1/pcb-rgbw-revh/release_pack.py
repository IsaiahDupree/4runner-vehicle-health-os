"""Build and CRC-check the explicit engineering handoff archives on owned Orion."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import zipfile


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--staged", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Windows" or platform.node().split(".")[0].lower() != "orion":
        raise RuntimeError("Release archive compression runs on Orion")
    plan = json.loads(args.plan.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    results = {}
    for archive in plan["archives"]:
        name = archive["name"]
        if PurePosixPath(name).name != name or not name.endswith(".zip"):
            raise ValueError("Expected a ZIP filename")
        entries = archive["entries"]
        seen = set()
        for entry in entries:
            for field in ("staged", "path"):
                rel = PurePosixPath(entry[field])
                if rel.is_absolute() or ".." in rel.parts or "\\" in str(rel) or ":" in str(rel):
                    raise ValueError("Unsafe archive path")
            if entry["path"] in seen:
                raise ValueError("Duplicate archive entry")
            seen.add(entry["path"])
            source = args.staged / entry["staged"]
            if source.stat().st_size != entry["bytes"] or sha256(source) != entry["sha256"]:
                raise ValueError("Staged input changed: " + entry["path"])
        target = args.output / name
        with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as writer:
            for entry in entries:
                writer.write(args.staged / entry["staged"], entry["path"])
            manifest = {"source_commit": plan["source_commit"], "archive": name,
                        "entries": [{k: value for k, value in entry.items() if k != "staged"}
                                    for entry in entries],
                        "physical_acceptance": "pending"}
            writer.writestr("CONTENTS-SHA256.json", json.dumps(manifest, indent=2) + "\n")
        with zipfile.ZipFile(target) as reader:
            if reader.testzip() is not None:
                raise RuntimeError("Archive CRC validation failed")
        results[name] = {"bytes": target.stat().st_size, "sha256": sha256(target),
                         "files": len(entries) + 1, "crc_passed": True}
    (args.output / "archive-receipt.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results), flush=True)


if __name__ == "__main__":
    main()
