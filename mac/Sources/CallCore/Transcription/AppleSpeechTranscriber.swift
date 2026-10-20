@preconcurrency import AVFoundation
import Foundation
import os
import Speech

/// Apple's on-device speech-to-text (`SpeechAnalyzer` + `SpeechTranscriber`,
/// macOS 26+). macOS downloads and manages the language model; nothing ships
/// with the app.
public final class AppleSpeechTranscriber: LiveTranscriber, @unchecked Sendable {
    private let requestedLocale: Locale
    /// Set once by `prepare`, before any `run`.
    private var locale: Locale?

    public init(locale: Locale = .current) {
        self.requestedLocale = locale
    }

    public func prepare(
        onStatus: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedLocale(requestedLocale)
        }
        let module = Self.makeModule(locale: supported)
        let status = await AssetInventory.status(forModules: [module])
        Log.transcription.info("speech model for \(supported.identifier, privacy: .public): \(String(describing: status), privacy: .public)")
        if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onStatus("Downloading the speech model (\(supported.identifier))…")
            let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                onProgress(progress.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        locale = supported
        onStatus("Speech model ready (\(supported.identifier))")
    }

    public func run(
        _ audio: AsyncStream<AVAudioPCMBuffer>,
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (TranscribedSegment) -> Void
    ) async throws {
        guard let locale else { throw TranscriptionError.notPrepared }
        let transcriber = Self.makeModule(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        // Result times count from the first buffer; note when that arrived.
        let firstBufferAt = OSAllocatedUnfairLock<Date?>(initialState: nil)
        let results = transcriber.results
        let resultsTask = Task {
            for try await result in results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal {
                    onPartial("")
                    guard !text.isEmpty else { continue }
                    let origin = firstBufferAt.withLock { $0 } ?? Date()
                    onFinal(TranscribedSegment(
                        text: text,
                        start: origin + result.range.start.seconds,
                        end: origin + result.range.end.seconds
                    ))
                } else {
                    onPartial(text)
                }
            }
        }

        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)

        let converter = AudioBufferConverter(to: format)
        do {
            for await buffer in audio {
                firstBufferAt.withLock { if $0 == nil { $0 = Date() } }
                if let converted = try converter.convert(buffer) {
                    inputContinuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            inputContinuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            throw error
        }
        try await resultsTask.value
    }

    /// Partial ("volatile") results as well as final ones, with time ranges.
    private static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }
}
