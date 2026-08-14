import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root, cliOverride: out)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let cliOverride: String?
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var liveStore: LiveTranscriptStore?
    private var liveTranscriber: LiveTranscriber?
    private let panelModel = PanelModel()
    private let liveWindow: LiveTranscriptWindowController
    private var updateCompareURL: URL?

    /// Recomputed on every use so tray edits to recordings_dir take effect
    /// on the next recording without a relaunch. CLI --out still wins over
    /// config every time (Config.resolveRoot's precedence).
    private var currentRoot: URL { Config.resolveRoot(cliOverride: cliOverride) }

    init(root: URL, cliOverride: String?) {
        self.cliOverride = cliOverride
        liveWindow = LiveTranscriptWindowController(model: panelModel)
        panelModel.onToggleRecording = { [weak self] in self?.toggle() }
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onShowLiveTranscript = { [weak self] in self?.liveWindow.show(trayExpanded: false) }
        menuBar.onOpenConfig = { [weak self] in self?.liveWindow.show(trayExpanded: true) }
        menuBar.onCheckForUpdates = { [weak self] in self?.runUpdateCheck(manual: true) }
        menuBar.onUpdateStatusClick = { [weak self] in
            if let url = self?.updateCompareURL { NSWorkspace.shared.open(url) }
        }
        if Config.updateCheckEnabled() {
            runUpdateCheck(manual: false)
        }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: currentRoot)
            attachLiveTranscript(to: newSession)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            abortLiveTranscript()
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        panelModel.setRecording(true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

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

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)
        panelModel.setRecording(false, elapsed: nil)
        detachLiveTranscript(sessionName: session.dir.lastPathComponent)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        menuBar.update(recording: true, elapsed: elapsed)
        panelModel.setRecording(true, elapsed: elapsed)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(currentRoot)
    }

    /// One shot per trigger: build a fresh checker from current config
    /// (so tray edits to repo/branch apply immediately) and render the
    /// result. Background (launch) checks stay quiet unless there's news;
    /// manual clicks always answer, including "up to date" and failure.
    private func runUpdateCheck(manual: Bool) {
        menuBar.updateUpdateCheck(manual ? "checking for updates…" : nil, clickable: false)
        let checker = UpdateChecker(
            repo: Config.updateCheckRepo(), branch: Config.updateCheckBranch()
        )
        Task { [weak self] in
            let status = await checker.check()
            self?.showUpdateStatus(status, manual: manual)
        }
    }

    private func showUpdateStatus(_ status: UpdateStatus, manual: Bool) {
        switch status {
        case .upToDate:
            updateCompareURL = nil
            menuBar.updateUpdateCheck(manual ? "up to date" : nil, clickable: false)
        case .rebaseNeeded(let count, let url):
            updateCompareURL = url
            menuBar.updateUpdateCheck(
                "upstream +\(count) commit\(count == 1 ? "" : "s") — rebase needed",
                clickable: true
            )
        case .branchMoved(let url):
            updateCompareURL = url
            menuBar.updateUpdateCheck("branch updated since last check", clickable: true)
        case .failed:
            updateCompareURL = nil
            menuBar.updateUpdateCheck(
                manual ? "update check failed — offline?" : nil, clickable: false
            )
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
