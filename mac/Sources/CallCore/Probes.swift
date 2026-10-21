@preconcurrency import AVFoundation
import Accelerate
import Foundation
import os

/// Command-line checks the app runs in place of its window, for testing each
/// layer without the UI. Launch through `open` so macOS asks for permissions
/// on behalf of Call Assistant, not the shell:
///
///     open mac/dist/CallAssistant.app --stdout /tmp/ca.log --stderr /tmp/ca.log --args --probe-audio 15
public enum Probes {
    /// The probe named in the launch arguments, if any.
    public static func requested(in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix("--probe-") }
    }

    /// Runs the probe named in `arguments` and returns its exit code.
    public static func run(_ arguments: [String]) async -> Int32 {
        setlinebuf(stdout)
        guard let flag = requested(in: arguments) else { return 64 }
        let value = arguments.drop { $0 != flag }.dropFirst().first
        switch flag {
        case "--probe-audio":
            return await audio(seconds: value.flatMap(Int.init) ?? 15, echoCancellation: arguments.contains("--apple-voice-processing"))
        case "--probe-live":
            return await live(
                seconds: value.flatMap(Int.init) ?? 30,
                cancelEcho: !arguments.contains("--no-echo-canceller"),
                appleVoiceProcessing: arguments.contains("--apple-voice-processing"),
                filterEcho: !arguments.contains("--no-echo-filter"),
                autoAnswer: arguments.contains("--auto-answer")
            )
        case "--probe-transcribe":
            guard let value else {
                print("Usage: --probe-transcribe <audio file>")
                return 64
            }
            return await transcribe(file: URL(fileURLWithPath: value))
        case "--probe-answer":
            guard let value else {
                print("Usage: --probe-answer \"<question>\" [--effort low|medium|high] [--thinking-off] [--runs N] [--transcript <call.md>] [--playbook <name>] [--notes \"<text>\"] [--files <folder or file>]... [--warm] [--detected | --answer-now]")
                return 64
            }
            func option(_ name: String) -> String? { arguments.drop { $0 != name }.dropFirst().first }
            return await answer(
                question: value,
                effort: option("--effort") ?? "low",
                thinkingOff: arguments.contains("--thinking-off"),
                runs: option("--runs").flatMap(Int.init) ?? 1,
                transcript: option("--transcript").map { URL(fileURLWithPath: $0) },
                playbookName: option("--playbook"),
                notes: option("--notes") ?? "",
                files: arguments.indices.filter { arguments[$0] == "--files" && $0 + 1 < arguments.count }
                    .map { URL(fileURLWithPath: arguments[$0 + 1]) },
                warm: arguments.contains("--warm")
            )
        case "--probe-follow-up":
            let questions = arguments.drop { $0 != flag }.dropFirst().prefix { !$0.hasPrefix("--") }
            guard questions.count >= 2 else {
                print("Usage: --probe-follow-up \"<question>\" \"<follow-up>\"...")
                return 64
            }
            return await followUp(Array(questions))
        case "--probe-summary":
            guard let value, let text = try? String(contentsOf: URL(fileURLWithPath: value), encoding: .utf8) else {
                print("Usage: --probe-summary <call.md>")
                return 64
            }
            return await summary(of: text)
        case "--probe-files":
            let picks = arguments.drop { $0 != flag }.dropFirst().prefix { !$0.hasPrefix("--") }
            guard !picks.isEmpty else {
                print("Usage: --probe-files <folder or file>...")
                return 64
            }
            return await files(picks.map { URL(fileURLWithPath: $0) })
        case "--probe-detect":
            guard let value, let text = try? String(contentsOf: URL(fileURLWithPath: value), encoding: .utf8) else {
                print("Usage: --probe-detect <call.md>")
                return 64
            }
            return detect(in: text)
        default:
            print("Unknown probe \(flag)")
            return 64
        }
    }

    /// Captures the mic and the system audio for `seconds`, printing frames and
    /// peak level once a second. Returns 0 only if both channels delivered frames
    /// with sound in them.
    static func audio(seconds: Int, echoCancellation: Bool = false) async -> Int32 {
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        print("microphone permission: \(micAllowed ? "granted" : "denied")")
        print("echo cancellation: \(echoCancellation ? "on" : "off")")

        let mic = MicCapture()
        let system = SystemAudioCapture()
        let micStats = ChannelStats()
        let systemStats = ChannelStats()

        let micStream = mic.bufferStream(echoCancellation: echoCancellation)
        let systemStream: AsyncStream<AVAudioPCMBuffer>
        do {
            systemStream = try await system.bufferStream().systemAudio
        } catch {
            print("system audio failed to start: \(error.localizedDescription)")
            mic.stop()
            return 2
        }

        let micTask = Task.detached { for await buffer in micStream { micStats.add(buffer) } }
        let systemTask = Task.detached { for await buffer in systemStream { systemStats.add(buffer) } }

        for second in 1...max(1, seconds) {
            try? await Task.sleep(for: .seconds(1))
            let m = micStats.takeInterval()
            let s = systemStats.takeInterval()
            print(String(format: "%3ds  mic frames=%6d peak=%.4f | system frames=%6d peak=%.4f",
                         second, m.frames, m.peak, s.frames, s.peak)
                  + "  mic channels " + m.channelPeaks.map { String(format: "%.3f", $0) }.joined(separator: " "))
        }

        mic.stop()
        await system.stop()
        micTask.cancel()
        systemTask.cancel()

        let m = micStats.totals()
        let s = systemStats.totals()
        let pass = m.frames > 0 && m.peak > 0 && s.frames > 0 && s.peak > 0
        print(String(format: "RESULT mic frames=%d peak=%.4f | system frames=%d peak=%.4f => %@",
                     m.frames, m.peak, s.frames, s.peak, pass ? "PASS" : "FAIL"))
        if let error = mic.captureError { print("mic error: \(error)") }
        return pass ? 0 : 1
    }
}

