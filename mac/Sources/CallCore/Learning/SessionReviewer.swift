import Foundation

/// After a call, asks Claude what Jace's use of the app suggests for his next
/// calls (see SessionReview). Nothing changes until Jace accepts a suggestion.
public struct SessionReviewer: Sendable {
    public static let instructions = """
        After each call, you review how Jace used Call Assistant, a Mac app that listens to his calls and shows \
        him Claude's suggested replies, so it serves him better on the next call.

        The transcript has the call ("Me" is Jace, "Them" is the other side, from speech recognition) and every \
        reply Claude gave him, with how it was asked: Auto (a question of theirs was spotted), Answer Now (he \
        pressed the button), Typed (he typed the question shown), or Quick (a one-click button whose prompt is \
        shown).

        Look for patterns with evidence in this call, for example: he asked for shorter, simpler or different \
        replies; what he actually said differs from the reply he was given; he typed the same kind of request \
        more than once; facts about him or his work came up that future replies should know; replies missed.

        Suggest:
        - instructions: single lines for his Always instructions, which Claude follows on every call. Write each \
        as an instruction to Claude ("Keep the longer answer to two sentences."). Facts about Jace go in as facts \
        ("Jace has eight years of Swift.").
        - quick_actions: new one-click buttons for requests he typed or kept needing: a short name and the \
        prompt. Not ones he already has.
        - features: ideas for new features or changes to the app itself, for him to hand to a developer, each \
        with the problem it would have solved in this call.
        - observations: two to five short notes on how the call and the replies went.

        Give every suggestion a reason that points at what happened in the call. Suggest nothing that this call \
        gives no evidence for; empty lists are fine. Never repeat a suggestion the learning log shows as added \
        or skipped.
        """

    private let provider: StructuredProvider
    private let timeZone: TimeZone

    public init(provider: StructuredProvider, timeZone: TimeZone = .current) {
        self.provider = provider
        self.timeZone = timeZone
    }

    /// Whether a call had enough in it to review.
    public static func isWorthReviewing(lines: [Utterance], answers: [Answer]) -> Bool {
        lines.count >= 4 || answers.contains { !$0.text.isEmpty }
    }

    public func review(lines: [Utterance], answers: [Answer], always: String, quickActions: [QuickAction],
                       learningLog: String) async throws -> SessionReview {
        let prompt = prompt(lines: lines, answers: answers, always: always, quickActions: quickActions, learningLog: learningLog)
        return try SessionReview.decode(try await provider.json(prompt, schema: SessionReview.schema))
    }

    func prompt(lines: [Utterance], answers: [Answer], always: String, quickActions: [QuickAction],
                learningLog: String) -> AnswerPrompt {
        let always = always.trimmingCharacters(in: .whitespacesAndNewlines)
        let buttons = quickActions.filter(\.isComplete).map { "- \($0.name): \($0.prompt)" }.joined(separator: "\n")
        let log = learningLog.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = [
            "His Always instructions now:\n" + (always.isEmpty ? "(none)" : always),
            "His quick-action buttons now:\n" + (buttons.isEmpty ? "(none)" : buttons),
            "The learning log (earlier suggestions and what he chose):\n" + (log.isEmpty ? "(empty)" : log),
        ].joined(separator: "\n\n")
        return AnswerPrompt(
            system: [PromptBlock(text: Self.instructions, cacheBreakpoint: true)],
            transcript: [PromptBlock(text: context), PromptBlock(text: "The call:\n" + transcript(lines: lines, answers: answers))],
            question: "Review this call."
        )
    }

    /// The call's lines and Claude's replies in time order, each reply with
    /// how it was asked.
    func transcript(lines: [Utterance], answers: [Answer]) -> String {
        let spoken = lines.map { (time: $0.start, text: "[\($0.start.clockTime(in: timeZone))] \($0.speaker.label): \($0.text)") }
        let replies = answers.filter { !$0.text.isEmpty }.map { answer -> (time: Date, text: String) in
            let how = switch answer.trigger {
            case .auto: "Auto, for \u{201C}\(answer.question)\u{201D}"
            case .answerNow: "Answer Now"
            case .typed: "Typed: \u{201C}\(answer.question)\u{201D}"
            case .quick: "Quick: \u{201C}\(answer.question)\u{201D}"
            }
            let text = answer.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            let cut = answer.state == .stopped ? " (cut off)" : ""
            return (answer.askedAt, "[\(answer.askedAt.clockTime(in: timeZone))] Claude (\(how)): \(text)\(cut)")
        }
        return (spoken + replies).sorted { $0.time < $1.time }.map(\.text).joined(separator: "\n")
    }
}
