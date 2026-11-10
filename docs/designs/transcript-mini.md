# Transcript mini mode

Status: approved
Slug: transcript-mini
Date: 2026-11-10

## Problem
In transcription (meeting) mode, Ionian Flow shows `TranscriptPanel` (`app/Sources/IonianFlow/UI/TranscriptPanel.swift`), a glass panel as tall as the screen's usable area (minus 12 pt margins) on the right edge. The user finds it cumbersome, especially when presenting, because it covers part of the screen and can be seen by the people they present to. They need only a small signal that transcription is running and that both voices are being heard, without the text. Today the only way to get the panel out of the way is to stop transcribing.

## Context
- Ionian Flow is a local macOS menu-bar app for dictation and meeting transcription. Speech recognition runs on the Mac, not in the cloud.
- Supported: macOS 15 and later (app/Package.swift).
- In transcription mode it records two streams. "You" is the user's microphone. "Them" is everything the Mac plays (system audio, for example the other people in a video call). The panel shows a live level wave for each.
- The offscreen renderer is `IonianFlow --render <surface> <out.png> [--dark]` (and `--render all <dir>`). It draws a named SwiftUI surface from a table in `app/Sources/IonianFlow/UI/Renderer.swift` to a PNG without showing a window, and docs screenshots come from it. Existing transcript surfaces are `panel`, `panel-empty`, `panel-ended`, `panel-min` and `panel-min-live`. The last two are the full panel drawn at its minimum size of 300 x 320 pt (`WindowLayout.transcriptMin`), not a minimized mode; no minimized mode exists today.
- `MotionDuration.hover` is 0.25 s.
- `ShortcutHints.transcribe` is the display text of the transcription shortcut, for example "Double-tap Right Option".

## Out of scope
- A new global shortcut for minimize or expand.
- Changes to the dictation overlay (`OverlayPanel`), including hiding it from screen sharing.
- Any change to transcript content, transcription, summary or storage. Only the UI changes.
- Following the presenter across monitors on its own. While the pill is visible it stays on its own screen. It moves to another screen only when its own screen is removed (F2.6); a size change of its own screen keeps it on that screen, and changes to other screens do nothing.
- Any workaround if screen-share exclusion is not honoured (see Assumptions).

