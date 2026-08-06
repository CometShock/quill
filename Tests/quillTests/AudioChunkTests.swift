import AVFoundation
import Testing

@testable import quill

struct AudioChunkTests {
    private func makeBuffer(frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = value }
        return buffer
    }

    @Test func copyIsIndependentOfSource() {
        let source = makeBuffer(frames: 256, value: 0.5)
        let chunk = AudioChunk(copying: source)
        #expect(chunk != nil)
        // Clobber the source — simulates Core Audio reusing the memory.
        let sourceData = source.floatChannelData![0]
        for i in 0..<256 { sourceData[i] = 0 }
        let copied = chunk!.buffer.floatChannelData![0]
        #expect(copied[0] == 0.5)
        #expect(copied[255] == 0.5)
        #expect(chunk!.buffer.frameLength == 256)
        #expect(chunk!.buffer.format == source.format)
    }

    @Test func emptyBufferYieldsNil() {
        let source = makeBuffer(frames: 128, value: 0.5)
        source.frameLength = 0
        #expect(AudioChunk(copying: source) == nil)
    }
}
