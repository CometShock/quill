import AVFoundation
import FluidAudio
import Foundation

/// Runs one streaming ASR engine per track over live audio and publishes
/// settled utterances + in-flight partials to a LiveTranscriptStore.
///
/// Fire-and-forget from the capture path: ingest() deep-copies and enqueues
/// on the caller's thread, never blocking. Everything downstream — model
/// load, decoding, even total engine failure — degrades only the live text;
/// the recording on disk is untouched by design.
actor LiveTranscriber {
    enum Track: CaseIterable, Sendable {
        case mic, system

        /// Same speaker labels the offline transcript uses.
        var speaker: String {
            switch self {
            case .mic: return "me"
            case .system: return "them"
            }
        }
    }

    /// Queued chunks per track before oldest are dropped. Mic taps deliver
    /// ~85 ms buffers (4096 frames at 48 kHz), the system tap smaller ones —
    /// 512 chunks is comfortably tens of seconds, enough to absorb a slow
    /// first model load without losing the start of the meeting.
    private static let queueCapacity = 512

    private let variant: StreamingModelVariant
    private let store: LiveTranscriptStore
    private let streams: [Track: AsyncStream<AudioChunk>]
    private let continuations: [Track: AsyncStream<AudioChunk>.Continuation]
    private var settlers: [Track: UtteranceSettler] = [:]
    private var eouCounts: [Track: Int] = [:]
    private var consumers: [Task<Void, Never>] = []
    private var reportedDrop = false

    init(variant: StreamingModelVariant, store: LiveTranscriptStore) {
        self.variant = variant
        self.store = store
        var streams: [Track: AsyncStream<AudioChunk>] = [:]
        var continuations: [Track: AsyncStream<AudioChunk>.Continuation] = [:]
        for track in Track.allCases {
            let (stream, continuation) = AsyncStream.makeStream(
                of: AudioChunk.self,
                bufferingPolicy: .bufferingNewest(Self.queueCapacity)
            )
            streams[track] = stream
            continuations[track] = continuation
        }
        self.streams = streams
        self.continuations = continuations
    }

    /// Only the EOU variants are supported — they alone emit the utterance
    /// boundaries the settling model needs. Anything else warns and falls
    /// back, same as the offline engine config.
    static func resolveVariant(_ name: String) -> StreamingModelVariant {
        let supported: [StreamingModelVariant] = [
            .parakeetEou160ms, .parakeetEou320ms, .parakeetEou1280ms,
        ]
        if let variant = StreamingModelVariant(rawValue: name), supported.contains(variant) {
            return variant
        }
        FileHandle.standardError.write(Data(
            "warning: unsupported live transcript engine \"\(name)\" — using parakeet-eou-320ms\n"
                .utf8
        ))
        return .parakeetEou320ms
    }

    /// Called on the capture threads. The tap's buffer memory is not ours
    /// after the callback returns, so copy synchronously, then enqueue.
    nonisolated func ingest(_ buffer: AVAudioPCMBuffer, track: Track) {
        guard let chunk = AudioChunk(copying: buffer) else { return }
        if case .dropped = continuations[track]!.yield(chunk) {
            Task { await self.noteDrop() }
        }
    }

    /// Spawn one consumer loop per track. Returns immediately — model
    /// loading (and a possible first-run download) happens inside the loops
    /// while ingest() buffers audio.
    func start() {
        for track in Track.allCases {
            settlers[track] = UtteranceSettler(speaker: track.speaker)
            eouCounts[track] = 0
            let stream = streams[track]!
            consumers.append(Task { await self.run(track: track, stream: stream) })
        }
    }

    /// Finish the streams and wait for the loops to flush their tails and
    /// release the engines. The final settled text stays in the store for
    /// the window to show until the next recording resets it.
    func stop() async {
        for continuation in continuations.values {
            continuation.finish()
        }
        for consumer in consumers {
            await consumer.value
        }
        consumers = []
    }

    // MARK: -

    private func run(track: Track, stream: AsyncStream<AudioChunk>) async {
        let engine = variant.createManager()
        do {
            try await engine.loadModels()
        } catch {
            FileHandle.standardError.write(Data(
                "live: \(track.speaker) model load failed: \(error)\n".utf8
            ))
            await store.setNotice("live transcript unavailable — model load failed")
            return
        }
        for await chunk in stream {
            do {
                try await engine.appendAudio(chunk.buffer)
                try await engine.processBufferedAudio()
            } catch {
                FileHandle.standardError.write(Data(
                    "live: \(track.speaker) engine failed: \(error)\n".utf8
                ))
                await store.setNotice("live transcript stopped for \(track.speaker)")
                await engine.cleanup()
                return
            }
            await publish(track: track, engine: engine)
        }
        // Stream finished (recording stopped): flush whatever the engine is
        // still holding as a final utterance.
        let finalText: String
        if let flushed = try? await engine.finish() {
            finalText = flushed
        } else {
            finalText = await engine.getPartialTranscript()
        }
        if let utterance = settlers[track]!.settle(fullText: finalText, at: Date()) {
            await store.add(utterance)
        }
        await store.setPartial(speaker: track.speaker, text: "")
        await engine.cleanup()
    }

    /// Read the engine's cumulative transcript and EOU count after each
    /// chunk. Polling (rather than the engine's callbacks) keeps partials
    /// and boundaries ordered — callbacks would race the loop.
    private func publish(track: Track, engine: any StreamingAsrManager) async {
        let fullText = await engine.getPartialTranscript()
        let now = Date()
        var eouCount = eouCounts[track]!
        if let provider = engine as? any StreamingAsrEouProvider {
            eouCount = await provider.getEouTimestampsMs().count
        }
        if eouCount > eouCounts[track]! {
            eouCounts[track] = eouCount
            if let utterance = settlers[track]!.settle(fullText: fullText, at: now) {
                await store.add(utterance)
            }
        } else {
            settlers[track]!.update(fullText: fullText, at: now)
        }
        await store.setPartial(speaker: track.speaker, text: settlers[track]!.partial)
    }

    /// Queue overflowed — the engines can't keep up. Live text will have a
    /// gap; say so once instead of spamming.
    private func noteDrop() async {
        guard !reportedDrop else { return }
        reportedDrop = true
        FileHandle.standardError.write(Data(
            "live: transcription lagging — dropping oldest audio\n".utf8
        ))
        await store.setNotice("… live transcript lagging — some audio skipped")
    }
}
