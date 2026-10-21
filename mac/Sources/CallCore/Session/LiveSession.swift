@preconcurrency import AVFoundation
import Foundation
import Observation
import os

/// One call: captures the mic (me) and the system audio (them), transcribes
/// each on its own, and fills the transcript store and the session file. The
/// window drives it.
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
    /// Claude's answers for this call.
    public let answers: AnswerEngine
    /// The call's running summary, saved beside the transcript.
    public let summary: SummaryEngine
    /// Suggestions from the review after the last call.
    public let reviews: ReviewInbox
    /// The current (or last) call's transcript file.
    public private(set) var sessionFile: URL?
    /// WebRTC's echo canceller: removes the speakers' sound from the mic, using
    /// the system audio as the reference, without turning the call down.
    /// Applies from the next start.
    public var cancelEcho = true
    /// Apple's voice processing on the mic, the other way to cancel echo. It
    /// turns other audio down (measured: the call to about a third), so it's
    /// off. Applies from the next start.
    public var appleVoiceProcessing = false
    /// Drop or trim my lines that repeat what they just said (the mic hearing
    /// the speakers). Text only, so it costs no volume.
    public var filterEcho = true

    private let sessionsDirectory: URL
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var writer: SessionWriter?
    private var channels: [Task<Void, Never>] = []
    /// My lines wait this long before they're recorded, because the line of
    /// theirs they may echo can finish recognizing a little later.
    private static let echoHold: TimeInterval = 3
    private let echoFilter = EchoFilter()
    private var heldMine: [(utterance: Utterance, heldAt: Date)] = []
    private var releaser: Task<Void, Never>?

    public init(sessionsDirectory: URL = Paths.sessionsDirectory, provider: AnswerProvider = ClaudeProvider(),
                summarizer: StructuredProvider = ClaudeProvider()) {
        self.sessionsDirectory = sessionsDirectory
        answers = AnswerEngine(provider: provider)
        summary = SummaryEngine(provider: summarizer)
        reviews = ReviewInbox(reviewer: SessionReviewer(provider: summarizer))
        answers.onFinished = { [weak self] answer in self?.save(answer) }
        answers.pendingMine = { [weak self] in self?.pendingMine() ?? [] }
        summary.callNotes = { [weak self] in self?.answers.callNotes ?? "" }
        summary.onUpdate = { [weak self] summary, at in self?.saveSummary(summary, at: at) }
        reviews.onAlwaysChanged = { [weak self] text in self?.answers.always = text }
    }

    /// The stand-in question a warm request carries; it's read, never answered.
    public static let warmQuestion = "(The call is starting.)"

    public var isRunning: Bool {
        switch state {
        case .preparing, .listening, .stopping: true
        case .idle, .failed: false
        }
    }

    /// Answer Now needs something they or I said, and no start or stop under
    /// way. The button and the hotkey both check this.
    public var canAnswerNow: Bool {
        switch state {
        case .preparing, .stopping: return false
        case .idle, .listening, .failed: return !store.utterances.isEmpty || !store.partial.isEmpty
        }
    }

    /// The folders and files picked for answers. During a call, the new set
    /// is cached at once.
    public func useFiles(_ files: CallFiles) {
        guard files != answers.files else { return }
        answers.files = files
        if state == .listening { Task { await answers.warm() } }
    }

    public func start() async {
        guard !isRunning else { return }
        store.clear()
        answers.reset()
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
        let micAudio = mic.bufferStream(echoCancellation: appleVoiceProcessing)
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

        var meAudio = micAudio
        var themAudio = systemAudio
        if cancelEcho {
            if let canceller = WebRTCEchoCanceller() {
                (meAudio, themAudio) = Self.cancellingEcho(mic: micAudio, system: systemAudio, with: canceller)
            } else {
                Log.session.error("WebRTC echo canceller couldn't be set up; continuing without it")
            }
        }
        channels = [
            channel(.me, transcriber: micTranscriber, audio: meAudio),
            channel(.them, transcriber: systemTranscriber, audio: themAudio),
        ]
        releaser = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.releaseHeldLines()
            }
        }
        state = .listening
        // Caches the files now rather than on the first question.
        Task { await answers.warm() }
        summary.start { [weak self] in self?.store.utterances ?? [] }
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
        releaser?.cancel()
        releaser = nil
        // The last results hop to the main actor after the channels end.
        try? await Task.sleep(for: .milliseconds(200))
        releaseHeldLines(all: true)
        await answers.finishCurrent(within: .seconds(10))
        // Lines were saved as each finished; put the file in time order.
        do {
            try writer?.rewrite(store.utterances, answers: answers.answers)
        } catch {
            Log.session.error("couldn't put the transcript in order: \(error.localizedDescription, privacy: .public)")
        }
        mic = nil
        system = nil
        writer?.close()
        writer = nil
        state = .idle
        // A last summary covering the end of the call, and the review, after
        // Stop returns.
        Task { await summary.finish() }
        let call = sessionFile?.deletingPathExtension().lastPathComponent ?? "a call"
        let lines = store.utterances, answers = answers.answers
        Task { await reviews.review(call: call, lines: lines, answers: answers) }
    }

    /// The summary file beside the call's transcript: "<day> <time> summary.md".
    public var summaryFile: URL? {
        sessionFile.map { file in
            let name = file.deletingPathExtension().lastPathComponent
            let base = name.hasSuffix(" call") ? String(name.dropLast(" call".count)) : name
            return file.deletingLastPathComponent().appendingPathComponent("\(base) summary.md")
        }
    }

    private func saveSummary(_ summary: CallSummary, at time: Date) {
        guard let file = summaryFile else { return }
        do {
            try Data(summary.markdown(updatedAt: time).utf8).write(to: file, options: .atomic)
        } catch {
            Log.session.error("couldn't save the summary: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Passes the system audio to the canceller as the reference (and on, as
    /// it was, to the Them transcriber), and the mic through the canceller.
    /// Each stream ends when its source ends.
    private static func cancellingEcho(
        mic: AsyncStream<AVAudioPCMBuffer>,
        system: AsyncStream<AVAudioPCMBuffer>,
        with canceller: WebRTCEchoCanceller
    ) -> (me: AsyncStream<AVAudioPCMBuffer>, them: AsyncStream<AVAudioPCMBuffer>) {
        let (me, meInput) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let (them, themInput) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let mic = UncheckedSendable(mic)
        let system = UncheckedSendable(system)
        let meOut = UncheckedSendable(meInput)
        let themOut = UncheckedSendable(themInput)
        Task.detached {
            for await buffer in system.value {
                canceller.addFarEnd(buffer)
                themOut.value.yield(buffer)
            }
            themOut.value.finish()
        }
        Task.detached {
            for await buffer in mic.value {
                if let cleaned = canceller.process(buffer) { meOut.value.yield(cleaned) }
            }
            meOut.value.finish()
        }
        return (me, them)
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
        if utterance.speaker == .me && filterEcho {
            heldMine.append((utterance, Date()))
            return
        }
        commit(utterance)
    }

    /// My held lines as Claude should see them now: cleaned against their
    /// lines so far, and left out if they're nothing but echo.
    private func pendingMine() -> [Utterance] {
        heldMine.compactMap { echoFilter.clean($0.utterance, against: store.utterances) }
    }

    /// Filters and records my held lines once they've waited long enough
    /// (or all of them, when stopping).
    private func releaseHeldLines(all: Bool = false) {
        let now = Date()
        let ready = heldMine.filter { all || $0.heldAt + Self.echoHold <= now }
        guard !ready.isEmpty else { return }
        heldMine.removeAll { held in ready.contains { $0.utterance.id == held.utterance.id } }
        for (utterance, _) in ready {
            if let cleaned = echoFilter.clean(utterance, against: store.utterances) {
                if cleaned.text != utterance.text {
                    Log.session.info("echo trimmed: \"\(utterance.text, privacy: .private)\" -> \"\(cleaned.text, privacy: .private)\"")
                }
                commit(cleaned)
            } else {
                Log.session.info("echo dropped: \"\(utterance.text, privacy: .private)\"")
            }
        }
    }

    private func commit(_ utterance: Utterance) {
        store.append(utterance)
        do {
            try writer?.append(utterance)
        } catch {
            Log.session.error("couldn't write to the transcript: \(error.localizedDescription, privacy: .public)")
        }
        answers.lineRecorded(utterance, transcript: store)
    }

    /// Adds a finished answer to the call file (answers given outside a call
    /// aren't saved).
    private func save(_ answer: Answer) {
        do {
            try writer?.append(answer)
        } catch {
            Log.session.error("couldn't write an answer to the transcript: \(error.localizedDescription, privacy: .public)")
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
