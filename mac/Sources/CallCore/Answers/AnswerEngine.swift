import Foundation
import Observation

/// One answer from Claude: what prompted it, the text as it streams in, and
/// how it ended.
public struct Answer: Identifiable, Sendable, Equatable {
    public enum Trigger: String, Sendable {
        /// Auto-Answer spotted a question in what they said.
        case auto
        /// The Answer Now button or the hotkey.
        case answerNow
        /// A question Jace typed.
        case typed

        /// Its name, the same in the window and the call file.
        public var label: String {
            switch self {
            case .auto: "Auto"
            case .answerNow: "Answer Now"
            case .typed: "Typed"
            }
        }
    }

    public enum State: Sendable, Equatable {
        case waiting
        case streaming
        case done
        /// Cut short by a newer request; the text so far is kept.
        case stopped
        case failed(String)
        case declined

        public var isFinished: Bool {
            switch self {
            case .waiting, .streaming: false
            case .done, .stopped, .failed, .declined: true
            }
        }
    }

    public let id: UUID
    public let trigger: Trigger
    /// What was asked, as shown: the question spotted, what they last said, or what Jace typed.
    public let question: String
    public let askedAt: Date
    public var text: String
    public var state: State
    /// Seconds from the request to the first piece of text.
    public var firstTextAfter: TimeInterval?
    /// What Claude is looking up in the files before it answers
    /// ("Reading …"); nil once the answer's text starts.
    public var activity: String?
    /// The files Claude searched or read for this answer, in order.
    public var lookups: [String]

    public init(id: UUID = UUID(), trigger: Trigger, question: String, askedAt: Date,
                text: String = "", state: State = .waiting, firstTextAfter: TimeInterval? = nil,
                activity: String? = nil, lookups: [String] = []) {
        self.id = id
        self.trigger = trigger
        self.question = question
        self.askedAt = askedAt
        self.text = text
        self.state = state
        self.firstTextAfter = firstTextAfter
        self.activity = activity
        self.lookups = lookups
    }
}

/// Turns the three triggers into answers, one at a time:
/// - Auto-Answer: a question spotted in their line is answered once they've
///   paused, so a question spoken over two lines is finished first.
/// - Answer Now and typed questions start at once, stopping an answer that's
///   still streaming (its text is kept).
/// - A question spotted while an answer streams waits for it; only the newest
///   waiting question is kept.
@MainActor
@Observable
public final class AnswerEngine {
    public private(set) var answers: [Answer] = []
    public var autoAnswer = false
    public var playbook: Playbook?
    public var callNotes = ""
    /// The folders and files picked for the call, read as text.
    public var files = CallFiles.none
    /// Called once for each answer when it ends, however it ends.
    @ObservationIgnored public var onFinished: ((Answer) -> Void)?

    @ObservationIgnored private let provider: AnswerProvider
    @ObservationIgnored private let detector: QuestionDetector
    @ObservationIgnored private let pause: Duration
    /// The call's lines in the order they were recorded (see PromptBuilder).
    @ObservationIgnored private var lines: [Utterance] = []
    @ObservationIgnored private var current: (id: UUID, task: Task<Void, Never>)?
    /// A spotted question waiting for them to pause.
    @ObservationIgnored private var spotted: String?
    @ObservationIgnored private var spotter: Task<Void, Never>?
    /// A spotted question waiting for the current answer to end.
    @ObservationIgnored private var queued: String?
    @ObservationIgnored private weak var transcript: TranscriptStore?

    public init(provider: AnswerProvider, detector: QuestionDetector = QuestionDetector(), pause: Duration = .milliseconds(1500)) {
        self.provider = provider
        self.detector = detector
        self.pause = pause
    }

    public var isAnswering: Bool { current != nil }

    /// A finished line of the call. Auto-Answer looks for a question in it.
    public func lineRecorded(_ line: Utterance, transcript: TranscriptStore) {
        self.transcript = transcript
        lines.append(line)
        guard autoAnswer, let question = detector.question(in: line) else { return }
        spotted = spotted.map { "\($0) \(question)" } ?? question
        watchForPause()
    }

    /// Answers what they just said, now.
    public func answerNow(transcript: TranscriptStore) {
        self.transcript = transcript
        let saying = transcript.partial[.them].flatMap { $0.isEmpty ? nil : $0 }
        let said = saying ?? lines.last { $0.speaker == .them }?.text ?? "What they just said"
        startNow(.answerNow, shown: said, trigger: .answerNow)
    }

