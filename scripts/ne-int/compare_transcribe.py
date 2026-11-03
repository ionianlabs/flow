"""Compares the segment lists printed by two `--transcribetest` runs (new engine, old engine) on the files from
make_two_speaker.py: segment count and speaker order, start/end offsets between matched segments, Markdown speaker blocks, and WER
per speaker against truth.json.

    python3 -I compare_transcribe.py TRUTH.json NEW.log OLD.log

The logs are the stdout of `IonianFlow --transcribetest ...` (lines "You  12.3– 15.1 s  final  text").
Needs a python with numpy (bench_wer imports it).
"""

import json
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "asr"))
from bench_wer import normalize  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
from score_dictation import edits  # noqa: E402

LINE = re.compile(r"^(You|Them)\s+([\d.]+)–\s*([\d.]+) s\s+(\S+)\s+(.*)$")


def segments(path: str) -> list[dict]:
    out = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        m = LINE.match(line)
        if m:
            out.append({"speaker": m[1], "start": float(m[2]), "end": float(m[3]), "stage": m[4], "text": m[5]})
    return sorted(out, key=lambda s: s["start"])


def wer(truth: list[dict], segs: list[dict], who: str) -> tuple[float, int]:
    ref = normalize(" ".join(t["ref"] for t in truth if t["speaker"].capitalize() == who)).split()
    hyp = normalize(" ".join(s["text"] for s in segs if s["speaker"] == who)).split()
    return 100 * edits(ref, hyp) / max(1, len(ref)), len(ref)


def deltas(a: list[dict], b: list[dict]) -> tuple[list[float], list[float]]:
    """For each segment of a, the closest-start segment of b with the same speaker (within 3 s)."""
    ds, de = [], []
    for s in a:
        cand = [t for t in b if t["speaker"] == s["speaker"] and abs(t["start"] - s["start"]) < 3]
        if cand:
            t = min(cand, key=lambda t: abs(t["start"] - s["start"]))
            ds.append(abs(t["start"] - s["start"]))
            de.append(abs(t["end"] - s["end"]))
    return ds, de


def q(v: list[float], p: float) -> float:
    return sorted(v)[min(len(v) - 1, int(len(v) * p))] if v else float("nan")


def main() -> None:
    truth = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    new, old = segments(sys.argv[2]), segments(sys.argv[3])
    print(f"truth turns {len(truth)} ({sum(t['speaker'] == 'you' for t in truth)} you, {sum(t['speaker'] == 'them' for t in truth)} them)")
    for label, segs in (("new", new), ("old", old)):
        print(f"{label}: {len(segs)} segments ({sum(s['speaker'] == 'You' for s in segs)} You, {sum(s['speaker'] == 'Them' for s in segs)} Them), "
              + ", ".join(f"WER {w} {wer(truth, segs, w)[0]:.2f}% of {wer(truth, segs, w)[1]} words" for w in ("You", "Them")))
    order_new = "".join(s["speaker"][0] for s in new)
    order_old = "".join(s["speaker"][0] for s in old)
    print(f"speaker order identical: {order_new == order_old} (edit distance {edits(list(order_new), list(order_old))} of {len(order_old)})")
    ds, de = deltas(new, old)
    print(f"new vs old, matched {len(ds)}/{len(new)}: start offset median {statistics.median(ds):.2f} s p90 {q(ds, .9):.2f} max {max(ds):.2f}; "
          f"end offset median {statistics.median(de):.2f} s p90 {q(de, .9):.2f} max {max(de):.2f}")
    blocks = {}
    for label, path in (("new", sys.argv[2]), ("old", sys.argv[3])):
        blocks[label] = re.findall(r"^\*\*(You|Them)\*\* · \d\d:\d\d$", Path(path).read_text(encoding="utf-8"), re.M)
    print(f"Markdown speaker blocks: new {len(blocks['new'])}, old {len(blocks['old'])}, same order: {blocks['new'] == blocks['old']}")
    print("note: the harness feeds files at 4x real time, so segment times are on a compressed wall-clock axis; only new-vs-old is meaningful.")

if __name__ == "__main__":
    main()
