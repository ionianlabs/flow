# Aware

Status: approved 2026-11-05
Slug: aware
Date: 2026-11-05

## Problem
Things worth keeping are said out loud all day and then lost: "can you send me the deck by Friday" in a meeting and "we're dropping the legacy export" in a call. Flow turns that speech into text on the device, but nothing picks out what matters, so it reaches the Ionian Brain only if the user rereads transcripts or retells the day to an agent, which mostly does not happen. Flow already runs a local language model, so it can do the sifting itself. Four constraints shape it. The sweep must not load the Mac while the user works. Nothing goes into the brain directly: Aware proposes, the user accepts or rejects. And above all the inbox must not flood: the first version of Flow's vocabulary sweep indexed nearly everything it saw and was useless until it got an evidence bar, a score threshold and a hard cap per run. Aware needs the same discipline from day one, plus a solid check that what it proposes is not already in the brain.

## Existing system
- **Flow** (this repo, overview in `README.md` and `STATE.md`) is a macOS menu-bar app. Hold a hotkey to dictate: speech becomes text on the device, `Polisher` cleans it, and `deliver(_:)` in `app/Sources/IonianFlow/App/main.swift` pastes it into the front app.
- **Transcripts**: transcription mode records meetings (mic as `**You**`, system audio as `**Them**`) and `TranscriptStore` (in `app/Sources/IonianFlow/Speech/Transcriber.swift`) writes one Markdown file per meeting, flat, into `Settings.transcriptsFolder`. Frontmatter has `date`, `start` and, once the meeting has ended, `end`. Speaker blocks are `**You** · 09:17` (wall-clock start time) followed by the text. When a summary is made, `TranscriptStore.insert` adds a `## Summary` (points, **Decisions**, **Action items**) and a `## Transcript` heading. The transcript panel shows "Always get consent when transcribing others."
- **Local model**: Gemma 4 E2B, loaded through `ModelHub`, used by `Polisher`, `Summarizer` (chunks long transcripts into 12,000-character parts) and `VaultSweeper` (reads a Markdown vault for vocabulary; pauses while the user dictates). The vocabulary sweep's anti-flood rules live in `Vocabulary/VaultSweepRank.swift` (`SweepRank.minScore`) and its per-run cap of new terms.
- **Vault**: `Settings.vault` is a Markdown folder the user picks; Flow only reads it today.
- **Ionian Brain** (github.com/ionianlabs/brain) is a Markdown folder with `AGENTS.md`, `projects/<slug>.md` (frontmatter `description`, `focus`; sections `## Now` for current state, `## Open` for to-dos as `- [ ] Text (owner: Name, due: YYYY-MM-DD)`), `logs/<slug>.md` (newest first, `## YYYY-MM-DD` headings, bullets prefixed `Decision:` or `Done:`), `knowledge/` and `inbox/`. Anyone may drop a capture into `inbox/` (frontmatter `type: capture`, `org`, `source`); in a later agent session the user triages each capture into the right note and moves the file to `_archive/inbox/`. The brain is versioned with git. Folders starting with `.` are off limits to every tool.

## Out of scope
- Kinds of knowledge other than to-dos, decisions and facts: ideas, opinions, people profiles, preferences. A later spec may add them once precision is measured.
- Writing anywhere in the brain except Aware's own files in `inbox/`. Flow never edits a project, log, knowledge note or transcript, and never moves or archives an inbox file.
- Auto-accepting items. That comes only after measured precision, in a later spec.
- The review walk-through and archiving (a brain plugin skill next to `brain:brief`), in the brain repo. This spec defines only the file format it reads.
- Duplicate checks against `knowledge/` notes. Only project files, recent logs and Aware's own files are compared.
- A per-meeting "keep out of Aware" control. The only route is adding `aware: false` to a transcript's frontmatter by hand.
- Any network service, audio storage, or suggestions while speaking.
- Dictations (capture, buffer, schedule, excluded apps, pause): removed 2026-11-08 to try Aware on meetings first; the last code with them is commit 32689e5.

