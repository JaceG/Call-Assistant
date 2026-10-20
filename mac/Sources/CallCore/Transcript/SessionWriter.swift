import Foundation
import os

/// Saves one call's transcript as a Markdown file, adding each utterance as it
/// arrives so nothing is lost if the app quits mid-call. Lines finish out of
/// time order (each side has its own recognizer), so `rewrite` puts the whole
/// file in order at the end.
public final class SessionWriter: @unchecked Sendable {
    public let fileURL: URL
    private let timeZone: TimeZone
    private let header: String
    /// Guards the file handle; appends can come from either channel.
    private let handle: OSAllocatedUnfairLock<FileHandle?>

    /// Creates `<yyyy-MM-dd HHmm> call.md` in `directory` (and the directory,
    /// if missing). A second call in the same minute gets " 2", and so on.
    public init(directory: URL, startedAt: Date, timeZone: TimeZone = .current) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let hour = String(format: "%02d", c.hour ?? 0)
        let minute = String(format: "%02d", c.minute ?? 0)

        var url = directory.appendingPathComponent("\(day) \(hour)\(minute) call.md")
        var copy = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(day) \(hour)\(minute) call \(copy).md")
            copy += 1
        }

        let header = "# Call, \(day) \(hour):\(minute)\n\nMe is the microphone; Them is the computer's audio.\n\n"
        guard fileManager.createFile(atPath: url.path, contents: Data(header.utf8)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle.seekToEnd()

        self.fileURL = url
        self.timeZone = timeZone
        self.header = header
        self.handle = OSAllocatedUnfairLock(uncheckedState: fileHandle)
    }

    deinit {
        close()
    }

    /// Writes "**[HH:mm:ss] Them:** text". The file holds it when this returns.
    public func append(_ utterance: Utterance) throws {
        try handle.withLockUnchecked { fileHandle in
            guard let fileHandle else { return }
            try fileHandle.write(contentsOf: Data(line(for: utterance).utf8))
        }
    }

    /// Replaces the file's lines with `utterances`, in the order given (the
    /// transcript store keeps them in time order). The file is swapped in one
    /// step, so a crash leaves either the old file or the new one.
    public func rewrite(_ utterances: [Utterance]) throws {
        let contents = header + utterances.map(line(for:)).joined()
        try handle.withLockUnchecked { fileHandle in
            try? fileHandle?.close()
            fileHandle = nil
            try Data(contents.utf8).write(to: fileURL, options: .atomic)
            let reopened = try FileHandle(forWritingTo: fileURL)
            try reopened.seekToEnd()
            fileHandle = reopened
        }
    }

    private func line(for utterance: Utterance) -> String {
        "**[\(utterance.start.clockTime(in: timeZone))] \(utterance.speaker.label):** \(utterance.text)\n\n"
    }

    public func close() {
        handle.withLockUnchecked { fileHandle in
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}
