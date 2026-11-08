# Aware

Status: approved 2026-11-05
Slug: aware
Date: 2026-11-05

## Problem
Things worth keeping are said out loud all day and then lost: "can you send me the deck by Friday" in a meeting, "we're dropping the legacy export" in a call, "remind me to renew the contract" dictated into a chat. Flow turns that speech into text on the device, but nothing picks out what matters, so it reaches the Ionian Brain only if the user rereads transcripts or retells the day to an agent, which mostly does not happen. Flow already runs a local language model, so it can do the sifting itself. Five constraints shape it. Dictations are stored only briefly and in little space. The sweep must not load the Mac while the user works. Nothing goes into the brain directly: Aware proposes, the user accepts or rejects. And above all the inbox must not flood: the first version of Flow's vocabulary sweep indexed nearly everything it saw and was useless until it got an evidence bar, a score threshold and a hard cap per run. Aware needs the same discipline from day one, plus a solid check that what it proposes is not already in the brain.

## Existing system
- **Flow** (this repo, overview in `README.md` and `STATE.md`) is a macOS menu-bar app. Hold a hotkey to dictate: speech becomes text on the device, `Polisher` cleans it, and `deliver(_:)` in `app/Sources/IonianFlow/App/main.swift` pastes it into the front app. Only the last 10 dictations are kept, in memory, so there is no dictation store today.
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

## Terms
- **Brain**: the first of `Settings.vault`, `$BRAIN_DIR`, `$IONIAN_HOME/brain` and `~/Ionian/brain` that holds `AGENTS.md`, `inbox/` and `projects/`.
- **Buffer**: the local file of recent dictations waiting for the next sweep.
- **Sweep**: one batch run, of one of two kinds. A **meeting sweep** reads one transcript right after its meeting ends. A **dictation sweep** runs on the schedule and reads the buffer plus any finished transcript still not swept. Only one sweep runs at a time; a sweep that comes due while another runs waits for it.
- **Item**: one proposal: category (`todo`, `decision` or `fact`), text, verbatim quote, source, suggested project, confidence.
- **Knowledge item**: an item of category `decision` or `fact`.
- **Confidence**: the model's own score from 0 to 1 that the item is real, lasting and worth keeping, as returned in its JSON answer.
- **Brain lines**: what an item is compared against, across all projects: for each project, its `description`, `focus`, the lines under `## Now` and `## Open`, and its log bullets from the last 30 days; plus the item text (between the category and `→`) of every line in unarchived Aware files and in archived Aware files whose file-name date is within the last 30 days, whatever their mark.
- **Duplicate**: an item that says the same thing as a brain line or as an earlier item in the same sweep.
- **Verbatim**: the quote appears in the source text, compared after collapsing whitespace and ignoring case.
- **Idle**: no dictation and no transcription in progress, and the Mac awake.

## Features

### F1. Aware sweep (P1)
Why: removes the loss of what was said while meeting every constraint in the Problem: a buffer that lives only until the next sweep, a sweep every few hours at low load, a relevance gate, caps and a duplicate check against the brain, and proposals that wait for the user in the inbox.

Story: As the user, I want the to-dos, decisions and facts I said or heard today to show up in my brain inbox, few, shaped and new, so that I accept them in minutes instead of rereading transcripts.

Buffer:
- F1.1 Given `aware` is true and the front app is Notes, when the user dictates "Remind me to renew the vendor contract by Friday", then one line with id, time, app name, bundle id and the delivered (polished) text is appended to `buffer.jsonl`.
- F1.2 Given the front app's bundle id is in `awareExcludedApps` (default: `com.1password.1password`, `com.agilebits.onepassword7`, `com.bitwarden.desktop`, `com.apple.Passwords`, `com.apple.keychainaccess`), when the user dictates, then nothing is stored.
- F1.3 Given secure text input is active (`IsSecureEventInputEnabled()` is true, as in a password field in any app), when the user dictates, then nothing is stored.
- F1.4 Given the user chose "Pause Aware for 1 hour" in the menu, when they dictate in that hour, then nothing is stored and no sweep runs.
- F1.5 Given an empty Aware folder, when the first line is appended, then `buffer.jsonl` and `state.json` have mode 0600.
- F1.6 Given the buffer has a line that does not parse, when it is read, then that line is skipped and logged once and the others are kept.
- F1.7 Given buffer lines older than 24 hours, when the buffer is read or appended to, then those lines are dropped and the file rewritten without them.
- F1.8 Given the buffer has reached 1 MB, when a dictation is appended, then the oldest lines are dropped until it fits.