extension Probes {
    /// Transcribes an audio file as if it were live audio (0.1 s buffers),
    /// printing partials (marked `~`) and final segments. Returns 0 if any
    /// final text came back.
    static func transcribe(file: URL) async -> Int32 {
        let transcriber = AppleSpeechTranscriber()
        let started = Date()
        do {
            try await transcriber.prepare(
                onStatus: { print($0) },
                onProgress: { print(String(format: "model download %.0f%%", $0 * 100)) }
            )
        } catch {
            print("prepare failed: \(error.localizedDescription)")
            return 2
        }
        print(String(format: "prepared in %.1f s", Date().timeIntervalSince(started)))

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: file)
        } catch {
            print("can't read \(file.path): \(error.localizedDescription)")
            return 2
        }
        let format = audioFile.processingFormat
        print("file: \(format.sampleRate) Hz, \(format.channelCount) ch, \(audioFile.length) frames")

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            let chunk = AVAudioFrameCount(format.sampleRate / 10)
            while let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                  (try? audioFile.read(into: buffer, frameCount: chunk)) != nil,
                  buffer.frameLength > 0 {
                continuation.yield(buffer)
            }
            // A second of silence after the speech, as a live call would have.
            if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                silence.frameLength = silence.frameCapacity
                for channel in 0..<Int(format.channelCount) {
                    silence.floatChannelData?[channel].update(repeating: 0, count: Int(silence.frameLength))
                }
                continuation.yield(silence)
            }
            continuation.finish()
        }

        let finals = OSAllocatedUnfairLock(initialState: [String]())
        let transcribeStarted = Date()
        do {
            try await transcriber.run(
                stream,
                onPartial: { if !$0.isEmpty { print("~ \($0)") } },
                onFinal: { segment in
                    finals.withLock { $0.append(segment.text) }
                    print(String(format: "FINAL [%.2f-%.2f s] %@",
                                 segment.start.timeIntervalSince(transcribeStarted),
                                 segment.end.timeIntervalSince(transcribeStarted), segment.text))
                }
            )
        } catch {
            print("transcription failed: \(error.localizedDescription)")
            return 1
        }
        let text = finals.withLock { $0 }.joined(separator: " ")
        print(String(format: "transcribed in %.1f s", Date().timeIntervalSince(transcribeStarted)))
        print("RESULT \(text.isEmpty ? "FAIL (no final text)" : "PASS"): \(text)")
        return text.isEmpty ? 1 : 0
    }
}

