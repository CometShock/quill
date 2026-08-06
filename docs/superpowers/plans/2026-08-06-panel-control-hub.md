# Panel Control Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The live transcript panel becomes quill's one persistent window: settings tray (gear in the bottom transport bar, slides up from the bottom), record/stop transport, transcript — openable any time.

**Architecture:** A `@MainActor @Observable PanelModel` sits between `AppController` and a persistent `LiveTranscriptWindowController`. Per-session `LiveTranscriptStore`s remain (stale-flush race fix); the view follows `PanelModel.currentStore`. Config gets a write API (read-modify-write preserving unknown keys) that the tray's controls call directly.

**Tech Stack:** Swift 6 / SPM, SwiftUI in the existing NSPanel, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-06-panel-control-hub-design.md`

## Global Constraints

- Swift 6 strict concurrency; macOS 15 floor; no new dependencies; single binary (UI in source only).
- Style: `///` why-comments, stderr via `FileHandle.standardError.write(Data("...".utf8))`, lowercase user-facing strings except menu items in Sentence case.
- The recording/capture path is untouched by this plan. `LiveTranscriber`, recorders, `RecordingSession` are NOT modified.
- Config JSON keys snake_case; quill never rewrites a config file it could not parse.
- Menu item names exactly: "Show live transcript" (existing), "Open config" (new, keyEquivalent ",").
- Branch: `live-transcript`. Commit per task with the message given.

## File Structure

```
Sources/quill/
  Config.swift                        Task 1 — modify: write API + test path override
  UI/PanelModel.swift                 Task 2 — new
  UI/QuillPanelView.swift             Task 3 — new (transcript zone + tray + transport)
  UI/ConfigTrayView.swift             Task 3 — new
  UI/LiveTranscriptView.swift         Task 3 — modify: relayout grace for pin
  UI/LiveTranscriptWindowController.swift  Task 4 — rework: persistent, hosts QuillPanelView
  UI/MenuBarController.swift          Task 4 — modify: Open config item; transcript item always enabled
  Quill.swift                         Task 4 — rework AppController lifecycle
README.md                             Task 5 — modify
Tests/quillTests/
  ConfigWriteTests.swift              Task 1 — new
  PanelModelTests.swift               Task 2 — new
```

---

### Task 1: Config write API

**Files:**
- Modify: `Sources/quill/Config.swift`
- Test: `Tests/quillTests/ConfigWriteTests.swift`

**Interfaces:**
- Consumes: existing `Config.load()` pattern.
- Produces (Task 3 depends on):
  - `Config.pathOverride: URL?` (internal, tests only)
  - `enum ConfigWriteError: Error { case malformed }`
  - `static func setValue(_ value: Any, forKeyPath keys: [String]) throws`
  - `static func fileIsMalformed() -> Bool`

- [ ] **Step 1: Make the path overridable for tests**

In `Config`, replace the `static let path` declaration with:

```swift
    /// Test seam: unit tests point this at a temp file; production never
    /// sets it. A stored `let` would bake the real home path into every
    /// read, making the write API untestable without touching ~/.config.
    static var pathOverride: URL?

    static var path: URL {
        pathOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quill/config.json")
    }
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/quillTests/ConfigWriteTests.swift`:

```swift
import Foundation
import Testing

@testable import quill

/// These tests mutate Config.pathOverride, so they must not run in
/// parallel with each other.
@Suite(.serialized)
struct ConfigWriteTests {
    /// Point Config at a fresh temp file, run the body, restore.
    private func withTempConfig(
        initial: String?, _ body: (URL) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")
        if let initial {
            try Data(initial.utf8).write(to: file)
        }
        Config.pathOverride = file
        defer {
            Config.pathOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try body(file)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func preservesUnknownKeysOnWrite() throws {
        try withTempConfig(
            initial: #"{"custom_thing": 42, "live_transcript": {"enabled": true, "future_key": "x"}}"#
        ) { file in
            try Config.setValue(false, forKeyPath: ["live_transcript", "enabled"])
            let json = try readJSON(file)
            #expect(json["custom_thing"] as? Int == 42)
            let live = json["live_transcript"] as! [String: Any]
            #expect(live["enabled"] as? Bool == false)
            #expect(live["future_key"] as? String == "x")
        }
    }

    @Test func createsFileAndNestedContainersWhenMissing() throws {
        try withTempConfig(initial: nil) { file in
            try Config.setValue(true, forKeyPath: ["live_transcript", "auto_open"])
            let json = try readJSON(file)
            let live = json["live_transcript"] as! [String: Any]
            #expect(live["auto_open"] as? Bool == true)
            #expect(Config.liveTranscriptAutoOpen() == true)
        }
    }

    @Test func setsTopLevelValue() throws {
        try withTempConfig(initial: "{}") { file in
            try Config.setValue("~/Meetings", forKeyPath: ["recordings_dir"])
            #expect(try readJSON(file)["recordings_dir"] as? String == "~/Meetings")
        }
    }

    @Test func throwsOnMalformedFileWithoutClobbering() throws {
        try withTempConfig(initial: "{not json") { file in
            #expect(throws: ConfigWriteError.self) {
                try Config.setValue(true, forKeyPath: ["live_transcript", "enabled"])
            }
            let raw = try String(contentsOf: file, encoding: .utf8)
            #expect(raw == "{not json")
            #expect(Config.fileIsMalformed())
        }
    }

    @Test func malformedFalseWhenFileMissingOrValid() throws {
        try withTempConfig(initial: nil) { _ in
            #expect(Config.fileIsMalformed() == false)
        }
        try withTempConfig(initial: "{}") { _ in
            #expect(Config.fileIsMalformed() == false)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ConfigWriteTests 2>&1 | tail -10`
Expected: compile FAILURE — `setValue`, `ConfigWriteError`, `fileIsMalformed` not defined.

- [ ] **Step 4: Implement**

Add to `Config` (after the private `load()`):

```swift
    enum ConfigWriteError: Error, CustomStringConvertible {
        case malformed

        var description: String {
            "config file is not valid JSON — fix or delete \(Config.path.path)"
        }
    }

    /// True when a config file exists but can't be parsed. The settings
    /// tray checks this to switch into its read-only warning state.
    static func fileIsMalformed() -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        guard
            let data = try? Data(contentsOf: path),
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil
        else { return true }
        return false
    }

    /// Set one value at a key path (creating intermediate objects), keeping
    /// every other key byte-preserved-in-spirit: the whole file is
    /// re-serialized, but unknown keys and values survive untouched. Never
    /// writes over a file it couldn't parse — user-owned config beats
    /// convenience.
    static func setValue(_ value: Any, forKeyPath keys: [String]) throws {
        precondition(!keys.isEmpty)
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            guard
                let data = try? Data(contentsOf: path),
                let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { throw ConfigWriteError.malformed }
            root = parsed
        }
        root = Self.setting(root, keys: ArraySlice(keys), value: value)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: path, options: .atomic)
    }

    /// Functional nested-dictionary set: JSONSerialization gives plain
    /// dictionaries, so mutation has to rebuild each level.
    private static func setting(
        _ dict: [String: Any], keys: ArraySlice<String>, value: Any
    ) -> [String: Any] {
        var dict = dict
        let key = keys.first!
        if keys.count == 1 {
            dict[key] = value
        } else {
            let child = dict[key] as? [String: Any] ?? [:]
            dict[key] = setting(child, keys: keys.dropFirst(), value: value)
        }
        return dict
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ConfigWriteTests 2>&1 | tail -10` then full `swift test 2>&1 | tail -5`
Expected: 5 new tests pass; full suite (20) passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/quill/Config.swift Tests/quillTests/ConfigWriteTests.swift
git commit -m "feat: config write API preserving unknown keys"
```

---

### Task 2: PanelModel

**Files:**
- Create: `Sources/quill/UI/PanelModel.swift`
- Test: `Tests/quillTests/PanelModelTests.swift`

**Interfaces:**
- Consumes: `LiveTranscriptStore` (existing).
- Produces (Tasks 3, 4 depend on):
  - `@MainActor @Observable final class PanelModel` with
    `private(set) var currentStore: LiveTranscriptStore?`,
    `private(set) var recording: Bool`,
    `private(set) var elapsed: String?`,
    `var trayExpanded: Bool` (view-writable),
    `var onToggleRecording: (() -> Void)?`,
    `func setSession(store: LiveTranscriptStore?)`,
    `func setRecording(_ recording: Bool, elapsed: String?)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/quillTests/PanelModelTests.swift`:

```swift
import Foundation
import Testing

@testable import quill

@MainActor
struct PanelModelTests {
    @Test func startsIdleWithNoStore() {
        let model = PanelModel()
        #expect(model.currentStore == nil)
        #expect(model.recording == false)
        #expect(model.elapsed == nil)
        #expect(model.trayExpanded == false)
    }