Schedule and load:
- F1.9 Given `awareIntervalHours` is 3 and the last dictation sweep ended 2026-11-05 09:00, when Flow is idle at 12:00, then a dictation sweep starts; at 11:59 none starts. Flow checks every 10 minutes and on launch, so a sweep missed while the Mac slept or Flow was closed runs once at the first idle check, never twice.
- F1.10 Given the Mac runs on battery below 30%, when a sweep is due, then it is skipped until a check finds power above 30% or the charger connected.
- F1.11 Given a sweep is running, when the user presses the dictation hotkey or starts a transcription, then the sweep yields the model within 1 s and resumes when Flow is idle again. Sweeps run at background priority.

Sources:
- F1.36 Given a transcription ends at 10:45 and `TranscriptStore` has written the file with `end:` (and, when `summarizeTranscripts` is on, the summary has finished or failed), when Flow is idle, then a meeting sweep of that one transcript starts within 1 minute, and its items appear under `## 10:46 meeting` in the day file. The battery rule (F1.10) and the caps (F1.27, F1.28) apply; a meeting skipped for battery, a missing model or a crash is picked up by the next dictation sweep.
- F1.37 Given a dictation sweep is running when a meeting ends, then the meeting sweep starts as soon as the dictation sweep ends, not in parallel.
- F1.38 Given the model fails on every part of a sweep, then the sweep counts as failed: no buffer line is deleted, no transcript is marked swept, and the failure is recorded for the page. One unreadable part among readable ones stays F1.32.
- F1.39 Given Aware is turned on at 08:00:24 and a transcript has `start: "08:00"`, then that transcript is read, not recorded as swept: the file only stores the minute, so F1.35 applies from the next earlier minute.
- F1.40 Given a sweep ends, then `state.json` holds `lastResult` (time, meetings and dictations read, proposals written, failed, day file), and the Aware page shows it, for example "Last sweep 12:22: read 13 dictations, wrote 3 proposals". While a sweep runs the page shows "Reading now"; dictations waiting show as "3 dictations collected". The log holds counts only, never content.
- F1.41 Given a sweep wrote proposals, then a notification says how many, and clicking it opens the day file. Given the user asked for the sweep, then a notification also answers when nothing was read, nothing was found or the read failed. An automatic sweep that finds nothing stays silent.
- F1.12 Given the buffer holds 12 dictations and `Settings.transcriptsFolder` holds one finished transcript not yet swept (its meeting sweep was skipped), when a dictation sweep runs, then it reads exactly those. Finished means the frontmatter has `end:`. The folder is read flat, `*.md` only.
- F1.13 Given a transcript whose frontmatter has `confidential: true` or `aware: false`, when a sweep runs, then it is skipped and never mentioned.
- F1.14 Given a transcript was swept and later changed (the user fixed a name), when the next sweep runs, then it is not swept again. `state.json` records swept transcripts by file name.
- F1.35 Given Aware is turned on 2026-11-05 at 08:00 and the folder already holds 120 older transcripts, when the first sweep runs, then every transcript whose frontmatter `date` and `start` lie before 08:00 that day is recorded as swept without being read. `state.json` stores the moment as `enabledAt`; turning Aware off and on again moves it.
- F1.15 Prefilter for dictations, before the model, in this order (transcript blocks are not prefiltered): a dictation with fewer than 3 words is dropped; a dictation from an app in `codeApps` (`com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`, `com.mitchellh.ghostty`, `com.microsoft.VSCode`, `com.apple.dt.Xcode`, `com.todesktop.230313mzl4w4u92`, `dev.zed.Zed`) with no cue is dropped; everything else goes to the model. Cues (`AwareRules.cues`), whole words or phrases, ignoring case: "todo", "to do", "remind me", "note to self", "don't forget", "I need to", "we decided", "for the record", "erinner mich", "nicht vergessen", "wir haben entschieden". Example: 40 Terminal captures like "git rebase main and fix the merge conflicts" are dropped; "note to self: rotate the staging key monthly" from Terminal goes to the model.

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
- F1.31 Given `Settings.vault` is unset or is not a Brain, or the model is not downloaded, when a sweep is due, then nothing is read or written, the buffer is kept (within F1.7), and the menu shows "Aware: no brain connected" or "Aware: model not downloaded".
- F1.32 Given the model's answer for one chunk does not parse twice in a row, then that chunk is skipped and counted as "unreadable", and the sweep goes on.
- F1.33 Given Flow quits during a sweep, then no buffer line is deleted and no transcript marked swept. The order is fixed: write the inbox file, then update `state.json`, then delete the buffer lines read. A crash after the write makes the next sweep repeat the sources, and F1.22 drops the repeats as duplicates of the day file.
- F1.34 Given a sweep ends without error, then every buffer line it read, including those F1.15 dropped, is deleted; transcripts are never deleted.

