"""Build readable captions from the measured Orion transcript word spans."""
import argparse
import json
from pathlib import Path


def timestamp(value):
    ms = round(value * 1000)
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def write(analysis, out):
    data = json.loads(analysis.read_text())
    if not data["passed"] or not data["timing_validation"]["passed"]:
        raise ValueError("The measured speech timing must pass inspection")
    words = data["words"]
    cleaned = []
    index = 0
    while index < len(words):
        word = dict(words[index])
        # Reviewed spelling corrections retain the measured phrase span.
        if word["text"].lower().strip(".,") == "esp32's" and index + 1 < len(words):
            if words[index + 1]["text"].lower().strip(".,") == "three":
                word.update(text="ESP32-S3", end=words[index + 1]["end"])
                index += 1
        if word["text"].lower().strip(".,") == "ceiling":
            word["text"] = word["text"].replace("ceiling", "sealing")
        if not word["timed"] or word["end"] < word["start"]:
            raise ValueError("Caption words must have valid measured times")
        cleaned.append(word)
        index += 1
    captions, batch = [], []
    for index, word in enumerate(cleaned):
        batch.append(word)
        text = " ".join(row["text"] for row in batch)
        gap = index + 1 == len(cleaned) or cleaned[index + 1]["start"] - word["end"] > .42
        if len(batch) >= 8 or len(text) > 64 or gap or word["text"].endswith((".", "?", "!")):
            captions.append({"text": text, "start": batch[0]["start"], "end": batch[-1]["end"]})
            batch = []
    if batch:
        raise RuntimeError("Unflushed caption words")
    out.mkdir(exist_ok=True)
    (out / "captions.json").write_text(json.dumps(captions, indent=2) + "\n")
    srt = "\n\n".join(f"{i}\n{timestamp(row['start'])} --> {timestamp(row['end'])}\n{row['text']}"
                       for i, row in enumerate(captions, 1))
    (out / "captions.srt").write_text(srt + "\n")
    print(f"{len(captions)} caption cues from {len(words)} measured words")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("analysis", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()
    write(args.analysis, args.output)