    /// Answers a typed question, now. Works with no call running.
    public func ask(_ text: String, transcript: TranscriptStore) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        self.transcript = transcript
        startNow(.typed(question), shown: question, trigger: .typed)
    }

    /// Stops the answer that's streaming, keeping its text.
    public func stop() {
        guard let current else { return }
        self.current = nil
        current.task.cancel()
        end(current.id, as: .stopped)
    }

    /// For the end of a call: drops waiting questions, gives the current answer
    /// up to `limit` to finish, then stops it.
    public func finishCurrent(within limit: Duration) async {
        cancelWaiting()
        let deadline = ContinuousClock.now + limit
        while current != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        stop()
    }

    /// A new call: forgets the lines and clears the answers.
    public func reset() {
        cancelWaiting()
        current?.task.cancel()
        current = nil
        answers = []
        lines = []
    }

    // MARK: Running answers

    private var promptBuilder: PromptBuilder {
        PromptBuilder(playbook: playbook, callNotes: callNotes, files: files)
    }

    /// Caches the instructions and files before the first question, so it's
    /// answered as quickly as later ones. A failure only costs that speed.
    public func warm() async {
        guard !files.isEmpty else { return }
        let prompt = promptBuilder.prompt(lines: lines, themSaying: nil, question: .typed(LiveSession.warmQuestion))
        do {
            let usage = try await provider.warm(prompt)
            Log.session.info("warmed the cache: \(usage.cacheWriteTokens) written, \(usage.cacheReadTokens) read")
        } catch {
            Log.session.error("couldn't warm the cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startNow(_ question: Question, shown: String, trigger: Answer.Trigger) {
        cancelWaiting()
        stop()
        start(question, shown: shown, trigger: trigger)
    }

    private func cancelWaiting() {
        spotter?.cancel()
        spotter = nil
        spotted = nil
        queued = nil
    }

    /// Waits until they've said nothing for `pause`, then answers the
    /// spotted question (or queues it behind the current answer).
    private func watchForPause() {
        spotter?.cancel()
        let pause = pause
        let step = min(pause / 5, .milliseconds(250))
        spotter = Task { [weak self] in
            var quietSince = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                guard let self, !Task.isCancelled else { return }
                if let saying = self.transcript?.partial[.them], !saying.isEmpty {
                    quietSince = .now
                } else if ContinuousClock.now - quietSince >= pause {
                    self.answerSpotted()
                    return
                }
            }
        }
    }

    private func answerSpotted() {
        spotter = nil
        guard let question = spotted else { return }
        spotted = nil
        if current != nil {
            queued = question
        } else {
            start(.detected(question), shown: question, trigger: .auto)
        }
    }

    private func start(_ question: Question, shown: String, trigger: Answer.Trigger) {
        let prompt = promptBuilder.prompt(lines: lines, themSaying: transcript?.partial[.them], question: question)
        let answer = Answer(trigger: trigger, question: shown, askedAt: Date())
        answers.append(answer)
        let id = answer.id
        let stream = provider.answer(prompt)
        let started = ContinuousClock.now
        let task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    self?.receive(event, for: id, started: started)
                }
                guard !Task.isCancelled else { return }
                self?.end(id, as: .done)
            } catch {
                guard !Task.isCancelled else { return }
                self?.end(id, as: .failed(error.localizedDescription))
            }
        }
        current = (id, task)
    }

    private func receive(_ event: AnswerEvent, for id: UUID, started: ContinuousClock.Instant) {
        guard let index = answers.firstIndex(where: { $0.id == id }), !answers[index].state.isFinished else { return }
        switch event {
        case .text(let piece):
            if answers[index].firstTextAfter == nil {
                let elapsed = (ContinuousClock.now - started).components
                answers[index].firstTextAfter = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            }
            answers[index].text += piece
            answers[index].activity = nil
            answers[index].state = .streaming
        case .lookingUp(let activity):
            answers[index].activity = activity
            answers[index].lookups.append(activity)
        case .finished:
            end(id, as: .done)
        case .declined:
            end(id, as: .declined)
        }
    }

    /// Records how an answer ended, hands it on, and starts a waiting question.
    private func end(_ id: UUID, as state: Answer.State) {
        guard let index = answers.firstIndex(where: { $0.id == id }), !answers[index].state.isFinished else { return }
        answers[index].state = state
        if current?.id == id { current = nil }
        onFinished?(answers[index])
        if current == nil, let question = queued {
            queued = nil
            start(.detected(question), shown: question, trigger: .auto)
        }
    }
}
