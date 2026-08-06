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