## Terms
- **Brain**: the first of `Settings.vault`, `$BRAIN_DIR`, `$IONIAN_HOME/brain` and `~/Ionian/brain` that holds `AGENTS.md`, `inbox/` and `projects/`.
- **Sweep**: one batch run, of one of two kinds. A **meeting sweep** reads one transcript right after its meeting ends. A **catch-up sweep** reads every finished transcript still not swept (F1.42). Only one sweep runs at a time; a sweep that comes due while another runs waits for it.
- **Item**: one proposal: category (`todo`, `decision` or `fact`), text, verbatim quote, source, suggested project, confidence.
- **Knowledge item**: an item of category `decision` or `fact`.
- **Confidence**: the model's own score from 0 to 1 that the item is real, lasting and worth keeping, as returned in its JSON answer.
- **Brain lines**: what an item is compared against, across all projects: for each project, its `description`, `focus`, the lines under `## Now` and `## Open`, and its log bullets from the last 30 days; plus the item text (between the category and `→`) of every line in unarchived Aware files and in archived Aware files whose file-name date is within the last 30 days, whatever their mark.
- **Duplicate**: an item that says the same thing as a brain line or as an earlier item in the same sweep.
- **Verbatim**: the quote appears in the source text, compared after collapsing whitespace and ignoring case.
- **Idle**: no dictation and no transcription in progress in Flow, and the Mac awake.
- **Pending**: finished transcripts not yet swept, whether to be read or, being older than `enabledAt`, to be recorded as swept unread.

## Features

### F1. Aware sweep (P1)
Why: removes the loss of what was said while meeting every constraint in the Problem: a sweep right after each meeting and a catch-up for any it missed, both at low load, a relevance gate, caps and a duplicate check against the brain, and proposals that wait for the user in the inbox.

Story: As the user, I want the to-dos, decisions and facts I said or heard in my meetings to show up in my brain inbox, few, shaped and new, so that I accept them in minutes instead of rereading transcripts.

Buffer (removed 2026-11-08):
- F1.1 Removed 2026-11-08: dictations are out of scope for now.
- F1.2 Removed 2026-11-08: dictations are out of scope for now.
- F1.3 Removed 2026-11-08: dictations are out of scope for now.
- F1.4 Removed 2026-11-08: dictations are out of scope for now.
- F1.5 Removed 2026-11-08: dictations are out of scope for now.
- F1.6 Removed 2026-11-08: dictations are out of scope for now.
- F1.7 Removed 2026-11-08: dictations are out of scope for now.
- F1.8 Removed 2026-11-08: dictations are out of scope for now.

Schedule and load:
- F1.9 Removed 2026-11-08: the dictation schedule and its interval are out of scope for now. Flow still checks every 10 minutes and on launch, now for the catch-up (F1.42).
- F1.10 Given the Mac runs on battery below 30%, when a catch-up is due (F1.42), then it is skipped until a check finds power above 30% or the charger connected.
- F1.11 Given a sweep is running, when the user presses the dictation hotkey or starts a transcription, then the sweep yields the model within 1 s and resumes when Flow is idle again. Sweeps run at background priority.

