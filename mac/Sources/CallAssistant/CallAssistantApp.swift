import CallCore
import SwiftUI

struct CallAssistantApp: App {
    @State private var session = LiveSession()
    /// Floats the window above the call app; toggled from the window's toolbar.
    @AppStorage(TranscriptWindow.keepOnTopKey) private var keepOnTop = TranscriptWindow.keepOnTopByDefault

    var body: some Scene {
        Window("Call Assistant", id: "transcript") {
            TranscriptWindow(session: session)
        }
        .windowLevel(keepOnTop ? .floating : .normal)
    }
}
