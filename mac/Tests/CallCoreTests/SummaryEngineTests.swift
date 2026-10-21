@testable import CallCore
import Foundation
import os
import Testing

/// Replies with summaries numbered by request ("Version 1", "Version 2"…)
/// and keeps the prompts.
final class FakeSummarizer: StructuredProvider, Sendable {
    private let received = OSAllocatedUnfairLock(initialState: [AnswerPrompt]())
    let failure: AnswerError?

    init(failure: AnswerError? = nil) {
        self.failure = failure
    }

    var prompts: [AnswerPrompt] { received.withLock { $0 } }

    func json(_ prompt: AnswerPrompt, schema: Data) async throws -> Data {
        let count = received.withLock { $0.append(prompt); return $0.count }
        if let failure { throw failure }
        return Data(CallSummary(summary: "Version \(count)", keyPoints: ["Point \(count)"]).json().utf8)
    }
}

@MainActor
struct SummaryEngineTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_505_600)

    static func lines(_ count: Int) -> [Utterance] {
        (0..<count).map { Utterance(speaker: .them, text: "Line \($0).", start: t0 + Double($0), end: t0 + Double($0) + 1) }
    }

    @Test func nothingNewMeansNoRequest() async {
        let provider = FakeSummarizer()
        let engine = SummaryEngine(provider: provider)
        await engine.update(lines: [])
        await engine.update(lines: Self.lines(2))
        await engine.update(lines: Self.lines(2))
        #expect(provider.prompts.count == 1)
        #expect(engine.shown?.summary.summary == "Version 1")
    }

    @Test func laterVersionsBuildOnThePreviousOne() async {
        let provider = FakeSummarizer()
        let engine = SummaryEngine(provider: provider)
        await engine.update(lines: Self.lines(2))
        await engine.update(lines: Self.lines(3))
        #expect(provider.prompts[0].question == "Write the summary of the call so far.")
        #expect(provider.prompts[1].question.hasPrefix("The previous summary:\n{"))
        #expect(provider.prompts[1].question.contains("\"summary\":\"Version 1\""))
        #expect(provider.prompts[1].system.first?.text == SummaryEngine.instructions)
        #expect(provider.prompts[1].transcript.first?.text.contains("Line 2.") == true)
        #expect(engine.shown?.summary.summary == "Version 2")
    }

    @Test func whileHeldANewVersionWaitsUntilReleased() async {
        let engine = SummaryEngine(provider: FakeSummarizer())
        await engine.update(lines: Self.lines(1))
        engine.isHeld = true
        await engine.update(lines: Self.lines(2))
        #expect(engine.shown?.summary.summary == "Version 1")
        #expect(engine.pending?.summary.summary == "Version 2")
        #expect(engine.latest?.summary.summary == "Version 2")
        engine.isHeld = false
        #expect(engine.shown?.summary.summary == "Version 2")
        #expect(engine.pending == nil)
    }

    @Test func updateNowShowsTheWaitingVersionWhileStillHeld() async {
        let engine = SummaryEngine(provider: FakeSummarizer())
        await engine.update(lines: Self.lines(1))
        engine.isHeld = true
        await engine.update(lines: Self.lines(2))
        engine.applyPending()
        #expect(engine.shown?.summary.summary == "Version 2")
        #expect(engine.pending == nil)
    }

    @Test func theFirstVersionShowsEvenWhileHeld() async {
        let engine = SummaryEngine(provider: FakeSummarizer())
        engine.isHeld = true
        await engine.update(lines: Self.lines(1))
        #expect(engine.shown?.summary.summary == "Version 1")
    }

    @Test func checksOncePerIntervalAndOnlyWithNewLines() async throws {
        let provider = FakeSummarizer()
        let engine = SummaryEngine(provider: provider, interval: .milliseconds(100))
        var lines = Self.lines(1)
        engine.start { lines }
        try await Task.sleep(for: .milliseconds(250))
        #expect(provider.prompts.count == 1)   // two checks, one with new lines
        lines = Self.lines(3)
        try await Task.sleep(for: .milliseconds(150))
        #expect(provider.prompts.count == 2)
        await engine.finish()                  // nothing new since
        #expect(provider.prompts.count == 2)
    }

    @Test func finishCoversTheLastLines() async {
        let provider = FakeSummarizer()
        let engine = SummaryEngine(provider: provider, interval: .seconds(60))
        engine.start { Self.lines(4) }
        await engine.finish()
        #expect(provider.prompts.count == 1)
        #expect(engine.shown != nil)
    }

    @Test func eachNewVersionIsHandedOnAndAFailureIsKept() async {
        let engine = SummaryEngine(provider: FakeSummarizer())
        var handed: [String] = []
        engine.onUpdate = { summary, _ in handed.append(summary.summary) }
        await engine.update(lines: Self.lines(1))
        #expect(handed == ["Version 1"])

        let failing = SummaryEngine(provider: FakeSummarizer(failure: .overloaded))
        await failing.update(lines: Self.lines(1))
        #expect(failing.failure == AnswerError.overloaded.localizedDescription)
        #expect(failing.shown == nil)
    }

    @Test func markdownLeavesOutEmptySectionsAndEndsWithWhereNext() {
        let summary = CallSummary(
            summary: "An interview about Swift.",
            keyPoints: ["Optionals came up."],
            questions: [.init(askedBy: "Them", question: "How do optionals work?", answer: "Not answered yet")],
            quotes: [.init(speaker: "Them", time: "12:43:06", words: "Optionals are a keystone.")],
            actionItems: [.init(owner: "Jace", item: "Send the repo link.")],
            next: ["Explain the enum behind optionals."]
        )
        let markdown = summary.markdown(updatedAt: Self.t0, timeZone: TimeZone(identifier: "UTC")!)
        #expect(markdown == """
            # Call summary

            *Updated 14:13:20*

            An interview about Swift.

            ## Key points

            - Optionals came up.

            ## Questions and answers

            - **Them:** How do optionals work?
              - Not answered yet

            ## Quotes

            - \u{201C}Optionals are a keystone.\u{201D} (Them, 12:43:06)

            ## Action items

            - **Jace:** Send the repo link.

            ## Where this could go next

            - Explain the enum behind optionals.

            """)
    }

    @Test func theSchemaAndJSONUseTheSameKeys() throws {
        let summary = CallSummary(summary: "S", keyPoints: ["K"], namesAndNumbers: ["N"])
        #expect(try CallSummary.decode(Data(summary.json().utf8)) == summary)
        #expect(summary.json().contains("\"names_and_numbers\":[\"N\"]"))
        let schema = try #require(try JSONSerialization.jsonObject(with: CallSummary.schema) as? [String: Any])
        #expect((schema["required"] as? [String])?.contains("names_and_numbers") == true)
    }

    @Test func theVersionBeforeIsKeptToMarkWhatsNew() async {
        let engine = SummaryEngine(provider: FakeSummarizer())
        await engine.update(lines: Self.lines(1))
        #expect(engine.previous == nil)
        await engine.update(lines: Self.lines(2))
        #expect(engine.previous?.summary == "Version 1")
        engine.isHeld = true
        await engine.update(lines: Self.lines(3))
        #expect(engine.previous?.summary == "Version 1")   // still showing version 2
        engine.applyPending()
        #expect(engine.previous?.summary == "Version 2")
    }

    @Test func onlyItemsNotInThePreviousVersionAreNew() {
        let before = CallSummary(summary: "S", keyPoints: ["Kept", "Dropped"], actionItems: [.init(owner: "Jace", item: "Send it")])
        let after = CallSummary(summary: "S2", keyPoints: ["Kept", "Added"], actionItems: [.init(owner: "Them", item: "Send it")])
        #expect(!CallSummary.isNew("Kept", in: .keyPoints, since: before))
        #expect(CallSummary.isNew("Added", in: .keyPoints, since: before))
        #expect(CallSummary.isNew(after.summary, in: .summary, since: before))
        #expect(CallSummary.isNew(after.texts(.actionItems)[0], in: .actionItems, since: before))
        #expect(!CallSummary.isNew("Added", in: .keyPoints, since: nil))
    }

    @Test func finishWaitsForAnUpdateUnderWayThenCoversTheRest() async throws {
        let provider = SlowSummarizer()
        let engine = SummaryEngine(provider: provider, interval: .milliseconds(50))
        var lines = Self.lines(2)
        engine.start { lines }
        try await Task.sleep(for: .milliseconds(120))   // the first request is under way
        #expect(engine.isUpdating)
        lines = Self.lines(5)
        await engine.finish()
        #expect(engine.failure == nil)
        #expect(provider.count == 2)
        #expect(engine.shown?.summary.summary == "Version 2")
    }
}

/// Like FakeSummarizer, but each reply takes 200 ms.
final class SlowSummarizer: StructuredProvider, Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { calls.withLock { $0 } }

    func json(_ prompt: AnswerPrompt, schema: Data) async throws -> Data {
        let count = calls.withLock { $0 += 1; return $0 }
        try await Task.sleep(for: .milliseconds(200))
        return Data(CallSummary(summary: "Version \(count)").json().utf8)
    }
}

