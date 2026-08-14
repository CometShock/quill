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
    @State private var updateCheckEnabled = Config.updateCheckEnabled()
    @State private var writeError: String?
    @State private var malformed = Config.fileIsMalformed()

    private static let engines = [
        "parakeet-eou-160ms", "parakeet-eou-320ms", "parakeet-eou-1280ms",
    ]

    /// The known engines plus, if the config file has a hand-edited value
    /// we don't recognize, that value appended so the Picker always has a
    /// matching selection. We never rewrite it ourselves — only a deliberate
    /// user selection through the Picker writes to config.
    private var engineOptions: [String] {
        Self.engines.contains(engine) ? Self.engines : Self.engines + [engine]
    }

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
                ForEach(engineOptions, id: \.self) { Text($0) }
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
            Toggle("Check for updates at launch", isOn: $updateCheckEnabled)
                .onChange(of: updateCheckEnabled) {
                    save(updateCheckEnabled, ["update_check", "enabled"])
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
        .onDisappear { saveUnsubmittedTextFields() }
    }

    /// Text fields only save via onSubmit (Return). If the tray closes or
    /// focus moves elsewhere first, that edit would otherwise be silently
    /// discarded while the UI still shows it as if it were saved — so flush
    /// any edits that differ from what's on disk when the tray goes away.
    private func saveUnsubmittedTextFields() {
        if recordingsDir != (Config.recordingsDir()?.path ?? "") {
            save(recordingsDir, ["recordings_dir"])
        }
        if onStop != (Config.onStop() ?? "") {
            save(onStop, ["on_stop"])
        }
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
