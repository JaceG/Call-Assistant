@preconcurrency import AVFoundation
import Foundation
import Observation
import os

/// One call: captures the mic (me) and the system audio (them), transcribes
/// each on its own, and fills the transcript store and the session file. The
/// window drives it today; the phone server and headless mode will later.
@MainActor
@Observable
public final class LiveSession {
    public enum State: Equatable {
        case idle
        case preparing(String, progress: Double?)
        case listening
        case stopping
        case failed(String)
    }

    public private(set) var state: State = .idle
    public let store = TranscriptStore()
    /// The current (or last) call's transcript file.
    public private(set) var sessionFile: URL?
    /// Voice processing on the mic, so it doesn't pick up the other side from
    /// the speakers. Not needed with headphones. Applies from the next start.
    public var echoCancellation = false

    private let sessionsDirectory: URL
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var writer: SessionWriter?
    private var channels: [Task<Void, Never>] = []

    public init(sessionsDirectory: URL = Paths.sessionsDirectory) {
        self.sessionsDirectory = sessionsDirectory
    }

    public var isRunning: Bool {
        switch state {
        case .preparing, .listening, .stopping: true
        case .idle, .failed: false
        }
    }

    public func start() async {
        guard !isRunning else { return }
        store.clear()
        state = .preparing("Checking the speech model…", progress: nil)

        let micTranscriber = AppleSpeechTranscriber()
        let systemTranscriber = AppleSpeechTranscriber()
        do {
            let session = self
            try await micTranscriber.prepare(
                onStatus: { status in Task { @MainActor in session.state = .preparing(status, progress: nil) } },
                onProgress: { progress in Task { @MainActor in session.state = .preparing("Downloading the speech model…", progress: progress) } }
            )
            try await systemTranscriber.prepare(onStatus: { _ in }, onProgress: { _ in })
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard await AVAudioApplication.requestRecordPermission() else {
            fail("Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone.")
            return
        }

        let startedAt = Date()
        do {
            let writer = try SessionWriter(directory: sessionsDirectory, startedAt: startedAt)
            self.writer = writer
            sessionFile = writer.fileURL
        } catch {
            fail("Couldn't create the transcript file: \(error.localizedDescription)")
            return
        }

        let mic = MicCapture()
        let system = SystemAudioCapture()
        let micAudio = mic.bufferStream(echoCancellation: echoCancellation)
        let systemAudio: AsyncStream<AVAudioPCMBuffer>
        do {
            systemAudio = try await system.bufferStream().systemAudio
        } catch {
            mic.stop()
            fail(error.localizedDescription)
            return
        }
        self.mic = mic
        self.system = system

        channels = [
            channel(.me, transcriber: micTranscriber, audio: micAudio),
            channel(.them, transcriber: systemTranscriber, audio: systemAudio),
        ]
        state = .listening
        Log.session.info("listening; transcript at \(self.sessionFile?.path ?? "-", privacy: .public)")
    }

    /// Stops capture, waits for both transcribers to finish their last words,
    /// and closes the transcript file.
    public func stop() async {
        guard state == .listening else { return }
        state = .stopping
        mic?.stop()
        await system?.stop()
        for channel in channels { await channel.value }
        channels = []
        mic = nil
        system = nil
        writer?.close()
        writer = nil
        state = .idle
    }

    /// Transcribes one side of the call on a background task.
    private func channel(
        _ speaker: Speaker,
        transcriber: AppleSpeechTranscriber,
        audio: AsyncStream<AVAudioPCMBuffer>
    ) -> Task<Void, Never> {
        let audio = UncheckedSendable(audio)
        // The task holds the session until this channel's audio ends (on stop).
        let session = self
        return Task.detached {
            do {
                try await transcriber.run(
                    audio.value,
                    onPartial: { text in
                        Task { @MainActor in session.store.setPartial(text, for: speaker) }
                    },
                    onFinal: { segment in
                        let utterance = Utterance(speaker: speaker, text: segment.text, start: segment.start, end: segment.end)
                        Task { @MainActor in session.record(utterance) }
                    }
                )
            } catch {
                Log.session.error("\(speaker.label, privacy: .public) transcription stopped: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { session.store.setPartial("", for: speaker) }
            }
        }
    }

    private func record(_ utterance: Utterance) {
        store.append(utterance)
        do {
            try writer?.append(utterance)
        } catch {
            Log.session.error("couldn't write to the transcript: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fail(_ message: String) {
        Log.session.error("\(message, privacy: .public)")
        state = .failed(message)
    }
}

/// Hands a value to another task when the compiler can't prove that's safe.
/// Used for the capture streams: AsyncStream is thread-safe, but its audio
/// buffers aren't marked Sendable, and each stream has exactly one reader.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