extension Probes {
    /// Runs a whole call without the window for `seconds`: both channels,
    /// transcribed and saved. Prints each finished utterance as it arrives.
    /// Returns 0 if both sides produced at least one.
    @MainActor
    static func live(seconds: Int, cancelEcho: Bool, appleVoiceProcessing: Bool, filterEcho: Bool, autoAnswer: Bool = false) async -> Int32 {
        let session = LiveSession()
        session.cancelEcho = cancelEcho
        session.appleVoiceProcessing = appleVoiceProcessing
        session.filterEcho = filterEcho
        session.answers.autoAnswer = autoAnswer
        if autoAnswer { print("Auto-Answer: on") }
        print("echo canceller (WebRTC): \(cancelEcho ? "on" : "off"), Apple voice processing: \(appleVoiceProcessing ? "on" : "off"), echo filter: \(filterEcho ? "on" : "off")")
        let clock = { (date: Date) in date.clockTime(in: .current) }
        await session.start()
        if case .failed(let message) = session.state {
            print("failed to start: \(message)")
            return 2
        }
        print("listening for \(seconds) s, transcript: \(session.sessionFile?.path ?? "-")")

        var printed = Set<UUID>()
        func printNew() {
            for utterance in session.store.utterances where !printed.contains(utterance.id) {
                printed.insert(utterance.id)
                print("[\(clock(utterance.start))] \(utterance.speaker.label): \(utterance.text)")
            }
            for answer in session.answers.answers where answer.state.isFinished && !printed.contains(answer.id) {
                printed.insert(answer.id)
                // How long after their line ended the first words appeared.
                let theirLine = session.store.utterances.last { $0.speaker == .them && $0.end <= answer.askedAt }
                let afterLine = answer.firstTextAfter.flatMap { first in
                    theirLine.map { answer.askedAt.timeIntervalSince($0.end) + first }
                }
                print(String(format: "[%@] Claude (%@, %@): first text %@ after the request, %@ after their line ended",
                             clock(answer.askedAt), answer.trigger.label, "\(answer.state)",
                             answer.firstTextAfter.map { String(format: "%.2f s", $0) } ?? "-",
                             afterLine.map { String(format: "%.2f s", $0) } ?? "-"))
                print("  asked: \(answer.question)")
                print("  answer: \(answer.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        let end = Date() + Double(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(250))
            printNew()
        }
        print("stopping…")
        await session.stop()
        printNew()

        let counts = Dictionary(grouping: session.store.utterances, by: \.speaker).mapValues(\.count)
        let me = counts[.me] ?? 0
        let them = counts[.them] ?? 0
        let lines = (try? String(contentsOf: session.sessionFile!, encoding: .utf8))?
            .split(separator: "\n").filter { $0.hasPrefix("**[") }.count ?? 0
        print("RESULT Me=\(me) Them=\(them), \(lines) lines in the file => \(me > 0 && them > 0 ? "PASS" : "FAIL")")
        return me > 0 && them > 0 ? 0 : 1
    }
}

/// Frame count and peak level of one audio channel, safe to update from the
/// capture thread and read from the probe.
private final class ChannelStats: Sendable {
    private struct Counts { var frames = 0; var peak: Float = 0; var channelPeaks: [Float] = [] }
    private let interval = OSAllocatedUnfairLock(initialState: Counts())
    private let total = OSAllocatedUnfairLock(initialState: Counts())

    func add(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let peaks = Self.channelPeaks(of: buffer)
        let peak = peaks.max() ?? 0
        for lock in [interval, total] {
            lock.withLock { counts in
                counts.frames += frames
                counts.peak = max(counts.peak, peak)
                if counts.channelPeaks.count < peaks.count {
                    counts.channelPeaks += Array(repeating: 0, count: peaks.count - counts.channelPeaks.count)
                }
                for (i, p) in peaks.enumerated() { counts.channelPeaks[i] = max(counts.channelPeaks[i], p) }
            }
        }
    }

    func takeInterval() -> (frames: Int, peak: Float, channelPeaks: [Float]) {
        interval.withLock { counts in
            defer { counts = Counts() }
            return (counts.frames, counts.peak, counts.channelPeaks)
        }
    }

    func totals() -> (frames: Int, peak: Float) {
        total.withLock { ($0.frames, $0.peak) }
    }

    /// Peak level per channel (one value for interleaved audio).
    private static func channelPeaks(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let format = buffer.format
        // Interleaved audio keeps every channel's samples in the first pointer.
        let pointers = format.isInterleaved ? 1 : Int(format.channelCount)
        let count = Int(buffer.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
        return (0..<pointers).map { i in
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[i], 1, &channelPeak, vDSP_Length(count))
            return channelPeak
        }
    }
}

extension Probes {
    /// Asks Claude `question` `runs` times and prints, for each run, how long
    /// the first piece of text took, the total time, the token counts and the
    /// answer. Never prints the key. Returns 0 if every run returned text.
    static func answer(
        question: String, effort: String, thinkingOff: Bool, runs: Int,
        transcript: URL? = nil, playbookName: String? = nil, notes: String = "",
        files picks: [URL] = [], warm: Bool = false
    ) async -> Int32 {
        // Read the key once, timed on its own, so a Keychain prompt doesn't
        // count toward the first run's answer time.
        let keyStarted = ContinuousClock.now
        let key: String
        do {
            key = try APIKeyStore.read()
        } catch {
            print("RESULT no key: \(error.localizedDescription)")
            return 2
        }
        print("key read from the Keychain in \(ContinuousClock.now - keyStarted)")
        let provider = ClaudeProvider(apiKey: { key }, effort: effort, thinkingOff: thinkingOff)
        var lines: [Utterance] = []
        if let transcript {
            guard let text = try? String(contentsOf: transcript, encoding: .utf8) else {
                print("Couldn't read \(transcript.path)")
                return 66
            }
            lines = transcriptLines(in: text)
            print("transcript: \(lines.count) lines from \(transcript.lastPathComponent)")
        }
        var playbook: Playbook?
        if let playbookName {
            playbook = (try? PlaybookLibrary().load())?.first { $0.name == playbookName }
            guard playbook != nil else {
                print("No playbook named \"\(playbookName)\" in \(Paths.playbooksDirectory.path)")
                return 66
            }
        }
        var files = CallFiles.none
        if !picks.isEmpty {
            files = await FileCollector().collect(picks)
            print("files: \(files.files.count), about \(files.estimatedTokens) tokens → \(files.mode == .whole ? "whole" : "look-up")")
        }
        let builder = PromptBuilder(playbook: playbook, callNotes: notes, files: files)
        let prompt = builder.prompt(lines: lines, themSaying: nil,
                                    question: CommandLine.arguments.contains("--answer-now") ? .answerNow
                                        : CommandLine.arguments.contains("--detected") ? .detected(question) : .typed(question))
        print("model \(ClaudeProvider.defaultModel), effort \(effort), thinking \(thinkingOff ? "between_tools (off)" : "adaptive")")
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        if warm {
            let started = ContinuousClock.now
            do {
                let usage = try await provider.warm(builder.prompt(lines: lines, themSaying: nil, question: .typed(LiveSession.warmQuestion)))
                print(String(format: "warm: %.2f s, tokens in %d, cache read %d write %d", seconds(ContinuousClock.now - started),
                             usage.inputTokens, usage.cacheReadTokens, usage.cacheWriteTokens))
            } catch {
                print("warm: ERROR \(error.localizedDescription)")
            }
        }
        var firstTextTimes: [Double] = []
        var failures = 0
        for run in 1...max(runs, 1) {
            let started = ContinuousClock.now
            var firstText: Duration?
            var text = ""
            var ending = "no ending"
            do {
                for try await event in provider.answer(prompt) {
                    switch event {
                    case .text(let piece):
                        if firstText == nil { firstText = ContinuousClock.now - started }
                        text += piece
                    case .lookingUp(let activity):
                        print(String(format: "  %.2f s: %@", seconds(ContinuousClock.now - started), activity))
                    case .finished(let stopReason, let usage):
                        ending = "stop \(stopReason), tokens in \(usage.inputTokens) out \(usage.outputTokens) cache read \(usage.cacheReadTokens) write \(usage.cacheWriteTokens)"
                    case .declined(let category):
                        ending = "DECLINED (\(category ?? "no category"))"
                    }
                }
            } catch {
                ending = "ERROR \(error.localizedDescription)"
            }
            let total = ContinuousClock.now - started
            if let firstText { firstTextTimes.append(seconds(firstText)) } else { failures += 1 }
            print(String(format: "run %d: first text %@, total %.2f s, %@", run,
                         firstText.map { String(format: "%.2f s", seconds($0)) } ?? "-", seconds(total), ending))
            print("  answer: \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        let sorted = firstTextTimes.sorted()
        if !sorted.isEmpty {
            print(String(format: "RESULT median first text %.2f s over %d runs (min %.2f, max %.2f)",
                         sorted[sorted.count / 2], sorted.count, sorted.first!, sorted.last!))
        }
        return failures == 0 ? 0 : 1
    }
}

extension Probes {
    /// The lines of a saved call file ("**[14:13:25] Them:** text"), dated
    /// today. Answers and other text in the file are skipped.
    static func transcriptLines(in text: String) -> [Utterance] {
        let pattern = /^\*\*\[(\d\d):(\d\d):(\d\d)\] (Me|Them):\*\* (.+)$/
        let today = Calendar.current.startOfDay(for: Date())
        return text.split(separator: "\n").compactMap { line -> Utterance? in
            guard let match = try? pattern.wholeMatch(in: String(line)),
                  let h = Double(match.1), let m = Double(match.2), let s = Double(match.3) else { return nil }
            let start = today + h * 3600 + m * 60 + s
            return Utterance(speaker: match.4 == "Me" ? .me : .them, text: String(match.5), start: start, end: start)
        }
    }
}

extension Probes {
    /// Replays a saved call through the question detector, with no API call,
    /// and prints each line Auto-Answer would answer.
    static func detect(in text: String) -> Int32 {
        let lines = transcriptLines(in: text)
        let detector = QuestionDetector()
        var picked = 0
        for line in lines {
            guard let question = detector.question(in: line) else { continue }
            picked += 1
            print("[\(line.start.clockTime())] would answer: \(question)")
        }
        let them = lines.filter { $0.speaker == .them }.count
        let marked = lines.filter { $0.speaker == .them && $0.text.contains("?") }.count
        print("RESULT \(picked) of \(them) Them lines picked (\(marked) contain \"?\"), \(lines.count) lines in all")
        return 0
    }
}

extension Probes {
    /// Reads the picked folders and files as a call would and prints what
    /// Claude would get: the counts, the size estimate, the mode, the largest
    /// files and what was skipped. Makes no API call.
    static func files(_ picks: [URL]) async -> Int32 {
        let started = ContinuousClock.now
        let files = await FileCollector().collect(picks)
        print("read in \(ContinuousClock.now - started)")
        print("\(files.files.count) files, \(files.byteCount) bytes of text, about \(files.estimatedTokens) tokens → \(files.mode == .whole ? "whole" : "look-up")")
        print("largest:")
        for file in files.files.sorted(by: { $0.text.utf8.count > $1.text.utf8.count }).prefix(10) {
            print("  \(file.text.utf8.count) \(file.path)")
        }
        let byReason = Dictionary(grouping: files.skipped, by: \.reason.label)
        print("skipped \(files.skipped.count):")
        for (reason, skipped) in byReason.sorted(by: { $0.key < $1.key }) {
            print("  \(skipped.count) \(reason): \(skipped.prefix(5).map(\.path).joined(separator: ", "))\(skipped.count > 5 ? ", …" : "")")
        }
        return files.isEmpty ? 1 : 0
    }
}

extension Probes {
    /// Types each question in turn, as Jace would in Ask Claude, waiting for
    /// each answer, so later questions can refer to earlier answers ("make
    /// that shorter"). Prints every answer.
    @MainActor
    static func followUp(_ questions: [String]) async -> Int32 {
        let key: String
        do {
            key = try APIKeyStore.read()
        } catch {
            print("RESULT no key: \(error.localizedDescription)")
            return 2
        }
        let engine = AnswerEngine(provider: ClaudeProvider(apiKey: { key }))
        let transcript = TranscriptStore()
        for question in questions {
            engine.ask(question, transcript: transcript)
            while engine.isAnswering { try? await Task.sleep(for: .milliseconds(100)) }
            let answer = engine.answers.last
            print("Q: \(question)")
            print("A (\(answer.map { "\($0.state)" } ?? "none")): \(answer?.text.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "")")
        }
        return engine.answers.allSatisfy { $0.state == .done } ? 0 : 1
    }
}

extension Probes {
    /// Summarizes the first 60% of a saved call, then the whole call building
    /// on that, as the live summary would a minute apart. Prints the times
    /// and both versions.
    @MainActor
    static func summary(of text: String) async -> Int32 {
        let key: String
        do {
            key = try APIKeyStore.read()
        } catch {
            print("RESULT no key: \(error.localizedDescription)")
            return 2
        }
        let lines = transcriptLines(in: text)
        let engine = SummaryEngine(provider: ClaudeProvider(apiKey: { key }))
        for part in [Array(lines.prefix(lines.count * 6 / 10)), lines] {
            let started = ContinuousClock.now
            await engine.update(lines: part)
            print("=== \(part.count) of \(lines.count) lines, \(ContinuousClock.now - started)")
            if let failure = engine.failure { print("FAILED: \(failure)"); return 1 }
            print(engine.shown?.summary.markdown(updatedAt: Date()) ?? "(none)")
        }
        return 0
    }
}

