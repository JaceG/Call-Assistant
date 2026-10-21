import Foundation

/// The record of every review: what was suggested after each call and what
/// Jace chose (Learning.md), plus the feature ideas he kept for a developer
/// (Feature Ideas.md). Both are Markdown, appended to, in the support folder.
public struct LearningLog: Sendable {
    public let file: URL
    public let featureIdeasFile: URL
    private let timeZone: TimeZone

    public init(file: URL = Paths.learningFile, featureIdeasFile: URL = Paths.featureIdeasFile, timeZone: TimeZone = .current) {
        self.file = file
        self.featureIdeasFile = featureIdeasFile
        self.timeZone = timeZone
    }

    /// The end of the log, for the next review to read (most recent last).
    public func tail(maxCharacters: Int = 20_000) -> String {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return String(text.suffix(maxCharacters))
    }

    /// Writes down a new review as it arrives, before Jace decides.
    public func recordReview(_ review: SessionReview, call: String, at date: Date) throws {
        var lines = ["", "## \(Self.day(date, timeZone)) \(date.clockTime(in: timeZone)), \(call)", ""]
        if !review.observations.isEmpty {
            lines += ["Observations:"] + review.observations.map { "- \($0)" } + [""]
        }
        lines += ["Suggested:"]
        lines += review.instructions.map { "- Instruction: \($0.text) (\($0.reason))" }
        lines += review.quickActions.map { "- Quick action \($0.name): \($0.prompt) (\($0.reason))" }
        lines += review.features.map { "- Feature: \($0.title): \($0.description) (\($0.reason))" }
        if review.suggestionCount == 0 { lines += ["- Nothing"] }
        try append(lines.joined(separator: "\n") + "\n", to: file, heading: "# Learning\n\nWhat Claude suggested after each call, and what Jace chose.\n")
    }

    /// Writes down one of Jace's choices ("Added instruction: …").
    public func recordChoice(_ choice: String) throws {
        try append("- \(choice)\n", to: file, heading: "# Learning\n\nWhat Claude suggested after each call, and what Jace chose.\n")
    }

    /// Keeps a feature idea for a developer.
    public func keepFeature(_ idea: SessionReview.FeatureIdea, call: String, at date: Date) throws {
        let entry = "\n## \(idea.title)\n\n*\(Self.day(date, timeZone)), from \(call)*\n\n\(idea.description)\n\nWhy: \(idea.reason)\n"
        try append(entry, to: featureIdeasFile, heading: "# Feature Ideas\n\nIdeas for Call Assistant from the reviews after calls, to hand to a developer.\n")
    }

    private func append(_ text: String, to file: URL, heading: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: file.path) {
            try Data(heading.utf8).write(to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func day(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
