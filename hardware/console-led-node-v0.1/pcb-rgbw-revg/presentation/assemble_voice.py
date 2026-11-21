"""Join the accepted native voice PCM on Orion and retain measured chapter timing."""
import argparse
from hashlib import sha256
import json
from math import ceil
from pathlib import Path
import platform
import wave


def assemble(root):
    if platform.node().split(".")[0].lower() != "orion":
        raise RuntimeError("Assemble the accepted voice on Orion")
    index = json.loads((root / "voice-index.json").read_text())
    fps = 24
    sample_rate = 24000
    cursor = 1
    timeline = []
    for row in index:
        source = root / row["file"]
        if sha256(source.read_bytes()).hexdigest() != row["sha256"]:
            raise ValueError("Voice stem hash mismatch " + row["id"])
        with wave.open(str(source)) as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, sample_rate):
                raise ValueError("Expected the native 24 kHz mono 16-bit PCM")
            duration = audio.getnframes() / sample_rate
        if abs(duration - row["duration"]) > .02:
            raise ValueError("Narration timing differs from its receipt")
        last = cursor + 10 + ceil(duration * fps) + 14
        timeline.append({**row, "start_frame": cursor, "speech_start_frame": cursor + 10,
                         "end_frame": last})
        cursor = last + 1
    total = timeline[-1]["end_frame"] * (sample_rate // fps)
    with wave.open(str(root / "narration.wav"), "wb") as output:
        output.setparams((1, 2, sample_rate, 0, "NONE", "not compressed"))
        cursor = 0
        for row in timeline:
            start = (row["speech_start_frame"] - 1) * (sample_rate // fps)
            output.writeframesraw(b"\0\0" * (start - cursor))
            with wave.open(str(root / row["file"])) as audio:
                output.writeframesraw(audio.readframes(audio.getnframes()))
                cursor = start + audio.getnframes()
        output.writeframesraw(b"\0\0" * (total - cursor))
    (root / "timeline.json").write_text(json.dumps(timeline, indent=2) + "\n")
    print(json.dumps({"duration": total / sample_rate,
                      "sha256": sha256((root / "narration.wav").read_bytes()).hexdigest()}))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("prepared", type=Path)
    assemble(ap.parse_args().prepared)
