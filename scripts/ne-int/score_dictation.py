"""WER of the e2e dictation run (IonianFlow --e2e-engine dictation) against the manifest references, per
dataset and language, next to other hypothesis files on the same clips (e.g. the Phase 0 batch run).

    python3 -I score_dictation.py MANIFEST.jsonl E2E.jsonl [OTHER.jsonl[:label] ...]

Needs a python with numpy (bench_wer imports it). Normaliser: asr/bench_wer.normalize ("strict").
"""

import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "asr"))
from bench_wer import normalize  # noqa: E402


def edits(ref: list[str], hyp: list[str]) -> int:
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[-1]


def load(path: str) -> dict[str, dict]:
    return {r["id"]: r for r in map(json.loads, Path(path).read_text(encoding="utf-8").splitlines() if path else [])}


def main() -> None:
    manifest = load(sys.argv[1])
    runs = [("e2e", load(sys.argv[2]))]
    for spec in sys.argv[3:]:
        path, _, label = spec.partition(":")
        runs.append((label or Path(path).stem, load(path)))
    ids = list(runs[0][1])
    groups = defaultdict(list)
    for i in ids:
        m = manifest[i]
        groups[(m["dataset"], m["lang"])].append(i)
        groups[("all", m["lang"])].append(i)
        groups[("all", "all")].append(i)
    print(f"{'group':<18} {'clips':>5} " + " ".join(f"{label:>12}" for label, _ in runs))
    for key in sorted(groups):
        row = []
        for _, hyps in runs:
            e = n = 0
            for i in groups[key]:
                if i not in hyps:
                    continue
                ref = normalize(manifest[i]["ref"]).split()
                e += edits(ref, normalize(hyps[i].get("text", "")).split())
                n += len(ref)
            row.append(f"{100 * e / n:11.2f}%" if n else f"{'-':>12}")
        print(f"{'/'.join(key):<18} {len(groups[key]):>5} " + " ".join(row))


if __name__ == "__main__":
    main()