Testability: unit. Tested on its own by `CaptureBuffer`, `AwareRules`, `BrainLines`, `AwareDedup`, `AwareScheduler` and `AwareWriter` against a temporary Aware folder and a fixture brain (paths injected; with `IONIAN_FLOW_TEST_DIR` set they default to `<testDir>/Aware` and `<testDir>/Brain`), a fixed clock, a stubbed power state, a stubbed hotkey event and a stubbed model returning fixed JSON; shows F1.1 to F1.15, F1.19 to F1.25 (the overlap step on its own, the model step stubbed) F1.27 to F1.37, including the file mode, the 1 s yield and the menu strings. Integration behind `IONIAN_FLOW_MODEL_TESTS=1`: real Gemma on two fixture meetings, 20 fixture dictations and a fixture brain; shows F1.16 to F1.18, F1.22 and F1.26 with the model step, and that every quote is verbatim.

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
- F3.2 Given Aware is on with a Brain at `~/Ionian/brain`, last sweep 12:00, interval 3 h and 4 lines marked `[ ]` in today's day file, then the page shows the switch, "Last sweep 12:00", "Next around 15:00", "4 items waiting", and the Brain path.
- F3.3 Given the user picks a folder under Brain, when it is an Ionian Brain, then `awareBrainFolder` is set and `BrainLocator` tries it first; when it is not, the choice is refused, the old Brain stays, and the page says "That folder is not an Ionian Brain." with the link to get one.
- F3.4 Given a Brain, when the user chooses "Open inbox", then Finder opens `<brain>/inbox/`. The inbox location itself cannot be changed: it is part of the Brain structure.
- F3.5 Given "Facts" is switched off under What it looks for (`awareKinds`, default all three), when a sweep finds a fact, then it is dropped after extraction, before the verification call, and counted "by rules".
- F3.6 Given "Meetings" (`awareMeetings`, default true) is off, then no meeting sweep starts and scheduled sweeps read no transcripts; turning it on sets `enabledAt` to now, so meetings from the off period are not swept.
- F3.7 Given "Dictations" (`awareDictations`, default true) is off, then nothing is captured, and switching it off deletes `buffer.jsonl`.
- F3.8 Given the user switches Aware off, then `buffer.jsonl` is deleted, so no dictation stays on disk while nothing would ever sweep it.
- F3.9 Given the interval picker (1, 2, 3 or 6 hours, `awareIntervalHours`), when the user picks 2, then F1.9 uses 2 hours.
- F3.10 Given the Never capture from list (`awareExcludedApps`), when the user adds an app, then its bundle id is excluded (F1.2); when they remove one, it is captured again.
- F3.11 Given "Sweep now" and "Pause for 1 hour" on the page, then they do what the menu items of the same name do; while paused the page says until when.
- F3.12 Given no Brain, or no cleanup model, then the page shows the matching state from the General row of 2026-11-06 (F1.31) with its link, and the controls that cannot work are disabled.
- F3.13 Given Aware is off, then the top of the page shows a stage: when the page first appears after launch, a few fragments of speech settle once as lines tagged to-do, decision and fact, with invented sample text and a one-line pitch, and the stage then rests as a still frame.
- F3.14 Given the user switches Aware on, then the stage plays one quiet moment of about 1.5 seconds that resolves into the live status, and is then still; it moves again only while a sweep really runs. It does not replay on page open or launch. With Reduce Motion on, the page shows a still frame. At rest, hidden or off-screen, the stage draws nothing.
- F3.15 Given no Brain, then the page invites instead of blocking: the teaser plays, the copy presents the Ionian Brain as the reason it works, with "Get Ionian Brain" as the page's one pill and a way to connect an existing Brain. Flipping the switch without a Brain moves focus to that invitation. This replaces the no-Brain part of F3.12.
- F3.16 Given Aware is paused, then Sweep now is off and says "Paused until 14:05. Resume to read now.", the page and the menu offer Resume, and the menu shows the pause. Turning Aware on clears an old pause. A Sweep now that cannot run answers with a notification, never with silence.

