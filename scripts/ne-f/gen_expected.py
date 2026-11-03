"""Writes app/Sources/IonianFlow/VaultSweepExpected.swift: crafted inputs and what asr/sweep.py and
asr/polish.py answer for them. The Swift self tests (--selftest) check the port against it.

  python -I gen_expected.py > ../../app/Sources/IonianFlow/VaultSweepExpected.swift
"""

import hashlib
import json
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "asr"))
import polish  # noqa: E402
import sweep  # noqa: E402

NOW = 1_000_000_000.0
sweep.time = types.SimpleNamespace(time=lambda: NOW, perf_counter=lambda: 0.0)

NOTES = [
    ("Quill Plan", "---\naliases: [QP, Quill Plan]\norg: acme\nowner: \"Marta Kessling\"\n---\n# Quill Plan: Roadmap\n"
     "Kickoff with Marta Kessling and Tobias Vance about NimbusQL. The Harbor Team of Practice meets.\n"
     "See [[Marta Kessling]] and [[tobias|Toby]] and https://example.com/Quill and `CodeThing`.\n"
     "```\nHiddenThing in a fence\n```\nTicket QFR-1042, color #A8B1B6, Oct 3, Level 2, CI/CD, Marco/Lena.\n"
     "- Bullet Starts Here and then Atlas Dashboard.\n"),
    ("2026-10-01", "Standup. Tomaz wrote the notes, Tomaz again. Tomas presented. API-based work, ETL jobs, DONE.\n"
     "Der Kunde wünscht eine Lösung. Frau Weber und Dr. Meier. Ionian Flow Log, ToP log.\n"),
    ("Daily Note", "Nothing but ordinary words here, plus iPhone and M365 and X200 and P1.\n\n## Heading Two\nLumAI is a Project\n"),
]
PLAUSIBLE = [("Product Owner", "People", False), ("Marta Kessling", "People", False), ("May", "People", False),
             ("Level 1", "Terms", False), ("Expo 2026", "Terms", False), ("DONE", "Terms", False), ("ACME", "Acronyms", False),
             ("In Progress", "Terms", False), ("Night Owl", "Terms", False), ("Python", "Terms", False), ("lumai", "Terms", False),
             ("Oct 3", "Terms", False), ("PROJ-30092", "Terms", False), ("UX Guild", "Terms", False), ("Data Garage", "Terms", False),
             ("report.pdf", "Terms", False), ("release notes", "Terms", False), ("Thu", "Terms", False), ("TO BE DELETED", "Terms", False),
             ("Lena", "People", True), ("Nemotron", "Products", False), ("P1", "Terms", False), ("Kubernetes", "Terms", False)]
CHUNKS = "First paragraph here.\n\nSecond paragraph is a bit longer than the first.\n\nThird.\n\n\n\nFourth one closes."
SUMCHUNKS = "line one\nline two is longer\r\nthree\rfour\n\nfive and then a very long line that exceeds the size\nsix\n"


def entry(term, category, count, alias=False, lower=False):
    return {"term": term, "category": category, "count": count, "alias": alias, "lower": lower}


RANK = [
    {"age_days": 1, "terms": [entry("Nimbus", "Products", 3), entry("Tomas", "People", 9), entry("Tomaz", "People", 2),
                              entry("Tomes", "People", 1), entry("QP", "Acronyms", 1, True), entry("Atlas", "Projects", 1)]},
    {"age_days": 40, "terms": [entry("NIMBUS", "Products", 2), entry("Tomas", "People", 4), entry("Tomaz", "People", 1),
                               entry("Atlas", "Terms", 2), entry("Product Owner", "People", 5, False, True)]},
    {"age_days": 400, "terms": [entry("Nimbus", "Terms", 1), entry("Atlas", "Projects", 1), entry("Jona", "People", 3),
                                entry("Jonas", "People", 3), entry("Zeta Corp", "Organizations", 2)]},
    {"age_days": 3, "terms": [entry("Zeta Corp", "Organizations", 4), entry("Jona", "People", 1)]},
]

