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
