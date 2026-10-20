import Foundation

/// Decides whether a line they said asks something worth answering, for
/// Auto-Answer. Apple's recognizer ends questions with "?" (every played test
/// question in Phase 1 had one), so that's the main signal. Requests that
/// aren't phrased as questions ("Tell me about…") count too. Short questions,
/// tag questions ("…, right?") and call logistics ("Can you hear me?") don't.
public struct QuestionDetector: Sendable {
    /// Fewer words than this isn't a question worth answering ("Really?").
    static let minimumWords = 4

    /// Whole sentences that don't need an answer from Claude.
    static let ignoredQuestions: Set<String> = [
        "does that make sense", "does that sound good", "sound good", "make sense", "is that right",
        "is that okay", "is that ok", "can you hear me", "can you see my screen", "can you hear me okay",
        "can you see it", "are you there", "is my audio okay",
    ]

    /// Endings that turn a statement into a tag question: "We ship weekly, right?"
    static let tags: Set<String> = ["right", "you know", "okay", "ok", "yeah", "yes", "no", "correct", "isn't it", "don't you think"]

    /// Openings of a request that isn't phrased as a question.
    static let requestOpenings = ["tell me about", "walk me through", "talk me through", "can you explain", "explain", "describe"]
    /// Words that may come before a request opening: "So walk me through…".
    static let fillers: Set<String> = ["so", "okay", "ok", "and", "alright", "all right", "great", "well", "now"]

    public init() {}

    /// The part of `line` to answer, or nil when there's nothing to answer.
    public func question(in line: Utterance) -> String? {
        guard line.speaker == .them else { return nil }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let questions = Self.sentences(in: text).filter { sentence in
            guard sentence.hasSuffix("?") else { return false }
            let words = Self.words(in: sentence)
            guard words.count >= Self.minimumWords else { return false }
            if Self.ignoredQuestions.contains(words.joined(separator: " ")) { return false }
            // A tag after the last comma: "We ship every two weeks, right?"
            if let comma = sentence.lastIndex(of: ","),
               Self.tags.contains(Self.words(in: String(sentence[comma...])).joined(separator: " ")) {
                return false
            }
            return true
        }
        if !questions.isEmpty { return questions.joined(separator: " ") }

        return Self.isRequest(text) ? text : nil
    }

    /// "Tell me about…", "So walk me through…", "Okay, explain…".
    private static func isRequest(_ text: String) -> Bool {
        var words = Self.words(in: text)
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        let start = words.joined(separator: " ")
        return requestOpenings.contains { start == $0 || start.hasPrefix($0 + " ") }
    }

    /// Sentences, each with its closing punctuation.
    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if sentence.count > 1 { sentences.append(sentence) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    /// Lowercased words without punctuation (apostrophes kept: "isn't").
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
            .map(String.init)
    }
}
