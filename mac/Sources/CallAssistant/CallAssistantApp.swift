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
        answerNowKey = GlobalHotKey {
            if session.canAnswerNow { session.answers.answerNow(transcript: session.store) }
        }
        if answerNowKey == nil {
            Logger(subsystem: "com.jaceg.callassistant", category: "app").error("couldn't register ⌃⌥A; another app may hold it")
        }
    }

    var body: some Scene {
        Window("Call Assistant", id: "transcript") {
            TranscriptWindow(session: session)
        }
        .windowLevel(keepOnTop ? .floating : .normal)
    }
}