Sources:
- F1.36 Given a transcription ends at 10:45 and `TranscriptStore` has written the file with `end:` (and, when `summarizeTranscripts` is on, the summary has finished or failed), when Flow is idle, then a meeting sweep of that one transcript starts within 1 minute, and its items appear under `## 10:46 meeting` in the day file. The battery rule (F1.10) and the caps (F1.27, F1.28) apply; a meeting skipped for battery, a busy Flow, a missing model, a failed sweep or a crash, or ended while Flow was not running, is picked up by the next catch-up sweep (F1.42).
- F1.37 Given a catch-up sweep is running when a meeting ends, then the meeting sweep starts as soon as the catch-up sweep ends, not in parallel.
- F1.38 Given the model fails on every part of a sweep, then the sweep counts as failed: no transcript is marked swept, and the failure is recorded for the page. One unreadable part among readable ones stays F1.32.
- F1.39 Given Aware is turned on at 08:00:24 and a transcript has `start: "08:00"`, then that transcript is read, not recorded as swept: the file only stores the minute, so F1.35 applies from the next earlier minute.
- F1.40 Given a sweep ends, then `state.json` holds `lastResult` (time, meetings read, proposals written, failed, day file), and the Aware page shows it, for example "Last sweep 12:22: read 2 meetings, wrote 3 proposals". While a sweep runs the page shows "Reading now"; meetings waiting show as "1 meeting waiting" (F1.42). The log holds counts only, never content.
- F1.41 Given a sweep wrote proposals, then a notification says how many, and clicking it opens the day file. Given the user asked for the sweep, then a notification also answers when nothing was read, nothing was found or the read failed. An automatic sweep that finds nothing stays silent.
- F1.42 Given three transcripts in the folder: A is finished and not swept (its meeting sweep did not run at 10:45 because the model was missing), B is finished and starts before `enabledAt`, C is already swept; when the 10-minute check runs at 12:00 with Flow idle, the brain connected, the model downloaded, power above 30% or charging and no sweep running, then one catch-up sweep starts, reads A, records B as swept unread, and writes its items under `## 12:00`; the page showed "2 meetings waiting" until then. Given no transcript is pending (all swept, confidential, `aware: false` or without `end:`), then no sweep starts. Given Flow is busy, the brain or model is missing, power is below 30% on battery, or a sweep is running, then none starts and the next check tries again. "Sweep now" runs a catch-up whatever is pending and whatever the battery says, but not past the brain, model or busy checks.
- F1.12 Given one finished transcript not yet swept (its meeting sweep was skipped), when a catch-up sweep runs, then it reads it. Finished means the frontmatter has `end:`. The folder is read flat, `*.md` only.
- F1.13 Given a transcript whose frontmatter has `confidential: true` or `aware: false`, when a sweep runs, then it is skipped and never mentioned.
- F1.14 Given a transcript was swept and later changed (the user fixed a name), when the next sweep runs, then it is not swept again. `state.json` records swept transcripts by file name.
- F1.35 Given Aware is turned on 2026-11-05 at 08:00 and the folder already holds 120 older transcripts, when the first sweep runs, then every transcript whose frontmatter `date` and `start` lie before 08:00 that day is recorded as swept without being read. `state.json` stores the moment as `enabledAt`; turning Aware off and on again moves it.
- F1.15 Removed 2026-11-08: dictations are out of scope for now.

Relevance gate:
- F1.16 Given a `**Them** · 10:14` block on Thursday 2026-11-05 saying "Can you send me the deck by Friday?", when a sweep runs, then a `todo` item `- [ ] Send the deck (due: 2026-11-06)` appears with that sentence as its quote, speaker `Them`. Requests from others are the user's to-dos. An owner appears only when the quote names one; a due date only when the quote gives one, resolved against the source date.
- F1.17 Given `**You** · 10:20` "Okay, so we drop the legacy export, that's decided", and the brain has project `alpha` whose description mentions the export, then a `decision` item "Drop the legacy export" for `alpha` appears.
- F1.18 Given "we could maybe look at caching someday", "how was your weekend", or "I think the API is kind of slow", when the model judges them, then no item is written: not a task, not a decision, not a lasting fact.
- F1.19 Given the model returns an item whose quote is not verbatim in its source, then the item is dropped and counted as "quote not found".
- F1.20 Given a knowledge item whose suggested project is `none`, then it is dropped and counted as "no project". To-dos may have project `none`.
- F1.21 Given an item below its confidence floor (`todo` 0.5, `decision` and `fact` 0.7), then it is dropped and counted as "low confidence".

