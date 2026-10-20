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
}
