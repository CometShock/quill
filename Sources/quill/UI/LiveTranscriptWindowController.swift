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