Duplicate check:
- F1.22 Given `projects/alpha.md` has `- [ ] Send the deck to the board` under `## Open`, when the item "Send the deck" for `alpha` is checked, then it is a duplicate, dropped and counted. The check has two steps. First a cheap one without the model: if the item's content words (lowercased, without the fixed English and German stop-word list in `AwareRules.stopWords`, no stemming) overlap a brain line's by at least 0.6 (Jaccard), it is a duplicate. Otherwise the model sees the item and the 20 brain lines with the highest overlap and answers `same`, `conflicts` or `new`; `same` is a duplicate.
- F1.23 Given `logs/alpha.md` has under `## 2026-10-28` "Decision: Legacy export is dropped in Q1", when the item "Drop the legacy export" for `alpha` is checked, then it is a duplicate.
- F1.24 Given an Aware file archived on 2026-10-20 with `- [-] Look into caching` and the same item comes up again, then it is a duplicate: a rejected item is not proposed again within 30 days.
- F1.25 Given the same request is said three times in one meeting, then one item is written.
- F1.26 Given `## Now` of `projects/alpha.md` says "launch in April" and an item for `alpha` says "launch moved to June", when the model answers `conflicts`, then the item is kept and its line ends with `conflicts: "launch in April"`.

Caps:
- F1.27 Given a sweep finds 14 items that pass the gate and the check, then the 10 with the highest confidence are written, and the other 4 are discarded and counted as "below the cut".
- F1.28 Given the day file already holds 25 items, then later sweeps that day write nothing to the brain, their sources count as swept, and the menu shows "Aware: daily cap reached" until midnight.

Output and failure:
- F1.29 Given the first sweep with items on 2026-11-05 at 12:00, then `inbox/2026-11-05-aware.md` is created; a later sweep that day appends a `## 15:00` section at the end and leaves every existing line as it is, except `description`.
- F1.30 Given a sweep finds no items, then nothing is written to the brain and its sources count as swept.
- F1.31 Given `Settings.vault` is unset or is not a Brain, or the model is not downloaded, when a sweep is due, then nothing is read or written, and the menu shows "Aware: no brain connected" or "Aware: model not downloaded".
- F1.32 Given the model's answer for one chunk does not parse twice in a row, then that chunk is skipped and counted as "unreadable", and the sweep goes on.
- F1.33 Given Flow quits during a sweep, then no transcript is marked swept. The order is fixed: write the inbox file, then update `state.json`. A crash after the write makes the next sweep repeat the sources, and F1.22 drops the repeats as duplicates of the day file.
- F1.34 Removed 2026-11-08: dictations are out of scope for now.

Testability: unit. Tested on its own by `AwareRules`, `TranscriptSource`, `BrainLines`, `AwareDedup`, `AwareScheduler` and `AwareWriter` against a temporary Aware folder and a fixture brain (paths injected; with `IONIAN_FLOW_TEST_DIR` set they default to `<testDir>/Aware` and `<testDir>/Brain`), a fixed clock, a stubbed power state, a stubbed pending count and a stubbed model returning fixed JSON; shows F1.10 to F1.14, F1.19 to F1.25 (the overlap step on its own, the model step stubbed), F1.27 to F1.33 and F1.35 to F1.42, including the file mode of `state.json`, the 1 s yield and the menu strings. Integration behind `IONIAN_FLOW_MODEL_TESTS=1`: real Gemma on two fixture meetings and a fixture brain; shows F1.16 to F1.18, F1.22 and F1.26 with the model step, and that every quote is verbatim.

### F2. Precision report (P2)
Why: the anti-flood thresholds in F1 are guesses until measured, and auto-accept is only safe with measured precision; the user's marks already end up in archived Aware files.

Story: As the user, I want to see how often each kind of item was accepted and how many were duplicates, so that I can tighten the thresholds and later let one kind skip review.

