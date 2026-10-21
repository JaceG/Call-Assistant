import AppKit
import CallCore
import SwiftUI

/// Every saved call: a searchable list, newest first, and the chosen call's
/// transcript (with Claude's answers in place) or its summary, with ways to
/// export, share and copy it.
struct PastCallsWindow: View {
    let session: LiveSession

    /// The id of this window.
    static let windowID = "pastCalls"

    enum Showing: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case summary = "Summary"
        var id: Self { self }
    }

    @State private var calls: [PastCall] = []
    /// Each call's transcript and summary text, lowercased, for searching.
    @State private var searchText: [URL: String] = [:]
    @State private var selection: PastCall.ID?
    @State private var content: PastCallContent?
    @State private var showing = Showing.transcript
    @State private var search = ""
    @State private var failure: String?

    /// The list's widths (points).
    private static let listWidth: (min: CGFloat, ideal: CGFloat) = (220, 280)
    /// The smallest the window can be: room for the list and a transcript (points).
    private static let minimumSize = CGSize(width: 640, height: TranscriptWindow.minimumSize.height)

    var body: some View {
        NavigationSplitView {
            List(filteredCalls, selection: $selection) { call in
                PastCallRow(call: call)
            }
            .navigationSplitViewColumnWidth(min: Self.listWidth.min, ideal: Self.listWidth.ideal)
            .overlay {
                if calls.isEmpty {
                    Text("No calls yet. Each call you record appears here.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else if filteredCalls.isEmpty {
                    Text("No calls mention \u{201C}\(search)\u{201D}.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        } detail: {
            VStack(spacing: 0) {
                detail
                // An export or read failure, under whatever is shown.
                if let failure {
                    Divider()
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search calls")
        .toolbar { toolbar }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .task { await reload() }
        .onChange(of: selection) { load() }
        // Searching shows the first match rather than a call it filtered out.
        .onChange(of: search) {
            if !filteredCalls.contains(where: { $0.id == selection }) { selection = filteredCalls.first?.id }
        }
        // A call that just ended shows up without reopening the window.
        .onChange(of: session.state) {
            if session.state == .idle { Task { await reload() } }
        }
    }

    private var selected: PastCall? {
        calls.first { $0.id == selection }
    }

    private var filteredCalls: [PastCall] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return calls }
        return calls.filter { call in
            let text = searchText[call.file] ?? ""
            return words.allSatisfy(text.contains)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if selected != nil, let content {
            switch showing {
            case .transcript:
                PastCallTranscript(content: content)
            case .summary:
                if let summary = content.summary {
                    ScrollView {
                        VStack(alignment: .leading) {
                            if let updated = content.summaryUpdated {
                                Text("Updated \(updated)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            SummaryDocument(summary: summary, previous: nil)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("No summary was made for this call.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            Text(calls.isEmpty || failure != nil ? "" : "Choose a call to see its transcript and summary.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Show", selection: $showing) {
                ForEach(Showing.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Show the call's transcript or its summary")
            .disabled(selected == nil)

            Button(action: export) {
                Label("Export…", systemImage: "square.and.arrow.down")
            }
            .disabled(selected == nil)
            .help("Save the call's summary and transcript as one Markdown file")

            ShareLink(items: selected.map(files(of:)) ?? []) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(selected == nil)
            .help("Send the call's files with AirDrop, Mail, Messages and others")

            Button(action: showInFinder) {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(selected == nil)
            .help("Show the call's files in Finder")

            Button(action: copy) {
                Label(showing == .transcript ? "Copy Transcript" : "Copy Summary", systemImage: "doc.on.doc")
            }
            .disabled(selected == nil || (showing == .summary && selected?.summaryFile == nil))
            .help(showing == .transcript ? "Copy the transcript as text" : "Copy the summary as Markdown")
        }
    }

    // MARK: Loading

    private func reload() async {
        let (calls, texts) = await Task.detached(priority: .userInitiated) { () -> ([PastCall], [URL: String]) in
            let calls = SessionReader.calls()
            var texts: [URL: String] = [:]
            for call in calls {
                let transcript = (try? String(contentsOf: call.file, encoding: .utf8)) ?? ""
                let summary = call.summaryFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                texts[call.file] = (transcript + "\n" + summary).lowercased()
            }
            return (calls, texts)
        }.value
        self.calls = calls
        searchText = texts
        if !filteredCalls.contains(where: { $0.id == selection }) {
            selection = filteredCalls.first?.id
        }
        load()
    }

    private func load() {
        guard let call = selected else {
            content = nil
            failure = nil
            return
        }
        do {
            content = try SessionReader.read(call)
            failure = nil
        } catch {
            content = nil
            failure = "Couldn't read this call: \(error.localizedDescription)"
        }
    }

    // MARK: Actions

    private func files(of call: PastCall) -> [URL] {
        [call.file] + (call.summaryFile.map { [$0] } ?? [])
    }

    /// The summary (if any), then the transcript, in one Markdown file.
    private func combinedMarkdown(_ call: PastCall) -> String {
        let transcript = (try? String(contentsOf: call.file, encoding: .utf8)) ?? ""
        guard let summaryFile = call.summaryFile, let summary = try? String(contentsOf: summaryFile, encoding: .utf8) else {
            return transcript
        }
        return summary + "\n---\n\n" + transcript
    }

    private func export() {
        guard let call = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(call.file.deletingPathExtension().lastPathComponent).md"
        panel.message = "Save the call's summary and transcript as one Markdown file."
        // Modal, so it shows above the call window when that one floats.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(combinedMarkdown(call).utf8).write(to: url, options: .atomic)
            failure = nil
        } catch {
            failure = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func showInFinder() {
        guard let call = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files(of: call))
    }

    private func copy() {
        guard let call = selected else { return }
        let file = showing == .summary ? call.summaryFile : call.file
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One call in the list: when, how long and how much, and how it began.
private struct PastCallRow: View {
    let call: PastCall

    var body: some View {
        VStack(alignment: .leading) {
            Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                .fontWeight(.semibold)
            Text(details)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !call.preview.isEmpty {
                Text(call.preview)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
        }
        // One row reads as one item.
        .accessibilityElement(children: .combine)
    }

    /// "8 min · 99 lines · 3 answers".
    private var details: String {
        let minutes = max(Int((call.duration / 60).rounded()), call.lineCount > 0 ? 1 : 0)
        let answers = call.answerCount == 1 ? "1 answer" : "\(call.answerCount.formatted()) answers"
        let lines = call.lineCount == 1 ? "1 line" : "\(call.lineCount.formatted()) lines"
        return "\(minutes) min · \(lines) · \(answers)"
    }
}

/// A saved call's lines in time order with Claude's answers among them, as
/// in the call window.
private struct PastCallTranscript: View {
    let content: PastCallContent

    private enum Entry: Identifiable {
        case line(Utterance)
        case answer(Answer)

        var id: UUID {
            switch self {
            case .line(let line): line.id
            case .answer(let answer): answer.id
            }
        }

        var time: Date {
            switch self {
            case .line(let line): line.start
            case .answer(let answer): answer.askedAt
            }
        }
    }

    private var entries: [Entry] {
        (content.lines.map(Entry.line) + content.answers.map(Entry.answer)).sorted { $0.time < $1.time }
    }

    var body: some View {
        if content.lines.isEmpty && content.answers.isEmpty {
            Text("Nothing was said on this call.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .line(let line):
                            TranscriptLine(time: line.start, speaker: line.speaker, text: line.text)
                        case .answer(let answer):
                            // Boxed, so Claude's answers stand apart from the lines around them.
                            GroupBox {
                                AnswerView(answer: answer)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
