"""Summaries by asr/polish.py, the parity reference for Summarizer.swift.

  python -I summary_ref.py FIXTURE_DIR OUT_DIR       one <name>.json per <name>.txt (tags from tags.txt)
  python -I summary_ref.py --prompts                 the prompt strings as JSON (for byte comparison)
"""

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "asr"))
import polish  # noqa: E402

if sys.argv[1:2] == ["--prompts"]:
    print(json.dumps({"summary": polish.SUMMARY_SYSTEM, "notes": polish.NOTES_SYSTEM}, ensure_ascii=False))
    sys.exit()

fixtures, out = sys.argv[1:3]
tags = [t.strip() for t in open(os.path.join(fixtures, "tags.txt"), encoding="utf-8").read().split(",") if t.strip()]
p = polish.Polisher()
os.makedirs(out, exist_ok=True)
for path in sorted(glob.glob(os.path.join(fixtures, "*.txt"))):
    name = os.path.basename(path)[:-4]
    if name == "tags":
        continue
    transcript = open(path, encoding="utf-8").read()
    p.load()
    result = p.summarize(transcript, tags)
    with open(os.path.join(out, name + ".py.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1, sort_keys=True)
    print(name, "->", result.get("description", "-"))
