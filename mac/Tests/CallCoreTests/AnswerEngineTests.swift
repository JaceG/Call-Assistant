import CallCore
import Foundation
import os
import Testing

/// Plays back scripted answer events, one every `step`, and remembers the
/// prompts it was given.
final class FakeProvider: AnswerProvider, Sendable {
    let events: [AnswerEvent]
    let failure: AnswerError?
    let step: Duration
    private let received = OSAllocatedUnfairLock(initialState: [AnswerPrompt]())

    init(_ events: [AnswerEvent] = FakeProvider.reply, failure: AnswerError? = nil, step: Duration = .milliseconds(10)) {
        self.events = events
        self.failure = failure
        self.step = step
    }

    static let reply: [AnswerEvent] = [.text("Short "), .text("answer."), .finished(stopReason: "end_turn", usage: Usage())]

    var prompts: [AnswerPrompt] { received.withLock { $0 } }

    func answer(_ prompt: AnswerPrompt) -> AsyncThrowingStream<AnswerEvent, Error> {
        received.withLock { $0.append(prompt) }
        let events = events, failure = failure, step = step
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for event in events {
                        try await Task.sleep(for: step)
                        continuation.yield(event)
                    }
                    if let failure { throw failure }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
struct AnswerEngineTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_505_600)
    static let question = "Can you walk me through how you would cache API responses?"

    static func line(_ speaker: Speaker, _ text: String, at seconds: TimeInterval = 0) -> Utterance {
        Utterance(speaker: speaker, text: text, start: t0 + seconds, end: t0 + seconds + 2)
    }

