import Foundation

/// Instructions Jace writes once for a kind of call (an interview, a client
/// check-in) and picks before the call starts. Claude follows them in every
/// answer. One Markdown file per playbook, named after the file.
public struct Playbook: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let instructions: String

    public init(name: String, instructions: String) {
        self.name = name
        self.instructions = instructions
    }
}

/// Instructions Claude follows on every call, whatever the playbook: one
/// Markdown file Jace edits in the app, and that accepted suggestions from
/// the review after a call are added to.
public struct AlwaysInstructions: Sendable {
    public let file: URL

    public init(file: URL = Paths.alwaysFile) {
        self.file = file
    }

    /// The instructions, or "" when there are none yet.
    public func load() -> String {
        (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func save(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data((trimmed.isEmpty ? "" : trimmed + "\n").utf8).write(to: file, options: .atomic)
    }

    /// Adds one instruction on its own line at the end.
    public func append(_ instruction: String) throws {
        let current = load()
        try save(current.isEmpty ? instruction : current + "\n" + instruction)
    }
}

/// The folder of playbook files.
public struct PlaybookLibrary: Sendable {
    public let directory: URL

    /// Written when the folder has no playbooks yet, so there's one to pick
    /// and an example of the format.
    static let starter = Playbook(name: "General", instructions: "Keep answers short and concrete. Lead with the answer.")

    public init(directory: URL = Paths.playbooksDirectory) {
        self.directory = directory
    }

    /// Every `.md` file in the folder, sorted by name. Creates the folder, and
    /// the starter playbook, when there are none. A file that isn't UTF-8
    /// text is skipped.
    public func load() throws -> [Playbook] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "md" }

        if files.isEmpty {
            let url = directory.appendingPathComponent("\(Self.starter.name).md")
            try Data((Self.starter.instructions + "\n").utf8).write(to: url, options: .withoutOverwriting)
            return [Self.starter]
        }

        return files.compactMap { url -> Playbook? in
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                Log.session.error("skipped playbook \(url.lastPathComponent, privacy: .public): not UTF-8 text")
                return nil
            }
            return Playbook(name: url.deletingPathExtension().lastPathComponent,
                            instructions: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
