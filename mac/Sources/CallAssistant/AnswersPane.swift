import CallCore
import SwiftUI

/// Claude's answers for the call, newest at the bottom, and a field to type a
/// question. Sits under the transcript.
struct AnswersPane: View {
    let session: LiveSession

    @State private var scrollPosition = ScrollPosition(idType: UUID.self)
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            answers
            TextField("Ask Claude…", text: $question)
                .onSubmit(ask)
                .padding()
        }
    }

    @ViewBuilder private var answers: some View {
        let answers = session.answers.answers
        if answers.isEmpty {
            Text("Answers appear here. Press Answer Now, type a question, or turn on Auto-Answer.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(answers) { answer in
                        AnswerView(answer: answer)
                        if answer.id != answers.last?.id { Divider() }
                    }
                }
                .scrollTargetLayout()
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($scrollPosition)
            // A new answer scrolls its top into view and stays there while it
            // streams, so its first sentence (what to say) stays readable even
            // when the pane is short.
            .onAppear { showNewest(answers) }
            .onChange(of: answers.last?.id) { showNewest(answers) }
        }
    }

    private func showNewest(_ answers: [Answer]) {
        if let id = answers.last?.id { scrollPosition.scrollTo(id: id, anchor: .top) }
    }

    private func ask() {
        session.answers.ask(question, transcript: session.store)
        question = ""
    }
}

/// One answer: when and how it was asked, the question, then the answer as
/// it streams in, or how it ended.
private struct AnswerView: View {
    let answer: Answer

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: answer.askedAt.clockTime())
                    .font(.caption.monospacedDigit())
                Text(answer.trigger.label)
                // Kept short so a long question can't push the answer out of a short pane.
                Text(answer.question)
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !answer.text.isEmpty {
                Text(Self.styled(answer.text))
                    .textSelection(.enabled)
            }
            switch answer.state {
            case .waiting:
                Text("Thinking…")
                    .italic()
                    .foregroundStyle(.secondary)
            case .streaming, .done:
                EmptyView()
            case .stopped:
                Text("Stopped")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
            case .declined:
                Text("Claude declined to answer this one.")
                    .foregroundStyle(.secondary)
            }
        }
        // One answer reads as one item: "10:41:09 Auto How do you cache? Serve the cached copy…".
        .accessibilityElement(children: .combine)
    }

    /// The quick answer (the first paragraph; all of the text until a blank
    /// line arrives) in the window's own emphasis, then one blank line, then
    /// the longer answer. One text, so one selection copies the whole answer.
    private static func styled(_ text: String) -> AttributedString {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gap = text.range(of: "\n\n") else { return quick(text) }
        let longer = text[gap.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return quick(String(text[..<gap.lowerBound])) + AttributedString("\n\n") + inlineMarkdown(longer)
    }

    private static func quick(_ text: String) -> AttributedString {
        var quick = inlineMarkdown(text)
        quick.font = .body.weight(.semibold)
        return quick
    }

    /// Bold, italics, code and links; anything else shows as written.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
