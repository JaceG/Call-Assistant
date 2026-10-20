import CallCore
import Foundation
import Testing

struct SessionWriterTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-20 14:13:20 UTC.
    static let start = Date(timeIntervalSince1970: 1_792_505_600)

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionWriterTests-\(UUID().uuidString)", isDirectory: true)
        // The writer must create a missing folder itself, so don't make it here.
        return url
    }

    @Test func createsTheFolderAndAFileNamedForTheStartTime() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionWriter(directory: directory, startedAt: Self.start, timeZone: Self.utc)
        #expect(writer.fileURL.lastPathComponent == "2026-10-20 1413 call.md")
        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        #expect(contents.hasPrefix("# Call, 2026-10-20 14:13\n"))
    }

    @Test func eachUtteranceIsOnDiskWhenAppendReturns() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionWriter(directory: directory, startedAt: Self.start, timeZone: Self.utc)
        try writer.append(Utterance(speaker: .them, text: "Can you walk me through it?",
                                    start: Self.start + 5, end: Self.start + 7))
        #expect(try String(contentsOf: writer.fileURL, encoding: .utf8)
            .contains("**[14:13:25] Them:** Can you walk me through it?\n"))
        try writer.append(Utterance(speaker: .me, text: "Sure.", start: Self.start + 8, end: Self.start + 9))
        #expect(try String(contentsOf: writer.fileURL, encoding: .utf8)
            .contains("**[14:13:28] Me:** Sure.\n"))
    }

    @Test func twoSessionsInTheSameMinuteGetDifferentFiles() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SessionWriter(directory: directory, startedAt: Self.start, timeZone: Self.utc)
        let second = try SessionWriter(directory: directory, startedAt: Self.start + 20, timeZone: Self.utc)
        #expect(first.fileURL != second.fileURL)
        #expect(second.fileURL.lastPathComponent == "2026-10-20 1413 call 2.md")
    }

    /// Lines are saved as they finish, and my lines wait for the echo check,
    /// so the file can be out of time order (seen on Jace's first real call,
    /// 2026-10-20). Stop rewrites it in order.
    @Test func rewritingPutsTheFileInTimeOrder() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionWriter(directory: directory, startedAt: Self.start, timeZone: Self.utc)
        let theirs = Utterance(speaker: .them, text: "Okay.", start: Self.start + 9, end: Self.start + 10)
        let mine = Utterance(speaker: .me, text: "I'm testing out a software.", start: Self.start + 6, end: Self.start + 8)
        try writer.append(theirs)
        try writer.append(mine)

        try writer.rewrite([mine, theirs])
        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        #expect(contents == """
            # Call, 2026-10-20 14:13

            Me is the microphone; Them is the computer's audio.

            **[14:13:26] Me:** I'm testing out a software.

            **[14:13:29] Them:** Okay.


            """)

        // Lines added after a rewrite still land in the file.
        try writer.append(Utterance(speaker: .them, text: "Bye.", start: Self.start + 12, end: Self.start + 13))
        #expect(try String(contentsOf: writer.fileURL, encoding: .utf8).hasSuffix("**[14:13:32] Them:** Bye.\n\n"))
    }

    @Test func anAnswerIsSavedAsAQuoteBlock() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionWriter(directory: directory, startedAt: Self.start, timeZone: Self.utc)
        try writer.append(Answer(trigger: .auto, question: "How do you cache?", askedAt: Self.start + 30,
                                 text: "Serve the cached copy first.\n\n- Refresh in the background.", state: .done))
        #expect(try String(contentsOf: writer.fileURL, encoding: .utf8).hasSuffix("""
            > **[14:13:50] Claude** (Auto): *How do you cache?*
            >
            > Serve the cached copy first.
            >
            > - Refresh in the background.


            """))
    }

    @Test func unfinishedAnswersSayHowTheyEnded() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionWriter(directory: directory, startedAt: Self.start, timeZone: Self.utc)
        try writer.append(Answer(trigger: .answerNow, question: "Okay.", askedAt: Self.start, text: "Half an", state: .stopped))
        try writer.append(Answer(trigger: .typed, question: "Hi?", askedAt: Self.start, text: "", state: .failed("Claude is busy. Try again in a moment.")))
        try writer.append(Answer(trigger: .auto, question: "Hm?", askedAt: Self.start, text: "", state: .declined))
        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        #expect(contents.contains("> **[14:13:20] Claude** (Answer Now): *Okay.*\n>\n> Half an\n>\n> *(stopped)*\n"))
        #expect(contents.contains("> **[14:13:20] Claude** (Typed): *Hi?*\n>\n> *(failed: Claude is busy. Try again in a moment.)*\n"))
        #expect(contents.contains("> **[14:13:20] Claude** (Auto): *Hm?*\n>\n> *(Claude declined to answer this one.)*\n"))
    }

    @Test func rewritingPutsAnswersAmongTheLinesByTime() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionWriter(directory: directory, startedAt: Self.start, timeZone: Self.utc)
        let question = Utterance(speaker: .them, text: "How do you cache?", start: Self.start + 5, end: Self.start + 7)
        let reply = Utterance(speaker: .me, text: "We cache per endpoint.", start: Self.start + 12, end: Self.start + 14)
        let answer = Answer(trigger: .auto, question: "How do you cache?", askedAt: Self.start + 9, text: "Per endpoint.", state: .done)
        try writer.rewrite([question, reply], answers: [answer])
        let contents = try String(contentsOf: writer.fileURL, encoding: .utf8)
        let them = try #require(contents.range(of: "Them:** How do you cache?"))
        let claude = try #require(contents.range(of: "Claude** (Auto)"))
        let me = try #require(contents.range(of: "Me:** We cache per endpoint."))
        #expect(them.lowerBound < claude.lowerBound)
        #expect(claude.lowerBound < me.lowerBound)
    }
}