- F2.1 Given three Aware files in `<brain>/_archive/inbox/` with 10 `decision` lines (7 `[x]`, 1 `[~]`, 1 `[-]`, 1 `[=]`), when `IonianFlow --aware-precision` runs, then it prints `decision 8/10 80% duplicates 1`. `[x]` and `[~]` count as accepted, `[-]` and `[=]` as not; rounded to the nearest whole percent; one line per category, a category with no marked lines not printed.
- F2.2 Given lines still marked `[ ]`, then they are counted on a last line `unreviewed <n>` and in no rate.
- F2.3 Given `--brain DIR`, then it reads `DIR/_archive/inbox/`; without it, `<Settings.vault>/_archive/inbox/`; if neither exists it prints "no brain" and exits 1.

Testability: unit. Tested on its own by running the report function on fixture files in a temporary folder; shows the exact lines of F2.1 to F2.3.

### F3. Aware page (P3)
Why: Aware is Flow's key feature, and one row under General hides it. The user needs one place to turn it on, see what it is doing, and say where it writes and what it looks for.

Story: As the user, I want Aware as its own page in the settings, so that I can see and control it without hunting.

Scenarios:
- F3.1 Given the Flow window, then the sidebar lists "Aware" directly under "General", and General has no Aware row any more.
- F3.2 Given Aware is on with a Brain at `~/Ionian/brain`, a last sweep at 12:00 that read 1 meeting and wrote 2 proposals, 1 pending meeting and 4 lines marked `[ ]` in today's day file, then the page shows the switch, "Last sweep 12:00: read 1 meeting, wrote 2 proposals", "1 meeting waiting", "4 items waiting", and the Brain path. There is no "Next around" line.
- F3.3 Given the user picks a folder under Brain, when it is an Ionian Brain, then `awareBrainFolder` is set and `BrainLocator` tries it first; when it is not, the choice is refused, the old Brain stays, and the page says "That folder is not an Ionian Brain." with the link to get one.
- F3.4 Given a Brain, when the user chooses "Open inbox", then Finder opens `<brain>/inbox/`. The inbox location itself cannot be changed: it is part of the Brain structure.
- F3.5 Given "Facts" is switched off under What it looks for (`awareKinds`, default all three), when a sweep finds a fact, then it is dropped after extraction, before the verification call, and counted "by rules".
- F3.6 Removed 2026-11-08: dictations are out of scope for now. The Meetings switch went with them; Aware on means meetings are read.
- F3.7 Removed 2026-11-08: dictations are out of scope for now.
- F3.8 Removed 2026-11-08: dictations are out of scope for now.
- F3.9 Removed 2026-11-08: dictations are out of scope for now.
- F3.10 Removed 2026-11-08: dictations are out of scope for now.
- F3.11 Given "Sweep now" on the page, then it does what the menu item of the same name does. The pause and the "Paused until" line were removed 2026-11-08: dictations are out of scope for now.
- F3.12 Given no Brain, or no cleanup model, then the page shows the matching state from the General row of 2026-11-06 (F1.31) with its link, and the controls that cannot work are disabled.
- F3.13 Given Aware is off, then the top of the page shows a stage: when the page first appears after launch, a few fragments of speech settle once as lines tagged to-do, decision and fact, with invented sample text and a one-line pitch, and the stage then rests as a still frame.
- F3.14 Given the user switches Aware on, then the stage plays one quiet moment of about 1.5 seconds that resolves into the live status, and is then still; it moves again only while a sweep really runs. It does not replay on page open or launch. With Reduce Motion on, the page shows a still frame. At rest, hidden or off-screen, the stage draws nothing.
- F3.15 Given no Brain, then the page invites instead of blocking: the teaser plays, the copy presents the Ionian Brain as the reason it works, with "Get Ionian Brain" as the page's one pill and a way to connect an existing Brain. Flipping the switch without a Brain moves focus to that invitation. This replaces the no-Brain part of F3.12.
- F3.16 Given a Sweep now that cannot run (no brain or no model), then it answers with a notification, never with silence. The pause part was removed 2026-11-08: dictations are out of scope for now.

Testability: unit. Tested on its own by the page's pure state function and the settings and sweep rules with a fixture brain, a fixed clock and injected paths; shows F3.2 to F3.5 and F3.11. Offscreen renders in light and dark for F3.1, F3.2 and F3.12.

