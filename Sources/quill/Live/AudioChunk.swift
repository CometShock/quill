import AVFoundation

/// A deep-copied PCM buffer that is safe to send across concurrency domains.
/// Tap callbacks hand out buffers whose memory Core Audio reuses (the system
/// tap wraps it no-copy), so escaping the callback requires this copy. The
/// @unchecked Sendable is sound because the wrapped buffer is a private copy
/// that nothing mutates after init.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init?(copying source: AVAudioPCMBuffer) {
        guard source.frameLength > 0,
            let copy = AVAudioPCMBuffer(
                pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return nil }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(src, dst) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        buffer = copy
    }
}
