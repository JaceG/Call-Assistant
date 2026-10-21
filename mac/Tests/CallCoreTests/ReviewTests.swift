@testable import CallCore
import Foundation
import os
import Testing

/// Replies with a fixed review and keeps the prompts.
final class FakeReviewer: StructuredProvider, Sendable {
    let reply: SessionReview
    private let received = OSAllocatedUnfairLock(initialState: [AnswerPrompt]())

    init(_ reply: SessionReview) {
        self.reply = reply
    }

    var prompts: [AnswerPrompt] { received.withLock { $0 } }

    func json(_ prompt: AnswerPrompt, schema: Data) async throws -> Data {
        received.withLock { $0.append(prompt) }
        return Data(reply.json().utf8)
    }
}

@MainActor
struct ReviewTests {
    static let t0 = Date(timeIntervalSince1970: 1_792_505_600)
    static let utc = TimeZone(identifier: "UTC")!

    static let review = SessionReview(
        observations: ["Shorter was pressed after most answers."],
        instructions: [.init(text: "Keep the longer answer to two sentences.", reason: "Shorter pressed 4 times.")],
        quickActions: [.init(name: "Stat", prompt: "Give me one number I can quote.", reason: "Typed twice.")],
        features: [.init(title: "Answer length setting", description: "A slider for answer length.", reason: "Shorter pressed 4 times.")]
    )

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func inbox(_ provider: FakeReviewer) throws -> (ReviewInbox, URL, UserDefaults) {
        let folder = try folder()
        let defaults = try #require(UserDefaults(suiteName: "ReviewTests-\(UUID().uuidString)"))
        let inbox = ReviewInbox(
            reviewer: SessionReviewer(provider: provider, timeZone: utc),
            log: LearningLog(file: folder.appendingPathComponent("Learning.md"),
                             featureIdeasFile: folder.appendingPathComponent("Feature Ideas.md"), timeZone: utc),
            always: AlwaysInstructions(file: folder.appendingPathComponent("Always.md")),
            defaults: defaults
        )
        return (inbox, folder, defaults)
    }

    static func line(_ speaker: Speaker, _ text: String, at seconds: TimeInterval) -> Utterance {
        Utterance(speaker: speaker, text: text, start: t0 + seconds, end: t0 + seconds + 1)
    }

    static func answer(_ trigger: Answer.Trigger, _ question: String, _ text: String, at seconds: TimeInterval) -> Answer {
        Answer(trigger: trigger, question: question, askedAt: t0 + seconds, text: text, state: .done)
    }

    // MARK: The prompt

    @Test func theCallReadsInTimeOrderWithHowEachReplyWasAsked() {
        let reviewer = SessionReviewer(provider: FakeReviewer(Self.review), timeZone: Self.utc)
        let text = reviewer.transcript(
            lines: [Self.line(.them, "How do you cache?", at: 0), Self.line(.me, "At the edge.", at: 20)],
            answers: [
                Self.answer(.auto, "How do you cache?", "I cache at the edge.\n\nThen invalidate.", at: 3),
                Self.answer(.quick, "Make that shorter.", "Edge cache.", at: 10),
            ]
        )
        #expect(text == """
            [14:13:20] Them: How do you cache?
            [14:13:23] Claude (Auto, for \u{201C}How do you cache?\u{201D}): I cache at the edge. Then invalidate.
            [14:13:30] Claude (Quick: \u{201C}Make that shorter.\u{201D}): Edge cache.
            [14:13:40] Me: At the edge.
            """)
    }

    @Test func thePromptCarriesAlwaysButtonsAndTheLog() {
        let reviewer = SessionReviewer(provider: FakeReviewer(Self.review), timeZone: Self.utc)
        let prompt = reviewer.prompt(lines: [], answers: [], always: "Be brief.", quickActions: QuickAction.starters,
                                     learningLog: "- Skipped instruction: Use bullets.")
        #expect(prompt.system.first?.text == SessionReviewer.instructions)
        let context = prompt.transcript[0].text
        #expect(context.contains("His Always instructions now:\nBe brief."))
        #expect(context.contains("- Shorter: Make that shorter."))
        #expect(context.contains("- Skipped instruction: Use bullets."))
    }

    @Test func aCallWithTooLittleInItIsNotReviewed() async throws {
        let provider = FakeReviewer(Self.review)
        let (inbox, _, _) = try Self.inbox(provider)
        await inbox.review(call: "short call", lines: [Self.line(.them, "Hi.", at: 0)], answers: [])
        #expect(provider.prompts.isEmpty)
        #expect(inbox.review == nil)
    }

    // MARK: Choices

    @Test func addingAnInstructionAppendsItToAlwaysAndLogsIt() async throws {
        let (inbox, folder, _) = try Self.inbox(FakeReviewer(Self.review))
        var always: String?
        inbox.onAlwaysChanged = { always = $0 }
        await inbox.review(call: "2026-10-21 0954 call", lines: [], answers: [Self.answer(.quick, "Make that shorter.", "Short.", at: 0)])
        #expect(inbox.waiting == 3)
        inbox.add(Self.review.instructions[0])
        #expect(always == "Keep the longer answer to two sentences.")
        #expect(inbox.waiting == 2)
        let log = try String(contentsOf: folder.appendingPathComponent("Learning.md"), encoding: .utf8)
        #expect(log.contains("2026-10-21 0954 call"))
        #expect(log.contains("- Instruction: Keep the longer answer to two sentences. (Shorter pressed 4 times.)"))
        #expect(log.hasSuffix("- Added instruction: Keep the longer answer to two sentences.\n"))
    }

    @Test func addingAQuickActionPutsAButtonInTheRow() async throws {
        let (inbox, _, defaults) = try Self.inbox(FakeReviewer(Self.review))
        await inbox.review(call: "call", lines: [], answers: [Self.answer(.typed, "Give me a number", "42.", at: 0)])
        inbox.add(Self.review.quickActions[0])
        let actions = QuickAction.decode(defaults.string(forKey: QuickAction.storageKey) ?? "")
        #expect(actions.map(\.name) == ["Shorter", "Simpler", "Example", "Ask them", "Recap", "Stat"])
    }

    @Test func keepingAFeatureIdeaWritesItForADeveloperAndSkippingTheRestCloses() async throws {
        let (inbox, folder, _) = try Self.inbox(FakeReviewer(Self.review))
        await inbox.review(call: "call", lines: [], answers: [Self.answer(.typed, "Q", "A.", at: 0)])
        inbox.keep(Self.review.features[0])
        let ideas = try String(contentsOf: folder.appendingPathComponent("Feature Ideas.md"), encoding: .utf8)
        #expect(ideas.contains("## Answer length setting"))
        #expect(ideas.contains("A slider for answer length."))
        inbox.skipAll()
        #expect(inbox.review == nil)
        let log = try String(contentsOf: folder.appendingPathComponent("Learning.md"), encoding: .utf8)
        #expect(log.contains("- Skipped instruction: Keep the longer answer to two sentences."))
        #expect(log.contains("- Skipped quick action Stat: Give me one number I can quote."))
        #expect(log.contains("- Kept feature idea: Answer length setting"))
    }

    @Test func theSchemaAndJSONUseTheSameKeys() throws {
        #expect(try SessionReview.decode(Data(Self.review.json().utf8)) == Self.review)
        #expect(Self.review.json().contains("\"quick_actions\""))
    }
}