SUMMARIES = [
    ('Sure! {"description": "  A call about the   rollout. ", "tags": ["Roadmap Q3", "roadmap-q3", "A/B", ""], '
     '"keywords": ["Quillfeather", "NimbusQL", "invented"], "points": ["- one", "two", "two", 3, null], '
     '"decisions": ["Freeze on Friday", "Ship tomorrow"], "actions": [{"who": "You", "what": "write notes by Monday"}, '
     '"Them: send draft by Tuesday"]} trailing', "We use Quillfeather. Freitag works, ship morgen. nimbusql is up."),
    ('{"description": "", "tags": [], "keywords": [], "points": [], "decisions": [], "actions": []}', "x"),
    ("not json at all", "x"),
    ('{"description": "Only a string list", "points": "single point", "tags": "a b", "keywords": 5, "decisions": {"a": 1}, '
     '"actions": [["x", "y"], true, 2.5, {"k": ""}]}', "nächste Woche is fine, Montag too"),
    ('["a list"]', "x"),
    ('{"description": "D", "decisions": ["Meet next week", "Meet nächste Woche", "On Dienstag", "Am Mittwoch"]}', "Mittwoch and next week"),
    ('{"description": "Unicode \\u00e4 \\ud83d\\ude00 end", "points": ["  • star * ", "a" ]}', "x"),
    ('{"description": "dup", "description": "last wins", "points": []}', "x"),
]

out = {
    "notes": [{"stem": s, "text": t, "terms": [
        {"term": k, "category": v["category"], "count": v["count"], "alias": v["alias"]} for k, v in sweep.extract_rules(t, s).items()]}
        for s, t in NOTES],
    "plausible": [{"term": t, "category": c, "lower": lo, "ok": sweep.plausible(t, c, lo)} for t, c, lo in PLAUSIBLE],
    "chunks": {"text": CHUNKS, "size": 40, "default": list(sweep.chunks(CHUNKS)), "small": list(sweep.chunks(CHUNKS, 40))},
    "sumchunks": {"text": SUMCHUNKS, "size": 30, "parts": polish.chunks(SUMCHUNKS, 30)},
    "plain": [{"text": NOTES[0][1], "body": sweep.plain(NOTES[0][1])[0], "aliases": sweep.plain(NOTES[0][1])[1]}],
    "oneedit": [{"a": a, "b": b, "ok": sweep.one_edit(a, b)} for a, b in
                [("tomas", "tomaz"), ("tomas", "tomass"), ("tomas", "toma"), ("abc", "abc"), ("abc", "axc"), ("abc", "xbd"), ("ab", "ba"), ("", "a")]],
    "summaries": [{"raw": r, "transcript": t, "clean": polish.clean_summary(r, t)} for r, t in SUMMARIES],
    "hashes": {"summary": hashlib.sha256(polish.SUMMARY_SYSTEM.encode()).hexdigest(),
               "notes": hashlib.sha256(polish.NOTES_SYSTEM.encode()).hexdigest(),
               "extract": hashlib.sha256(sweep.EXTRACT.encode()).hexdigest(),
               "domain": hashlib.sha256(sweep.DOMAIN.encode()).hexdigest()},
}
rank_notes = [{"mtime": NOW - n["age_days"] * 86400, "terms": n["terms"]} for n in RANK]
ranked = sweep.rank({str(i): {"mtime": n["mtime"], "terms": {t["term"]: t for t in n["terms"]}} for i, n in enumerate(rank_notes)})
out["rank"] = {"now": NOW, "notes": rank_notes,
               "ranked": [{"term": t["term"], "category": t["category"], "notes": t["notes"], "count": t["count"],
                           "score": round(t["score"], 9)} for t in ranked]}
print("// Generated by scripts/ne-f/gen_expected.py from asr/sweep.py and asr/polish.py. Do not edit.")
print("enum VaultSweepExpected {")
print('    static let json = #"""')
print(json.dumps(out, ensure_ascii=False, indent=1))
print('"""#')
print("}")
