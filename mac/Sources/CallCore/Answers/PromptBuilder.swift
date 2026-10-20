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
        Recognition makes sound-alike mistakes, such as "home" for "phone" or "cash" for "cache". Silently \
        read them as what the speaker meant, and never mention them.

        Jace reads your reply while the call is going and says it out loud, so always reply in exactly \
        two parts and nothing else:
        1. The quick answer: one short sentence, in the first person, that he can say right away. Begin \
        your reply with it. No lead-in such as "Here's what to say", no label, no quotation marks.
        2. Then a blank line, and the longer answer: two to four sentences that carry on naturally from \
        the quick answer, as if Jace kept talking. Don't repeat the quick answer.

        Write plain spoken sentences: no bullets, labels, headings, tables or code blocks. Bold and \
        italics are fine.
        When the question is about Jace himself and the playbook and notes don't say, write the words as \
        he plausibly would and keep them general, rather than inventing names, numbers or employers.
        If it's unclear what they asked, the quick answer is a short, natural question to ask them back.
        When Jace types a question to you himself, use the same two parts, with the direct answer first.

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
        case .detected(let asked): "They just asked: \"\(asked)\"\nWhat should I say?"
        case .answerNow: "What should I say back to what they just said?"
        case .typed(let typed): typed
        }
    }
}