## Terms
- **Panel**: the one `NSPanel` owned by `TranscriptPanel` (existing). It has two **modes**.
- **Full mode**: today's layout: header, transcript, footer, full height, on the right edge.
- **Mini mode** (the **pill**): a small panel of exactly 300 x 44 pt showing the You wave, the Them wave and the elapsed time. Never any transcript text.
- **Corner**: one of `topLeft`, `topRight`, `bottomLeft`, `bottomRight` of a screen's `visibleFrame`, inset by the 12 pt margin. There is one global stored corner (`transcriptPillCorner`), not one per screen.
- **Target screen**: the screen under the mouse, else `NSScreen.main` (how today's full panel picks its screen).
- **Consent line**: "Always get consent when transcribing others."
- **Reminder**: the F3.1 display of the Consent line in the pill for 5 s.

## Features
IDs are stable; features are listed by priority.

### F1. Mini mode (P1)
Why: removes the screen cost of the full panel while keeping proof that transcription runs.

Story: As the user presenting or working, I want to shrink the panel to a small pill that shows both voices live, so that it stays out of my way and I can still see that it works.

Scenarios:
- F1.1 Given full mode with `model.ended == nil` and visibleFrame (0, 0, 1440, 875), when the user clicks the minimize button in the header, then the panel animates to a 300 x 44 pt pill; with no stored corner (bottom-right), `PillCorner.frame(size:in:margin:)` gives frame (1128, 12, 300, 44) (x = 1440 - 12 - 300, y = 0 + 12), and the mode `mini` is stored. The pill goes on the screen the full panel is on when minimizing mid-session, and on the target screen when the panel opens as a pill (F3.1). The minimize button shows only while `model.ended == nil`; once the session has ended it is not shown.
- F1.2 Given the pill, then it shows the You wave (accent colour, from `model.level`), the Them wave (`Color.muted`, the colour of today's Them meter, from `model.themLevel`) and the elapsed time, and no transcript text, except during the F3.1 reminder.
- F1.3 Given the pill and the pointer outside it, then the Stop and expand controls are hidden (`controlsVisible(hovering: false)` is false); when the pointer enters, they appear (`controlsVisible(hovering: true)` is true).
- F1.4 Given the pill, when the user clicks the expand control or the pill body (not Stop), then the panel returns to full mode on the screen the pill is on, at the remembered width (`transcriptPanelWidth`, capped at half the screen's visibleFrame width, as `TranscriptPanel.show()` does today), and the mode `full` is stored. Example: `TranscriptPanel.fullFrame(savedWidth: 400, in: (0, 0, 1440, 875))` returns (1028, 12, 400, 851).
- F1.4a Given the pill, when the pointer moves more than 4 pt (Euclidean distance) between mouse down and mouse up on the body, then it is a drag and the panel does not expand; 4 pt or less is a click and expands. `PillClick.isClick(down:up:)` (new) is true at exactly 4 pt.
- F1.5 Given the pill with the pointer over it, when the user clicks Stop, then `onStop` runs exactly once and the panel does not expand from that click.
- F1.6 Given the pill and `model.finishing` is true, then the waves are inactive (the existing `Wave(active: false)` behaviour, the same as the header uses today while finishing), the label "Finishing" replaces the elapsed time and Stop is disabled.
- F1.7 Given the pill and `model.ended` becomes set, then the panel expands to full mode so the finished transcript and summary show as today; the stored mode is unchanged.
- F1.8 Given the pill and `model.notice` is non-empty (for example a permission problem), then a marker shows on the pill: SF Symbol `exclamationmark.circle` in `Color.accent`, always at the leading edge of the pill, before whatever label is shown (time, "Finishing" or the Consent line). After expanding, the notice shows in the footer as today. Clearing the notice removes the marker.
- F1.9 Given Reduce Motion is on (`reduceMotionEnabled`), when the mode changes, then `TranscriptPanel.modeChangeDuration(reduceMotion: true)` is 0 and the frame and content change with no animation; with Reduce Motion off it returns `MotionDuration.hover`.
- F1.10 Given the pill, then Stop and expand have help tooltips (Stop uses `ShortcutHints.transcribe`) and accessibility labels, and Stop in the pill uses the same `.primaryCompact` style as Stop in the full header. Stop and expand stay in the accessibility tree while visually hidden, so VoiceOver can reach them. Keyboard focus does not apply, because the panel is non-activating.
- F1.11 Given mini mode, then `.resizable` is removed from the panel's style mask, `minSize` is the pill size (300 x 44 pt) and `transcriptPanelWidth` is never written. When `setMode(.full)` runs, `.resizable` and `WindowLayout.transcriptMin` are restored.

Testability:
- unit. Tested on its own by calling `PillCorner.frame`, `TranscriptPanel.fullFrame(savedWidth:in:)`, the style-mask/minSize setters on a created panel, `TranscriptPillState` built from model values, `PillClick.isClick(down:up:)` at 3, 4 and 5 pt, the mode state with a fake `onStop`, and `modeChangeDuration(reduceMotion:)`; shows, for F1.1, F1.4, F1.4a, F1.5, F1.7, F1.9 and F1.11, the frames, flags, one `onStop` call with no expand, the expand on `ended`, and 0 and 0.25 s; and, for F1.2, F1.3, F1.6, F1.8 and F1.10, that `TranscriptPillState` exposes no transcript text, `controlsVisible(hovering:)`, label text, Stop enabled, marker shown, Stop help text and accessibility labels, and wave colours accent and muted.
- manual. Tested on its own by switching modes on a running panel with Reduce Motion off and on (F1.1, F1.4, F1.9); shows the change animates smoothly in 0.25 s with Reduce Motion off and with no animation with it on.

### F4. Hidden from screen sharing (P1)
Why: attendees and presentation viewers must never see the panel or the pill, or the transcription controls, while the user does.

Story: As the user sharing my screen, I want Flow's panel and pill left out of what others see, so that they see only what I mean to show.

Scenarios:
- F4.1 Given the panel in either mode, then `TranscriptPanel.sharingType` (new, read-only, returns the panel's value) is `.none`. Set once at creation, so both modes share it.
- F4.2 Given a real screen share in Microsoft Teams and in Zoom on the newest macOS on the test Mac (macOS 26 today), with the panel in full mode and in mini mode, then the remote viewer sees neither (checked by hand). Required. The same on macOS 15 when a macOS 15 Mac is available.
- F4.3 Given a hand-test combination of F4.2 in which the panel is still visible to the viewer, then release is not blocked: the combination is listed in the README as a known limitation, F4 is recorded as partial in the Review section of this spec, and no workaround is added. The pill's small size is the mitigation.

Testability:
- unit. Tested on its own by creating a `TranscriptPanel` and reading `sharingType` in both modes (F4.1); shows `.none`.
- manual. Tested on its own by sharing the screen in Teams and in Zoom with a second device viewing (F4.2, F4.3); shows the panel absent from the remote view, or the failing combination listed in the README.

### F2. Draggable pill with remembered corner (P2)
Why: the pill must not cover whatever the user presents, so they choose where it sits.

Story: As the user, I want to drag the pill to any screen corner and have it stay there, so that it never hides what I am showing.

Scenarios:
- F2.1 Given the pill in the bottom-right corner and visibleFrame (0, 0, 1440, 875), when the user drops it with its centre at (300, 700), then it snaps to `topLeft`, frame (12, 819, 300, 44) (AppKit's y-origin is at the bottom, so y = maxY - margin - height = 875 - 12 - 44), and `TranscriptPanelPrefs` (new) stores `topLeft` under `transcriptPillCorner`. Quarters are taken from the `visibleFrame` of the screen that contains the pill's centre at drop; if the centre is on no screen, the screen under the pointer, else `NSScreen.main`.
- F2.2 Given the same visibleFrame, a drop with the centre exactly at (720, 437.5) gives `bottomRight`, frame (1128, 12, 300, 44). Ties are resolved per axis: exactly on the vertical midline counts as right, exactly on the horizontal midline as bottom.
- F2.3 Given a second screen with visibleFrame (1440, 0, 1920, 1055) and a drop with the centre at (1500, 1000), then the pill snaps to `topLeft` of that screen, frame (1452, 999, 300, 44), and `topLeft` is stored as the one global corner.
- F2.4 Given no stored corner in `TranscriptPanelPrefs`, then the pill opens in `bottomRight`. Given a stored value that is not one of the four names, then it is treated as absent.
- F2.5 Given the stored corner and the screen changes size or a display is unplugged between sessions, then the next show places the pill on the target screen in the stored corner.
- F2.6 Given the pill is visible and `NSApplication.didChangeScreenParametersNotification` fires: if the pill's own screen still exists but its `visibleFrame` changed, the pill moves to the stored corner of that same screen; only if its own screen was removed does it move to the stored corner of the target screen; changes to other screens do nothing.

Testability:
- unit. Tested on its own by calling `PillCorner.nearest(point:in:)` (new) and `PillCorner.frame(size:in:margin:)` (new) with the rectangles above, and by reading and writing the corner through `TranscriptPanelPrefs` on an isolated `UserDefaults` suite (F2.1 to F2.6); shows the corner and frame for each case, `bottomRight` for absent or invalid stored values (F2.4), the stored-corner frame on the target screen (F2.5), and for F2.6 the frame on the same screen after a size change, on the target screen after removal, and no move for other screens.
- manual. Tested on its own by dragging the pill across a real screen and dropping it near each corner (F2.1, F2.3); shows the pill snaps to the nearest corner and stays there.

### F3. Start in the last used mode, with consent reminder (P2)
Why: a user who works in the pill should not have to shrink the panel at every meeting.

Story: As the user, I want transcription to open in the mode I used last, so that I do not resize it each time.

Scenarios:
- F3.1 Given stored mode `mini`, when transcription starts, then the panel opens as the pill on the target screen in the stored corner and shows the Consent line inside the pill for 5 s, replacing the waves and time, then changes to the normal pill content. Hover controls (Stop, expand) still work during the 5 s.
- F3.2 Given stored mode `full` or none stored, when transcription starts, then the panel opens in full mode as today, with the Consent line in the footer.
- F3.3 Given the Consent line is showing in the pill, when the user expands within the 5 s, then the full panel opens with the footer Consent line, mode `full` is stored as in F1.4, and the reminder timer is cancelled.
- F3.4 Given the Consent line is showing in the pill and Reduce Motion is on, then the line still shows for 5 s and switches with no animation.
- F3.5 Given the pill is minimized by the user mid-meeting (F1.1), then no consent reminder shows, because it is only for a start.
- F3.6 Given a stored mode value other than `full` or `mini`, then it is treated as `full`.
- F3.7 Given the pill during the Reminder, then "Finishing" (F1.6) replaces the Reminder if `model.finishing` becomes true, and the notice marker (F1.8) shows during the Reminder too, at the leading edge before the Consent line.

Testability:
- unit. Tested on its own by reading the stored mode through `TranscriptPanelPrefs` on an isolated suite, driving `ConsentReminder` (new) with a manual clock, and building `TranscriptPillState` for each combination of reminder, finishing and notice (F3.1 to F3.7); shows the start mode (F3.1, F3.2, F3.6), the Consent line from 0 s to 4.9 s and normal content at 5 s (F3.1, F3.4), mode `full` stored and a cancelled reminder that never fires (F3.3), and the label and marker for F3.5 and F3.7.
- manual. Tested on its own by starting transcription with stored mode `mini` and hovering the pill during the 5 s (F3.1); shows the Consent line in the pill and working Stop and expand controls.

### F5. Pill in the offscreen renderer (P3)
Why: docs and screenshots are rendered offscreen only, so the pill needs a surface.

Story: As the maintainer, I want a `pill` render surface, so that I can produce pill images for docs without a screen.

Scenarios:
- F5.1 Given `--render pill <out.png>`, then the renderer writes an image of the pill with both waves active, time `12:34` and the controls visible.
- F5.2 Given the surfaces `pill-finishing`, `pill-notice` and `pill-consent` (new entries in the renderer's surface table, named like the existing `panel-ended`; they are unrelated to `panel-min` and `panel-min-live`, which stay as they are), then the matching state is drawn, and `--render all` includes all four pill surfaces in light and dark.
- F5.3 Given an unknown render surface name, then the renderer fails as it does today.

Testability:
- integration. Tested on its own by running the renderer for each surface (F5.1 to F5.3) and for an unknown name; shows the output file exists, has the surface size multiplied by the renderer's existing scale factor, as for the existing surfaces, and is not blank, and the unknown name fails as today.

## Success criteria
- SC1 Mini mode occupies exactly 300 x 44 pt, about 1% of the area of a 1440 x 900 pt screen, against the default full size of about 400 x 851 pt (`WindowLayout.transcript.width` 400).
- SC2 Switching modes takes at most `MotionDuration.hover` (0.25 s) and at most 0 s with Reduce Motion on (asserted on `modeChangeDuration(reduceMotion:)`).
- SC3 Mode and corner persist in 100% of the cases tested: a unit test writes the values through `TranscriptPanelPrefs` on an isolated `UserDefaults` suite, creates a new `TranscriptPanelPrefs` on the same suite and reads the same values back (no real relaunch).
- SC4 In the pill, no transcript character is ever shown (the view model exposes no transcript text).
- SC5 Stop from the pill ends the session with at most one click when the pill is hovered, and the Stop click itself never triggers an expand. The expand when `model.ended` is set afterwards (F1.7) still happens.
- SC6a Target: in the hand test (F4.2) as it stands now, the panel in both modes is absent from the remote view in every required combination (Teams and Zoom on the newest macOS on the test Mac, 2 of 2; plus macOS 15 when available).
- SC6b Failure rule: a failing combination does not block release. It is listed in the README as a known limitation and F4 is recorded as partial in the Review section (F4.3).
- SC7 The Consent line stays visible for 5 s (+/- 0.5 s) at a start in mini mode.

## Interfaces and data
- Tests run with `swift test --package-path app` (from docs/DEVELOPMENT.md); tests live in `app/Tests/IonianFlowTests`.
- `TranscriptPanel` (existing): one `NSPanel`; `sharingType = .none` (new); adds `setMode(_:)` (new), `sharingType` (new, read-only), `modeChangeDuration(reduceMotion:)` (new, pure: 0 or `MotionDuration.hover`), `fullFrame(savedWidth:in:)` (new, pure, extracted from today's `show()`); keeps `show()`, `hide()`, `onStop`.
- `TranscriptPanelMode` (new): `full | mini`, key `transcriptPanelMode` (new).
- `TranscriptPanelPrefs` (new): small struct taking an injected `UserDefaults` (default `.standard`); reads and writes `transcriptPanelMode` and `transcriptPillCorner`. Invalid or absent values read as `full` and `bottomRight`.
- `PillCorner` (new): `topLeft | topRight | bottomLeft | bottomRight`, key `transcriptPillCorner` (new); `nearest(point:in:)` and `frame(size:in:margin:)` pure functions.
- `PillClick` (new): `isClick(down:up:)` pure, true when the Euclidean distance is 4 pt or less.
- `TranscriptPillState` (new): pill view-model; exposes `controlsVisible(hovering:)`, label text, Stop enabled, marker shown, Stop help text and accessibility label strings. No transcript text.
- `ConsentReminder` (new): 5 s reminder with an injected clock; cancellable.
- Existing key `transcriptPanelWidth` is unchanged, applies to full mode only and is never written in mini mode.
- `TranscriptView` (existing) gains a minimize button in its header. `meter(_:color:level:)` is lifted from the private `TranscriptView` into a shared internal view used by both the header and the pill. `TranscriptPillView` (new) uses it with `Wave`, `TranscriptView.elapsed(from:to:)` and the Stop button style `.primaryCompact`.
- Renderer (`app/Sources/IonianFlow/UI/Renderer.swift`): new surfaces `pill`, `pill-finishing`, `pill-notice`, `pill-consent` in the surface table next to `panel`.

## Decisions
- One panel that changes frame and content between modes. Rejected: a separate pill window, because it doubles the show/hide path, the level and the sharing setting.
- Toggle by a minimize button in the full header and, in the pill, an expand control on hover plus a click on the body. Rejected: a global shortcut, because it adds something to learn and may conflict with other apps.
- Pill content is waves and time always, Stop and expand on hover. Rejected: waves only (cannot stop without expanding); one pulsing dot (cannot tell You from Them).
- Both modes are excluded from screen capture. Rejected: staying visible, because the user's goal is that presentation viewers do not see it; a setting defaulting off, because the default would leave the problem in place and it adds one more setting for no clear benefit.
- Remember the last mode across sessions. Rejected: always open full.
- Snap to the nearest corner on drop. Rejected: free placement, because it needs a stored point per screen and can end off-screen.
- On session end the pill expands to full mode without changing the stored mode, so the user sees the result as today.
- In mini mode the panel is not resizable, so the pill size is fixed and the saved full width cannot be overwritten.
- Stop in the pill is an icon button (SF Symbol `stop.fill`) of about 24 pt in the `.primaryCompact` style, so that the waves and the time keep their spacing.

## Assumptions
- Pill size of 300 x 44 pt is small enough. If wrong: trim the time label or the wave bar count.
- `sharingType = .none` is honoured by Teams and Zoom on macOS 15 and later. Newer capture paths (ScreenCaptureKit) may ignore it. If wrong: ship anyway, list the limitation in the README and mark F4 partial (F4.3, SC6b); the pill's small size is the only mitigation.
- `sharingType = .none` also hides the panel from the user's own screenshots and screen recordings, which is acceptable because docs images come from the offscreen renderer. If wrong: add a debug override for screenshots.
- Bottom-right does not collide badly with a Dock on the right, because `visibleFrame` already excludes the Dock. If wrong: the user drags the pill to another corner.
- An attention marker on the pill is enough for a notice. If wrong: show the first notice line in the pill.

## Dependencies
none

## Review
- Clarification (2026-11-10): If screen-share exclusion is not honoured in the hand test, does it block release? Answer: No; ship, document in README, mark F4 partial. Changed: F4, Success criteria.
- Round 1 (2026-11-10): paraphrase context missing, 0 divergences, 10 guesses; critic B0 M7 N3; readiness B0 M10 N5 (C1-3 merged with R1-9, C1-4 with R1-10). Fixed 33, rejected 0, escalated 1 (C1-1, answered and applied). Not run: none.
- Round 2 (2026-11-10): paraphrase context sufficient, 0 divergences, 9 guesses (1 Blocker P2-6, 8 Nits); critic B0 new, 0 open; readiness B0 new, 1 open (R1-2). Fixed 10, rejected 0, escalated 0. Not run: none.
- Fixes after round 2 (not re-reviewed): R1-2 testability lines; P2-6 screen resize keeps the pill on its own screen; P2-1 `TranscriptPanelPrefs` store; P2-2 to P2-9 wording.
- Approved (2026-11-10): user said "approve".
- Change with user consent (2026-11-10): pill widened from 260 to 300 pt and Stop shrunk to a ~24 pt icon; the user said "it looks a bit munched together and could need a bit more spacing…like more weidth and the stop button is too large". Changed: Terms, F1.1, F1.11, F2.1–F2.3, SC1, Assumptions, Decisions.
