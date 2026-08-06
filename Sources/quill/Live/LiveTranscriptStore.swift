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
