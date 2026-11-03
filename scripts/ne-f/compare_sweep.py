"""Compares two sweep runs (Python reference, Swift) from their caches and vocabulary files.

  python -I compare_sweep.py PY_CACHE SWIFT_CACHE PY_VOCAB SWIFT_VOCAB [--details FILE]

Prints aggregates only (counts, overlap, rank correlation). Per-term lines go to --details, which
belongs outside the repository when the vault is private.
"""

import json
import re
import sys


def vault_terms(path):
    """Terms of the vault block, in file order, with their category."""
    text = open(path, encoding="utf-8").read()
    block = text[text.find("<!-- ionian-flow:vault:start"):text.find("<!-- ionian-flow:vault:end -->")]
    out, cat = [], None
    for line in block.splitlines():
        if line.startswith("### "):
            cat = line[4:].strip()
        elif line.startswith("- ") and cat:
            out.append((line[2:].strip(), cat))
    return out


def note_terms(path):
    c = json.load(open(path, encoding="utf-8"))
    notes = c["notes"]
    if isinstance(notes, dict):  # Python's cache: rel -> {terms: {term: entry}}
        return {rel: set(e["terms"]) for rel, e in notes.items()}
    return {n["rel"]: {t["term"] for t in n["terms"]} for n in notes}  # Swift's: a list


def spearman(a, b):
    common = [t for t in a if t in set(b)]
    if len(common) < 3:
        return float("nan")
    ra = {t: i for i, t in enumerate(common)}
    rb = {t: i for i, t in enumerate(t for t in b if t in set(common))}
    n = len(common)
    d2 = sum((ra[t] - rb[t]) ** 2 for t in common)
    return 1 - 6 * d2 / (n * (n * n - 1))


args = sys.argv[1:]
details = None
if "--details" in args:
    i = args.index("--details")
    details = args[i + 1]
    del args[i:i + 2]
py_cache, sw_cache, py_vocab, sw_vocab = args

pn, sn = note_terms(py_cache), note_terms(sw_cache)
shared = [r for r in pn if r in sn]
same = sum(pn[r] == sn[r] for r in shared)
tp, ts = sum(len(pn[r]) for r in shared), sum(len(sn[r]) for r in shared)
inter = sum(len(pn[r] & sn[r]) for r in shared)
union = sum(len(pn[r] | sn[r]) for r in shared)
print(f"notes: python {len(pn)}, swift {len(sn)}, in both {len(shared)}")
print(f"notes with identical term sets: {same} ({100 * same / max(1, len(shared)):.1f} %)")
print(f"extracted terms (per note, summed): python {tp}, swift {ts}, common {inter}, jaccard {100 * inter / max(1, union):.1f} %")

pv, sv = vault_terms(py_vocab), vault_terms(sw_vocab)
pk, sk = [t.lower() for t, _ in pv], [t.lower() for t, _ in sv]
both = set(pk) & set(sk)
print(f"vocabulary terms: python {len(pk)}, swift {len(sk)}, common {len(both)}")
print(f"overlap: {100 * len(both) / max(1, len(set(pk) | set(sk))):.1f} % of the union, "
      f"{100 * len(both) / max(1, len(pk)):.1f} % of python's, {100 * len(both) / max(1, len(sk)):.1f} % of swift's")
cats = dict((t.lower(), c) for t, c in pv)
catsw = dict((t.lower(), c) for t, c in sv)
print(f"same category for common terms: {sum(cats[t] == catsw[t] for t in both)} of {len(both)}")
print(f"identical vault blocks (terms, order, categories): {pv == sv}")
print(f"rank correlation (Spearman, common terms): {spearman(pk, sk):.3f}")

if details:
    with open(details, "w", encoding="utf-8") as f:
        f.write("# Sweep parity details (private)\n\n## Only in python\n")
        f.writelines(f"- {t}\n" for t, _ in pv if t.lower() not in both)
        f.write("\n## Only in swift\n")
        f.writelines(f"- {t}\n" for t, _ in sv if t.lower() not in both)
        f.write("\n## Notes with different term sets\n")
        for r in shared:
            if pn[r] != sn[r]:
                f.write(f"- {r}: only python {sorted(pn[r] - sn[r])}; only swift {sorted(sn[r] - pn[r])}\n")