    @Test func sessionSwapReplacesStore() {
        let model = PanelModel()
        let first = LiveTranscriptStore()
        let second = LiveTranscriptStore()
        model.setSession(store: first)
        #expect(model.currentStore === first)
        model.setSession(store: second)
        #expect(model.currentStore === second)
    }

    @Test func recordingStateCarriesElapsed() {
        let model = PanelModel()
        model.setRecording(true, elapsed: "0:07")
        #expect(model.recording == true)
        #expect(model.elapsed == "0:07")
        model.setRecording(false, elapsed: nil)
        #expect(model.recording == false)
        #expect(model.elapsed == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PanelModelTests 2>&1 | tail -10`
Expected: compile FAILURE — `PanelModel` not defined.

- [ ] **Step 3: Implement**

Create `Sources/quill/UI/PanelModel.swift`:

```swift
import Foundation
import Observation

/// Model for the one persistent panel. Sessions come and go (each with its
/// own LiveTranscriptStore — see attachLiveTranscript for why they're never
/// reused); the panel outlives them all and follows whichever store is
/// current. AppController writes; QuillPanelView reads.
@MainActor
@Observable
final class PanelModel {
    private(set) var currentStore: LiveTranscriptStore?
    private(set) var recording = false
    private(set) var elapsed: String?
    /// The settings tray's open state — owned by the view (gear button)
    /// and by "Open config" (opens the panel with the tray up).
    var trayExpanded = false
    /// Wired to AppController.toggle() — the transport button is the menu
    /// item's twin, same code path.
    var onToggleRecording: (() -> Void)?

    func setSession(store: LiveTranscriptStore?) {
        currentStore = store
    }

    func setRecording(_ recording: Bool, elapsed: String?) {
        self.recording = recording
        self.elapsed = elapsed
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PanelModelTests 2>&1 | tail -10`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quill/UI/PanelModel.swift Tests/quillTests/PanelModelTests.swift
git commit -m "feat: panel model for the persistent control-hub window"
```

---

### Task 3: Panel UI — transcript zone, config tray, transport bar

New views only referenced by Task 4; this task must compile standalone.

**Files:**
- Create: `Sources/quill/UI/QuillPanelView.swift`
- Create: `Sources/quill/UI/ConfigTrayView.swift`
- Modify: `Sources/quill/UI/LiveTranscriptView.swift` (relayout grace)

**Interfaces:**
- Consumes: `PanelModel` (Task 2), `LiveTranscriptStore`, `LiveTranscriptView` (existing), `Config` accessors + write API (Task 1), `LiveTranscriber.resolveVariant` NOT needed here (picker uses raw strings).
- Produces (Task 4 depends on): `struct QuillPanelView: View { init(model: PanelModel) }`.

- [ ] **Step 1: LiveTranscriptView — relayout grace for the pin**

The tray toggling resizes the scroll container; `onScrollGeometryChange`
fires with transient not-near-bottom geometry and would spuriously unpin.
Give the view a layout epoch: when it changes, re-scroll if pinned and
ignore unpin signals until the geometry has settled near the bottom again.

In `LiveTranscriptView`, add a property after `let store`:

```swift
    /// Bump when the surrounding layout resizes the scroll container (tray
    /// open/close). During the grace that follows, geometry churn can't
    /// unpin — only the user scrolling away can, once geometry has settled
    /// near the bottom again.
    var layoutEpoch = 0
```

Add state after `@State private var pinned = true`:

```swift
    @State private var settlingAfterRelayout = false
```

Replace the body of the `.onScrollGeometryChange` `action:` closure
(currently `pinned = nearBottom`) with:

```swift
                if settlingAfterRelayout {
                    if nearBottom { settlingAfterRelayout = false }
                } else {
                    pinned = nearBottom
                }
```

Add after the existing `.onChange(of: store.partials)` modifier:

```swift
            .onChange(of: layoutEpoch) {
                if pinned {
                    settlingAfterRelayout = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
```

- [ ] **Step 2: Create the transport bar + panel container**

Create `Sources/quill/UI/QuillPanelView.swift`:

```swift
import SwiftUI

/// The persistent panel's three zones: transcript (or idle placeholder),
/// the slide-up settings tray, and the transport bar. Layout is a plain
/// VStack — the tray "slides" by being inserted above the transport bar
/// with a move-from-bottom transition.
struct QuillPanelView: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            transcriptZone
            if model.trayExpanded {
                Divider()
                ConfigTrayView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            transportBar
        }
        .frame(minWidth: 280, minHeight: 240)
    }

    @ViewBuilder
    private var transcriptZone: some View {
        if let store = model.currentStore {
            LiveTranscriptView(store: store, layoutEpoch: model.trayExpanded ? 1 : 0)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("not recording")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button {
                model.onToggleRecording?()
            } label: {
                Image(systemName: model.recording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(model.recording ? Color.primary : Color.red)
            }
            .buttonStyle(.plain)
            .help(model.recording ? "Stop recording" : "Start recording")

            if let elapsed = model.elapsed {
                Text(elapsed)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.trayExpanded.toggle()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(model.trayExpanded ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 3: Create the config tray**

Create `Sources/quill/UI/ConfigTrayView.swift`:

```swift
import AppKit
import SwiftUI

/// Structured controls over ~/.config/quill/config.json. Each control
/// saves immediately through Config.setValue — no apply button, no staged
/// state. The file stays user-owned: unknown keys survive every write, and
/// a file we can't parse switches the tray to a warning instead of
/// controls (quill never rewrites what it couldn't read).
struct ConfigTrayView: View {
    @State private var liveEnabled = Config.liveTranscriptEnabled()
    @State private var autoOpen = Config.liveTranscriptAutoOpen()
    @State private var engine = Config.liveTranscriptEngine()
    @State private var transcriptionEnabled = Config.transcriptionEnabled()
    @State private var micVoiceProcessing = Config.micVoiceProcessing()
    @State private var recordingsDir = Config.recordingsDir()?.path ?? ""
    @State private var onStop = Config.onStop() ?? ""
    @State private var writeError: String?
    @State private var malformed = Config.fileIsMalformed()

    private static let engines = [
        "parakeet-eou-160ms", "parakeet-eou-320ms", "parakeet-eou-1280ms",
    ]

    var body: some View {
        if malformed {
            malformedWarning
        } else {
            controls
        }
    }

    private var malformedWarning: some View {
        VStack(spacing: 6) {
            Text("config file is not valid JSON — settings are read-only")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open config file") {
                NSWorkspace.shared.open(Config.path)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Live transcript", isOn: $liveEnabled)
                .onChange(of: liveEnabled) {
                    save(liveEnabled, ["live_transcript", "enabled"])
                }
            Toggle("Open window when recording starts", isOn: $autoOpen)
                .onChange(of: autoOpen) {
                    save(autoOpen, ["live_transcript", "auto_open"])
                }
            Picker("Live engine", selection: $engine) {
                ForEach(Self.engines, id: \.self) { Text($0) }
            }
            .onChange(of: engine) {
                save(engine, ["live_transcript", "engine"])
            }
            Toggle("Transcribe after recording", isOn: $transcriptionEnabled)
                .onChange(of: transcriptionEnabled) {
                    save(transcriptionEnabled, ["transcription", "enabled"])
                }
            Toggle("Mic voice processing (echo cancel)", isOn: $micVoiceProcessing)
                .onChange(of: micVoiceProcessing) {
                    save(micVoiceProcessing, ["mic_voice_processing"])
                }
            HStack {
                TextField("Recordings folder", text: $recordingsDir, prompt: Text("~/Recordings"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save(recordingsDir, ["recordings_dir"]) }
                Button("Choose…") { chooseFolder() }
                    .controlSize(.small)
            }
            TextField("Run after each recording (on_stop hook)", text: $onStop)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save(onStop, ["on_stop"]) }

            if let writeError {
                Text(writeError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("most changes apply at the next recording")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(12)
    }

    private func save(_ value: Any, _ keyPath: [String]) {
        do {
            try Config.setValue(value, forKeyPath: keyPath)
            writeError = nil
        } catch {
            writeError = "couldn't save: \(error)"
            malformed = Config.fileIsMalformed()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Config.recordingsDir() ?? Config.defaultRoot
        // runModal, not a sheet: the host is a nonactivating utility panel,
        // and a modal open panel is the one interaction that may take focus.
        if panel.runModal() == .OK, let url = panel.url {
            recordingsDir = url.path
            save(recordingsDir, ["recordings_dir"])
        }
    }
}
```

- [ ] **Step 4: Verify build + full tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete (new views compile even though nothing references them yet); all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/quill/UI/QuillPanelView.swift Sources/quill/UI/ConfigTrayView.swift Sources/quill/UI/LiveTranscriptView.swift
git commit -m "feat: control-hub panel UI — config tray, transport bar, pin grace"
```

---

### Task 4: Persistent window lifecycle + menu

**Files:**
- Modify: `Sources/quill/UI/LiveTranscriptWindowController.swift`
- Modify: `Sources/quill/UI/MenuBarController.swift`
- Modify: `Sources/quill/Quill.swift`

**Interfaces:**
- Consumes: `PanelModel` (Task 2), `QuillPanelView` (Task 3).
- Produces: `LiveTranscriptWindowController.init(model: PanelModel)`, `func show(trayExpanded: Bool? = nil)`; `MenuBarController.onOpenConfig: (() -> Void)?`.

- [ ] **Step 1: Rework the window controller**

Replace the full contents of `Sources/quill/UI/LiveTranscriptWindowController.swift` with:

```swift
import AppKit
import SwiftUI

/// The one persistent panel: floating, non-activating, created once at app
/// start and never recreated (a single window means the frame autosave
/// name has exactly one owner — the conflict dance the per-session design
/// needed is gone). Glanceable over the meeting window; never takes key
/// focus; follows across Spaces and full-screen apps.
@MainActor
final class LiveTranscriptWindowController {
    private let panel: NSPanel
    private let model: PanelModel

    init(model: PanelModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "quill"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuillPanelView(model: model))
        panel.setFrameAutosaveName("quill.live-transcript")
    }

    var isVisible: Bool { panel.isVisible }

    /// orderFrontRegardless: the app is .accessory and must not activate.
    /// Pass trayExpanded to open directly onto the settings tray ("Open
    /// config") or collapsed ("Show live transcript"); nil leaves it as
    /// the user last had it (auto-open).
    func show(trayExpanded: Bool? = nil) {
        if let trayExpanded {
            model.trayExpanded = trayExpanded
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}
```

(The `releaseFrameAutosave()` method is deleted — its reason to exist was
per-session recreation.)

- [ ] **Step 2: Menu — Open config item, transcript item always enabled**

In `Sources/quill/UI/MenuBarController.swift`:

Add alongside the other callbacks:

```swift
    var onOpenConfig: (() -> Void)?
```

In `init()`, where `liveTranscriptItem` is created: change
`liveTranscriptItem.isEnabled = false` to `liveTranscriptItem.isEnabled = true`
and DELETE the `liveTranscriptItem.isHidden = !Config.liveTranscriptEnabled()`
line (the window now shows config + transport regardless, and the transcript
zone explains itself when idle).

After `menu.addItem(liveTranscriptItem)`, add:

```swift
        let openConfig = NSMenuItem(
            title: "Open config",
            action: #selector(openConfigClicked),
            keyEquivalent: ","
        )
        menu.addItem(openConfig)
```

Add `openConfig` to the target loop (`for item in [toggleItem, liveTranscriptItem, openConfig, openFolder, quit]`).

In `update(recording:elapsed:)`, DELETE the line `liveTranscriptItem.isEnabled = recording`.

Add the action next to the others:

```swift
    @objc private func openConfigClicked() { onOpenConfig?() }
```

- [ ] **Step 3: AppController — persistent window, model wiring**

In `Sources/quill/Quill.swift`:

Replace the three live properties (`liveStore`, `liveTranscriber`, `liveWindow`) with:

```swift
    private var liveStore: LiveTranscriptStore?
    private var liveTranscriber: LiveTranscriber?
    private let panelModel = PanelModel()
    private let liveWindow: LiveTranscriptWindowController
```

In `init(root:)`, before the `menuBar.on…` assignments, add:

```swift
        liveWindow = LiveTranscriptWindowController(model: panelModel)
        panelModel.onToggleRecording = { [weak self] in self?.toggle() }
```

(`liveWindow` must be assigned before `self` is captured in closures; put
it first in `init`.)

Replace the `menuBar.onShowLiveTranscript` line and add the config one:

```swift
        menuBar.onShowLiveTranscript = { [weak self] in self?.liveWindow.show(trayExpanded: false) }
        menuBar.onOpenConfig = { [weak self] in self?.liveWindow.show(trayExpanded: true) }
```

Replace `attachLiveTranscript(to:)` with (window no longer recreated; the
model swaps stores):

```swift
    /// Build the live pipeline for this session: a fresh store, a fresh
    /// transcriber, buffer routing. Each session gets its own store (never
    /// reused/reset) so a still-flushing previous transcriber can never
    /// land stale text or notices into the new session's panel — see
    /// detachLiveTranscript. The persistent panel follows the new store
    /// through the model.
    private func attachLiveTranscript(to newSession: RecordingSession) {
        guard Config.liveTranscriptEnabled() else {
            panelModel.setSession(store: nil)
            return
        }
        let store = LiveTranscriptStore()
        liveStore = store
        let variant = LiveTranscriber.resolveVariant(Config.liveTranscriptEngine())
        let transcriber = LiveTranscriber(variant: variant, store: store)
        liveTranscriber = transcriber
        newSession.setBufferHandlers(
            mic: { transcriber.ingest($0, track: .mic) },
            system: { transcriber.ingest($0, track: .system) }
        )
        Task { await transcriber.start() }
        panelModel.setSession(store: store)
        if Config.liveTranscriptAutoOpen() {
            liveWindow.show()
        }
    }
```

Replace `abortLiveTranscript()` with (window persists; just point the model
away from the aborted session's store):

```swift
    /// Undo a partial attachLiveTranscript() after `newSession.start()`
    /// throws. The transcriber's consumer Tasks are already parked on live
    /// streams (and may have loaded engines / kicked off a model download);
    /// without this they'd park forever, leaking the actor and its engines.
    /// stop() finishes the continuations so those loops exit and clean up.
    private func abortLiveTranscript() {
        if let transcriber = liveTranscriber {
            liveTranscriber = nil
            Task { await transcriber.stop() }
        }
        panelModel.setSession(store: nil)
    }
```

`detachLiveTranscript(sessionName:)` stays unchanged — the last session's
store (with final text + ended notice) intentionally remains current so the
panel stays useful after stop.

Mirror recording state into the model everywhere `menuBar.update` is called:
in `startSession()` after `menuBar.update(recording: true, elapsed: "0:00")` add

```swift
        panelModel.setRecording(true, elapsed: "0:00")
```

in `stopSession()` after `menuBar.update(recording: false, elapsed: nil)` add

```swift
        panelModel.setRecording(false, elapsed: nil)
```

in `tick()`, restructure so the formatted string is shared:

```swift
    private func tick() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        menuBar.update(recording: true, elapsed: elapsed)
        panelModel.setRecording(true, elapsed: elapsed)
    }
```

- [ ] **Step 4: Verify build + full tests + smoke**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete, all tests pass.
Smoke: `swift run quill` — starts clean; Ctrl-C. (Menu/panel interaction is the human's E2E.)

- [ ] **Step 5: Commit**

```bash
git add Sources/quill/UI/LiveTranscriptWindowController.swift Sources/quill/UI/MenuBarController.swift Sources/quill/Quill.swift
git commit -m "feat: persistent control-hub window — open config menu, transport wiring"
```

---

### Task 5: README + verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Live transcript section**

In README.md's "Live transcript" section, after the first paragraph, add:

```markdown
The window is also quill's control surface: a record/stop button at the
bottom, and a settings gear that slides up a config tray — every option in
`config.json` editable in place (unknown keys in the file are preserved).
**Open config** in the menu (⌘-less `,` while the menu is open) jumps
straight to it.
```

- [ ] **Step 2: Full suite + release build**

Run: `swift test 2>&1 | tail -5 && swift build -c release 2>&1 | tail -3`
Expected: all tests pass; release build completes.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: control-hub window in README"
```

---

## Self-Review (completed)

- **Spec coverage:** persistent window + PanelModel (T2/T4), gear + bottom tray + transport (T3), config write-back preserving unknown keys + malformed read-only fallback (T1/T3), menu items (T4), autoscroll pin grace (T3), idle placeholder (T3), last-session transcript persists after stop (T4 detach unchanged), separable commits (each task commits alone).
- **Placeholder scan:** clean.
- **Type consistency:** `PanelModel.setSession(store:)/setRecording(_:elapsed:)/trayExpanded/onToggleRecording` consistent across T2/T3/T4; `Config.setValue(_:forKeyPath:)/fileIsMalformed()/pathOverride` across T1/T3; `LiveTranscriptView(store:layoutEpoch:)` matches T3's added property with default value; `show(trayExpanded:)` across T4 call sites.