Testability: unit. Tested on its own by the page's pure state function and the settings and sweep rules with a fixture brain, a fixed clock and injected paths; shows F3.2 to F3.11. Offscreen renders in light and dark for F3.1, F3.2 and F3.12.

## Success criteria
- SC1 At least 60% of the first 50 reviewed items are accepted or edited, and at least 70% of reviewed knowledge items, checked with `--aware-precision`.
- SC2 At most 10% of reviewed items are marked duplicate, checked with `--aware-precision`.
- SC3 At most 25 items a day; a day's file takes the user at most 5 minutes to review, timed by hand on one real day.
- SC4 Zero files created or changed in the brain outside `inbox/`, checked by diffing a fixture brain before and after 10 sweeps.
- SC5 No dictation text older than 24 hours is ever read, and the buffer never exceeds 1 MB.
- SC6 Every item's quote is verbatim in its source: 100%.
- SC7 A sweep over 3 hours of meetings and 100 dictations finishes within 10 minutes on an Apple M1 or later, and polish of a dictation started during it begins at most 1 s later than when idle; both timed in a model integration test on a fixture set of that size.
- SC8 A one-hour meeting's items are in the inbox within 5 minutes of the meeting's end on an Apple M1 or later, timed in a model integration test on a one-hour fixture meeting.

## Interfaces and data

Tests: `swift test --package-path app`; model tests: `IONIAN_FLOW_MODEL_TESTS=1 swift test --package-path app`.

Settings (new keys in `Settings`): `aware` Bool (default false), `awareExcludedApps` [String] (default in F1.2), `awareIntervalHours` Int (default 3), `awarePausedUntil` Date?. An Aware toggle on the General page; menu items "Sweep now" and "Pause Aware for 1 hour"; status line as in F1.28 and F1.31. "Sweep now" starts a dictation sweep at once, ignoring the interval and the battery rule but not the pause, the brain and model checks, the caps or the yield, and it resets `lastSweep`. Thresholds (confidence floors, overlap 0.6, caps 10 and 25) are constants in `AwareRules`, like `SweepRank.minScore`, tuned from F2.

Local files (new), in `~/Library/Application Support/Ionian Flow/Aware/`, mode 0600:
- `buffer.jsonl`: `{"id":"<uuid>","time":"<ISO 8601>","app":"Notes","bundle":"com.apple.Notes","text":"..."}` per line. About 200 bytes per dictation.
- `state.json`: `{"enabledAt": "<ISO 8601>", "swept": ["<transcript file name>", ...], "lastSweep": "<ISO 8601>"}`.

Code (new), in `app/Sources/IonianFlow/Aware/`: `CaptureBuffer` (append, read with age and size limits, remove(ids:)), `AwareRules` (prefilter, `codeApps`, `cues`, thresholds), `BrainLines` (reads the brain lines from `projects/*.md`, `logs/*.md` and Aware files in `inbox/` and `_archive/inbox/`; skips folders starting with `.`), `AwareSweep` (Gemma prompt to items, verbatim guard, relevance gate), `AwareDedup` (overlap step, model step), `AwareWriter` (creates or appends the day file), `AwareScheduler` (due rule, power check, yield on hotkey as `VaultSweeper` pauses). `--aware-precision` (new) is registered in `Dev/EngineCLI.swift`. Hook: `deliver(_:)` calls `CaptureBuffer.append` after pasting. The model comes from `ModelHub`; long transcripts go in parts the way `Summarizer` chunks them.

