#!/usr/bin/env python3
"""Writes app/Resources/wordfreq.tsv: the German and English word-frequency table behind
VocabNormalizer's common-word guard (Zipf scale, like wordfreq).

    asr/.venv/bin/python scripts/make-wordfreq.py [out.tsv]

One line per word: `word<TAB>de<TAB>en`, Zipf frequency times 100 (an integer), empty where the
word is below 3.0 in that language. 3.0 is the lowest threshold vocab.py ever asks for.

The data comes from wordfreq (code Apache-2.0, data CC-BY-SA-4.0). To use another source, replace
`frequencies()` so it returns {word: zipf} for a language, tokenized the way Swift's
WordFrequency.tokens does (lowercase, "ß" as "ss", digit runs as zeros); nothing else changes.
"""
import math
import os
import sys

from wordfreq import get_frequency_dict

MIN_ZIPF = 3.0


def frequencies(lang: str) -> dict[str, float]:
    out = {}
    for word, freq in get_frequency_dict(lang, "best").items():
        zipf = round(math.log10(freq) + 9, 2)
        if zipf >= MIN_ZIPF:
            out[word] = zipf
    return out


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "app", "Resources", "wordfreq.tsv")
    de, en = frequencies("de"), frequencies("en")
    cell = lambda table, w: str(round(table[w] * 100)) if w in table else ""
    with open(path, "w", encoding="utf-8") as f:
        for w in sorted(de.keys() | en.keys()):
            f.write(f"{w}\t{cell(de, w)}\t{cell(en, w)}\n")
    print(f"{path}: {len(de.keys() | en.keys())} words, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
