# Live Transcript Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A floating always-on-top panel showing a live, speaker-tagged (`me`/`them`) transcript of the meeting while quill records, fed by FluidAudio's streaming ASR.

**Architecture:** Each recorder's existing tap callback fans out a copy of every PCM buffer to a `LiveTranscriber` actor running one streaming engine per track (mic→`me`, system→`them`). Engine output settles into utterances at end-of-utterance boundaries, published to a `@MainActor` store observed by a SwiftUI view inside a non-activating `NSPanel`. Fire-and-forget: if the live pipeline stalls or dies, the recording path is byte-identical to today.

**Tech Stack:** Swift 6 / SPM, AppKit + SwiftUI (`NSHostingView`), FluidAudio 0.15.5 streaming API (`StreamingModelVariant.createManager()` → `StreamingAsrManager` actor), Swift Testing (`import Testing`) for unit tests.

**Spec:** `docs/superpowers/specs/2026-08-06-live-transcript-design.md`

## Global Constraints

- Platform floor: macOS 15 (`platforms: [.macOS(.v15)]`) — `onScrollGeometryChange` etc. are fine.
- **No new package dependencies.** FluidAudio 0.15.5 (already pinned) provides everything.
- Single binary: no resource bundles, no asset catalogs; all UI in source.
- Swift 6 strict concurrency — code must compile with the existing settings, no `@preconcurrency` imports added to quill sources unless a step says so.
- Follow existing style: `///` doc comments explaining *why*, stderr logging via `FileHandle.standardError.write(Data("...".utf8))`, lowercase user-facing strings ("live transcript", not "Live Transcript") except menu items which are Sentence case ("Show live transcript" — matches "Start recording").
- Config keys are snake_case in JSON (`live_transcript`, `auto_open`), camelCase accessors in `Config`.
- Default engine: `parakeet-eou-320ms`. Only the three EOU variants are supported in v1 (they alone emit utterance boundaries); other/unknown values warn on stderr and fall back to the default — same pattern as `Config.transcriptionEngine()`.
- Branch: `live-transcript`. Commit after every task with the message given in the task.

## FluidAudio streaming API facts (verified against 0.15.5 checkout)

The implementer should trust these — they were read from the pinned source:

- `StreamingModelVariant` is a public enum; `.parakeetEou160ms/.parakeetEou320ms/.parakeetEou1280ms` raw values are `"parakeet-eou-160ms"` etc. `variant.createManager()` returns `any StreamingAsrManager`. `variant.repo.folderName` is public.
- `StreamingAsrManager` is an **Actor** protocol: `loadModels()`, `appendAudio(_ buffer: AVAudioPCMBuffer) throws` (accepts any format, resamples to 16 kHz mono internally), `processBufferedAudio()`, `finish() -> String`, `reset()`, `cleanup()`, `getPartialTranscript() -> String`.
- `getPartialTranscript()` returns the **cumulative transcript since session start** (accumulated token IDs are never trimmed at utterance boundaries). It grows monotonically.
- EOU boundaries: cast the manager to `any StreamingAsrEouProvider` (actor protocol) and call `getEouTimestampsMs() -> [Int]`. The array grows by one entry per confirmed end-of-utterance (after a 1280 ms silence debounce). Counting its length is the ordered, race-free way to detect boundaries — do **not** use the callback API (`setEouCallback`), which fires on the engine's actor and would race our per-chunk reads.
- Models auto-download on first `loadModels()` into `~/Library/Application Support/FluidAudio/Models/parakeet-eou-streaming/<repo.folderName>/` (contains `streaming_encoder.mlmodelc`, `decoder.mlmodelc`, `joint_decision.mlmodelc`, `vocab.json`).

## File Structure

```
Sources/quill/
  Live/                              (new directory)
    UtteranceSettler.swift           Task 1 — Utterance + pure settling logic
    AudioChunk.swift                 Task 2 — deep-copied Sendable PCM buffer
    LiveTranscriptStore.swift        Task 3 — @MainActor observable UI model
    LiveTranscriber.swift            Task 6 — actor: engines + streams + publish
  UI/
    LiveTranscriptView.swift         Task 7 — SwiftUI transcript view
    LiveTranscriptWindowController.swift  Task 7 — floating NSPanel host
    MenuBarController.swift          Task 8 — modify: menu item
  Config.swift                       Task 4 — modify: live_transcript accessors
  Audio/MicRecorder.swift            Task 5 — modify: bufferHandler fan-out
  Audio/SystemAudioRecorder.swift    Task 5 — modify: bufferHandler fan-out
  RecordingSession.swift             Task 5 — modify: setBufferHandlers
  Quill.swift                        Task 8 — modify: AppController wiring
  Doctor.swift                       Task 9 — modify: model-cache check
Tests/quillTests/                    (new directory, Task 1)
  UtteranceSettlerTests.swift        Task 1
  AudioChunkTests.swift              Task 2
  LiveTranscriptStoreTests.swift     Task 3
Package.swift                        Task 1 — modify: test target
README.md                            Task 9 — modify: live transcript section
```

---

### Task 1: Test target + `UtteranceSettler`

The pure heart of the feature: turning a cumulative streaming transcript into
discrete utterances. No engine, no clock source, no UI — fully unit-testable.
Also sets up the repo's first test target.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/quill/Live/UtteranceSettler.swift`
- Test: `Tests/quillTests/UtteranceSettlerTests.swift`

**Interfaces:**
- Consumes: nothing (Foundation only).
- Produces (used by Tasks 3, 6, 7):
  - `struct Utterance: Identifiable, Equatable, Sendable { let id: UUID; let speaker: String; let text: String; let startedAt: Date }`
  - `struct UtteranceSettler { let speaker: String; private(set) var partial: String; init(speaker: String); mutating func update(fullText: String, at now: Date); mutating func settle(fullText: String, at now: Date) -> Utterance? }`

