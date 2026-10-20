import CallCore
import os
import SwiftUI

struct CallAssistantApp: App {
    @State private var session: LiveSession
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
            TranscriptWindow(session: session)
        }
        .windowLevel(keepOnTop ? .floating : .normal)
    }
}
