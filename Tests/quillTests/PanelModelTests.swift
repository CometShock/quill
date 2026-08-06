import Foundation
import Testing

@testable import quill

@MainActor
struct PanelModelTests {
    @Test func startsIdleWithNoStore() {
        let model = PanelModel()
        #expect(model.currentStore == nil)
        #expect(model.recording == false)
        #expect(model.elapsed == nil)
        #expect(model.trayExpanded == false)
    }

    @Test func sessionSwapReplacesStore() {
        let model = PanelModel()
        let first = LiveTranscriptStore()
        let second = LiveTranscriptStore()
        model.setSession(store: first)
        #expect(model.currentStore === first)
        model.setSession(store: second)
        #expect(model.currentStore === second)
    }

    @Test func recordingStateCarriesElapsed() {
        let model = PanelModel()
        model.setRecording(true, elapsed: "0:07")
        #expect(model.recording == true)
        #expect(model.elapsed == "0:07")
        model.setRecording(false, elapsed: nil)
        #expect(model.recording == false)
        #expect(model.elapsed == nil)
    }
}