- [ ] **Step 1: Add the test target to Package.swift**

Append to the `targets:` array (after the `.executableTarget`):

```swift
        .testTarget(
            name: "quillTests",
            dependencies: ["quill"]
        ),
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/quillTests/UtteranceSettlerTests.swift`:

```swift
import Foundation
import Testing

@testable import quill

struct UtteranceSettlerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func partialTracksTailOfCumulativeText() {
        var settler = UtteranceSettler(speaker: "me")
        settler.update(fullText: "hello", at: t0)
        #expect(settler.partial == "hello")
        settler.update(fullText: "hello there", at: t0.addingTimeInterval(1))
        #expect(settler.partial == "hello there")
    }

    @Test func settleCutsUtteranceStampedAtFirstPartial() {
        var settler = UtteranceSettler(speaker: "me")
        settler.update(fullText: "hello", at: t0)
        settler.update(fullText: "hello there", at: t0.addingTimeInterval(2))
        let utterance = settler.settle(fullText: "hello there.", at: t0.addingTimeInterval(3))
        #expect(utterance?.text == "hello there.")
        #expect(utterance?.speaker == "me")
        // Stamped when its first words appeared, not when the boundary landed —
        // start-time ordering is what interleaves the two speakers correctly.
        #expect(utterance?.startedAt == t0)
        #expect(settler.partial.isEmpty)
    }

    @Test func settleWithNothingNewReturnsNil() {
        var settler = UtteranceSettler(speaker: "me")
        _ = settler.settle(fullText: "first.", at: t0)
        let second = settler.settle(fullText: "first.", at: t0.addingTimeInterval(5))
        #expect(second == nil)
    }

    @Test func secondUtteranceContainsOnlyNewTail() {
        var settler = UtteranceSettler(speaker: "them")
        settler.update(fullText: "one two", at: t0)
        _ = settler.settle(fullText: "one two.", at: t0.addingTimeInterval(1))
        settler.update(fullText: "one two. three four", at: t0.addingTimeInterval(2))
        let second = settler.settle(fullText: "one two. three four.", at: t0.addingTimeInterval(3))
        #expect(second?.text == "three four.")
        #expect(second?.startedAt == t0.addingTimeInterval(2))
    }

    @Test func shrunkenFullTextDoesNotCrashOrEmitGarbage() {
        var settler = UtteranceSettler(speaker: "me")
        _ = settler.settle(fullText: "a longer settled sentence.", at: t0)
        settler.update(fullText: "short", at: t0.addingTimeInterval(1))
        #expect(settler.partial.isEmpty)
        #expect(settler.settle(fullText: "short", at: t0.addingTimeInterval(2)) == nil)
    }

    @Test func leadingWhitespaceOnTailIsTrimmed() {
        var settler = UtteranceSettler(speaker: "me")
        _ = settler.settle(fullText: "first.", at: t0)
        settler.update(fullText: "first. second", at: t0.addingTimeInterval(1))
        #expect(settler.partial == "second")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -20`
Expected: compile FAILURE — `UtteranceSettler` and `Utterance` not defined. (First build compiles FluidAudio; it can take a few minutes.)

- [ ] **Step 4: Implement**

Create `Sources/quill/Live/UtteranceSettler.swift`:

```swift
import Foundation

/// One settled utterance in the live transcript window.
struct Utterance: Identifiable, Equatable, Sendable {
    let id: UUID
    let speaker: String
    let text: String
    /// When this utterance's first words appeared — utterances from the two
    /// tracks interleave by start time, not by when their boundary landed.
    let startedAt: Date
}

/// Cuts a streaming engine's cumulative transcript into discrete utterances.
/// The engine reports the full transcript-so-far after each chunk (it never
/// trims at boundaries); this tracks how much is already settled, exposes the
/// unsettled tail as the in-flight partial, and converts the tail into an
/// Utterance at each end-of-utterance boundary. Pure logic — no engine, no
/// clock, no UI — so the interesting edge cases are unit-testable.
struct UtteranceSettler {
    let speaker: String
    private(set) var partial = ""
    /// Length (in characters) of the cumulative text already settled.
    private var settledCount = 0
    /// When the current partial first became non-empty.
    private var partialStartedAt: Date?

    init(speaker: String) {
        self.speaker = speaker
    }

    /// Record the new cumulative transcript after a processed chunk.
    mutating func update(fullText: String, at now: Date) {
        let tail = Self.tail(of: fullText, after: settledCount)
        if partial.isEmpty && !tail.isEmpty {
            partialStartedAt = now
        }
        partial = tail
    }

    /// An end-of-utterance boundary: everything unsettled becomes one
    /// utterance. Returns nil when nothing new was said since the last one.
    mutating func settle(fullText: String, at now: Date) -> Utterance? {
        let tail = Self.tail(of: fullText, after: settledCount)
        settledCount = max(settledCount, fullText.count)
        partial = ""
        let startedAt = partialStartedAt ?? now
        partialStartedAt = nil
        guard !tail.isEmpty else { return nil }
        return Utterance(id: UUID(), speaker: speaker, text: tail, startedAt: startedAt)
    }

    /// The unsettled suffix. Character-count prefixes are safe because the
    /// engine's accumulated token decode only ever appends; a shorter text
    /// (post-reset defensive case) yields an empty tail rather than garbage.
    private static func tail(of text: String, after count: Int) -> String {
        guard text.count > count else { return "" }
        return String(text.dropFirst(count)).trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -10`
