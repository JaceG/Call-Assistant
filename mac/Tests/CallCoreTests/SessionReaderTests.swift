import CallCore
import Foundation
import Testing

/// Saved calls read back for Past Calls: what SessionWriter and the live
/// summary write comes back the same.
struct SessionReaderTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-21 10:05:00 UTC.
    static let started = Date(timeIntervalSince1970: 1_792_577_100)

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func line(_ speaker: Speaker, _ text: String, at seconds: TimeInterval) -> Utterance {
        Utterance(speaker: speaker, text: text, start: started + seconds, end: started + seconds)
    }

    static let summary = CallSummary(
        summary: "A recruiter call about a Swift role.",
        keyPoints: ["Remote is fine.", "Start in November."],
        questions: [.init(askedBy: "Them", question: "When can you start?", answer: "In two weeks.")],
        quotes: [.init(speaker: "Them", time: "10:05:20", words: "We move fast here.")],
        decisions: ["A second interview next week."],
        actionItems: [.init(owner: "Jace", item: "Send portfolio links.")],
        openQuestions: ["Who is the hiring manager?"],
        namesAndNumbers: ["Acme: the company."],
        next: ["Ask about the team size."]
    )

    @Test func aWrittenCallReadsBackTheSame() throws {
        let folder = try Self.folder()
        let writer = try SessionWriter(directory: folder, startedAt: Self.started, timeZone: Self.utc)
        let lines = [Self.line(.them, "When can you start?", at: 5), Self.line(.me, "In two weeks.", at: 20)]
        let answers = [
            Answer(trigger: .auto, question: "When can you start?", askedAt: Self.started + 8,
                   text: "I can start in two weeks.\n\nI'd want to wrap up my current project first.", state: .done),
            Answer(trigger: .quick, question: "Make that shorter.", askedAt: Self.started + 12, text: "Two weeks.", state: .stopped),
            Answer(trigger: .typed, question: "Salary range?", askedAt: Self.started + 14, state: .failed("Claude is busy.")),
        ]
        try writer.rewrite(lines, answers: answers)
        writer.close()
        try Data(Self.summary.markdown(updatedAt: Self.started + 60, timeZone: Self.utc).utf8)
            .write(to: SessionReader.summaryFile(for: writer.fileURL))

        let calls = SessionReader.calls(in: folder, timeZone: Self.utc)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.startedAt == Self.started)
        #expect(call.lineCount == 2 && call.answerCount == 3)
        #expect(call.duration == 15)
        #expect(call.preview == "A recruiter call about a Swift role.")

        let content = try SessionReader.read(call, timeZone: Self.utc)
        #expect(content.lines.map(\.text) == lines.map(\.text))
        #expect(content.lines.map(\.speaker) == [.them, .me])
        #expect(content.lines.map(\.start) == lines.map(\.start))
        #expect(content.answers.map(\.trigger) == [.auto, .quick, .typed])
        #expect(content.answers.map(\.question) == answers.map(\.question))
        #expect(content.answers.map(\.text) == answers.map(\.text))
        #expect(content.answers.map(\.state) == [.done, .stopped, .failed("Claude is busy.")])
        #expect(content.summary == Self.summary)
        #expect(content.summaryUpdated == "10:06:00")
    }

    @Test func callsAreNewestFirstAndOtherFilesAreIgnored() throws {
        let folder = try Self.folder()
        for name in ["2026-10-20 0923 call.md", "2026-10-21 1005 call.md", "2026-10-21 1005 call 2.md",
                     "2026-10-21 1005 summary.md", "notes.md"] {
            try Data("# Call\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        let names = SessionReader.calls(in: folder, timeZone: Self.utc).map(\.file.lastPathComponent)
        #expect(names == ["2026-10-21 1005 call 2.md", "2026-10-21 1005 call.md", "2026-10-20 0923 call.md"])
    }

    @Test func aSecondCallInOneMinuteHasItsOwnSummaryFile() {
        let folder = URL(fileURLWithPath: "/tmp/Sessions")
        #expect(SessionReader.summaryFile(for: folder.appendingPathComponent("2026-10-21 1005 call.md")).lastPathComponent
            == "2026-10-21 1005 summary.md")
        #expect(SessionReader.summaryFile(for: folder.appendingPathComponent("2026-10-21 1005 call 2.md")).lastPathComponent
            == "2026-10-21 1005 call 2 summary.md")
    }

    @Test func aCallPastMidnightKeepsItsTimesInOrder() {
        let lateStart = Date(timeIntervalSince1970: 1_792_626_900)   // 2026-10-21 23:55 UTC
        let text = "**[23:59:50] Them:** Almost midnight.\n\n**[00:00:10] Them:** Past it.\n\n"
        let lines = SessionReader.lines(in: text, startedAt: lateStart, timeZone: Self.utc)
        #expect(lines[1].start.timeIntervalSince(lines[0].start) == 20)
    }

    @Test func notASummaryFileReadsAsNothing() {
        #expect(CallSummary.parse(markdown: "# Call, 2026-10-21 10:05\n") == nil)
    }
}