Day file `inbox/YYYY-MM-DD-aware.md`:
```
---
type: capture
description: "Aware: 4 items from 1 meeting and 12 dictations"
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
- [ ] todo: Renew the vendor contract (due: 2026-11-06) → none > "Remind me to renew the vendor contract by Friday" (Notes 2026-11-05 10:41, 0.77)

Swept 1 meeting, 12 dictations. Dropped: 9 by rules, 1 no project, 2 low confidence, 3 duplicate, 0 quote not found, 0 unreadable, 0 below the cut.
```
`description` counts the items and the sources behind the sections in the file. The source link is root-relative when `Settings.transcriptsFolder` is inside the brain, else the file name alone; the time is the start of the block holding the quote.

## Decisions
- Name: Aware (user's choice, 2026-11-05).
- To-dos, decisions and facts, each behind a relevance gate: knowledge needs a known project and a higher confidence floor than to-dos. Rejected: everything worth noting, because the vocabulary sweep showed that an open net floods the review; rejected: to-dos only, because decisions and facts are knowledge the user wants kept too.
- Duplicate check in two steps, word overlap first and the model only on the closest 20 brain lines. Rejected: model against the whole brain, because it costs too much load per item; rejected: overlap only, because rephrased duplicates slip through.
- Compare against rejected items of the last 30 days too. Rejected: only accepted content, because a rejected idea would come back every time it is said again.
- Hard caps of 10 items per sweep and 25 per day, best confidence first. Rejected: no cap, for the flooding reason above.
- Meetings are swept the moment they end; dictations every 3 hours over what is new since the last sweep. Rejected: meetings on the schedule too, because a meeting's to-dos matter most right after it and one finished meeting is a bounded load; dictations one by one, because the model would load all day for single sentences; daily, because the buffer would hold a whole day of text.
- A separate extraction pass over the transcript text. Rejected: reusing the summary's **Decisions** and **Action items**, because those are paraphrases without verbatim quotes, exist only when a summary was made, and carry no facts.
- Items said by `Them` are kept and labelled. Rejected: the user's own speech only, because most to-dos and many facts in a meeting come from others; the consent line in the transcript panel already covers recording others.
- One inbox file per day, appended per sweep. Rejected: one file per sweep, because up to 8 files a day would crowd the inbox.
- `org: unknown` and a suggested project only. Rejected: deciding the org, because the brain's rules leave that to triage.
- Same Gemma 4 E2B as polish and the vault sweep. Rejected: a second model, because batch runs remove the latency concern.
- Off by default. Rejected: on by default, because storing what the user says needs an explicit yes.
- `Settings.vault` changes from read-only to "read, plus Aware's own files in `inbox/`". Rejected: a separate output folder, because the review should happen where the brain's inbox already gets triaged.
- Quotes persist: each item's quote stays in the brain's inbox and, after review, in `_archive/inbox/` and the brain's git history. The buffer itself is short-lived. The review skill may strip quotes from rejected lines; the precision report and the 30-day rejected check need only the item text and the mark.

## Assumptions
- Building starts only once the native build is in daily use and stable (user decision 2026-11-03). If wrong: only the start date changes.
- The brain accepts `source: flow`; its rules list a fixed set of capture sources today. If wrong: the file uses `source: desktop`.
- Gemma 4 E2B judges relevance and sameness well enough for SC1 and SC2 on short quotes. If wrong: try a larger Gemma for sweeps before any other model.
- Brain lines for a typical brain stay under 5,000 lines, so `BrainLines` reads them fresh each sweep. If wrong: cache them by file modification time.

## Dependencies
- Brain: `source: flow` added to the brain's inbox rules, and a review skill that reads the marks and archives the file (brain repo, separate spec).
- No new packages. Secure input uses Carbon's `IsSecureEventInputEnabled()`, battery state IOKit's power source API; both ship with macOS.

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
