#!/usr/bin/env python3
"""Differential check: vocab.py's normalize against VocabNormalizer.swift on a few hundred invented strings.

    asr/.venv/bin/python scripts/vocab_parity.py [--seed N] [--count N] [--binary app/.build/debug/IonianFlow]

Builds a few vocabularies (made-up names, German and English words, common-word traps), derives
test lines from their terms (case, separators, typos, umlauts) mixed with ordinary words, runs them
through both implementations and prints every difference. Also compares Zipf values for a sample
of words. Needs app/Resources/wordfreq.tsv (scripts/make-wordfreq.py). Exit code 1 on a mismatch.
"""
import argparse
import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "asr"))
import vocab  # noqa: E402
from wordfreq import top_n_list, zipf_frequency  # noqa: E402

VOCABS = [
    """Domain: logistics IT

## Terms
- ACME
- ETL
- ToP
- Ionian Flow
- IonianFlow
- Data Garage
- Netvora
- pull request (heard as: pool request, pul request)
- Gamma
- Ace
- Open Flow
- Zeitplan

## People
- Jana Weber
- Lena
- Marco Reuter
- Meyer
- Müller-Lüdenscheidt
- Zoë Brandt

## Organizations
- Northwind Logistics
- Strasse & Söhne
- Straße GmbH (heard as: Strasse GmbH)

## Ignore
- Lena
""",
    """## Projects
- Project Nimbus 2
- C3PO
- GPT-4 (heard as: GPT 4, G P T 4)
- Node.js
- Kubernetes (heard as: Cuber Netties, Kuber Netties)
- Phoenix
- Anna-Lena Schmidt
- X
- QDX
- Ölpreis Monitor
<!-- ionian-flow:vault:start x -->
## From vault: Notes
### People
- Katharina Brunnhuber
- Nikolaus Teller
### Products
- Hydra Dashboard
- Daten Garten
<!-- ionian-flow:vault:end -->
""",
    """Domain: x
## Terms
* Raumstation
* Wasserfall (heard as: Wasser Fall)
* Feldweg
\t- Tabbed Term
## Ignore
* Katharina
<!-- openflow:vault:start -->
### People
- Katharina
- Rüdiger Okonkwo
<!-- openflow:vault:end -->
""",
]

PUNCT = [" ", " ", " ", ", ", ". ", " - ", "-", " (", ") ", "; ", ": ", "! ", "? ", " ", "  ", "\t"]
FILLER_EXTRA = ["top", "ace", "open", "flow", "pool", "request", "gamma", "straße", "Strasse", "übermorgen",
                "the", "und", "ist", "wir", "Meyer", "Maier", "Mayer", "Müller", "Muller", "weber", "weder",
                "garage", "daten", "garten", "daten garten", "kuber", "net", "ties", "2024", "100", "x"]


def typo(rng, w):
    if len(w) < 3:
        return w
    i = rng.randrange(len(w))
    kind = rng.choice(["del", "swap", "sub", "dup", "ins", "case", "umlaut"])
    if kind == "del":
        return w[:i] + w[i + 1:]
    if kind == "swap" and i + 1 < len(w):
        return w[:i] + w[i + 1] + w[i] + w[i + 2:]
    if kind == "sub":
        return w[:i] + rng.choice("aeiouyklmnrstvwfzß") + w[i + 1:]
    if kind == "dup":
        return w[:i] + w[i] + w[i:]
    if kind == "ins":
        return w[:i] + rng.choice("aeioulhrsx") + w[i:]
    if kind == "umlaut":
        return w.replace("ö", "oe").replace("ü", "ue").replace("ä", "ae").replace("ß", "ss") if rng.random() < .5 else w.replace("oe", "ö").replace("ue", "ü")
    return rng.choice([w.upper(), w.lower(), w.capitalize(), w.swapcase()])


def term_variant(rng, term):
    r = rng.random()
    words = [w for w in term.replace("-", " ").split() if w]
    if r < 0.2:
        s = "".join(words)
    elif r < 0.35:
        s = " ".join(words)
    elif r < 0.45:
        s = "-".join(words)
    elif r < 0.5:
        s = " ".join(term.replace(" ", ""))  # E T L
    elif r < 0.75:
        s = " ".join(typo(rng, w) if rng.random() < 0.5 else w for w in words)
    elif r < 0.85:
        s = "".join(typo(rng, w) for w in words)
    else:
        s = term
    return rng.choice([s, s, s.lower(), s.upper(), s.capitalize()])


def lines_for(rng, v, fillers, count):
    terms = [t.text for t in v.terms] + [a for t in v.terms for a in t.aliases]
    out = []
    for _ in range(count):
        parts = []
        for _ in range(rng.randint(1, 9)):
            x = rng.random()
            if x < 0.4 and terms:
                parts.append(term_variant(rng, rng.choice(terms)))
            elif x < 0.5:
                parts.append(rng.choice(FILLER_EXTRA))
            else:
                parts.append(rng.choice(fillers))
            parts.append(rng.choice(PUNCT))
        out.append("".join(parts).rstrip("\n"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--count", type=int, default=200, help="lines per vocabulary")
    ap.add_argument("--binary", default=os.path.join(ROOT, "app/.build/debug/IonianFlow"))
    a = ap.parse_args()
    rng = random.Random(a.seed)
    fillers = top_n_list("de", 3000) + top_n_list("en", 3000) + top_n_list("de", 60000)[30000:30300] + top_n_list("en", 60000)[40000:40300]
    fillers = [w for w in fillers if w.isalpha()]
    bad = 0
    total = 0
    with tempfile.TemporaryDirectory() as d:
        for n, md in enumerate(VOCABS):
            v = vocab.parse(md)
            vp, ip = os.path.join(d, f"v{n}.md"), os.path.join(d, f"in{n}.txt")
            lines = lines_for(rng, v, fillers, a.count)
            open(vp, "w", encoding="utf-8").write(md)
            open(ip, "w", encoding="utf-8").write("\n".join(lines))
            got = subprocess.run([a.binary, "--vocab-normalize", vp, ip], capture_output=True, text=True, check=True).stdout.split("\n")[:-1]
            assert len(got) == len(lines), (len(got), len(lines))
            for line, g in zip(lines, got):
                want = v.normalize(line)
                total += 1
                if g != want:
                    bad += 1
                    print(f"MISMATCH vocab {n}\n  in:     {line!r}\n  python: {want!r}\n  swift:  {g!r}")
        words = sorted(set(rng.sample(fillers, 600) + FILLER_EXTRA + ["gpt4", "c3po", "node.js", "don't", "e-mail", "2024", "1999", "3d", "nimbus2"]))
        wp = os.path.join(d, "words.txt")
        open(wp, "w", encoding="utf-8").write("\n".join(words))
        got = subprocess.run([a.binary, "--wordfreq-zipf", wp], capture_output=True, text=True, check=True).stdout.split("\n")[:-1]
        zbad = 0
        for w, g in zip(words, got):
            lw = w.lower()
            want = f"{zipf_frequency(lw, 'de'):.2f} {zipf_frequency(lw, 'en'):.2f}"
            # the table keeps only >= 3.0: anything below reads as 0
            wd, we = (float(x) for x in want.split())
            want = f"{wd if wd >= 3 else 0:.2f} {we if we >= 3 else 0:.2f}"
            if g != want:
                zbad += 1
                print(f"ZIPF {w!r}: python {want}, swift {g}")
    print(f"{total} lines, {bad} mismatches; {len(words)} words, {zbad} zipf mismatches")
    sys.exit(1 if bad or zbad else 0)


if __name__ == "__main__":
    main()
