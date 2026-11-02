"""The Python sidecar's side of engine-bench: latency (real-time paced, like `engine-bench latency`) and the
mixed-language clips, over the sidecar socket protocol (see asr/server.py). Standard library only.

Start your own server first, never the app's socket (from the repo's asr/ directory):
    HF_HUB_OFFLINE=1 uv run server.py --socket /tmp/ionian-flow-ne.sock --vocabulary= --no-boost

    python3 pybench.py latency [--native /tmp/engine-bench-latency-native-560.json] [--socket ...]
    python3 pybench.py mixed DIR [--socket ...]      (DIR from `engine-bench mixed DIR`; then `engine-bench mixed DIR --score`)

latency needs the native run's JSON for the word end times (the socket gives none): run
`engine-bench latency` first; Python's words are aligned to the native words by difflib.
"""

import argparse
import difflib
import json
import re
import socket
import statistics
import struct
import threading
import time
import os
import wave
from pathlib import Path

# The bench harness checkout (branch `bench`), next to this repo by default; FLOW_BENCH overrides it.
BENCH = os.path.join(os.environ.get("FLOW_BENCH", Path(__file__).resolve().parents[3] / "flow-bench/bench"), "data")
TAG = re.compile(r"\s*<[a-z]{2,3}-[A-Z]{2}>")


def frame(kind: bytes, payload: bytes = b"") -> bytes:
    return kind + struct.pack(">I", len(payload)) + payload


def read_pcm(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1, path
        return w.readframes(w.getnframes())


def norm(w: str) -> str:
    return re.sub(r"[^\w]", "", w.lower())


def words_of(text: str) -> list[str]:
    return [w for w in (norm(x) for x in TAG.sub("", text).split()) if w]


def run_clip(sock_path: str, pcm: bytes, language: str, paced: bool = True):
    """(partials [(wall_s, text)], final dict | None, t_release_wall_s, t_final_wall_s)"""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    f = s.makefile("r", encoding="utf-8")
    json.loads(f.readline())  # ready
    t0 = time.perf_counter()
    partials, final, t_final = [], [None], [None]
    done = threading.Event()

    def reader():
        for line in f:
            msg = json.loads(line)
            now = time.perf_counter() - t0
            if msg["type"] == "partial":
                partials.append((now, TAG.sub("", msg["text"]).strip()))
            elif msg["type"] == "final":
                final[0], t_final[0] = msg, now
                done.set()
                return
            elif msg["type"] == "error":
                final[0], t_final[0] = msg, now
                done.set()
                return

    threading.Thread(target=reader, daemon=True).start()
    s.sendall(frame(b"S", language.encode()))
    step = 3200
    for k, i in enumerate(range(0, len(pcm), step)):
        if paced:
            wait = (k + 1) * 0.1 - (time.perf_counter() - t0)
            if wait > 0:
                time.sleep(wait)
        s.sendall(frame(b"A", pcm[i : i + step]))
    t_release = time.perf_counter() - t0
    s.sendall(frame(b"E"))
    done.wait(60)
    s.close()
    return partials, final[0], t_release, t_final[0]


def pct(v, p):
    s = sorted(v)
    return s[min(len(s) - 1, int((len(s) - 1) * p + 0.5))] if s else float("nan")


def latency(args):
    native = json.load(open(args.native))
    manifest = {}
    for line in open(f"{BENCH}/manifest.jsonl"):
        d = json.loads(line)
        manifest[d["id"]] = d
    # warm-up so the first clip doesn't pay for a cold decoder
    run_clip(args.socket, b"\0\0" * 16000, "de-DE", paced=False)
    first, first_rel, lags, rel = [], [], [], []
    for r in native:
        d = manifest[r["id"]]
        locale = {"de": "de-DE", "en": "en-US"}[r["lang"]]
        partials, final, t_release, t_final = run_clip(args.socket, read_pcm(f"{BENCH}/{d['wav']}"), locale)
        if not final or final.get("type") != "final":
            print(r["id"], "no final", final)
            continue
        ref_words = [norm(w["word"]) for w in r["words"]]
        py_words = words_of(final["text"])
        sm = difflib.SequenceMatcher(None, py_words, ref_words, autojunk=False)
        to_ref = {}
        for a, b, n in sm.get_matching_blocks():
            for k in range(n):
                to_ref[a + k] = b + k
        appeared = []
        for t, text in partials:
            n = len(words_of(text))
            while len(appeared) < n:
                appeared.append(t)
        clip_lags = [(appeared[i] - r["words"][j]["end"]) * 1000 for i, j in to_ref.items() if i < len(appeared)]
        ttfp = next((t for t, text in partials if words_of(text)), None)
        if ttfp is not None:
            first.append(ttfp * 1000)
            first_rel.append((ttfp - r["words"][0]["start"]) * 1000)
        lags += clip_lags
        rel.append((t_final - t_release) * 1000)
        print(f"{r['id']}  first {ttfp or -1:.2f} s  release->final {rel[-1]:.0f} ms  lag median "
              f"{statistics.median(clip_lags) if clip_lags else float('nan'):.0f} ms  matched {len(to_ref)}/{len(py_words)}")
    f = lambda v: f"median {pct(v, .5):5.0f}  p90 {pct(v, .9):5.0f}  (n={len(v)})"
    print("== python sidecar, live lookahead 3 (320 ms), final lookahead 13  [PROVISIONAL if the machine was busy]")
    print("  first partial after first audio (ms)   ", f(first))
    print("  first partial after first word starts   ", f(first_rel))
    print("  live lag per word (ms)                  ", f(lags))
    print("  release to final (ms)                   ", f(rel))


def mixed(args):
    out = []
    for line in open(f"{args.dir}/manifest.jsonl"):
        c = json.loads(line)
        _, final, _, _ = run_clip(args.socket, read_pcm(f"{args.dir}/{c['wav']}"), "", paced=False)  # "" = server default (auto)
        out.append({"id": c["id"], "text": TAG.sub("", final.get("text", "")).strip() if final else "",
                    "lang": final.get("lang") if final else None})
        print(c["id"], out[-1]["lang"], out[-1]["text"][:100])
    with open(f"{args.dir}/hyp-python.jsonl", "w") as fh:
        for o in out:
            fh.write(json.dumps(o, ensure_ascii=False) + "\n")
    print(f"wrote {args.dir}/hyp-python.jsonl; score with: engine-bench mixed {args.dir} --score")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["latency", "mixed"])
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--socket", default="/tmp/ionian-flow-ne.sock")
    ap.add_argument("--native", default="/tmp/engine-bench-latency-native-560.json")
    a = ap.parse_args()
    latency(a) if a.cmd == "latency" else mixed(a)