## Success criteria
- SC1 At least 60% of the first 50 reviewed items are accepted or edited, and at least 70% of reviewed knowledge items, checked with `--aware-precision`.
- SC2 At most 10% of reviewed items are marked duplicate, checked with `--aware-precision`.
- SC3 At most 25 items a day; a day's file takes the user at most 5 minutes to review, timed by hand on one real day.
- SC4 Zero files created or changed in the brain outside `inbox/`, checked by diffing a fixture brain before and after 10 sweeps.
- SC5 Removed 2026-11-08: dictations are out of scope for now.
- SC6 Every item's quote is verbatim in its source: 100%.
- SC7 A catch-up sweep over 3 hours of meetings finishes within 10 minutes on an Apple M1 or later, timed in a model integration test on a fixture set of that size.
- SC8 A one-hour meeting's items are in the inbox within 5 minutes of the meeting's end on an Apple M1 or later, timed in a model integration test on a one-hour fixture meeting.

## Interfaces and data

Tests: `swift test --package-path app`; model tests: `IONIAN_FLOW_MODEL_TESTS=1 swift test --package-path app`.

Settings (keys in `Settings`): `aware` Bool (default false), `awareBrainFolder` URL?, `awareKinds` [String] (default all three). The Aware page has the switch; the menu, when Aware is on, shows the status line (F1.28, F1.31) when there is one, then "Sweep now". "Sweep now" starts a catch-up sweep at once, ignoring what is pending and the battery rule but not the brain and model checks, the caps or the yield. The scheduler takes a `pendingMeetings` closure; the app passes the count of `TranscriptSource.pending(...)` `toRead` plus `recordAsSwept`. Thresholds (confidence floors, overlap 0.6, caps 10 and 25) are constants in `AwareRules`, like `SweepRank.minScore`, tuned from F2.

Local file, in `~/Library/Application Support/Ionian Flow/Aware/`, mode 0600:
- `state.json`: `{"enabledAt": "<ISO 8601>", "swept": ["<transcript file name>", ...], "lastResult": {...}}`. A `lastSweep` key from an older file is ignored and dropped on the next save.

Code (new), in `app/Sources/IonianFlow/Aware/`: `TranscriptSource` (pending transcripts, speaker blocks), `AwareRules` (evidence rule, gate, thresholds), `BrainLines` (reads the brain lines from `projects/*.md`, `logs/*.md` and Aware files in `inbox/` and `_archive/inbox/`; skips folders starting with `.`), `AwareSweep` (Gemma prompt to items, verbatim guard, relevance gate), `AwareDedup` (overlap step, model step), `AwareWriter` (creates or appends the day file), `AwareScheduler` (the catch-up rule of F1.42, power check, yield on hotkey as `VaultSweeper` pauses). `--aware-precision` (new) is registered in `Dev/EngineCLI.swift`. Hook: `Transcriber.onFileFinal` calls `AwareScheduler.meetingEnded`; the app's 10-minute timer calls `tick()`. The model comes from `ModelHub`; long transcripts go in parts the way `Summarizer` chunks them.

Day file `inbox/YYYY-MM-DD-aware.md`:
```
---
type: capture
description: "Aware: 4 items from 1 meeting"
tags: [automation]
org: unknown
source: flow
updated: 2026-11-05
---

# Aware 2026-11-05

Mark each line: [x] accept, [~] edited, [-] reject, [=] duplicate.

## 12:00
- [ ] todo: Send the deck (due: 2026-11-06) → alpha > "Can you send me the deck by Friday?" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:14, Them, 0.82)
- [ ] decision: Drop the legacy export → alpha > "so we drop the legacy export, that's decided" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:20, You, 0.88)
- [ ] fact: Launch moved to June → alpha > "the launch moved to June" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:31, Them, 0.74) conflicts: "launch in April"
- [ ] todo: Renew the vendor contract (due: 2026-11-06) → none > "Remind me to renew the vendor contract by Friday" ([2026-11-05 10-02](/transcripts/2026-11-05%2010-02.md) 10:41, You, 0.77)

Swept 1 meeting. Dropped: 9 by rules, 1 no project, 2 low confidence, 3 duplicate, 0 quote not found, 0 unreadable, 0 below the cut.
```
`description` counts the items and the meetings behind the sections in the file. A catch-up section is headed `## HH:mm`, a meeting section `## HH:mm meeting`. The source link is root-relative when `Settings.transcriptsFolder` is inside the brain, else the file name alone; the time is the start of the block holding the quote.