Expected: all 6 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/quill/Live/UtteranceSettler.swift Tests/quillTests/UtteranceSettlerTests.swift
git commit -m "feat: utterance settling for live transcript + first test target"
```

---

### Task 2: `AudioChunk` — deep-copied Sendable buffer

Tap callbacks hand us buffers whose memory Core Audio owns — the system tap
wraps its buffer list with `bufferListNoCopy`, so the memory is invalid the
moment the callback returns. Anything that escapes the callback must be a deep
copy.

**Files:**
- Create: `Sources/quill/Live/AudioChunk.swift`
- Test: `Tests/quillTests/AudioChunkTests.swift`

**Interfaces:**
- Consumes: nothing (AVFoundation only).
- Produces (used by Task 6): `struct AudioChunk: @unchecked Sendable { let buffer: AVAudioPCMBuffer; init?(copying source: AVAudioPCMBuffer) }` — `nil` when the source has no frames or allocation fails.

- [ ] **Step 1: Write the failing tests**

Create `Tests/quillTests/AudioChunkTests.swift`:

```swift
import AVFoundation
import Testing

@testable import quill

struct AudioChunkTests {
    private func makeBuffer(frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = value }
        return buffer
    }

    @Test func copyIsIndependentOfSource() {
        let source = makeBuffer(frames: 256, value: 0.5)
        let chunk = AudioChunk(copying: source)
        #expect(chunk != nil)
        // Clobber the source — simulates Core Audio reusing the memory.
        let sourceData = source.floatChannelData![0]
        for i in 0..<256 { sourceData[i] = 0 }
        let copied = chunk!.buffer.floatChannelData![0]
        #expect(copied[0] == 0.5)
        #expect(copied[255] == 0.5)
        #expect(chunk!.buffer.frameLength == 256)
        #expect(chunk!.buffer.format == source.format)
    }

    @Test func emptyBufferYieldsNil() {
        let source = makeBuffer(frames: 128, value: 0.5)
        source.frameLength = 0
        #expect(AudioChunk(copying: source) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioChunkTests 2>&1 | tail -10`
Expected: compile FAILURE — `AudioChunk` not defined.

- [ ] **Step 3: Implement**

Create `Sources/quill/Live/AudioChunk.swift`:

```swift
import AVFoundation

/// A deep-copied PCM buffer that is safe to send across concurrency domains.
/// Tap callbacks hand out buffers whose memory Core Audio reuses (the system
/// tap wraps it no-copy), so escaping the callback requires this copy. The
/// @unchecked Sendable is sound because the wrapped buffer is a private copy
/// that nothing mutates after init.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init?(copying source: AVAudioPCMBuffer) {
        guard source.frameLength > 0,
            let copy = AVAudioPCMBuffer(
                pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return nil }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(src, dst) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        buffer = copy
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioChunkTests 2>&1 | tail -10`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/quill/Live/AudioChunk.swift Tests/quillTests/AudioChunkTests.swift
git commit -m "feat: sendable deep-copied audio chunk for live fan-out"
```

---

### Task 3: `LiveTranscriptStore`

**Files:**
- Create: `Sources/quill/Live/LiveTranscriptStore.swift`
- Test: `Tests/quillTests/LiveTranscriptStoreTests.swift`

**Interfaces:**
- Consumes: `Utterance` (Task 1).
- Produces (used by Tasks 6, 7, 8):
  - `@MainActor @Observable final class LiveTranscriptStore` with
    `private(set) var utterances: [Utterance]`,
    `private(set) var partials: [String: String]` (speaker → in-flight text),
    `var notice: String?`,
    `func add(_ utterance: Utterance)` (sorted insert by `startedAt`),
    `func setPartial(speaker: String, text: String)` (empty text removes the key),
    `func setNotice(_ text: String?)`,
    `func reset()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/quillTests/LiveTranscriptStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import quill

@MainActor
struct LiveTranscriptStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func utterance(_ speaker: String, _ text: String, at offset: TimeInterval) -> Utterance {
        Utterance(id: UUID(), speaker: speaker, text: text, startedAt: t0.addingTimeInterval(offset))
    }

    @Test func addKeepsStartTimeOrderAcrossSpeakers() {
        let store = LiveTranscriptStore()
        // "them" spoke a long utterance starting at 0 that settled late;
        // "me" interjected at 2 and settled first.
        store.add(utterance("me", "quick interjection", at: 2))
        store.add(utterance("them", "long monologue", at: 0))
        #expect(store.utterances.map(\.text) == ["long monologue", "quick interjection"])
    }

    @Test func equalTimestampsPreserveInsertionOrder() {
        let store = LiveTranscriptStore()
        store.add(utterance("me", "first", at: 1))
        store.add(utterance("them", "second", at: 1))
        #expect(store.utterances.map(\.text) == ["first", "second"])
    }

    @Test func emptyPartialRemovesSpeakerLine() {
        let store = LiveTranscriptStore()
        store.setPartial(speaker: "me", text: "typing…")
        #expect(store.partials["me"] == "typing…")
        store.setPartial(speaker: "me", text: "")
        #expect(store.partials["me"] == nil)
    }

    @Test func resetClearsEverything() {
        let store = LiveTranscriptStore()
        store.add(utterance("me", "hello", at: 0))
        store.setPartial(speaker: "them", text: "in flight")
        store.setNotice("a notice")
        store.reset()
        #expect(store.utterances.isEmpty)
        #expect(store.partials.isEmpty)
        #expect(store.notice == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveTranscriptStoreTests 2>&1 | tail -10`
Expected: compile FAILURE — `LiveTranscriptStore` not defined.

- [ ] **Step 3: Implement**

Create `Sources/quill/Live/LiveTranscriptStore.swift`:

```swift
import Foundation
import Observation

/// The live window's model: settled utterances in start-time order plus one
/// in-flight partial line per speaker. Written by LiveTranscriber, read by
/// SwiftUI — main-actor confined so the view observes plain property changes.
@MainActor
@Observable
final class LiveTranscriptStore {
    private(set) var utterances: [Utterance] = []
    /// speaker → unsettled text currently being spoken (rendered dimmed).
    private(set) var partials: [String: String] = [:]
    /// One-line status shown under the transcript ("recording ended — …",
    /// "live transcript unavailable"), or nil for none.
    private(set) var notice: String?

    /// Insert preserving start-time order. The two tracks settle
    /// independently, so a long utterance that began first can arrive after
    /// a short one that began later.
    func add(_ utterance: Utterance) {
        let index =
            utterances.lastIndex { $0.startedAt <= utterance.startedAt }
            .map { utterances.index(after: $0) } ?? 0
        utterances.insert(utterance, at: index)
    }

    func setPartial(speaker: String, text: String) {
        partials[speaker] = text.isEmpty ? nil : text
    }

    func setNotice(_ text: String?) {
        notice = text
    }

    /// A new recording starts with a clean slate.
    func reset() {
        utterances = []
        partials = [:]
        notice = nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveTranscriptStoreTests 2>&1 | tail -10`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/quill/Live/LiveTranscriptStore.swift Tests/quillTests/LiveTranscriptStoreTests.swift
git commit -m "feat: observable store backing the live transcript window"
```

---

### Task 4: Config accessors

File-based singleton like every other `Config` accessor — no unit tests, matching the codebase (verify by build).

**Files:**
- Modify: `Sources/quill/Config.swift`

**Interfaces:**
- Produces (used by Tasks 8, 9): `Config.liveTranscriptEnabled() -> Bool` (default `true`), `Config.liveTranscriptAutoOpen() -> Bool` (default `false`), `Config.liveTranscriptEngine() -> String` (default `"parakeet-eou-320ms"`).

- [ ] **Step 1: Update the doc comment and add accessors**

In the `Config` enum's leading doc comment, extend the example JSON to:

```swift
/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "live_transcript": { "enabled": true, "auto_open": false, "engine": "parakeet-eou-320ms" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
```

Add after `micVoiceProcessing()` (before `load()`):

```swift
    /// Whether the live transcript runs during recording. Default on; off
    /// skips streaming-engine creation entirely and hides the menu item.
    static func liveTranscriptEnabled() -> Bool {
        liveTranscript()?["enabled"] as? Bool ?? true
    }

    /// Whether the live transcript panel opens itself when recording starts
    /// (default off — open on demand from the menu). Transcription runs
    /// either way; the panel only toggles visibility.
    static func liveTranscriptAutoOpen() -> Bool {
        liveTranscript()?["auto_open"] as? Bool ?? false
    }

    /// Configured streaming engine variant. Only the parakeet-eou-* variants
    /// are supported; LiveTranscriber warns and falls back for anything else.
    static func liveTranscriptEngine() -> String {
        liveTranscript()?["engine"] as? String ?? "parakeet-eou-320ms"
    }

    private static func liveTranscript() -> [String: Any]? {
        load()?["live_transcript"] as? [String: Any]
    }
```

- [ ] **Step 2: Verify it builds**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/quill/Config.swift
git commit -m "feat: live_transcript config block"
```

---

### Task 5: Recorder buffer fan-out + session wiring

The entire footprint on the capture path: one optional closure per recorder,
invoked after the disk write. Handlers run on capture threads (mic: AVAudio
render thread; system: the tap's dispatch queue) — the contract is copy fast
and return.

**Files:**
- Modify: `Sources/quill/Audio/MicRecorder.swift`
- Modify: `Sources/quill/Audio/SystemAudioRecorder.swift`
- Modify: `Sources/quill/RecordingSession.swift`

**Interfaces:**
- Produces (used by Task 8):
  - `MicRecorder.bufferHandler: ((AVAudioPCMBuffer) -> Void)?` / `SystemAudioRecorder.bufferHandler: ((AVAudioPCMBuffer) -> Void)?` — set before `start()`.
  - `RecordingSession.setBufferHandlers(mic: ((AVAudioPCMBuffer) -> Void)?, system: ((AVAudioPCMBuffer) -> Void)?)` — call before `start()`.

- [ ] **Step 1: MicRecorder — add the handler property**

After `private(set) var firstBufferAt: Date?` (around `MicRecorder.swift:36`), add:

```swift
    /// Optional live consumer of captured buffers, called on the render
    /// thread after each disk write. The buffer is only valid during the
    /// call — copy before escaping. Set before start().
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
```

- [ ] **Step 2: MicRecorder — invoke it in both taps**

In `installVoiceTap`, after the `do { try file.write(from: buffer) } catch { … }` block, add:

```swift
            self.bufferHandler?(buffer)
```

In `installRawTap`, inside the closure after the `do { … convert … write … } catch { … }` block, add (note: the *converted mono* buffer, so both paths deliver the same shape):

```swift
            self.bufferHandler?(mono)
```

Careful with `installRawTap`: `mono` is declared via `guard let mono = AVAudioPCMBuffer(…) else { return }` before the do-block, so it is in scope after it. The handler call goes after the catch so a disk-write failure still feeds the live path.

- [ ] **Step 3: SystemAudioRecorder — same pattern**

After `private(set) var firstBufferAt: Date?` (around `SystemAudioRecorder.swift:40`), add:

```swift
    /// Optional live consumer of captured buffers, called on the tap queue
    /// after each disk write. The buffer wraps Core Audio's memory no-copy —
    /// it is invalid after the call returns, so consumers must deep-copy.
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
```

In `installIOProc`, after the `do { try file.write(from: buffer) } catch { … }` block, add:

```swift
            self.bufferHandler?(buffer)
```

- [ ] **Step 4: RecordingSession — expose wiring**

Add to `RecordingSession` (after `init`, before `start()`), plus the needed import at the top (`import AVFoundation`):

```swift
    /// Route a live copy of each track's buffers to a consumer (the live
    /// transcriber). Call before start(). Handlers run on capture threads
    /// and must return fast — copy, enqueue, nothing else.
    func setBufferHandlers(
        mic micHandler: ((AVAudioPCMBuffer) -> Void)?,
        system systemHandler: ((AVAudioPCMBuffer) -> Void)?
    ) {
        mic.bufferHandler = micHandler
        system.bufferHandler = systemHandler
    }
```

Note: the parameter labels shadow the `mic`/`system` stored properties — use the labels exactly as written (`micHandler`/`systemHandler` internal names) so the assignments refer to the properties.

- [ ] **Step 5: Verify build + full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/quill/Audio/MicRecorder.swift Sources/quill/Audio/SystemAudioRecorder.swift Sources/quill/RecordingSession.swift
git commit -m "feat: optional live buffer fan-out from both capture taps"
```

---

### Task 6: `LiveTranscriber` actor

Engine-bound integration code — no unit tests (the settling logic it drives
was tested in Task 1); verified by build here and live in Task 10.

**Files:**
- Create: `Sources/quill/Live/LiveTranscriber.swift`

**Interfaces:**
- Consumes: `AudioChunk` (Task 2), `UtteranceSettler`/`Utterance` (Task 1), `LiveTranscriptStore` (Task 3), FluidAudio `StreamingModelVariant` / `StreamingAsrManager` / `StreamingAsrEouProvider`.
- Produces (used by Tasks 8, 9):
  - `actor LiveTranscriber` with `enum Track: CaseIterable, Sendable { case mic, system; var speaker: String }` (`"me"`/`"them"`),
    `init(variant: StreamingModelVariant, store: LiveTranscriptStore)`,
    `nonisolated func ingest(_ buffer: AVAudioPCMBuffer, track: Track)`,
    `func start()`, `func stop() async`,
    `static func resolveVariant(_ name: String) -> StreamingModelVariant`.

- [ ] **Step 1: Implement**

Create `Sources/quill/Live/LiveTranscriber.swift`:

```swift
import AVFoundation
import FluidAudio
import Foundation

/// Runs one streaming ASR engine per track over live audio and publishes
/// settled utterances + in-flight partials to a LiveTranscriptStore.
///
/// Fire-and-forget from the capture path: ingest() deep-copies and enqueues
/// on the caller's thread, never blocking. Everything downstream — model
/// load, decoding, even total engine failure — degrades only the live text;
/// the recording on disk is untouched by design.
actor LiveTranscriber {
    enum Track: CaseIterable, Sendable {
        case mic, system

        /// Same speaker labels the offline transcript uses.
        var speaker: String {
            switch self {
            case .mic: return "me"
            case .system: return "them"
            }
        }
    }

    /// Queued chunks per track before oldest are dropped. Mic taps deliver
    /// ~85 ms buffers (4096 frames at 48 kHz), the system tap smaller ones —
    /// 512 chunks is comfortably tens of seconds, enough to absorb a slow
    /// first model load without losing the start of the meeting.
    private static let queueCapacity = 512

    private let variant: StreamingModelVariant
    private let store: LiveTranscriptStore
    private let streams: [Track: AsyncStream<AudioChunk>]
    private let continuations: [Track: AsyncStream<AudioChunk>.Continuation]
    private var settlers: [Track: UtteranceSettler] = [:]
    private var eouCounts: [Track: Int] = [:]
    private var consumers: [Task<Void, Never>] = []
    private var reportedDrop = false

    init(variant: StreamingModelVariant, store: LiveTranscriptStore) {
        self.variant = variant
        self.store = store
        var streams: [Track: AsyncStream<AudioChunk>] = [:]
        var continuations: [Track: AsyncStream<AudioChunk>.Continuation] = [:]
        for track in Track.allCases {
            let (stream, continuation) = AsyncStream.makeStream(
                of: AudioChunk.self,
                bufferingPolicy: .bufferingNewest(Self.queueCapacity)
            )
            streams[track] = stream
            continuations[track] = continuation
        }
        self.streams = streams
        self.continuations = continuations
    }

    /// Only the EOU variants are supported — they alone emit the utterance
    /// boundaries the settling model needs. Anything else warns and falls
    /// back, same as the offline engine config.
    static func resolveVariant(_ name: String) -> StreamingModelVariant {
        let supported: [StreamingModelVariant] = [
            .parakeetEou160ms, .parakeetEou320ms, .parakeetEou1280ms,
        ]
        if let variant = StreamingModelVariant(rawValue: name), supported.contains(variant) {
            return variant
        }
        FileHandle.standardError.write(Data(
            "warning: unsupported live transcript engine \"\(name)\" — using parakeet-eou-320ms\n"
                .utf8
        ))
        return .parakeetEou320ms
    }

    /// Called on the capture threads. The tap's buffer memory is not ours
    /// after the callback returns, so copy synchronously, then enqueue.
    nonisolated func ingest(_ buffer: AVAudioPCMBuffer, track: Track) {
        guard let chunk = AudioChunk(copying: buffer) else { return }
        if case .dropped = continuations[track]!.yield(chunk) {
            Task { await self.noteDrop() }
        }
    }

    /// Spawn one consumer loop per track. Returns immediately — model
    /// loading (and a possible first-run download) happens inside the loops
    /// while ingest() buffers audio.
    func start() {
        for track in Track.allCases {
            settlers[track] = UtteranceSettler(speaker: track.speaker)
            eouCounts[track] = 0
            let stream = streams[track]!
            consumers.append(Task { await self.run(track: track, stream: stream) })
        }
    }

    /// Finish the streams and wait for the loops to flush their tails and
    /// release the engines. The final settled text stays in the store for
    /// the window to show until the next recording resets it.
    func stop() async {
        for continuation in continuations.values {
            continuation.finish()
        }
        for consumer in consumers {
            await consumer.value
        }
        consumers = []
    }

    // MARK: -

    private func run(track: Track, stream: AsyncStream<AudioChunk>) async {
        let engine = variant.createManager()
        do {
            try await engine.loadModels()
        } catch {
            FileHandle.standardError.write(Data(
                "live: \(track.speaker) model load failed: \(error)\n".utf8
            ))
            await store.setNotice("live transcript unavailable — model load failed")
            return
        }
        for await chunk in stream {
            do {
                try await engine.appendAudio(chunk.buffer)
                try await engine.processBufferedAudio()
            } catch {
                FileHandle.standardError.write(Data(
                    "live: \(track.speaker) engine failed: \(error)\n".utf8
                ))
                await store.setNotice("live transcript stopped for \(track.speaker)")
                await engine.cleanup()
                return
            }
            await publish(track: track, engine: engine)
        }
        // Stream finished (recording stopped): flush whatever the engine is
        // still holding as a final utterance.
        let finalText: String
        if let flushed = try? await engine.finish() {
            finalText = flushed
        } else {
            finalText = await engine.getPartialTranscript()
        }
        if let utterance = settlers[track]!.settle(fullText: finalText, at: Date()) {
            await store.add(utterance)
        }
        await store.setPartial(speaker: track.speaker, text: "")
        await engine.cleanup()
    }

    /// Read the engine's cumulative transcript and EOU count after each
    /// chunk. Polling (rather than the engine's callbacks) keeps partials
    /// and boundaries ordered — callbacks would race the loop.
    private func publish(track: Track, engine: any StreamingAsrManager) async {
        let fullText = await engine.getPartialTranscript()
        let now = Date()
        var eouCount = eouCounts[track]!
        if let provider = engine as? any StreamingAsrEouProvider {
            eouCount = await provider.getEouTimestampsMs().count
        }
        if eouCount > eouCounts[track]! {
            eouCounts[track] = eouCount
            if let utterance = settlers[track]!.settle(fullText: fullText, at: now) {
                await store.add(utterance)
            }
        } else {
            settlers[track]!.update(fullText: fullText, at: now)
        }
        await store.setPartial(speaker: track.speaker, text: settlers[track]!.partial)
    }

    /// Queue overflowed — the engines can't keep up. Live text will have a
    /// gap; say so once instead of spamming.
    private func noteDrop() async {
        guard !reportedDrop else { return }
        reportedDrop = true
        FileHandle.standardError.write(Data(
            "live: transcription lagging — dropping oldest audio\n".utf8
        ))
        await store.setNotice("… live transcript lagging — some audio skipped")
    }
}
```

- [ ] **Step 2: Verify build + full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete, all tests pass. If the compiler rejects `continuations[track]!.yield(chunk)` from the `nonisolated` context, the fix is that `streams`/`continuations` are `let` constants of Sendable values (`AsyncStream.Continuation` is Sendable) — do NOT work around with `nonisolated(unsafe)`; restructure so the dictionaries stay immutable `let`s initialized in `init`.

- [ ] **Step 3: Commit**

```bash
git add Sources/quill/Live/LiveTranscriber.swift
git commit -m "feat: live transcriber — one streaming engine per track"
```

---

### Task 7: Live window UI

**Files:**
- Create: `Sources/quill/UI/LiveTranscriptView.swift`
- Create: `Sources/quill/UI/LiveTranscriptWindowController.swift`

**Interfaces:**
- Consumes: `LiveTranscriptStore` (Task 3), `Utterance` (Task 1).
- Produces (used by Task 8): `@MainActor final class LiveTranscriptWindowController { init(store: LiveTranscriptStore); var isVisible: Bool; func show(); func close() }`.

- [ ] **Step 1: Create the SwiftUI view**

Create `Sources/quill/UI/LiveTranscriptView.swift`:

```swift
import SwiftUI

/// The live panel's content: settled utterances, then a dimmed italic
/// in-flight line per speaker, auto-pinned to the bottom until the user
/// scrolls away (then a jump-back button appears).
struct LiveTranscriptView: View {
    let store: LiveTranscriptStore
    @State private var pinned = true

    private static let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.utterances) { utterance in
                        row(speaker: utterance.speaker, text: utterance.text, dimmed: false)
                    }
                    ForEach(store.partials.keys.sorted(), id: \.self) { speaker in
                        row(speaker: speaker, text: store.partials[speaker] ?? "", dimmed: true)
                    }
                    if let notice = store.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(10)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 40
            } action: { _, nearBottom in
                pinned = nearBottom
            }
            .onChange(of: store.utterances.count) {
                if pinned { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: store.partials) {
                if pinned { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !pinned {
                    Button("Jump to latest") {
                        pinned = true
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(8)
                }
            }
        }
        .frame(minWidth: 260, minHeight: 180)
    }

    private func row(speaker: String, text: String, dimmed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(speaker == "me" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 38, alignment: .trailing)
            Text(text)
                .font(.callout)
                .italic(dimmed)
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
```

- [ ] **Step 2: Create the panel controller**

Create `Sources/quill/UI/LiveTranscriptWindowController.swift`:

```swift
import AppKit
import SwiftUI

/// Floating, non-activating panel hosting the live transcript — glanceable
/// over the meeting window. Never takes key focus (nonactivating + no
/// first responder demands), follows across Spaces and full-screen apps,
/// and remembers its frame between runs.
@MainActor
final class LiveTranscriptWindowController {
    private let panel: NSPanel

    init(store: LiveTranscriptStore) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "live transcript"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: LiveTranscriptView(store: store))
        panel.setFrameAutosaveName("quill.live-transcript")
    }

    var isVisible: Bool { panel.isVisible }

    /// orderFrontRegardless: the app is .accessory and must not activate.
    func show() { panel.orderFrontRegardless() }

    func close() { panel.orderOut(nil) }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/quill/UI/LiveTranscriptView.swift Sources/quill/UI/LiveTranscriptWindowController.swift
git commit -m "feat: floating live transcript panel (SwiftUI in NSPanel)"
```

---

### Task 8: Menu item + AppController wiring

Everything connects here. After this task the feature works end-to-end.

**Files:**
- Modify: `Sources/quill/UI/MenuBarController.swift`
- Modify: `Sources/quill/Quill.swift` (the `AppController` class)

**Interfaces:**
- Consumes: everything produced by Tasks 3–7.
- Produces: `MenuBarController.onShowLiveTranscript: (() -> Void)?`; menu item "Show live transcript" (key equivalent `t`), hidden when `Config.liveTranscriptEnabled()` is false, enabled only while recording.

- [ ] **Step 1: MenuBarController — add the item**

Add a stored property alongside the others:

```swift
    private let liveTranscriptItem: NSMenuItem
```

Add a callback alongside `onToggle` etc.:

```swift
    var onShowLiveTranscript: (() -> Void)?
```

In `init()`, after `menu.addItem(toggleItem)` and before the `openFolder` item, create and add:

```swift
        liveTranscriptItem = NSMenuItem(
            title: "Show live transcript",
            action: #selector(liveTranscriptClicked),
            keyEquivalent: "t"
        )
        liveTranscriptItem.isEnabled = false
        liveTranscriptItem.isHidden = !Config.liveTranscriptEnabled()
        menu.addItem(liveTranscriptItem)
```

Add `liveTranscriptItem` to the `for item in [toggleItem, openFolder, quit]` target loop. NOTE: `liveTranscriptItem` must be initialized before `stateLabel`-style usage order complaints — Swift requires all stored properties assigned before `self` is used; initialize `liveTranscriptItem` in the same place the other `NSMenuItem` properties are built (before `statusItem.menu = menu`), and only then reference `#selector` (selectors don't touch self).

In `update(recording:elapsed:)`, add:

```swift
        liveTranscriptItem.isEnabled = recording
```

Add the action method next to the other `@objc` methods:

```swift
    @objc private func liveTranscriptClicked() { onShowLiveTranscript?() }
```

- [ ] **Step 2: AppController — own the live pipeline**

In `Sources/quill/Quill.swift`, add stored properties to `AppController` after `private var ticker: Timer?`:

```swift
    private var liveStore: LiveTranscriptStore?
    private var liveTranscriber: LiveTranscriber?
    private var liveWindow: LiveTranscriptWindowController?
```

In `init(root:)`, wire the menu callback alongside the others:

```swift
        menuBar.onShowLiveTranscript = { [weak self] in self?.liveWindow?.show() }
```

- [ ] **Step 3: AppController — start/stop lifecycle**

Replace `startSession()` with (only the marked lines are new — keep the existing error handling exactly):

```swift
    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            attachLiveTranscript(to: newSession)                       // new
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
```

Add the two new private methods:

```swift
    /// Build the live pipeline for this session: shared store (reset), a
    /// fresh transcriber, buffer routing, and the panel per auto_open. The
    /// previous session's panel closes — its content was reset anyway.
    private func attachLiveTranscript(to newSession: RecordingSession) {
        guard Config.liveTranscriptEnabled() else { return }
        liveWindow?.close()
        let store = liveStore ?? LiveTranscriptStore()
        store.reset()
        liveStore = store
        let variant = LiveTranscriber.resolveVariant(Config.liveTranscriptEngine())
        let transcriber = LiveTranscriber(variant: variant, store: store)
        liveTranscriber = transcriber
        newSession.setBufferHandlers(
            mic: { transcriber.ingest($0, track: .mic) },
            system: { transcriber.ingest($0, track: .system) }
        )
        Task { await transcriber.start() }
        if liveWindow == nil {
            liveWindow = LiveTranscriptWindowController(store: store)
        }
        if Config.liveTranscriptAutoOpen() {
            liveWindow?.show()
        }
    }

    /// Flush and release the live pipeline; leave the final text + a notice
    /// in the store so the panel stays useful until the next recording.
    private func detachLiveTranscript(sessionName: String) {
        guard let transcriber = liveTranscriber else { return }
        liveTranscriber = nil
        let store = liveStore
        Task {
            await transcriber.stop()
            store?.setNotice("recording ended — full transcript will land in \(sessionName)")
        }
    }
```

In `stopSession()`, after `menuBar.update(recording: false, elapsed: nil)`, add:

```swift
        detachLiveTranscript(sessionName: session.dir.lastPathComponent)
```

(Note `stopSession` already captured `let session` via `guard let session` — `session.dir` is available; the existing line `let dir = session.dir` for the transcription enqueue stays as is.)

- [ ] **Step 4: Verify build + tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete, tests pass.

- [ ] **Step 5: Functional smoke test (manual)**

Run: `swift run quill 2>&1 | head -5` (Ctrl-C after checking)
Expected: daemon starts, no startup-check failures. Full end-to-end verification happens in Task 10 — this step only proves the wiring doesn't crash at launch.

- [ ] **Step 6: Commit**

```bash
git add Sources/quill/UI/MenuBarController.swift Sources/quill/Quill.swift
git commit -m "feat: wire live transcript into menu bar and session lifecycle"
```

---

### Task 9: Doctor check + docs

**Files:**
- Modify: `Sources/quill/Doctor.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `Config.liveTranscriptEnabled()`/`liveTranscriptEngine()` (Task 4), `LiveTranscriber.resolveVariant` (Task 6), FluidAudio `StreamingModelVariant.repo.folderName`.

- [ ] **Step 1: Add the doctor check**

In `DoctorReport.run`, add `checkLiveTranscript(),` after `checkTranscription(),`. Then add the method after `checkTranscription()`:

```swift
    /// Same promise as the transcription check: never discover missing
    /// models mid-meeting. Streaming models live in FluidAudio's Application
    /// Support cache; presence of the encoder is the "downloaded" signal.
    static func checkLiveTranscript() -> Check {
        guard Config.liveTranscriptEnabled() else {
            return Check(
                name: "live transcript",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let variant = LiveTranscriber.resolveVariant(Config.liveTranscriptEngine())
        let modelDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent(variant.repo.folderName, isDirectory: true)
        let encoder = modelDir.appendingPathComponent("streaming_encoder.mlmodelc")
        if FileManager.default.fileExists(atPath: encoder.path) {
            return Check(name: "live transcript", status: .ok, remediation: nil)
        }
        return Check(
            name: "live transcript",
            status: .warn("streaming models not downloaded"),
            remediation: "downloads automatically when a recording starts while online"
        )
    }
```

- [ ] **Step 2: Verify doctor output**

Run: `swift run quill doctor`
Expected: existing checks plus a `live transcript` line (`ok` or the not-downloaded warning). Exit code 0 (warnings don't block).

- [ ] **Step 3: README section**

In `README.md`, after the **Transcription** section and before **Config**, add:

```markdown
## Live transcript

While recording, quill can show a floating, always-on-top panel with a live
speaker-tagged transcript — glance at it when you missed or misheard
something. Open it from the menu (**Show live transcript**), or set
`auto_open` to have it appear whenever recording starts.

The live text is a rough tier: it comes from a small streaming model
(Parakeet EOU 120M, one instance per track) and is never written to disk.
The accurate transcript is still produced after the meeting by the offline
pass. Streaming models (~100 MB) download once on first use; `quill doctor`
reports whether they're cached.

Disable with `"live_transcript": { "enabled": false }` to skip the streaming
engines entirely.
```

Also extend the config example in the **Config** section to include the new block:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "live_transcript": { "enabled": true, "auto_open": false, "engine": "parakeet-eou-320ms" },
  "on_stop": "my-hook"
}
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/quill/Doctor.swift README.md
git commit -m "feat: doctor check for streaming models + live transcript docs"
```

---

### Task 10: End-to-end verification

No new code — a scripted manual pass proving the spec's integration claims.
Record results (pass/fail per item) in the final commit message or a PR-notes
file; failures loop back into fixes before this task completes.

- [ ] **Step 1: Full automated suite**

Run: `swift test 2>&1 | tail -5 && swift build -c release 2>&1 | tail -3`
Expected: all tests pass; release build completes.

- [ ] **Step 2: Baseline session (feature off)**

```bash
echo '{"live_transcript": {"enabled": false}}' > ~/.config/quill/config.json.live-test
```
Temporarily move any real config aside, use the test config, run `swift run quill`, record ~30 s (play a video for system audio + speak into the mic), stop, wait for the offline transcript. Verify: session folder contains `mic.caf`, `system.caf`, `meta.json`, `transcript.json`, `transcript.md`; the menu has no "Show live transcript" item.

- [ ] **Step 3: Live session (feature on)**

Restore/enable config with `live_transcript.enabled: true`. Run `swift run quill`, start recording with a video playing and speak into the mic:
- Menu shows "Show live transcript" enabled; clicking opens the floating panel without stealing focus from the frontmost app.
- Both `me` and `them` lines appear; partials render dimmed, settle into normal rows at pauses.
- Scroll up → auto-scroll stops and "Jump to latest" appears; clicking it re-pins.
- Close and reopen the panel mid-recording → scrollback intact.
- Stop recording → panel shows the "recording ended" notice; offline transcript still lands normally.
- Compare the session folder file list to the baseline: identical structure.

- [ ] **Step 4: Failure injection**

Start a recording with live enabled, then verify recording survives live-path death: while recording, `kill -STOP` is not practical in-process — instead verify the designed degradation paths: (a) with Wi-Fi off and models **not** cached (`rm -rf ~/Library/"Application Support"/FluidAudio/Models/parakeet-eou-streaming` first), start recording → panel shows "live transcript unavailable — model load failed", recording completes and transcribes normally; (b) restore network, next recording downloads models and streams.

- [ ] **Step 5: Commit any fixes + verification notes**

```bash
git add -A
git commit -m "test: end-to-end verification notes for live transcript"
```

---

## Self-Review (completed)

- **Spec coverage:** both-track speaker tagging (T6), floating non-activating panel + frame memory (T7), auto_open/enabled/engine config (T4, T8), whole-recording transcription with visibility-only toggle (T6/T8), fire-and-forget + drop-oldest overflow (T2/T5/T6), one-engine-dies degradation (T6 `run` catch), ephemeral live text (nothing writes it), doctor line (T9), README (T9), menu item (T8), settled/partial seam for future tier-2 (T1 `UtteranceSettler`). Upstream-issue step is a user action outside the plan.
- **Placeholder scan:** clean — every code step contains the actual code.
- **Type consistency:** `Utterance(id:speaker:text:startedAt:)`, `UtteranceSettler.update(fullText:at:)`/`settle(fullText:at:)`, `LiveTranscriptStore.add/setPartial/setNotice/reset`, `AudioChunk(copying:)`, `LiveTranscriber.ingest(_:track:)/start()/stop()/resolveVariant(_:)`, `setBufferHandlers(mic:system:)`, `LiveTranscriptWindowController.show()/close()/isVisible` — cross-checked between producing and consuming tasks.
