import CallCore
import SwiftUI

struct CallAssistantApp: App {
    var body: some Scene {
        Window("Call Assistant", id: "transcript") {
            Text("Call Assistant \(AppInfo.version)")
                .frame(minWidth: 420, minHeight: 300)
        }
    }
}
