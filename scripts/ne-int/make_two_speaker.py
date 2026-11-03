"""Builds a two-speaker test meeting from public FLEURS clips: you.wav and them.wav (16 kHz mono Int16, same
length) with the clips placed alternately and silence between them, a few overlaps, and truth.json (who said
what, when). No invented audio, no personal content: only what the benchmark manifest already holds.

    python3 -I make_two_speaker.py MANIFEST.jsonl OUTDIR [--seconds 600] [--seed 7] [--overlap-every 9]

MANIFEST.jsonl: flow-bench's data/manifest.jsonl (lines with id, dataset, lang, kind, wav, ref); the wav paths
are relative to the manifest. Uses FLEURS "clip" entries only, each once, German and English mixed.
Feed it to `IonianFlow --transcribetest you.wav them.wav`.
"""

import argparse
import array
import json
import random
import wave
from pathlib import Path

SR = 16000


def read(path: Path) -> array.array:
    with wave.open(str(path), "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, SR), path
        a = array.array("h")
        a.frombytes(w.readframes(w.getnframes()))
        return a


def write(path: Path, samples: array.array) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(samples.tobytes())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("out")
    ap.add_argument("--seconds", type=float, default=600)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--overlap-every", type=int, default=9, help="every Nth turn starts before the other speaker is done")
    args = ap.parse_args()

    manifest = Path(args.manifest)
    rows = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()]
    pool = [r for r in rows if r["dataset"] == "fleurs" and r.get("kind") == "clip" and r.get("lang") in ("de", "en")]
    rng = random.Random(args.seed)
    rng.shuffle(pool)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    total = int(args.seconds * SR)
    channels = {"you": array.array("h", bytes(2 * total)), "them": array.array("h", bytes(2 * total))}
    truth = []
    t = 0.5  # seconds
    speaker = "you"
    for turn, row in enumerate(pool, start=1):
        audio = read(manifest.parent / row["wav"])
        start = int(t * SR)
        if start + len(audio) > total:
            break
        ch = channels[speaker]
        for i, v in enumerate(audio):
            ch[start + i] = v
        end = (start + len(audio)) / SR
        truth.append({"speaker": speaker, "start": round(start / SR, 2), "end": round(end, 2), "lang": row["lang"],
                      "id": row["id"], "ref": row["ref"]})
        speaker = "them" if speaker == "you" else "you"
        overlap = args.overlap_every > 0 and turn % args.overlap_every == 0
        t = end - 1.5 if overlap else end + rng.uniform(1.2, 3.0)
    last = max(x["end"] for x in truth)
    write(out / "you.wav", channels["you"][: int((last + 1) * SR)])
    write(out / "them.wav", channels["them"][: int((last + 1) * SR)])
    (out / "truth.json").write_text(json.dumps(truth, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{len(truth)} turns, {last:.0f} s, {sum(1 for a, b in zip(truth, truth[1:]) if b['start'] < a['end'])} overlaps")


if __name__ == "__main__":
    main()
