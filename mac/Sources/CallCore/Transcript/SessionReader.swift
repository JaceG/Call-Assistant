import Foundation

/// A saved call in the Sessions folder, for the Past Calls list.
public struct PastCall: Identifiable, Sendable, Hashable {
    public var id: URL { file }
    /// The transcript, "<yyyy-MM-dd HHmm> call.md" (or "call 2.md"…).
    public let file: URL
    public let startedAt: Date
    /// The summary beside it, if one was made.
    public let summaryFile: URL?
    public let lineCount: Int
    public let answerCount: Int
    /// From the first line to the last.
    public let duration: TimeInterval
    /// The summary's opening, or the first thing said.
    public let preview: String
}

/// A saved call read back: its lines, Claude's answers and the summary.
public struct PastCallContent: Sendable, Equatable {
    public let lines: [Utterance]
    public let answers: [Answer]
    public let summary: CallSummary?
    /// "HH:mm:ss", as the summary file says.
    public let summaryUpdated: String?
}

/// Reads the files SessionWriter and the live summary write.
public enum SessionReader {
    /// The summary file for a call file: "<day> <time> summary.md" beside it
    /// ("<day> <time> call 2 summary.md" for a second call in one minute).
    public static func summaryFile(for callFile: URL) -> URL {
        let name = callFile.deletingPathExtension().lastPathComponent
        let base = name.hasSuffix(" call") ? String(name.dropLast(" call".count)) : name
        return callFile.deletingLastPathComponent().appendingPathComponent("\(base) summary.md")
    }

    /// When a call started, from its file name, or nil if it isn't a call file.
    public static func startDate(of callFile: URL, timeZone: TimeZone = .current) -> Date? {
        let name = callFile.deletingPathExtension().lastPathComponent
        guard let match = try? /^(\d{4})-(\d\d)-(\d\d) (\d\d)(\d\d) call( \d+)?$/.wholeMatch(in: name) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3),
                                                  hour: Int(match.4), minute: Int(match.5)))
    }

    /// Every saved call in `directory`, newest first.
    public static func calls(in directory: URL = Paths.sessionsDirectory, timeZone: TimeZone = .current) -> [PastCall] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> PastCall? in
            guard file.pathExtension == "md", let started = startDate(of: file, timeZone: timeZone),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let lines = lines(in: text, startedAt: started, timeZone: timeZone)
            let answers = answers(in: text, startedAt: started, timeZone: timeZone)
            let summaryFile = summaryFile(for: file)
            let hasSummary = FileManager.default.fileExists(atPath: summaryFile.path)
            let summary = hasSummary ? (try? String(contentsOf: summaryFile, encoding: .utf8)).flatMap { CallSummary.parse(markdown: $0)?.summary } : nil
            let opening = summary?.summary ?? lines.first?.text ?? ""
            return PastCall(
                file: file, startedAt: started, summaryFile: hasSummary ? summaryFile : nil,
                lineCount: lines.count, answerCount: answers.count,
                duration: (lines.last?.start).map { $0.timeIntervalSince(lines[0].start) } ?? 0,
                preview: opening
            )
        }
        .sorted { ($0.startedAt, copy(of: $0.file)) > ($1.startedAt, copy(of: $1.file)) }
    }

    /// 2 for "… call 2.md", 1 for "… call.md": the order of calls started in
    /// the same minute.
    private static func copy(of file: URL) -> Int {
        let name = file.deletingPathExtension().lastPathComponent
        guard let match = try? /\ call (\d+)$/.firstMatch(in: name), let copy = Int(match.1) else { return 1 }
        return copy
    }

    public static func read(_ call: PastCall, timeZone: TimeZone = .current) throws -> PastCallContent {
        let text = try String(contentsOf: call.file, encoding: .utf8)
        let summary = call.summaryFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap { CallSummary.parse(markdown: $0) }
        return PastCallContent(
            lines: lines(in: text, startedAt: call.startedAt, timeZone: timeZone),
            answers: answers(in: text, startedAt: call.startedAt, timeZone: timeZone),
            summary: summary?.summary, summaryUpdated: summary?.updated
        )
    }

    // MARK: Parsing

    /// "**[HH:mm:ss] Them:** text" lines.
    public static func lines(in text: String, startedAt: Date, timeZone: TimeZone = .current) -> [Utterance] {
        text.split(separator: "\n").compactMap { line -> Utterance? in
            guard let match = try? /^\*\*\[(\d\d:\d\d:\d\d)\] (Me|Them):\*\* (.+)$/.wholeMatch(in: String(line)),
                  let time = date(String(match.1), after: startedAt, timeZone: timeZone) else { return nil }
            return Utterance(speaker: match.2 == "Me" ? .me : .them, text: String(match.3), start: time, end: time)
        }
    }

    /// Claude's answers: "> **[HH:mm:ss] Claude** (Label): *question*", then
    /// the quoted text, then how it ended if it didn't finish.
    public static func answers(in text: String, startedAt: Date, timeZone: TimeZone = .current) -> [Answer] {
        let triggers = Dictionary(uniqueKeysWithValues: [Answer.Trigger.auto, .answerNow, .typed, .quick].map { ($0.label, $0) })
        var answers: [Answer] = []
        var current: Answer?
        var body: [String] = []

        func finish() {
            guard var answer = current else { return }
            var lines = body
            if let last = lines.last {
                if last == "*(stopped)*" {
                    answer.state = .stopped
                    lines.removeLast()
                } else if last == "*(Claude declined to answer this one.)*" {
                    answer.state = .declined
                    lines.removeLast()
                } else if let failed = try? /^\*\(failed: (.*)\)\*$/.wholeMatch(in: last) {
                    answer.state = .failed(String(failed.1))
                    lines.removeLast()
                }
            }
            answer.text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            answers.append(answer)
            current = nil
            body = []
        }

        for line in text.components(separatedBy: "\n") {
            if let match = try? /^> \*\*\[(\d\d:\d\d:\d\d)\] Claude\*\* \((.+?)\): \*(.*)\*$/.wholeMatch(in: line),
               let time = date(String(match.1), after: startedAt, timeZone: timeZone) {
                finish()
                current = Answer(trigger: triggers[String(match.2)] ?? .typed, question: String(match.3), askedAt: time, state: .done)
            } else if current != nil, line.hasPrefix(">") {
                body.append(line == ">" ? "" : String(line.dropFirst(2)))
            } else if current != nil {
                finish()
            }
        }
        finish()
        return answers
    }

    /// "HH:mm:ss" on the call's day, or the next day for a call that ran past
    /// midnight.
    static func date(_ clock: String, after start: Date, timeZone: TimeZone) -> Date? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let time = calendar.date(bySettingHour: parts[0], minute: parts[1], second: parts[2], of: start) else { return nil }
        // A minute's slack: the file name only has minutes.
        return time < start - 60 ? calendar.date(byAdding: .day, value: 1, to: time) : time
    }
}