## Decisions
- Name: Aware (user's choice, 2026-11-05).
- To-dos, decisions and facts, each behind a relevance gate: knowledge needs a known project and a higher confidence floor than to-dos. Rejected: everything worth noting, because the vocabulary sweep showed that an open net floods the review; rejected: to-dos only, because decisions and facts are knowledge the user wants kept too.
- Duplicate check in two steps, word overlap first and the model only on the closest 20 brain lines. Rejected: model against the whole brain, because it costs too much load per item; rejected: overlap only, because rephrased duplicates slip through.
- Compare against rejected items of the last 30 days too. Rejected: only accepted content, because a rejected idea would come back every time it is said again.
- Hard caps of 10 items per sweep and 25 per day, best confidence first. Rejected: no cap, for the flooding reason above.
- Meetings are swept the moment they end; any that could not be swept then are picked up by a catch-up check every 10 minutes (F1.42). Rejected: a sweep on a fixed schedule, because a meeting's to-dos matter most right after it, one finished meeting is a bounded load, and a catch-up only runs when something is waiting.
- Meeting transcripts only, from 2026-11-08 (owner's decision). Dictations come back later if meetings prove the value; the last code with them is commit 32689e5.
- A separate extraction pass over the transcript text. Rejected: reusing the summary's **Decisions** and **Action items**, because those are paraphrases without verbatim quotes, exist only when a summary was made, and carry no facts.
- Items said by `Them` are kept and labelled. Rejected: the user's own speech only, because most to-dos and many facts in a meeting come from others; the consent line in the transcript panel already covers recording others.
- One inbox file per day, appended per sweep. Rejected: one file per sweep, because up to 8 files a day would crowd the inbox.
- `org: unknown` and a suggested project only. Rejected: deciding the org, because the brain's rules leave that to triage.
- Same Gemma 4 E2B as polish and the vault sweep. Rejected: a second model, because batch runs remove the latency concern.
- Off by default. Rejected: on by default, because storing what the user says needs an explicit yes.
- `Settings.vault` changes from read-only to "read, plus Aware's own files in `inbox/`". Rejected: a separate output folder, because the review should happen where the brain's inbox already gets triaged.
- Quotes persist: each item's quote stays in the brain's inbox and, after review, in `_archive/inbox/` and the brain's git history. The review skill may strip quotes from rejected lines; the precision report and the 30-day rejected check need only the item text and the mark.

## Assumptions
- Building starts only once the native build is in daily use and stable (user decision 2026-11-03). If wrong: only the start date changes.
- The brain accepts `source: flow`; its rules list a fixed set of capture sources today. If wrong: the file uses `source: desktop`.
- Gemma 4 E2B judges relevance and sameness well enough for SC1 and SC2 on short quotes. If wrong: try a larger Gemma for sweeps before any other model.
- Brain lines for a typical brain stay under 5,000 lines, so `BrainLines` reads them fresh each sweep. If wrong: cache them by file modification time.

## Dependencies
- Brain: `source: flow` added to the brain's inbox rules, and a review skill that reads the marks and archives the file (brain repo, separate spec).
- No new packages. Battery state uses IOKit's power source API, which ships with macOS.

## Review
- Round 1 (2026-11-05): paraphrase context missing, 0 divergences, 15 guesses; critic B0 M11 N4; readiness B6 M9 N0. After merging 4 duplicates: fixed 29, rejected 0, escalated 0. Not run: none. Mid-review the user set the name and the scope (below); the spec was rewritten on that basis.
- Round 2 (2026-11-05): paraphrase context sufficient, 0 divergences, 12 guesses; critic B1 M0 N0; readiness B0 M0 N0 (two Majors noted below its bar). After merging 2 duplicates: fixed 12, rejected 0, escalated 1 (C2-1, fixed with the recommended answer and put to the user). Not run: none. All round 2 fixes are unreviewed.
- Clarification (2026-11-05): On first enable, sweep the existing transcript backlog? Answer: no, start from the moment Aware is turned on. Changed: F1.35, Interfaces (`enabledAt`).
- Clarification (2026-11-05): Meetings on the schedule or right away? Answer: meetings right after they end, dictations on the schedule. Changed: Terms (Sweep), F1.9, F1.12, F1.36, F1.37 (new), SC8 (new), Interfaces, Decisions. Unreviewed.
- Change (2026-11-06, user's request): Aware gets its own settings page instead of a row under General, with the Brain folder, inbox, what it looks for and the schedule. Added: F3, including the teaser, the enable moment and the Brain invitation (F3.13 to F3.15). Removed from Out of scope: settings UI beyond one toggle. Not reviewed by the zero-context reviewers.
- Clarification (2026-11-05): Name? Answer: Aware.
- Approved (2026-11-05) by the user, including the unreviewed meeting-end change.
- Change (2026-11-06, user's request): Aware requires an Ionian Brain and says so. The Brain is the first of `Settings.vault`, `$BRAIN_DIR`, `$IONIAN_HOME/brain` and `~/Ionian/brain` that holds `AGENTS.md`, `inbox/` and `projects/` (the same lookup as the Brain plugin). Without one, the General page toggle is disabled and its row says that Aware needs an Ionian Brain, with a link to get it; with Aware on and the model missing, the row says so too. Shorter toggle copy so it fits one line. Changed: Terms (Brain), Interfaces (General page). Unreviewed.
- Change (2026-11-06, user consent): parts of at most 1,500 characters and 12 sources (one dictation per call) instead of `Summarizer` chunks, and a verification call per candidate plus an evidence rule for decisions and facts, both from measured precision (end-to-end precision 100% on four fixture sets, one held out). Changed: Interfaces (chunking), F1 relevance gate. Changed: title, Settings, Interfaces, Decisions.
- Clarification (2026-11-05): What should it extract and how often? Answer: to-dos and real knowledge, with a solid duplicate check so the inbox does not flood with redundant or irrelevant items (the early vocabulary sweep indexed everything); a sweep every 2 to 3 hours over the latest window; the temporary dictation buffer removed after each sweep, transcripts kept; light load. Changed: Problem, Out of scope, Terms, F1, F2, Success criteria, Interfaces, Decisions.
- Clarification (2026-11-07): First real use: the owner saw nothing happen on switching on or on Sweep now, and got no notifications. Answer: a sweep must say what it did. Added F1.38 to F1.41 and F3.16 at the owner's report; a sweep that wrote proposals was invisible, a meeting in the minute of enabling was skipped, a pause blocked everything silently. Unreviewed.
- Clarification (2026-11-08): Do dictations into AI tools (requests to an assistant, such as "can you check the build") count? Answer: yes, they stay in; no app is excluded for being an AI tool. Changed: nothing in the rules, recorded so it is not "fixed" later.
- Clarification (2026-11-08): Rename? Answer: the feature is called Aware, not Instinct. Changed: the name everywhere (code, settings keys, Application Support folder, day file `-aware.md`, CLI flags, copy, the brain skill `aware`). Unreviewed.
- Clarification (2026-11-08): Scope? Answer: meeting transcripts only for now; dictations come back later if meetings prove the value. Changed: F1, F3, SC5, SC7, Interfaces, Out of scope; F1.42 new. Unreviewed.
