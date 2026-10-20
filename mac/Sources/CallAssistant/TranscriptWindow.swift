import AppKit
import CallCore
import SwiftUI

/// The live transcript of a call: toolbar actions, both sides' lines as they
/// arrive, Claude's answers under them, and a status bar.
struct TranscriptWindow: View {
    let session: LiveSession

    /// Keep on Top's stored setting, shared with the app's window level.
    static let keepOnTopKey = "keepOnTop"
    static let keepOnTopByDefault = true
    /// Auto-Answer's stored setting.
    static let autoAnswerKey = "autoAnswer"
    static let autoAnswerByDefault = false
    /// The chosen playbook's name; "" for none.
    static let playbookKey = "playbook"
    static let playbookByDefault = "General"
    /// The folders and files picked for Claude, one path per line.
    static let filesKey = "files"

    @AppStorage(keepOnTopKey) private var keepOnTop = keepOnTopByDefault
    @AppStorage(autoAnswerKey) private var autoAnswer = autoAnswerByDefault
    @AppStorage(playbookKey) private var playbookName = playbookByDefault
    @AppStorage(filesKey) private var filePaths = ""
    @State private var playbooks: [Playbook] = []
    @State private var showingNotes = false
    @State private var showingFiles = false
    @State private var readingFiles = false
    /// Counts reads of the picks, so an older, slower read can't replace a newer one.
    @State private var filesRead = 0
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// False once the user scrolls up, so new lines don't pull them back down.
    @State private var followsNewLines = true

    /// How close to the bottom still counts as "at the bottom" (points).
    private static let bottomTolerance: CGFloat = 24
    /// The Call Notes editor's size (points).
    static let notesSize = CGSize(width: 320, height: 180)

    var body: some View {
        // The split view ignores safe-area insets, so the status bar sits
        // below it in a stack rather than in an inset.
        VStack(spacing: 0) {
            VSplitView {
                transcript
                AnswersPane(session: session)
            }
            Divider()
            StatusBar(state: session.state)
        }
        .toolbar { toolbar }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear {
            session.answers.autoAnswer = autoAnswer
            reloadPlaybooks()
        }
        .task { await readFiles() }
        .onChange(of: autoAnswer) { session.answers.autoAnswer = autoAnswer }
        .onChange(of: playbookName) { applyPlaybook() }
        .onChange(of: filePaths) { Task { await readFiles() } }
        // Playbook files added or edited in Finder show up when you come back to the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadPlaybooks()
        }
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        let store = session.store
        if store.utterances.isEmpty && store.partial.isEmpty {
            // While preparing or stopping, the status bar says what's happening.
            Text(isListening ? "Listening. Lines appear as people speak." : isBusy ? "" : "Press Start when your call begins.")
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
                Task {
                    if isListening {
                        await session.stop()
                    } else {
                        // Files may have changed since they were picked.
                        await readFiles()
                        await session.start()
                    }
                }
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
            .help("Open the Sessions folder, where each call's transcript is saved")

            Toggle(isOn: $keepOnTop) {
                Label("Keep on Top", systemImage: keepOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help(keepOnTop ? "Stop keeping this window above other windows" : "Keep this window above other windows")

            // A menu whose label names the playbook in use; the picker inside
            // marks it with a check.
            Menu {
                Picker("Playbook", selection: $playbookName) {
                    Text("None").tag("")
                    ForEach(playbooks) { playbook in
                        Text(playbook.name).tag(playbook.name)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(playbookName.isEmpty ? "No Playbook" : playbookName, systemImage: "list.bullet.rectangle")
            }
            .labelStyle(.titleAndIcon)
            .help("Choose the instructions Claude follows on this call")

            Button {
                showingNotes.toggle()
            } label: {
                Label("Call Notes", systemImage: "note.text")
            }
            .help("Write notes about this call for Claude")
            .popover(isPresented: $showingNotes) {
                TextEditor(text: callNotes)
                    .accessibilityLabel("Call notes")
                    .frame(width: Self.notesSize.width, height: Self.notesSize.height)
                    .padding()
            }

            Button {
                showingFiles.toggle()
            } label: {
                Label("Files", systemImage: picks.isEmpty ? "books.vertical" : "books.vertical.fill")
            }
            .help("Choose folders and files Claude can use on this call")
            .popover(isPresented: $showingFiles) {
                FilesPopover(picks: picks, files: session.answers.files, isReading: readingFiles,
                             add: addFiles, remove: removePick)
            }

            Button {
                session.answers.answerNow(transcript: session.store)
            } label: {
                Label("Answer Now", systemImage: "sparkles")
            }
            .disabled(!session.canAnswerNow)
            .help("Ask Claude to answer what they just said (⌃⌥A)")

            Toggle(isOn: $autoAnswer) {
                Label("Auto-Answer", systemImage: autoAnswer ? "bolt.fill" : "bolt")
            }
            .toggleStyle(.button)
            .help(autoAnswer ? "Stop answering their questions automatically" : "Answer their questions automatically")
        }
    }

    // MARK: Files

    private var picks: [URL] {
        filePaths.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// Reads the picks and hands them to the session.
    private func readFiles() async {
        filesRead += 1
        let read = filesRead
        readingFiles = true
        let files = await FileCollector().collect(picks)
        guard read == filesRead else { return }
        session.useFiles(files)
        readingFiles = false
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders and files Claude can use on this call."
        // Modal, so it shows above this window when it floats.
        guard panel.runModal() == .OK else { return }
        let paths = picks.map(\.path) + panel.urls.map(\.path).filter { !picks.map(\.path).contains($0) }
        filePaths = paths.joined(separator: "\n")
        showingFiles = true
    }

    private func removePick(_ pick: URL) {
        filePaths = picks.filter { $0.path != pick.path }.map(\.path).joined(separator: "\n")
    }

    private var callNotes: Binding<String> {
        Binding(get: { session.answers.callNotes }, set: { session.answers.callNotes = $0 })
    }

    /// Reads the Playbooks folder again. If it can't be read, the list and
    /// the choice stay as they were rather than falling back to none.
    private func reloadPlaybooks() {
        guard let loaded = try? PlaybookLibrary().load() else { return }
        playbooks = loaded
        if !playbookName.isEmpty && !loaded.contains(where: { $0.name == playbookName }) {
            playbookName = ""
        }
        applyPlaybook()
    }

    private func applyPlaybook() {
        session.answers.playbook = playbooks.first { $0.name == playbookName }
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
        // One line reads as one item: "10:41:03 Them Can you walk me through…".
        .accessibilityElement(children: .combine)
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
                    .accessibilityHidden(true)
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
