import Foundation

/// Where Call Assistant keeps its files. Under Application Support, so macOS
/// doesn't ask for folder access the way it would for ~/Documents.
public enum Paths {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallAssistant", isDirectory: true)
    }

    /// One Markdown transcript per call.
    public static var sessionsDirectory: URL {
        supportDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// One Markdown file of instructions per kind of call.
    public static var playbooksDirectory: URL {
        supportDirectory.appendingPathComponent("Playbooks", isDirectory: true)
    }
}
