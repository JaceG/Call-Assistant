@preconcurrency import AVFoundation
import Foundation

/// A stretch of speech the transcriber has settled on. Times are seconds from
/// the start of the audio stream.
public struct TranscribedSegment: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Turns a live audio stream into text. One instance per channel (mic, system
/// audio). Apple's transcriber is the only one today; others (Parakeet, a cloud
/// service) can sit behind the same interface.
public protocol LiveTranscriber: Sendable {
    /// Makes sure the speech model is installed (downloading it if needed) and ready.
    func prepare(
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Transcribes `audio` until the stream ends. Each partial replaces the
    /// previous one; an empty partial clears it.
    func run(
        _ audio: AsyncStream<AVAudioPCMBuffer>,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscribedSegment) -> Void
    ) async throws
}

public enum TranscriptionError: LocalizedError {
    case unavailable
    case unsupportedLocale(Locale)
    case notPrepared
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Speech recognition isn't available on this Mac."
        case .unsupportedLocale(let locale):
            "On-device speech recognition doesn't support \(locale.identifier)."
        case .notPrepared:
            "The transcriber wasn't prepared before use."
        case .noAudioFormat:
            "The speech analyzer didn't offer an audio format."
        }
    }
}
