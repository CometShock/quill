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
