import AppKit
import CallCore
import SwiftUI

/// The suggestions from the review after a call: Always lines and quick
/// actions to add, and feature ideas to keep for a developer, each with
/// Claude's reason. Nothing changes until Jace adds or keeps one.
struct ReviewSheet: View {
    let inbox: ReviewInbox

    @Environment(\.dismiss) private var dismiss

    /// The sheet's size (points).
    private static let size = CGSize(width: 520, height: 520)
    /// Extra room above and below each suggestion (points).
    fileprivate static let suggestionPadding: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading) {
                Text("Suggestions from This Call")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(inbox.call)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()
            if let review = inbox.review {
                ScrollView {
                    content(review)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Nothing left to decide.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()

            HStack {
                if let failure = inbox.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Skip All") { inbox.skipAll() }
                    .disabled(inbox.review == nil)
                    .help("Skip every suggestion that's left")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .help("Close; suggestions you haven't decided on stay for later")
            }
            .padding()
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Esc closes it, like Done.
        .onExitCommand { dismiss() }
    }

    @ViewBuilder private func content(_ review: SessionReview) -> some View {
        VStack(alignment: .leading, spacing: HeadedSection<EmptyView>.spacing) {
            if !review.observations.isEmpty {
                HeadedSection(title: "What Claude noticed") {
                    ForEach(Array(review.observations.enumerated()), id: \.offset) { _, observation in
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: "•")
                                .accessibilityHidden(true)
                            Text(observation)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if !review.instructions.isEmpty {
                HeadedSection(title: "For your Always instructions") {
                    ForEach(review.instructions, id: \.self) { instruction in
                        Suggestion(text: instruction.text, reason: instruction.reason) {
                            Button("Add") { inbox.add(instruction) }
                                .help("Add this line to your Always instructions")
                            Button("Skip") { inbox.skip(instruction) }
                                .help("Don't add it, and don't suggest it again")
                        }
                    }
                }
            }
            if !review.quickActions.isEmpty {
                HeadedSection(title: "New quick-action buttons") {
                    ForEach(review.quickActions, id: \.self) { idea in
                        Suggestion(title: idea.name, text: idea.prompt, reason: idea.reason) {
                            Button("Add") { inbox.add(idea) }
                                .help("Add a \(idea.name) button above Ask Claude")
                            Button("Skip") { inbox.skip(idea) }
                                .help("Don't add it, and don't suggest it again")
                        }
                    }
                }
            }
            if !review.features.isEmpty {
                HeadedSection(title: "Feature ideas for the app") {
                    ForEach(review.features, id: \.self) { idea in
                        Suggestion(title: idea.title, text: idea.description, reason: idea.reason) {
                            Button("Keep") { inbox.keep(idea) }
                                .help("Save it to Feature Ideas.md for a developer")
                            Button("Copy") { copy(idea) }
                                .help("Copy the idea to paste into Claude Code")
                            Button("Skip") { inbox.skip(idea) }
                                .help("Don't keep it, and don't suggest it again")
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func copy(_ idea: SessionReview.FeatureIdea) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(idea.title)\n\n\(idea.description)\n\nWhy: \(idea.reason)", forType: .string)
    }

    /// One suggestion: its name (if any), what it is, Claude's reason, and
    /// the buttons to decide.
    private struct Suggestion<Buttons: View>: View {
        var title: String?
        let text: String
        let reason: String
        @ViewBuilder let buttons: Buttons

        var body: some View {
            VStack(alignment: .leading) {
                if let title {
                    Text(title)
                        .fontWeight(.semibold)
                }
                Text(text)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    buttons
                }
                .controlSize(.small)
            }
            .padding(.vertical, ReviewSheet.suggestionPadding)
        }
    }
}
