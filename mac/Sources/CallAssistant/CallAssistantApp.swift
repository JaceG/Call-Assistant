import CallCore
import os
import SwiftUI

struct CallAssistantApp: App {
    @State private var session: LiveSession
    /// What the menu bar asks the call window to do.
    @State private var controls = WindowControls()
    /// Floats the window above the call app; toggled from the window's toolbar.
    @AppStorage(TranscriptWindow.keepOnTopKey) private var keepOnTop = TranscriptWindow.keepOnTopByDefault
    /// ⌃⌥A: Answer Now, even while the call app is in front.
    private let answerNowKey: GlobalHotKey?

    init() {
        let session = LiveSession()
        _session = State(initialValue: session)
        let log = Logger(subsystem: "com.jaceg.callassistant", category: "app")
        answerNowKey = GlobalHotKey {
            if session.canAnswerNow {
                log.info("⌃⌥A pressed: answering")
                session.answers.answerNow(transcript: session.store)
            } else {
                log.info("⌃⌥A pressed: nothing to answer yet")
            }
        }
        if answerNowKey == nil {
            log.error("couldn't register ⌃⌥A; another app may hold it")
        } else {
            log.info("⌃⌥A registered")
        }
    }

    var body: some Scene {
        Window("Call Assistant", id: "transcript") {
            TranscriptWindow(session: session, controls: controls)
        }
        .windowLevel(keepOnTop ? .floating : .normal)
        .commands { CallCommands(session: session, controls: controls) }

        // The summary on its own, opened from the side panel.
        Window("Call Summary", id: SummaryPanel.windowID) {
            SummaryPanel(session: session)
                .frame(minWidth: TranscriptWindow.summaryWidth.min, minHeight: TranscriptWindow.minimumSize.height)
        }
        .windowLevel(keepOnTop ? .floating : .normal)
        .defaultLaunchBehavior(.suppressed)

        Window("Past Calls", id: PastCallsWindow.windowID) {
            PastCallsWindow(session: session)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}
