import AppKit
import CallCore
import SwiftUI

/// The menu bar: File (Past Calls, the Sessions folder, Copy Transcript),
/// Call (everything for the call, with shortcuts) and View (the summary,
/// Keep on Top). The call window's own buttons do the same things.
struct CallCommands: Commands {
    let session: LiveSession
    let controls: WindowControls

    @Environment(\.openWindow) private var openWindow
    @AppStorage(TranscriptWindow.autoAnswerKey) private var autoAnswer = TranscriptWindow.autoAnswerByDefault
    @AppStorage(TranscriptWindow.keepOnTopKey) private var keepOnTop = TranscriptWindow.keepOnTopByDefault
    @AppStorage(TranscriptWindow.showsSummaryKey) private var showsSummary = false
    @AppStorage(TranscriptWindow.playbookKey) private var playbookName = TranscriptWindow.playbookByDefault
    @AppStorage(QuickAction.storageKey) private var storedQuickActions = ""

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Past Calls") { openWindow(id: PastCallsWindow.windowID) }
                .keyboardShortcut("y")
            Button("Open Sessions Folder") { TranscriptWindow.openSessionsFolder() }
            Divider()
            Button("Copy Transcript") { TranscriptWindow.copyTranscript(of: session) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(session.store.utterances.isEmpty)
        }

        CommandMenu("Call") {
            Button(isListening ? "Stop Call" : "Start Call") { controls.startStopRequests += 1 }
                .keyboardShortcut("r")
                .disabled(isBusy)
            Divider()
            Button("Answer Now") { session.answers.answerNow(transcript: session.store) }
                .keyboardShortcut("a", modifiers: [.control, .option])
                .disabled(!session.canAnswerNow)
            Button("Stop Answer") { session.answers.stop() }
                .keyboardShortcut(".")
                .disabled(!isAnswering)
            Toggle("Auto-Answer", isOn: $autoAnswer)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Ask Claude…") { controls.askRequests += 1 }
                .keyboardShortcut("k")
            Menu("Quick Actions") {
                ForEach(Array(quickActions.enumerated()), id: \.element.id) { index, action in
                    let button = Button(action.name) { session.answers.quickAction(action, transcript: session.store) }
                    if index < 9 {
                        button.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    } else {
                        button
                    }
                }
            }
            .disabled(quickActions.isEmpty)
            Divider()
            Menu("Playbook") {
                Picker("Playbook", selection: $playbookName) {
                    Text("None").tag("")
                    ForEach(playbooks) { playbook in
                        Text(playbook.name).tag(playbook.name)
                    }
                }
                .pickerStyle(.inline)
            }
            Button("Call Notes…") { controls.showingNotes = true }
            Button("Files…") { controls.showingFiles = true }
            Button("Edit Always Instructions…") { controls.editingAlways = true }
            Divider()
            Button("Review Suggestions…") { controls.reviewing = true }
                .disabled(session.reviews.waiting == 0)
        }

        CommandGroup(after: .sidebar) {
            Toggle("Summary", isOn: $showsSummary)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Summary in Its Own Window") { openWindow(id: SummaryPanel.windowID) }
            Toggle("Keep on Top", isOn: $keepOnTop)
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
        }
    }

    private var isListening: Bool { session.state == .listening }

    private var isBusy: Bool {
        switch session.state {
        case .preparing, .stopping: true
        case .idle, .listening, .failed: false
        }
    }

    /// Whether an answer is being written (the engine's own flag isn't observed).
    private var isAnswering: Bool {
        switch session.answers.answers.last?.state {
        case .waiting, .streaming: true
        default: false
        }
    }

    private var quickActions: [QuickAction] {
        QuickAction.decode(storedQuickActions).filter(\.isComplete)
    }

    private var playbooks: [Playbook] {
        (try? PlaybookLibrary().load()) ?? []
    }
}
