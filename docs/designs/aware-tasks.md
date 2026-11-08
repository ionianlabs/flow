# Aware: tasks

The dictation items were removed on 2026-11-08 (see `docs/designs/aware.md`); what remains is meetings only.

Spec: `docs/designs/aware.md` (approved 2026-11-05). Start only once the native build is in daily use and stable.

Each item is one TDD loop: the listed scenarios become failing tests first, then the smallest change, `swift test --package-path app` green, one commit. `[P]` items touch no shared file and can run in parallel worktrees once item 0 is merged. All code in `app/Sources/IonianFlow/Aware/` (new), tests in `app/Tests/IonianFlowTests/Aware/` (new). Fixtures use invented names only (public repo).

The model sits behind one protocol, `AwareModel` (new): `extract(source:projects:) -> [AwareItem]` and `judge(item:against:) -> same | conflicts(line) | new`. Unit tests stub it; item 10 implements it on Gemma.

## Foundation
- [ ] 0. `AwareItem`, `AwareSource` (dictation or transcript block with speaker and `HH:mm`), the `AwareModel` protocol, parsing the model's JSON, and the verbatim guard. Scenarios: F1.19, F1.32 (parse and retry part).

## Parallel units
- [ ] 1. [P] `CaptureBuffer`: append, read with the 24 h and 1 MB limits, skip bad lines, remove(ids:), mode 0600 on `buffer.jsonl` and `state.json`. Scenarios: F1.1 (buffer side), F1.5, F1.6, F1.7, F1.8.
- [ ] 2. [P] `AwareRules`: prefilter for dictations, `codeApps`, `cues`, `stopWords`, confidence floors, Jaccard overlap, caps as constants. Scenarios: F1.15, F1.20, F1.21, F1.22 (overlap step).
- [ ] 3. [P] `BrainLines`: the Brain check, project `description`/`focus`/`## Now`/`## Open`, log bullets of the last 30 days, item text of Aware files in `inbox/` and `_archive/inbox/` dated by file name, skipping dot folders. Scenarios: F1.23 (overlap), F1.24, F1.31 (not a Brain).
- [ ] 4. [P] `TranscriptSource`: flat `*.md` read, finished check (`end:`), `confidential: true` and `aware: false` skip, `state.json` `swept` and `enabledAt`, speaker block parsing. Scenarios: F1.12, F1.13, F1.14, F1.35.
- [ ] 5. [P] `AwareWriter`: create or append the day file, `## HH:mm` and `## HH:mm meeting` sections, footer counts, `description`, source links (root-relative inside the brain, file name outside), daily cap. Scenarios: F1.28 (writer side), F1.29, F1.30.
- [ ] 6. [P] `--aware-precision` in `Dev/EngineCLI.swift`. Scenarios: F2.1, F2.2, F2.3.

## Pipeline
- [ ] 7. `AwareDedup` (needs 2, 3): overlap step, then the stubbed model step on the 20 closest lines; duplicates within one sweep; `conflicts` kept and labelled. Scenarios: F1.22, F1.23, F1.25, F1.26.
- [ ] 8. `AwareSweep` (needs 0 to 7): sources, prefilter, model, verbatim, gate, dedup, cut, write, then `state.json`, then buffer delete, in that order. Scenarios: F1.27, F1.33, F1.34, and F1.16 to F1.18 with a stubbed model.
- [ ] 9. `AwareScheduler` (needs 8, sweep stubbed): 10-minute check and launch, interval, battery via an injected power state, pause, yield within 1 s on hotkey or transcription start, meeting-end trigger, one sweep at a time. Scenarios: F1.4 (sweep side), F1.9, F1.10, F1.11, F1.36, F1.37.

## Wiring and model
- [ ] 10. Gemma `AwareModel` through `ModelHub`, chunked like `Summarizer`; model tests behind `IONIAN_FLOW_MODEL_TESTS=1` on two invented meetings (one an hour long), 20 dictations and a fixture brain. Scenarios: F1.16, F1.17, F1.18, F1.22 and F1.26 (model step); SC6, SC7, SC8 timed.
- [ ] 11. App wiring: `Settings` keys, `deliver(_:)` hook with exclusions, `IsSecureEventInputEnabled()` and pause; transcription-end hook after the summary; General page toggle; menu items "Sweep now" and "Pause Aware for 1 hour"; status strings. Scenarios: F1.1 to F1.4 end to end, F1.28 and F1.31 (menu), SC4 (fixture brain diff over 10 sweeps).

## Outside this repo
- Brain repo: add `source: flow` to the inbox rules and spec the review skill that reads the marks and archives the day file. Needed before daily use, not before item 11.

## After shipping
- Use it for 2 weeks, then run `--aware-precision` for SC1 and SC2 and tune the constants in `AwareRules`. Time one real day's review for SC3.
