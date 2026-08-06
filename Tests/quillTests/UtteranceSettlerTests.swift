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