    /// Waits until `condition` holds, up to a second.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static func slowReply(_ pieces: Int = 20) -> [AnswerEvent] {
        Array(repeating: AnswerEvent.text("word "), count: pieces) + [.finished(stopReason: "end_turn", usage: Usage())]
    }

    @Test func whatClaudeLooksUpShowsUntilTheTextStarts() async {
        let provider = FakeProvider([.lookingUp("Reading Site/a.js…"), .text("Answer."), .finished(stopReason: "end_turn", usage: Usage())],
                                    step: .milliseconds(100))
        let engine = AnswerEngine(provider: provider)
        engine.ask("How did you build it?", transcript: TranscriptStore())
        #expect(await Self.eventually { engine.answers.first?.activity == "Reading Site/a.js…" })
        #expect(await Self.eventually { engine.answers.first?.state == .done })
        #expect(engine.answers.first?.activity == nil)
        #expect(engine.answers.first?.lookups == ["Reading Site/a.js…"])
    }

    @Test func thePickedFilesGoWithEveryAnswer() async {
        let provider = FakeProvider()
        let engine = AnswerEngine(provider: provider)
        engine.files = CallFiles(files: [ContextFile(path: "Notes/resume.md", text: "Eight years of Swift.")], skipped: [])
        engine.ask("What's my background?", transcript: TranscriptStore())
        #expect(await Self.eventually { engine.answers.first?.state == .done })
        #expect(provider.prompts.first?.system.contains { $0.text.contains("Eight years of Swift.") } == true)
    }

    @Test func laterAnswersSeeEarlierOnes() async {
        let provider = FakeProvider()
        let engine = AnswerEngine(provider: provider)
        let transcript = TranscriptStore()
        engine.ask("What is a mutex?", transcript: transcript)
        #expect(await Self.eventually { engine.answers.first?.state == .done })
        engine.ask("Make that shorter", transcript: transcript)
        #expect(await Self.eventually { provider.prompts.count == 2 })
        let seen = provider.prompts[1].transcript.map(\.text).joined(separator: "\n")
        #expect(seen.contains("Jace asked Claude: What is a mutex?"))
        #expect(seen.contains("Claude, to Jace only: Short answer."))
    }

    @Test func aFailedAnswerIsLeftOut() async {
        let provider = FakeProvider([.text("Partial ")], failure: .overloaded)
        let engine = AnswerEngine(provider: provider)
        let transcript = TranscriptStore()
        engine.ask("What is a mutex?", transcript: transcript)
        #expect(await Self.eventually { engine.answers.first?.state == .failed(AnswerError.overloaded.localizedDescription) })
        engine.ask("Again?", transcript: transcript)
        #expect(await Self.eventually { provider.prompts.count == 2 })
        #expect(!provider.prompts[1].transcript.contains { $0.text.contains("Claude,") })
    }

    @Test func aQuickActionIsAskedLikeATypedQuestionAndLabelledQuick() async {
        let provider = FakeProvider()
        let engine = AnswerEngine(provider: provider)
        let transcript = TranscriptStore()
        engine.ask("What is a mutex?", transcript: transcript)
        #expect(await Self.eventually { engine.answers.first?.state == .done })
        engine.quickAction(QuickAction(name: "Shorter", prompt: "Make that shorter."), transcript: transcript)
        #expect(await Self.eventually { engine.answers.count == 2 && engine.answers[1].state == .done })
        #expect(engine.answers[1].trigger == .quick)
        #expect(engine.answers[1].question == "Make that shorter.")
        #expect(provider.prompts[1].question == "Make that shorter.")
        #expect(provider.prompts[1].transcript.last?.text.contains("Claude, to Jace only: Short answer.") == true)
    }

    @Test func aQuickActionStopsAnAnswerStillStreaming() async {
        let engine = AnswerEngine(provider: FakeProvider(Self.slowReply()))
        let transcript = TranscriptStore()
        engine.ask("Tell me about caching", transcript: transcript)
        #expect(await Self.eventually { engine.answers.first?.state == .streaming })
        engine.quickAction(QuickAction.starters[0], transcript: transcript)
        #expect(engine.answers.first?.state == .stopped)
        #expect(engine.answers.count == 2)
    }

    @Test func myLinesStillHeldForTheEchoCheckAreInThePrompt() async {
        let provider = FakeProvider()
        let engine = AnswerEngine(provider: provider)
        let transcript = TranscriptStore()
        engine.lineRecorded(Self.line(.them, "How would you cache API responses?"), transcript: transcript)
        engine.pendingMine = { [Self.line(.me, "In production or in tests?", at: 5)] }
        engine.answerNow(transcript: transcript)
        #expect(await Self.eventually { provider.prompts.count == 1 })
        #expect(provider.prompts[0].transcript.last?.text.hasSuffix("Me: In production or in tests?") == true)
    }

    @Test func autoAnswerWaitsForThemToPauseThenAnswers() async {
        let engine = AnswerEngine(provider: FakeProvider(), pause: .milliseconds(150))
        let transcript = TranscriptStore()
        engine.autoAnswer = true
        engine.lineRecorded(Self.line(.them, Self.question), transcript: transcript)
        transcript.setPartial("and also how you", for: .them)   // still talking
        try? await Task.sleep(for: .milliseconds(300))
        #expect(engine.answers.isEmpty)

        transcript.setPartial("", for: .them)                   // stopped
        #expect(await Self.eventually { engine.answers.first?.state == .done })
        #expect(engine.answers.count == 1)
        #expect(engine.answers[0].trigger == .auto)
        #expect(engine.answers[0].question == Self.question)
        #expect(engine.answers[0].text == "Short answer.")
        #expect(engine.answers[0].firstTextAfter != nil)
    }

    @Test func withAutoAnswerOffNothingIsAnswered() async {
        let engine = AnswerEngine(provider: FakeProvider(), pause: .milliseconds(20))
        engine.lineRecorded(Self.line(.them, Self.question), transcript: TranscriptStore())
        try? await Task.sleep(for: .milliseconds(150))
        #expect(engine.answers.isEmpty)
    }

    @Test func answerNowStopsAStreamingAnswerAndKeepsItsText() async {
        let provider = FakeProvider(Self.slowReply(), step: .milliseconds(30))
        let engine = AnswerEngine(provider: provider, pause: .milliseconds(20))
        let transcript = TranscriptStore()
        engine.autoAnswer = true
        engine.lineRecorded(Self.line(.them, Self.question), transcript: transcript)
        #expect(await Self.eventually { engine.answers.first?.state == .streaming })

        engine.answerNow(transcript: transcript)
        #expect(engine.answers.count == 2)
        #expect(engine.answers[0].state == .stopped)
        #expect(engine.answers[0].text.hasPrefix("word"))
        #expect(engine.answers[1].trigger == .answerNow)
        #expect(engine.answers[1].question == Self.question)    // what they last said
        #expect(await Self.eventually { engine.answers[1].state == .done })
        #expect(engine.answers[0].state == .stopped)
    }

    @Test func aQuestionSpottedWhileBusyWaitsAndOnlyTheNewestRuns() async {
        let provider = FakeProvider(Self.slowReply(10), step: .milliseconds(30))
        let engine = AnswerEngine(provider: provider, pause: .milliseconds(20))
        let transcript = TranscriptStore()
        engine.autoAnswer = true
        engine.ask("What is a mutex?", transcript: transcript)
        engine.lineRecorded(Self.line(.them, "How big was the team at the time?", at: 1), transcript: transcript)
        try? await Task.sleep(for: .milliseconds(60))
        engine.lineRecorded(Self.line(.them, "And how did you split the work between you?", at: 4), transcript: transcript)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(engine.answers.count == 1)                       // still busy with the typed one

        #expect(await Self.eventually { engine.answers.count == 2 })
        #expect(engine.answers[0].state == .done)
        #expect(engine.answers[1].trigger == .auto)
        #expect(engine.answers[1].question == "And how did you split the work between you?")
        #expect(await Self.eventually { engine.answers[1].state == .done })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.answers.count == 2)
    }

    @Test func aTypedQuestionWorksWithNoCall() async {
        let provider = FakeProvider()
        let engine = AnswerEngine(provider: provider)
        engine.ask("  What is a mutex?  ", transcript: TranscriptStore())
        #expect(await Self.eventually { engine.answers.first?.state == .done })
        #expect(engine.answers[0].trigger == .typed)
        #expect(engine.answers[0].question == "What is a mutex?")
        #expect(provider.prompts.first?.transcript.isEmpty == true)
        #expect(provider.prompts.first?.question == "What is a mutex?")
    }

    @Test func aBlankTypedQuestionIsIgnored() {
        let engine = AnswerEngine(provider: FakeProvider())
        engine.ask("   ", transcript: TranscriptStore())
        #expect(engine.answers.isEmpty)
    }

    @Test func theCallsLinesPlaybookAndNotesReachThePrompt() async {
        let provider = FakeProvider()
        let engine = AnswerEngine(provider: provider)
        let transcript = TranscriptStore()
        engine.playbook = Playbook(name: "Interview", instructions: "Answer as a senior iOS developer.")
        engine.callNotes = "Call with Dana."
        engine.lineRecorded(Self.line(.them, "We mostly ship weekly."), transcript: transcript)
        engine.ask("What should I ask about their releases?", transcript: transcript)
        #expect(await Self.eventually { engine.answers.first?.state == .done })
        let prompt = provider.prompts[0]
        #expect(prompt.system.map(\.text).contains("# Playbook: Interview\n\nAnswer as a senior iOS developer."))
        #expect(prompt.system.map(\.text).contains("# Notes for this call\n\nCall with Dana."))
        #expect(prompt.transcript.first?.text.contains("Them: We mostly ship weekly.") == true)
    }

    @Test func failuresAndDeclinesShowOnTheAnswer() async {
        let failing = AnswerEngine(provider: FakeProvider([], failure: .keyRejected))
        failing.ask("What is a mutex?", transcript: TranscriptStore())
        #expect(await Self.eventually { failing.answers.first?.state == .failed("Claude rejected the API key.") })

        let declining = AnswerEngine(provider: FakeProvider([.declined(category: "cyber")]))
        declining.ask("What is a mutex?", transcript: TranscriptStore())
        #expect(await Self.eventually { declining.answers.first?.state == .declined })
    }

    @Test func eachAnswerIsHandedOnWhenItEnds() async {
        let engine = AnswerEngine(provider: FakeProvider())
        var finished: [Answer] = []
        engine.onFinished = { finished.append($0) }
        engine.ask("What is a mutex?", transcript: TranscriptStore())
        #expect(await Self.eventually { finished.count == 1 })
        #expect(finished[0].state == .done)
        #expect(finished[0].text == "Short answer.")
    }

    @Test func resetClearsTheListForANewCall() async {
        let engine = AnswerEngine(provider: FakeProvider())
        engine.ask("What is a mutex?", transcript: TranscriptStore())
        #expect(await Self.eventually { engine.answers.first?.state == .done })
        engine.reset()
        #expect(engine.answers.isEmpty)
    }
}
