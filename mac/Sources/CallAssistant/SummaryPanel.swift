import AppKit
import CallCore
import SwiftUI

/// The call's running summary, in the window's side panel or its own window:
/// when it was updated, Update Now when a newer version waits, Copy, and
/// the document. A new version waits while the pointer is over it.
struct SummaryPanel: View {
    let session: LiveSession
    /// In the side panel: a button to open the summary in its own window.
    var canPopOut = false

    /// The id of the summary's own window.
    static let windowID = "summary"

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let engine = session.summary
        VStack(spacing: 0) {
            header(engine)
            Divider()
            if let shown = engine.shown {
                ScrollView {
                    SummaryDocument(summary: shown.summary, previous: engine.previous)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(emptyText(engine))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Reading holds the next version back (see SummaryEngine); a closed
        // panel holds nothing.
        .onHover { engine.isHeld = $0 }
        .onDisappear { engine.isHeld = false }
    }

    private func header(_ engine: SummaryEngine) -> some View {
        HStack {
            VStack(alignment: .leading) {
                if engine.isUpdating {
                    Text("Updating…")
                } else if let shown = engine.shown {
                    Text("Updated \(shown.at.clockTime())")
                } else {
                    Text("Summary")
                }
                if engine.previous != nil && engine.shown != nil {
                    Text("Highlighted: new since the last update")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let failure = engine.failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .font(.callout)
            Spacer(minLength: 0)

            if engine.pending != nil {
                Button("Update Now") { engine.applyPending() }
                    .help("Show the newer summary that's waiting")
            }
            Button(action: copy) {
                Label("Copy Summary", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(engine.shown == nil)
            .help("Copy the summary as Markdown")
            if canPopOut {
                Button {
                    openWindow(id: Self.windowID)
                } label: {
                    Label("Open in Its Own Window", systemImage: "macwindow.badge.plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Open the summary in its own window")
            }
        }
        .padding()
    }

    private func emptyText(_ engine: SummaryEngine) -> String {
        if engine.isUpdating { return "Writing the first summary…" }
        if session.isRunning { return "The summary appears about a minute into the call." }
        return "Start a call to get a running summary."
    }

    private func copy() {
        guard let shown = session.summary.shown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown.summary.markdown(updatedAt: shown.at), forType: .string)
    }
}

/// The summary's sections in reading order; empty ones are left out. Items
/// new or changed since the previous version are highlighted until the next.
private struct SummaryDocument: View {
    let summary: CallSummary
    let previous: CallSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: HeadedSection<EmptyView>.spacing) {
            Text(summary.summary)
                .modifier(NewMark(isNew: isNew(summary.summary, in: .summary)))

            section("Key points", .keyPoints)
            if !summary.questions.isEmpty {
                HeadedSection(title: "Questions and answers") {
                    ForEach(Array(zip(summary.questions, summary.texts(.questions)).enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading) {
                            Text("\(pair.0.askedBy): \(pair.0.question)")
                                .fontWeight(.semibold)
                            Text(pair.0.answer)
                                .foregroundStyle(.secondary)
                        }
                        .modifier(NewMark(isNew: isNew(pair.1, in: .questions)))
                    }
                }
            }
            if !summary.quotes.isEmpty {
                HeadedSection(title: "Quotes") {
                    ForEach(Array(summary.quotes.enumerated()), id: \.offset) { _, quote in
                        VStack(alignment: .leading) {
                            Text("\u{201C}\(quote.words)\u{201D}")
                                .italic()
                            Text("\(quote.speaker), \(quote.time)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .modifier(NewMark(isNew: isNew(quote.words, in: .quotes)))
                    }
                }
            }
            section("Decisions", .decisions)
            section("Action items", .actionItems)
            section("Open questions", .openQuestions)
            section("Names and numbers", .namesAndNumbers)
            section("Where this could go next", .next)
        }
        .textSelection(.enabled)
    }

    private func isNew(_ text: String, in part: CallSummary.Part) -> Bool {
        CallSummary.isNew(text, in: part, since: previous)
    }

    @ViewBuilder private func section(_ title: String, _ part: CallSummary.Part) -> some View {
        let items = summary.texts(part)
        if !items.isEmpty {
            HeadedSection(title: title) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: "•")
                            .accessibilityHidden(true)
                        Text(item)
                    }
                    .modifier(NewMark(isNew: isNew(item, in: part)))
                }
            }
        }
    }
}

/// A heading and the items under it, in the summary and the review sheet.
struct HeadedSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    /// The gap between one section and the next (points).
    static var spacing: CGFloat { 16 }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// One summary item as one VoiceOver item, highlighted when it's new or
/// changed (VoiceOver reads that as "New").
private struct NewMark: ViewModifier {
    let isNew: Bool

    /// The highlight's corner radius (points).
    private static let cornerRadius: CGFloat = 3
    /// How strongly the find-highlight colour shows behind the text.
    private static let highlightOpacity = 0.35

    func body(content: Content) -> some View {
        if isNew {
            content
                .background(Color(nsColor: .findHighlightColor).opacity(Self.highlightOpacity), in: .rect(cornerRadius: Self.cornerRadius))
                .accessibilityElement(children: .combine)
                .accessibilityValue("New")
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }
}
