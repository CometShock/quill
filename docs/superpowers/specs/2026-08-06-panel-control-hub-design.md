# Panel Control Hub — Design

**Date:** 2026-08-06
**Status:** Approved
**Builds on:** `2026-08-06-live-transcript-design.md` (implemented)
**Goal:** Turn the live transcript panel into quill's one small window: a
settings tray, a record/stop transport, and the transcript — openable any
time, not just while recording.

## Decisions made

| Question | Decision |
|---|---|
| Pause support? | Deferred to its own spec (capture-path feature). Transport is record/stop only. |
| What does config UI edit? | All known settings, structured controls, immediate write-back to `~/.config/quill/config.json` preserving unknown keys. |
| Config UI placement | Settings gear at the right of the bottom transport bar; tapping it slides a tray up from the bottom (between transcript and transport). |
| Window lifecycle | One persistent panel created at app start; per-session stores stay (race fix); the view reads the current store through a `PanelModel` indirection. |
| Menu | "Show live transcript" opens the window (tray collapsed); new "Open config" (key ",") opens it with the tray expanded; both always enabled. |
| Malformed config file | Tray shows a warning + "open file" button instead of controls — quill never rewrites a file it couldn't parse. |
| Autoscroll | Unchanged behavior (pinned to bottom unless user scrolls away; "Jump to latest" re-pins). Tray open/close must not spuriously unpin. |

## Architecture

- **`PanelModel` (`@MainActor @Observable`, new)** — the persistent window's
  model: `currentStore: LiveTranscriptStore?` (swapped per session),
  `recording: Bool`, `elapsed: String?`, `trayExpanded: Bool`, and an
  `onToggleRecording` callback into `AppController`.
- **`QuillPanelView` (new)** — three zones: transcript area (existing
  `LiveTranscriptView` when a store exists, idle placeholder otherwise),
  slide-up `ConfigTrayView`, bottom `TransportBar` (record/stop + elapsed +
  gear).
- **`ConfigTrayView` (new)** — structured controls for: live transcript
  enabled / auto-open, engine (three EOU variants), transcription enabled,
  mic voice processing, recordings folder, on_stop hook. Each control writes
  immediately via the new Config write API. Footer hint: most changes apply
  at the next recording.
- **`Config` write API (extended)** — read-modify-write of the raw JSON
  keeping unknown keys, atomic pretty-printed write, throws on a malformed
  existing file. Test-injectable path.
- **`LiveTranscriptWindowController` (reworked)** — created once at app
  start with the `PanelModel`; per-session recreation and
  `releaseFrameAutosave()` are removed (single window ⇒ no autosave
  conflict). `show(trayExpanded:)` variant for "Open config".
- **`AppController` (reworked)** — owns the `PanelModel`; sessions swap
  `currentStore`; recording state/elapsed mirror into the model alongside
  the menu bar.

## Behavior details

- Window openable and useful with live transcript disabled (config +
  transport still work; transcript area shows the idle placeholder).
- Last session's transcript stays visible after stop until the next
  recording starts.
- Transport button mirrors `AppController.toggle()` exactly — same path as
  the menu item.
- Tray open/close resizes the transcript scroll area; the pin state gets a
  short relayout grace so geometry churn can't spuriously unpin.

## Testing

- Unit: Config write round-trip (unknown keys preserved, nested creation,
  missing file created, malformed file throws), PanelModel state
  transitions.
- Manual: tray editing reflected in config.json (with a custom unknown key
  surviving), record/stop from the window, autoscroll across tray toggles.

## Upstream note

Commits stay separable from the core live-transcript work: the eventual
upstream offering is (1) live transcript, (2) control-hub window — the
maintainer may want one without the other.
