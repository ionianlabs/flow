"""Post-process Parakeet(+CTC) hyps: our spelling pass (vocab.normalize) and a common-word guard on CTC replacements.

    uv run pk_post.py VOCAB_DIR BENCH_DIR      (VOCAB_DIR = native-bench/vocab, BENCH_DIR = flow-bench/bench)

Reads hyp-parakeet-ctc-{off,dict,default}.jsonl in VOCAB_DIR and results/work/native-parakeet-ctc{,-default}
in BENCH_DIR; writes hyp-parakeet-<variant>.jsonl there and results/work/native-parakeet-<variant>/ (raw = CTC off).
Guard: word-diff CTC-off vs ctc-default text; revert a change whose original words are all common (vocab.common).
"""
import difflib
import json
import os
import re
import sys

import vocab

VARIANTS = {  # name: (source, zipf guard or None, normalize)
    "norm-off": ("off", None, True),
    "norm-dict": ("dict", None, True),
    "guard4": ("default", 4.0, False),
    "guard4-norm": ("default", 4.0, True),
    "guard3": ("default", 3.0, False),
    "guard3-norm": ("default", 3.0, True),
}


def guard(off: str, ctc: str, zipf: float) -> str:
    a, b = off.split(), ctc.split()
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if op == "equal" or op == "insert":
            out += b[j1:j2]
            continue
        orig = a[i1:i2]
        words = [re.sub(r"\W+", "", w) for w in orig]
        revert = all(not w or vocab.common(w, zipf) for w in words)
        out += orig if revert else b[j1:j2]
    return " ".join(out)


def load(path):
    return [json.loads(line) for line in open(path)]


def make(off: str, ctc: str, spec, v) -> str:
    _, z, norm = spec
    t = guard(off, ctc, z) if z else ctc
    return v.normalize(t) if norm else t


def main():
    vdir, bdir = sys.argv[1:3]
    v = vocab.parse(open(os.path.join(vdir, "Vocabulary.md")).read())
    src = {k: {r["id"]: r["text"] for r in load(os.path.join(vdir, f"hyp-parakeet-ctc-{k}.jsonl"))}
           for k in ("off", "dict", "default")}
    for name, spec in VARIANTS.items():
        with open(os.path.join(vdir, f"hyp-parakeet-{name}.jsonl"), "w") as f:
            for i, ctc in src[spec[0]].items():
                f.write(json.dumps({"id": i, "text": make(src["off"][i], ctc, spec, v)}, ensure_ascii=False) + "\n")
    w = os.path.join(bdir, "results/work")
    dicts = {"default": load(f"{w}/native-parakeet-ctc-default/hyp-native-parakeet-ctc-default.jsonl"),
             "dict": load(f"{w}/native-parakeet-ctc/hyp-native-parakeet-ctc.jsonl")}
    for name, spec in VARIANTS.items():
        rows = dicts["default" if spec[0] == "default" else "dict"]
        out = f"{w}/native-parakeet-{name}"
        os.makedirs(out, exist_ok=True)
        with open(f"{out}/hyp-native-parakeet-{name}.jsonl", "w") as f:
            for r in rows:
                ctc = r["raw"] if spec[0] == "off" else r["text"]
                t = make(r["raw"], ctc, spec, v)
                f.write(json.dumps({**r, "text": t}, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
