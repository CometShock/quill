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
