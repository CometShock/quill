import FluidAudio
import Testing

@testable import quill

struct LiveTranscriberTests {
    @Test func listingPhaseText() {
        let text = LiveTranscriber.loadProgressText(
            DownloadProgress(fractionCompleted: 0, phase: .listing))
        #expect(text == "checking speech model…")
    }

    @Test func downloadingPhaseShowsFileCounter() {
        let text = LiveTranscriber.loadProgressText(
            DownloadProgress(fractionCompleted: 0.4, phase: .downloading(completedFiles: 8, totalFiles: 20)))
        #expect(text == "downloading speech model (8/20) — recording is unaffected")
    }

    @Test func compilingPhaseTextMentionsLiveStart() {
        let text = LiveTranscriber.loadProgressText(
            DownloadProgress(fractionCompleted: 0.9, phase: .compiling(modelName: "streaming_encoder")))
        #expect(text == "preparing speech model — recording is unaffected; live text starts when ready")
    }
}
