import Foundation

/// What an answer is for: a question spotted in what they said, Answer Now
/// (the button or the hotkey), or a question Jace typed.
public enum Question: Sendable, Equatable {
    case detected(String)
    case answerNow
    case typed(String)
}

/// One item of the call as Claude reads it: a line someone said, or one of
/// Claude's own earlier answers, which only Jace saw.
public enum TranscriptEntry: Sendable, Equatable {
    case line(Utterance)
    case answer(Answer)
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

        Lines marked "Claude" are your own earlier replies. Only Jace saw them, and he may or may not have \
        said them out loud; what he actually said is in his "Me" lines. When he asks you to change a reply \
        (shorter, simpler, in other words), he means your latest one.

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

        Follow the playbook and the notes for this call when they're given. When files for this call are \
        given and a question is about them, answer from what the files say.
        """

    public static let transcriptHeading = "Transcript so far:\n"

    public static let filesHeading = "# Files for this call"

    private let playbook: Playbook?
    private let callNotes: String
    private let files: CallFiles
    private let chunkSize: Int
    private let timeZone: TimeZone

    public init(playbook: Playbook?, callNotes: String, files: CallFiles = .none, chunkSize: Int = 10, timeZone: TimeZone = .current) {
        self.playbook = playbook
        self.callNotes = callNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.files = files
        self.chunkSize = max(chunkSize, 1)
        self.timeZone = timeZone
    }

    /// - Parameters:
    ///   - entries: the call's finished lines and Claude's finished answers,
    ///     in the order they were recorded.
    ///   - pendingMine: my lines heard but not recorded yet (they wait a few
    ///     seconds for the echo check); placed by time among the newest lines.
    ///   - themSaying: their words still being recognized, if any.
    public func prompt(entries: [TranscriptEntry], pendingMine: [Utterance] = [], themSaying: String?,
                       question: Question) -> AnswerPrompt {
        AnswerPrompt(system: system(), transcript: transcript(entries, pendingMine: pendingMine, themSaying: themSaying),
                     question: text(for: question),
                     lookup: !files.isEmpty && files.mode == .lookUp ? FileLookup(files: files) : nil)
    }

    /// A prompt from lines alone, with no earlier answers.
    public func prompt(lines: [Utterance], themSaying: String?, question: Question) -> AnswerPrompt {
        prompt(entries: lines.map(TranscriptEntry.line), themSaying: themSaying, question: question)
    }

    /// Base, files, playbook, notes. The files come before the notes so that
    /// editing the notes mid-call keeps the files cached; their breakpoint
    /// lasts an hour, since answers can be more than five minutes apart.
    private func system() -> [PromptBlock] {
        var blocks = [PromptBlock(text: Self.basePrompt)]
        if !files.isEmpty {
            blocks.append(PromptBlock(text: Self.filesText(files), cacheBreakpoint: true, cachesForAnHour: true))
        }
        if let playbook, !playbook.instructions.isEmpty {
            blocks.append(PromptBlock(text: "# Playbook: \(playbook.name)\n\n\(playbook.instructions)"))
        }
        if !callNotes.isEmpty {
            blocks.append(PromptBlock(text: "# Notes for this call\n\n\(callNotes)"))
        }
        blocks[blocks.count - 1].cacheBreakpoint = true
        return blocks
    }

    /// Every file's text, each in a `<file path="…">` element; or, when
    /// they're too big for that, the list of paths and how to look in them.
    static func filesText(_ files: CallFiles) -> String {
        var text = "\(filesHeading)\n\nJace picked these files for this call."
        if files.mode == .lookUp {
            text += """
                 They're too long to include here, so look in them with the tools: search_files finds lines, \
                read_file reads a file. Look things up only when the question is about these files, and keep it \
                to a few lookups, since Jace is waiting on the call. When you have what you need, reply in the same \
                two parts as always, starting with one short sentence he can say right away.

                The files:

                """
            return text + files.files.map(\.path).joined(separator: "\n")
        }
        for file in files.files {
            text += "\n\n<file path=\"\(file.path)\">\n\(file.text)\(file.text.hasSuffix("\n") ? "" : "\n")</file>"
        }
        return text
    }

    private func transcript(_ entries: [TranscriptEntry], pendingMine: [Utterance], themSaying: String?) -> [PromptBlock] {
        let rendered = entries.map(render)
        let frozenCount = rendered.count / chunkSize * chunkSize
        var blocks = stride(from: 0, to: frozenCount, by: chunkSize).map {
            PromptBlock(text: rendered[$0..<($0 + chunkSize)].joined(separator: "\n"))
        }
        if !blocks.isEmpty { blocks[blocks.count - 1].cacheBreakpoint = true }

        // The newest entries, with my pending lines placed by time: each goes
        // before the first entry that started after it.
        var tail = zip(entries[frozenCount...], rendered[frozenCount...]).map { (time: Self.time(of: $0), text: $1) }
        for line in pendingMine.sorted(by: { $0.start < $1.start }) {
            let index = tail.firstIndex { $0.time > line.start } ?? tail.endIndex
            tail.insert((line.start, render(.line(line))), at: index)
        }
        var tailText = tail.map(\.text)
        if let themSaying, !themSaying.isEmpty {
            tailText.append("(still speaking) \(Speaker.them.label): \(themSaying)")
        }
        if !tailText.isEmpty { blocks.append(PromptBlock(text: tailText.joined(separator: "\n"))) }

        if !blocks.isEmpty { blocks[0].text = Self.transcriptHeading + blocks[0].text }
        return blocks
    }

    /// A line as "[time] Speaker: text"; an answer as "[time] Claude, to Jace
    /// only: text" on one line, after the question when Jace typed it.
    private func render(_ entry: TranscriptEntry) -> String {
        switch entry {
        case .line(let line):
            return "[\(line.start.clockTime(in: timeZone))] \(line.speaker.label): \(line.text)"
        case .answer(let answer):
            let time = "[\(answer.askedAt.clockTime(in: timeZone))]"
            let text = answer.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            let reply = "\(time) Claude, to Jace only: \(text)\(answer.state == .stopped ? " (cut off)" : "")"
            return answer.trigger == .typed ? "\(time) Jace typed to Claude: \(answer.question)\n\(reply)" : reply
        }
    }

    private static func time(of entry: TranscriptEntry) -> Date {
        switch entry {
        case .line(let line): line.start
        case .answer(let answer): answer.askedAt
        }
    }

    private func text(for question: Question) -> String {
        switch question {
        case .detected(let asked): "They just asked: \"\(asked)\"\nWhat should I say?"
        case .answerNow: "What should I say back to what they just said?"
        case .typed(let typed): typed
        }
    }
}
