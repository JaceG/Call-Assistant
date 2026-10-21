import Foundation

/// The running summary of a call, as Claude keeps it: a short summary, then
/// sections Jace can scan during the call, ending with where it could go next.
public struct CallSummary: Codable, Sendable, Equatable {
    public struct Exchange: Codable, Sendable, Equatable {
        /// "Them" or "Me".
        public var askedBy: String
        public var question: String
        /// What was said back, or "Not answered yet".
        public var answer: String

        public init(askedBy: String, question: String, answer: String) {
            self.askedBy = askedBy
            self.question = question
            self.answer = answer
        }
    }

    public struct Quote: Codable, Sendable, Equatable {
        /// "Them" or "Me".
        public var speaker: String
        /// "HH:mm:ss", from the transcript.
        public var time: String
        public var words: String

        public init(speaker: String, time: String, words: String) {
            self.speaker = speaker
            self.time = time
            self.words = words
        }
    }

    public struct ActionItem: Codable, Sendable, Equatable {
        /// Who: "Jace", "Them", or a name.
        public var owner: String
        public var item: String

        public init(owner: String, item: String) {
            self.owner = owner
            self.item = item
        }
    }

    public var summary: String
    public var keyPoints: [String]
    public var questions: [Exchange]
    public var quotes: [Quote]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    public var namesAndNumbers: [String]
    public var next: [String]

    public init(summary: String, keyPoints: [String] = [], questions: [Exchange] = [], quotes: [Quote] = [],
                decisions: [String] = [], actionItems: [ActionItem] = [], openQuestions: [String] = [],
                namesAndNumbers: [String] = [], next: [String] = []) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.questions = questions
        self.quotes = quotes
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.namesAndNumbers = namesAndNumbers
        self.next = next
    }

    // MARK: What changed

    /// The parts of the summary, for comparing one version with the last.
    public enum Part: Sendable, CaseIterable {
        case summary, keyPoints, questions, quotes, decisions, actionItems, openQuestions, namesAndNumbers, next
    }

    /// Each item of a part as text, as compared between versions.
    public func texts(_ part: Part) -> [String] {
        switch part {
        case .summary: [summary]
        case .keyPoints: keyPoints
        case .questions: questions.map { "\($0.askedBy): \($0.question)\n\($0.answer)" }
        case .quotes: quotes.map(\.words)
        case .decisions: decisions
        case .actionItems: actionItems.map { "\($0.owner): \($0.item)" }
        case .openQuestions: openQuestions
        case .namesAndNumbers: namesAndNumbers
        case .next: next
        }
    }

    /// Whether `text` is new or changed since `previous`. With no previous
    /// version (the first one), nothing is marked.
    public static func isNew(_ text: String, in part: Part, since previous: CallSummary?) -> Bool {
        guard let previous else { return false }
        return !previous.texts(part).contains(text)
    }

    // MARK: JSON

    /// The JSON Schema Claude's reply must match (snake_case keys).
    public static let schema = Data(#"""
        {"type":"object","additionalProperties":false,
         "required":["summary","key_points","questions","quotes","decisions","action_items","open_questions","names_and_numbers","next"],
         "properties":{
          "summary":{"type":"string"},
          "key_points":{"type":"array","items":{"type":"string"}},
          "questions":{"type":"array","items":{"type":"object","additionalProperties":false,
            "required":["asked_by","question","answer"],
            "properties":{"asked_by":{"type":"string","enum":["Them","Me"]},"question":{"type":"string"},"answer":{"type":"string"}}}},
          "quotes":{"type":"array","items":{"type":"object","additionalProperties":false,
            "required":["speaker","time","words"],
            "properties":{"speaker":{"type":"string","enum":["Them","Me"]},"time":{"type":"string"},"words":{"type":"string"}}}},
          "decisions":{"type":"array","items":{"type":"string"}},
          "action_items":{"type":"array","items":{"type":"object","additionalProperties":false,
            "required":["owner","item"],
            "properties":{"owner":{"type":"string"},"item":{"type":"string"}}}},
          "open_questions":{"type":"array","items":{"type":"string"}},
          "names_and_numbers":{"type":"array","items":{"type":"string"}},
          "next":{"type":"array","items":{"type":"string"}}
         }}
        """#.utf8)

    public static func decode(_ data: Data) throws -> CallSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CallSummary.self, from: data)
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: Markdown

    /// A summary file read back (the inverse of `markdown`), with the time it
    /// says it was updated; nil if it isn't one.
    public static func parse(markdown: String) -> (summary: CallSummary, updated: String)? {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "# Call summary" else { return nil }
        var updated = ""
        var opening: [String] = []
        var sections: [String: [String]] = [:]
        var section: String?
        for line in lines.dropFirst() {
            if let match = try? /^\*Updated (.+)\*$/.wholeMatch(in: line), section == nil, updated.isEmpty {
                updated = String(match.1)
            } else if line.hasPrefix("## ") {
                section = String(line.dropFirst(3))
            } else if let section {
                if !line.isEmpty { sections[section, default: []].append(line) }
            } else if !line.isEmpty {
                opening.append(line)
            }
        }

        func items(_ title: String) -> [String] {
            (sections[title] ?? []).compactMap { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : nil }
        }
        var questions: [Exchange] = []
        for line in sections["Questions and answers"] ?? [] {
            if let match = try? /^- \*\*(.+?):\*\* (.*)$/.wholeMatch(in: line) {
                questions.append(Exchange(askedBy: String(match.1), question: String(match.2), answer: ""))
            } else if line.hasPrefix("  - "), !questions.isEmpty {
                questions[questions.count - 1].answer = String(line.dropFirst(4))
            }
        }
        let quotes = items("Quotes").compactMap { item -> Quote? in
            guard let match = try? /^\u{201C}(.*)\u{201D} \((.+), (\d\d:\d\d:\d\d)\)$/.wholeMatch(in: item) else { return nil }
            return Quote(speaker: String(match.2), time: String(match.3), words: String(match.1))
        }
        let actionItems = items("Action items").compactMap { item -> ActionItem? in
            guard let match = try? /^\*\*(.+?):\*\* (.*)$/.wholeMatch(in: item) else { return nil }
            return ActionItem(owner: String(match.1), item: String(match.2))
        }
        let summary = CallSummary(
            summary: opening.joined(separator: "\n"), keyPoints: items("Key points"), questions: questions, quotes: quotes,
            decisions: items("Decisions"), actionItems: actionItems, openQuestions: items("Open questions"),
            namesAndNumbers: items("Names and numbers"), next: items("Where this could go next")
        )
        return (summary, updated)
    }

    /// The summary as a Markdown document; empty sections are left out.
    public func markdown(updatedAt: Date, timeZone: TimeZone = .current) -> String {
        var out = ["# Call summary", "", "*Updated \(updatedAt.clockTime(in: timeZone))*", "", summary]
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out += ["", "## \(title)", ""] + lines
        }
        section("Key points", keyPoints.map { "- \($0)" })
        section("Questions and answers", questions.flatMap { ["- **\($0.askedBy):** \($0.question)", "  - \($0.answer)"] })
        section("Quotes", quotes.map { "- \u{201C}\($0.words)\u{201D} (\($0.speaker), \($0.time))" })
        section("Decisions", decisions.map { "- \($0)" })
        section("Action items", actionItems.map { "- **\($0.owner):** \($0.item)" })
        section("Open questions", openQuestions.map { "- \($0)" })
        section("Names and numbers", namesAndNumbers.map { "- \($0)" })
        section("Where this could go next", next.map { "- \($0)" })
        return out.joined(separator: "\n") + "\n"
    }
}
