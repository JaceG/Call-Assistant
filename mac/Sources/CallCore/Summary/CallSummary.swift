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
