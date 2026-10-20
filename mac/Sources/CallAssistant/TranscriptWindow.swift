import AppKit
import CallCore
import SwiftUI

/// The live transcript of a call: toolbar actions, both sides' lines as they
/// arrive, and a status bar.
struct TranscriptWindow: View {
    let session: LiveSession

    @AppStorage("keepOnTop") private var keepOnTop = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// False once the user scrolls up, so new lines don't pull them back down.
    @State private var followsNewLines = true

    /// How close to the bottom still counts as "at the bottom" (points).
    private static let bottomTolerance: CGFloat = 24

    var body: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(state: session.state)
            }
            .toolbar { toolbar }
            .frame(minWidth: 420, minHeight: 300)
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        let store = session.store
        if store.utterances.isEmpty && store.partial.isEmpty {
            Text(isListening ? "Listening. Lines appear as people speak." : "Press Start when your call begins.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(store.utterances) { utterance in
                        TranscriptLine(time: utterance.start, speaker: utterance.speaker, text: utterance.text)
                    }
                    ForEach(Speaker.allCases, id: \.self) { speaker in
                        if let text = store.partial[speaker] {
                            TranscriptLine(time: nil, speaker: speaker, text: text, inProgress: true)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.bottomTolerance
            } action: { _, atBottom in
                followsNewLines = atBottom
            }
            .onChange(of: store.utterances.count) { followNewLines() }
            .onChange(of: store.partial) { followNewLines() }
        }
    }

    private func followNewLines() {
        if followsNewLines { scrollPosition.scrollTo(edge: .bottom) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { isListening ? await session.stop() : await session.start() }
            } label: {
                if isListening {
                    Label("Stop", systemImage: "stop.circle")
                } else {
                    Label("Start", systemImage: "record.circle")
                }
            }
            .disabled(isBusy)
            .help(isListening ? "Stop transcribing the call" : "Start transcribing the call")

            Button(action: copyTranscript) {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }
            .disabled(session.store.utterances.isEmpty)
            .help("Copy the transcript as text")

            Button(action: openSessionsFolder) {
                Label("Open Sessions Folder", systemImage: "folder")
            }
            .help("Show saved transcripts in Finder")

            Toggle(isOn: $keepOnTop) {
                Label("Keep on Top", systemImage: keepOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help(keepOnTop ? "Stop keeping this window above other windows" : "Keep this window above other windows")
        }
    }

    private var isListening: Bool { session.state == .listening }

    private var isBusy: Bool {
        switch session.state {
        case .preparing, .stopping: true
        case .idle, .listening, .failed: false
        }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.store.plainText(), forType: .string)
    }

    private func openSessionsFolder() {
        let folder = Paths.sessionsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// One line of the transcript: time, who spoke, what they said. Text still
/// being recognized has no time yet and shows in grey italics.
private struct TranscriptLine: View {
    let time: Date?
    let speaker: Speaker
    let text: String
    var inProgress = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // The hidden widest value keeps the columns aligned without a fixed width.
            ZStack(alignment: .leading) {
                Text(verbatim: "00:00:00").hidden()
                if let time { Text(verbatim: time.clockTime()) }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                Text(Speaker.them.label).hidden()
                Text(speaker.label)
                    .foregroundStyle(speaker == .them ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .fontWeight(.semibold)

            Text(text)
                .italic(inProgress)
                .foregroundStyle(inProgress ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }
}

/// Where the session is: ready, preparing (with download progress), listening,
/// stopping, or what went wrong.
private struct StatusBar: View {
    let state: LiveSession.State

    var body: some View {
        HStack {
            switch state {
            case .idle:
                Text("Ready")
            case .preparing(let message, let progress):
                Text(message)
                if let progress { ProgressView(value: progress) }
            case .listening:
                Image(systemName: "circle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.small)
                Text("Listening")
            case .stopping:
                Text("Stopping…")
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding()
        .background(.bar)
    }
}
