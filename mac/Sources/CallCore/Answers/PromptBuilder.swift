import Foundation

/// What an answer is for: a question spotted in what they said, Answer Now
/// (the button or the hotkey), or a question Jace typed.
public enum Question: Sendable, Equatable {
    case detected(String)
    case answerNow
    case typed(String)
}

/// Builds the prompt for one answer: the base instructions, the playbook and
/// the call notes (system), then the transcript and the question.
///
/// The transcript is split into chunks of `chunkSize` lines, in the order the
/// lines were recorded. A full chunk never changes again, so the provider can
/// cache everything up to the last full chunk and later answers reuse it.
/// Lines carry their times, so a line recorded late still reads in context.
public struct PromptBuilder: Sendable {
    public static let basePrompt = """
        You are helping Jace live, during a call. The transcript comes from speech recognition on his Mac: \
        "Me" is Jace (his microphone) and "Them" is the other side of the call (the computer's audio). \
        Recognition makes sound-alike mistakes, such as "home" for "phone" or "cash" for "cache", so read \
        for what the speaker most likely meant.

        Jace will glance at your answer and say it in his own words while the call goes on, so:
        - Start with the direct answer in one or two sentences he can say out loud.
        - Then add at most three short "- " bullets with details worth mentioning, only if they help.
        - No headings, tables or code blocks unless he asks for code. Bold and italics are fine.
        - When the question is about Jace himself and the playbook or notes don't say, suggest how he \
        could answer instead of inventing facts about him.
        - If you're unsure what they asked, or of the facts, say so in a few words rather than guessing.

        Follow the playbook and the notes for this call when they're given.
        """

    public static let transcriptHeading = "Transcript so far:\n"

    private let playbook: Playbook?
    private let callNotes: String
    private let chunkSize: Int
    private let timeZone: TimeZone

    public init(playbook: Playbook?, callNotes: String, chunkSize: Int = 10, timeZone: TimeZone = .current) {
        self.playbook = playbook
        self.callNotes = callNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chunkSize = max(chunkSize, 1)
        self.timeZone = timeZone
    }

    /// - Parameters:
    ///   - lines: the call's finished lines, in the order they were recorded.
    ///   - themSaying: their words still being recognized, if any.
    public func prompt(lines: [Utterance], themSaying: String?, question: Question) -> AnswerPrompt {
        AnswerPrompt(system: system(), transcript: transcript(lines, themSaying: themSaying), question: text(for: question))
    }

    private func system() -> [PromptBlock] {
        var blocks = [PromptBlock(text: Self.basePrompt)]
        if let playbook, !playbook.instructions.isEmpty {
            blocks.append(PromptBlock(text: "# Playbook: \(playbook.name)\n\n\(playbook.instructions)"))
        }
        if !callNotes.isEmpty {
            blocks.append(PromptBlock(text: "# Notes for this call\n\n\(callNotes)"))
        }
        blocks[blocks.count - 1].cacheBreakpoint = true
        return blocks
    }

    private func transcript(_ lines: [Utterance], themSaying: String?) -> [PromptBlock] {
        let rendered = lines.map { "[\($0.start.clockTime(in: timeZone))] \($0.speaker.label): \($0.text)" }
        let frozenCount = rendered.count / chunkSize * chunkSize
        var blocks = stride(from: 0, to: frozenCount, by: chunkSize).map {
            PromptBlock(text: rendered[$0..<($0 + chunkSize)].joined(separator: "\n"))
        }
        if !blocks.isEmpty { blocks[blocks.count - 1].cacheBreakpoint = true }

        var tail = Array(rendered[frozenCount...])
        if let themSaying, !themSaying.isEmpty {
            tail.append("(still speaking) \(Speaker.them.label): \(themSaying)")
        }
        if !tail.isEmpty { blocks.append(PromptBlock(text: tail.joined(separator: "\n"))) }

        if !blocks.isEmpty { blocks[0].text = Self.transcriptHeading + blocks[0].text }
        return blocks
    }

    private func text(for question: Question) -> String {
        switch question {
        case .detected(let asked): "They just asked: \"\(asked)\"\nHelp me answer it."
        case .answerNow: "Help me respond to what they just said."
        case .typed(let typed): typed
        }
    }
}
