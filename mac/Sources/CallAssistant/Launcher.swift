import AppKit
import CallCore

/// Starts the app, or runs a command-line probe in its place when launched
/// with a `--probe-…` flag (see `Probes`).
@main
enum Launcher {
    static func main() {
        let arguments = CommandLine.arguments
        guard Probes.requested(in: arguments) != nil else {
            CallAssistantApp.main()
            return
        }
        // Run as a background app so macOS can show permission prompts for it.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            exit(await Probes.run(arguments))
        }
        app.run()
    }
}
