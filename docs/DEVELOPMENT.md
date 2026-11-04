# Developing Ionian Flow

The [README](../README.md) is for people using Ionian Flow. This page is for building, changing and
understanding it. Flow is a Swift package (`app/`); there is no other runtime.

## Build from source
You need a Mac with Apple Silicon, macOS 15 or later, Xcode and its Metal Toolchain (once:
`xcodebuild -downloadComponent MetalToolchain`). `swift build` and the tests work with the command line tools alone;
`build-app.sh` needs the Metal compiler. People who run the built app need nothing.
```bash
swift build --package-path app        # debug build, enough for the tests
scripts/make-cert.sh                  # once: stable code signature (see below)
scripts/build-app.sh && open "build/Ionian Flow.app"   # release build, signed .app in build/
```
`scripts/install.sh` runs `make-cert.sh`, `build-app.sh` and `open` for you.

**GPU kernels.** `scripts/build-metallib.sh` compiles the Metal sources of the pinned mlx-swift checkout into
`app/.build/mlx.metallib` (same flags as MLX's own CMake build; cached per mlx-swift revision) and `build-app.sh` ships
it as `Contents/Resources/mlx.metallib`. At run time `ModelStore.metallibLocation` picks the bundle's file, else an
`mlx.metallib` next to the binary or in a parent folder (so a bare `.build` binary finds `app/.build/mlx.metallib`);
`IONIAN_FLOW_METALLIB=/path/mlx.metallib` overrides both. Nothing is downloaded.

**Models.** No models are bundled. On first launch the setup guide downloads the models into
`~/Library/Application Support/Ionian Flow/Models` (`ModelStore`, `ModelHub`): the speech models are
required, the cleanup model (Gemma 4 E2B) is optional. After that the app runs offline.

**Why make-cert?** macOS ties the three permissions to the app's code signature. Without a stable
signature, every rebuild is a "new" app and you have to grant everything again. `make-cert.sh`
creates a self-signed "Ionian Flow Dev" identity in its own keychain
(`~/Library/Keychains/ionian-flow-signing.keychain-db`, added to your keychain search list). It needs
no password prompt and no trust settings, and `build-app.sh` uses it automatically.
Remove it with `scripts/make-cert.sh --remove`.

## How it works
Everything runs in one Swift process. Core ML models run on the Neural Engine through
[FluidAudio](https://github.com/FluidInference/FluidAudio), the cleanup LLM runs on the GPU through
mlx-swift-lm.
```
HotkeyMonitor   CGEventTap: right ⌥, Esc
AudioCapture    AVAudioEngine → 16 kHz Int16 ──▶ SpeechEngine (protocol)
AudioDevices    CoreAudio input selection          └ NativeEngine + NativeLive
OverlayPanel    SwiftUI + Liquid Glass                 live Nemotron, one stream per session and channel
FillerFilter    regex cleanup                        DictationFinal: on key release, Parakeet re-reads
TextFormatter   lists + layout commands, live          the utterance, CTC rescoring, common-word guard
TextInserter    pasteboard swap + ⌘V
Transcriber     transcription mode: sessions for mic ("You") and system audio ("Them"), cut into
                segments, Markdown store
FinalPass       Parakeet Ultra: each segment's final text
Polisher        Gemma 4 E2B: cleanup per segment        Summarizer: summary and frontmatter
VaultSweep      Gemma 4 E2B: vocabulary from a vault    (VaultSweeper schedules it)
ModelHub        lazy single loads, the serial lane, unload on memory pressure
ModelStore      the Models folder: download, verify, remove
SystemAudioCapture  Core Audio process tap, gaps filled with silence, rebuilt on output changes
TranscriptPanel     side panel
```
- **SpeechEngine** (`SpeechEngine.swift`) is the protocol the app talks to: sessions per channel
  (`.mic`, `.system`) and kind (`.dictation`, `.transcription`), events for partial text, cuts and
  finals. `EngineFake.swift` (in `app/Tests/IonianFlowTests`) implements it for tests.
- **NativeEngine / NativeLive** run the streaming Nemotron decoder at 560 ms chunks per channel (1.12 s
  swallowed words when speaking fast). They cut segments at encoder frames, hold punctuation briefly
  (`PUNCT_HOLD`), keep output to Latin script, pad on flush, tag the language and apply the live
  vocabulary bias.
- **DictationFinal** runs when you release the key: Parakeet Ultra re-reads the whole utterance, a CTC
  pass rescores terms from the vocabulary, a guard (Zipf 4.0) reverts changes to common words, and
  `VocabNormalizer` fixes spellings. **FinalPass** gives transcription segments the same Parakeet.
- **ModelHub** loads each model once and on demand, runs the GPU work through one serial lane (a
  priority lane for dictation), and unloads models when macOS reports memory pressure.
- **Polisher, Summarizer, VaultSweep** are Gemma 4 E2B prompts with output guards; `GemmaPrefill.swift`
  holds back the last two prompt tokens from the prefill, so generation matches mlx-lm.
- Output is limited to Latin script. In auto mode the language tag only arrives at the end of the first
  sentence, and until then the first words could come out in Devanagari, Hebrew or CJK.
- `defaults write dev.ionian.flow parakeetFinals -bool false` and `summarizeTranscripts -bool false`
  turn the Parakeet finals and the summaries off.

## Vocabulary internals
How the vault scan works:
- **Connect once:** on the Vocabulary page, Connect Vault lists the vaults Obsidian knows; "Choose
  Folder…" takes any folder of Markdown notes. The polish LLM (Gemma 4 E2B) reads every note and lists
  the people, organizations, projects, products, acronyms and jargon in it (~1 s per note). Rules keep
  it honest: a name must appear in the note word for word, takes the note's spelling, and job titles,
  ticket keys, file names and words the recognizer already knows ("Python", "Inbox") are dropped.
  Ionian Flow's own transcripts are skipped, so the recognizer's mistakes don't become vocabulary. The
  vault card shows the progress, and a notification says how many terms it learned.
- **Few terms, on purpose:** more biased terms mean more false insertions and a bigger glossary. A term
  needs two notes (one is enough only for a note alias, title or `[[link|alias]]`), a score above a
  floor (notes × mentions × recency, recent notes count up to 5× more), at most 120 are kept
  (`limit`), and one run adds at most 25 new ones (`maxNew`); the rest come in on later runs if
  they still rank. Terms already in the file keep their place. In the review sheet and the banner,
  Reject all sends every new term to Ignore (after a confirmation).
- **One model for everything** (October 2026 benchmark): Gemma 4 E2B passed all 16 cleanup
  cases at ~130 ms, where Qwen 3.5 and larger Gemma/Nemotron models translated a segment or took 2 to 6 times
  as long. For the vault scan Qwen 3.5 4B finds more names (86 % vs. 60 % on hand-labelled notes) but
  would be a second ~3 GB download.

How the list is used, at three points:
1. **While decoding**, the recognizer gets a small bonus for tokens that start a vocabulary term at a
   word start, and a larger one once a couple of letters match (shallow fusion with a character trie,
   so it doesn't matter how the model splits the word). This works in dictation too, adds no
   measurable time, and invented nothing in silence or noise in the benchmark.
2. **After decoding**, spellings are normalized: "data garage" and "Datagarage" become "Data
   Garage", "E T L" becomes "ETL", and "(heard as: …)" aliases are replaced. Near misses too, by
   spelling (Damerau-Levenshtein ≥ 0.75) or by sound (Kölner Phonetik): "Netfora", "Nematron",
   "Jana Waber". Terms that are ordinary words ("ACE" vs. "an ace"), spans of only common words and
   single words that are real words ("Gamma") are left alone. Parakeet's finals get the same pass.
3. **In transcription mode**, the polish LLM gets the domain and the ~15 terms that resemble something
   in the segment.

On the benchmark (64 TTS clips in German and English), terms come out right
64 % of the time instead of 36 % (53 % with the spelling fixes alone), sentences without terms don't
get worse, and nothing is invented in silence or noise. Parakeet, which gets no decoding bonus, gets
75 % with the spelling fixes (39 % raw). The near-miss matching was tuned on misses from this
benchmark, so expect less on your own terms.
Why not retrain the model on the vocabulary? A vault has text, not audio of you saying the words; TTS
audio would teach the model TTS voices; retraining takes hours, would have to be redone whenever your
notes change, and can cost general accuracy. Biasing applies a change on the next dictation.

## Transcription internals
- **One recognizer session per stream** for the whole meeting, cut into segments at pauses.
  The recognizer keeps its context and detected language across cuts; only the text is split.
  Every decoder step is reported, blanks included, and each blank is one 80 ms
  encoder frame, so every token has its audio time: the text splits at the exact frame, a full stop
  that comes a few frames late stays with its sentence, and segments carry audio times (the Markdown
  and the You/Them order use them). A 31-minute session decodes as fast at the end as at the start.
- A segment appears dimmed with the live decoder's text, turns solid with the final text, then gets a
  cleanup pass by [Gemma 4 E2B](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit) (MLX,
  ~200 ms): punctuation, stutters, self-corrections, numbers as digits, misheard terms ("pool request" →
  "pull request"), with the speaker's previous segment as context. It never translates or answers what
  was said; an output whose length is off, that loops, whose words mostly aren't in the segment or
  glossary, or that drops the segment's end is discarded. It won a 14-case German/English benchmark
  against Qwen 3.5 2B/4B, Ministral 3 3B and LFM 2.5 1.2B.
- **The final text comes from Parakeet** (`FinalPass.swift`): Moondream's Parakeet Ultra (a post-training
  of NVIDIA's Parakeet TDT 0.6B v3) as a Core ML model from FluidAudio, on the Neural Engine. It
  transcribes each finished segment's audio again, ~0.1 s per segment, and makes half the errors of the
  1.12 s streaming decoder (see the benchmark below). The model (~630 MB) downloads the first time you
  transcribe; until then, and if it fails, the live decoder's text is the final. The engine runs only
  the live decoders. `defaults write dev.ionian.flow parakeetFinals -bool false` turns it off.
- **On speakers** the mic also hears the other side. When the Mac plays through its speakers, a
  display, HDMI or AirPlay, the mic runs through macOS voice processing, which removes what the
  speakers play (any app's audio) and keeps your voice, also while you talk over someone. Other apps
  aren't turned down. As a second line of defense, runs of 3+ words under "You" that "Them" said in a
  segment overlapping it in audio time (±3 s) are cut, keeping your own words around them. With
  headphones neither is needed.
- The system audio keeps wall-clock time, so "Them" lines up with "You": when the tap stalls (output
  device change, headphones unplugged) the gap is filled with silence, and the tap is rebuilt when the
  default output changes or no audio arrives for 2 s.
- **When a transcription ends**, the polish LLM writes YAML frontmatter and a summary into the file:
  `type: transcript`, date, start, end, duration and speakers are there from the start; `description`
  (one sentence), `tags` and `keywords` follow, plus a `## Summary` with key points, decisions and
  action items above the transcript. Tags come from the vault's own tags (the `tags:` of its notes,
  most frequent first; hidden folders skipped) when one fits. Keywords must occur in the transcript,
  and a decision or action naming a day or date nobody said is dropped. A transcript longer than
  12,000 characters is condensed part by part first. ~3 s for a short meeting; the LLM takes the GPU
  lock per token, so a dictation in the meantime isn't held up.
  `defaults write dev.ionian.flow summarizeTranscripts -bool false` turns it off.
- The polish model's weights are read without the GPU lock and moved onto the GPU in small steps:
  loading it in one go stopped the live text for ~2 s (longer from a cold disk) when a transcription began.
- The transcript is written to `YYYY-MM-DD HH-MM.md` in the transcripts folder
  (`~/Documents/Ionian Flow/Transcripts` unless changed in Settings) after every finished segment (atomic
  rewrite), so a crash loses at most the segment being spoken. No audio is stored.
- Toggle from scripts or Shortcuts: post the distributed notification `dev.ionian.flow.toggleTranscription`.

## Benchmark: final text
The Python benchmark harness (since removed) ran the full FLEURS test sets (862 German, 647 English clips, M5 Pro, November 2026),
Nemotron exactly as the app runs it (fp16, lookahead 13, auto language, Latin only), Parakeet through
`scripts/parakeet-bench`, both scored with the same normalizer (lowercase, no punctuation):

| | WER de | WER en | without number clips de / en | long files: seam loss de / en | speed |
|---|---|---|---|---|---|
| Nemotron, final decoder (1.12 s) | 10.7 % | 11.8 % | 7.9 % / 9.0 % | +0.4 / −0.1 points | 26× real time (GPU) |
| Parakeet Ultra (Neural Engine) | **4.5 %** | **5.2 %** | **3.8 % / 4.7 %** | +0.3 / +1.0 points | 144 to 179× |

"Without number clips" leaves out references with digits, which Nemotron writes as words. "Long files"
are 12 sentences joined by 0.8 s of silence (~2.5 min), decoded as one session: their WER against the
same clips one by one. In auto mode Nemotron also returned nothing for 4 English clips (with `en-US`
pinned it transcribes them); Parakeet had no empty output. Through the whole app (`--transcribetest`,
3 minutes per side, with cuts, echo filter and polish) the transcript's WER went from 7.8 % to 2.0 %
(German) and 8.3 % to 4.9 % (English). FLEURS is read speech; meetings will score worse for both.

## Prior art
Ideas taken from two open-source Mac apps, both MIT-licensed, after reading their code:
- [Blitztext](https://github.com/cmagnussen/blitztext-app): Parakeet Ultra via FluidAudio as the
  recognizer, phonetic custom-term correction with a dictionary guard, a system-audio tap watchdog that
  fills gaps with clock-measured silence, and time-aligned echo removal.
- [MurmurBee](https://github.com/kai-kaushik/murmurbee): guards that fall back to the raw text when the
  LLM's output isn't grounded in the input, loops, or drops the end; the previous chunk as context.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) runs Parakeet on the Neural Engine.

## Design
The app follows the Ionian Labs brand (the brand repo's `patterns/app-macos.md`, rules MAC-01 to MAC-22). Nothing visual is picked by hand.
- **Tokens.** `app/Sources/IonianFlow/UI/IonianTokens.swift` is generated by `scripts/make-tokens.swift` from the brand repo's `dist/tokens.flat.json`. Set `IONIAN_BRAND` to the brand folder (default `../brand`) and run `IONIAN_BRAND=../brand swift scripts/make-tokens.swift` from the repo root. Never edit the generated file. Colors are dynamic `NSColor` values with a light and a dark value.
- **Fonts.** Funnel Display, Funnel Sans and Geist Mono are bundled in `app/Resources/Fonts` with their OFL texts, and registered at launch. The app never fetches a font.
- **Chrome.** `app/Resources/Chrome` holds two stills from the brand: `breeze.jpg` for the setup guide's welcome step and the rendered backdrops, and `tile-flow.jpg` for the app icon tile.
- **Theme.** [Theme.swift](../app/Sources/IonianFlow/UI/Theme.swift) holds the shared pieces: the `ionianText` modifier, `FlowSign`, `AppIcon`, `Lockup`, `ChromeStill`, `Eyebrow`, `MonoLabel`, `PageHead`, `StatusDot`, `KeyChip`, `Key`, `Wave`, `Hairline`, `SettingsGroup`, `Card`, `SettingRow`, the `.primary` and `.monoLink` button styles, `WellFieldStyle`, and the glass surface for the dictation pill and the transcript panel (Liquid Glass on macOS 26, a material before).
- **Layout.** Padding and gaps use the `Space` tokens. The widths with no token (content column, sidebar, window and panel sizes) are named constants in `WindowLayout`, in Theme.swift.
- **Menu bar icon.** A template image of the Flow sign, as macOS requires.

Images in this repo come only from the app's offscreen renderer or from headless Chromium, never from a screen capture:
- `--render <surface|all> <out> [--dark]` draws a surface offscreen at 2x. Nothing is shown on screen. Surfaces: `hud`, `hud-empty`, `hud-handsfree`, `hud-long`, `panel`, `panel-empty`, `settings-general`, `settings-shortcuts`, `settings-dictation`, `settings-transcription`, `vocabulary`, `vocabulary-empty`, `vocabulary-review` and `onboarding-0` to `onboarding-4`. Renders use made-up data only.
- `scripts/make-banner.mjs` renders the README banners in `docs/images/` with headless Chromium, from the brand's `tokens.css`, fonts, chrome stills and the Flow sign. It needs Playwright: `npm i playwright && npx playwright install chromium`, then `PLAYWRIGHT_DIR=<folder with node_modules> IONIAN_BRAND=../brand node scripts/make-banner.mjs`.

## Commands
`...` means `"build/Ionian Flow.app/Contents/MacOS/IonianFlow"`. The engine tests need
`IONIAN_FLOW_TEST_DIR`, a folder with an optional `Vocabulary.md`, so they never read your own folders
(the unit tests need no models). Models come from the Models folder; download them with the app once.

| Command | What it does |
|---|---|
| `swift test --package-path app` | Model-free unit tests (`app/Tests/IonianFlowTests`, Swift Testing): filler filter, formatter, and every engine unit (live cuts, finalizer guard, hub, polish, summary, sweep, model store, vocabulary, WER scoring) |
| `IONIAN_FLOW_MODEL_TESTS=1 swift test --package-path app` | The same plus the tests that need downloaded models (the Silero VAD segmenter cases) |
| `... --enginetest-live [--per N] [--data DIR] [--mixed DIR] [--cut-every S] [--vocab FILE]` | Clips through the live decoder: WER, language tags, segment counts |
| `... --enginetest-dictation vocab DIR`, `dict MANIFEST VOCAB.md OUTDIR`, `latency MANIFEST VOCAB.md` | The dictation final pass on a clip set (hypotheses as JSON lines), and release-to-text latency |
| `... --enginetest-hub`, `--enginetest-polish`, `--enginetest-summary`, `--enginetest-sweep --vault DIR --out FILE [--no-llm]` | Model hub, cleanup (JSON lines on stdin), summaries on fixtures, vocabulary sweep |
| `... --e2e-engine load\|reload\|unload\|dictation MANIFEST OUTDIR [perGroup]` | Whole-app engine run: model load and unload, dictation end to end |
| `... --transcribetest you.wav [them.wav] [--no-parakeet]` | Transcription mode on WAV files (16 kHz mono) instead of mic and system audio, 4× real time |
| `... --score-dictation`, `--compare-transcribe`, `--make-two-speaker` | WER scoring of dictation hypotheses and of a transcribetest run against its references, and building a two-speaker test file (Swift, `WERScore.swift`) |
| `open -n "build/Ionian Flow.app" --args --mictest` | Capture 1 s from each input device, write chunk counts and start latency to `/tmp/ionian-flow-mictest.txt` (runs with the app's mic permission) |
| `"build/Ionian Flow.app/Contents/MacOS/IonianFlow" --demo` | Loop a fake dictation through the pill (design work, no mic) |
| `"build/Ionian Flow.app/Contents/MacOS/IonianFlow" --transcript-demo` | Loop a fake meeting through the transcription panel |
| `"build/Ionian Flow.app/Contents/MacOS/IonianFlow" --onboarding-demo [STEP]` | The setup guide, from step 0 to 4 |
| `"build/Ionian Flow.app/Contents/MacOS/IonianFlow" --vocabulary-demo [FILE]` | The Ionian Flow window on a copy of a vocabulary file (`IONIAN_FLOW_DEMO_PAGE=General` for another page) |
| `swift scripts/make-icon.swift app/Resources/AppIcon.icns` | Regenerate the app icon |
| `IONIAN_BRAND=../brand swift scripts/make-tokens.swift` | Regenerate `IonianTokens.swift` from the brand repo |
| `PLAYWRIGHT_DIR=<dir> IONIAN_BRAND=../brand node scripts/make-banner.mjs` | Regenerate the README banners (light and dark) |
| `"build/Ionian Flow.app/Contents/MacOS/IonianFlow" --render <surface> <out.png> [--dark]` | Render a surface offscreen at 2x, nothing shown on screen; glass uses the GLS-01 fallback over the Breeze still |

`samples/` holds two clips made with macOS `say` (voices Anna and Samantha).
