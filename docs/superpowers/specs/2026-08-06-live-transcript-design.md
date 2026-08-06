# Live Transcript Window — Design

**Date:** 2026-08-06
**Status:** Approved
**Goal:** A Granola-style floating window showing a live, speaker-tagged
transcript of the meeting as it happens, so the user can glance back at
anything they missed or misheard. Built to be upstreamable to
`digimata/quill` as a single PR.

## Scope

**v1 (this design):** live rough transcript only, both tracks,
speaker-tagged. The accurate transcript remains the existing post-recording
offline pass, unchanged.

**Explicitly deferred:** tier-2 "rolling accurate replacement" (periodically
re-transcribing recent audio with the offline engine and replacing settled
rough text). The settled/partial data model below is the seam where it would
slot in later; nothing else is built for it.

## Decisions made

| Question | Decision |
|---|---|
| What does the live view show? | Both tracks, speaker-tagged (`me`/`them`), interleaved by time |
| Accurate tier during meeting? | No — live rough tier only; offline pass stays post-meeting |
| Window style | Non-activating floating `NSPanel`, always on top, no focus steal |
| Open behavior | Config setting: `auto_open` (default false = on demand from menu) |
| When does transcription run? | Whole recording whenever `enabled` (window toggles visibility only — scrollback is the point) |
| Pipeline architecture | In-process buffer fan-out from existing recorder taps (approach 1) |
| Default streaming engine | Parakeet EOU 120M, 320ms chunks (`parakeet-eou-320ms`), configurable |
| Live text persistence | Ephemeral — never written to disk; `transcript.json`/`.md` remain the only artifacts |

## Architecture

Four new units, five touched (two only for wiring):

- **`LiveTranscriber` (actor, new)** — owns two FluidAudio
  `StreamingAsrManager` instances (one per track), created at recording start
  when enabled, torn down on stop. Receives PCM buffers, emits transcript
  updates. Knows nothing about UI.
- **`LiveTranscriptStore` (`@MainActor` observable, new)** — the UI's model:
  ordered list of settled utterances (`speaker`, `text`, wall-clock
  timestamp) plus one in-flight partial line per speaker.
- **`LiveTranscriptWindowController` (new)** — non-activating floating
  `NSPanel` hosting a SwiftUI transcript view via `NSHostingView`.
  Closeable/reopenable at any time while recording.
- **`MenuBarController` (touched)** — adds "Show live transcript", enabled
  only while recording with the feature on.
- **`MicRecorder` / `SystemAudioRecorder` (touched)** — each gains an
  optional `bufferHandler: ((AVAudioPCMBuffer) -> Void)?`. One added line in
  each existing tap callback, after the disk write. This is the entire
  footprint on the capture path.
- **`RecordingSession` / `AppController` (touched, wiring only)** —
  `RecordingSession` connects recorder buffer handlers to the transcriber;
  `AppController` owns the `LiveTranscriber` / store / window lifecycle
  alongside the existing session lifecycle.

FluidAudio 0.15.5 (already pinned) provides the streaming API — no new
dependencies. `appendAudio(_:)` accepts any buffer format and resamples
internally, so recorders forward their existing tap buffers untouched.

## Data flow

```
mic tap ──write mic.caf──▶ disk        system tap ──write system.caf──▶ disk
   │                                        │
   └─▶ bufferHandler ─▶ LiveTranscriber ◀─ bufferHandler ─┘
                            │  (2 streaming engines, partial callbacks)
                            ▼
                   LiveTranscriptStore (@MainActor)
                            ▼
                 SwiftUI view in floating NSPanel
```

**Fire-and-forget fan-out:** the handler dispatches the buffer to the actor
and returns immediately. If the transcriber is slow, dead, or models never
downloaded, the recording path and on-disk files are byte-identical to a run
with the feature off. Buffers queue into the actor; past a cap (~10 s of
audio) drop oldest and log — live text degrades, disk never does.

**Utterance settling:** each streaming engine delivers a growing partial
string; the EOU variant signals end-of-utterance boundaries. On each
boundary, the partial moves into the settled list (stamped with wall-clock
time so the two speakers interleave in real order) and the partial resets.

## Config

New optional block in `~/.config/quill/config.json`, following existing
`Config.swift` patterns:

```json
"live_transcript": {
  "enabled": true,
  "auto_open": false,
  "engine": "parakeet-eou-320ms"
}
```

- `enabled: false` → no engines created, menu item hidden, zero overhead.
- Streaming models (~a few hundred MB) download once into FluidAudio's cache
  on first use; `quill doctor` gains a line reporting whether they're cached.
- `engine` accepts any FluidAudio `StreamingModelVariant` raw value; unknown
  values warn and fall back to the default (same pattern as the offline
  engine config).

## Window behavior

- `NSPanel` with `.nonactivatingPanel`, `.floating` level, resizable,
  `setFrameAutosaveName` so position/size persist across sessions.
- Never takes focus on open or click; app stays `.accessory` (no dock icon).
- Content: scrolling utterance list, speaker-styled (`me` vs `them` — exact
  look decided in implementation), dimmed italic partial line per active
  speaker at the bottom, auto-scroll pinned to bottom unless the user
  scrolls up (then a "jump to latest" affordance).
- On recording stop: shows "recording ended — full transcript will land in
  <session folder>"; panel closes on next recording start or manually.

## Error handling

- Streaming model download/load failure → stderr log; menu item shows "live
  transcript unavailable"; recording unaffected.
- One engine dies → the other track keeps streaming; failed track noted with
  a one-line notice in the panel.
- Buffer overflow → drop-oldest with logged count; subtle "…" gap marker in
  the UI.
- Window closed mid-recording → transcription continues (reopening must show
  scrollback).

## Testing

- **Unit:** utterance-settling logic (partial → settled transitions,
  interleaving order, drop policy) against a fake engine behind a small
  protocol, mirroring the existing `TranscriptionEngine` abstraction.
- **Integration (manual, scripted in the PR description):** record with
  system audio playing + mic speech; verify live text on both tracks; verify
  `mic.caf` / `system.caf` / final transcript are structurally identical to
  a feature-off run; verify killing the decoders mid-meeting leaves the
  recording intact.
- `swift build` clean; `quill doctor` still passes.

## Fork & upstream strategy

`origin` is `digimata/quill` (upstream). Plan: fork on GitHub → add fork as
`fork` remote → feature branch `live-transcript` → PR from fork to upstream.

PR case, matched to the repo's minimalism: no new dependencies, gated behind
`enabled` with near-zero cost when off, one-line touch per capture tap,
single binary preserved (SwiftUI in source, no resource bundle). Open a
short upstream issue first ("would you take a live transcript window?")
before polishing — cheap insurance against philosophical rejection.
