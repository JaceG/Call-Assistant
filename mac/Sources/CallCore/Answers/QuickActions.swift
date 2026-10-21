import Foundation

/// A prompt Jace sends in one click from a button under the answers, such as
/// "Shorter". It's answered like a typed question, seeing the whole call and
/// Claude's earlier answers.
public struct QuickAction: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// The button's name.
    public var name: String
    /// What's sent to Claude.
    public var prompt: String

    public init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    /// Whether it has both a name and a prompt, and so gets a button.
    public var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The buttons Jace chose to start with (2026-10-21).
    public static let starters = [
        QuickAction(name: "Shorter", prompt: "Make that shorter."),
        QuickAction(name: "Simpler", prompt: "Say that more simply, for someone non-technical."),
        QuickAction(name: "Example", prompt: "Give me a concrete example I can use."),
        QuickAction(name: "Ask them", prompt: "Give me a good question to ask them now."),
        QuickAction(name: "Recap", prompt: "Recap the call so far in three short points."),
    ]

    /// The stored list, as JSON text (the form the app's settings keep it in).
    /// An empty string means nothing was ever saved, so the starters are used.
    public static func decode(_ stored: String) -> [QuickAction] {
        guard !stored.isEmpty else { return starters }
        return (try? JSONDecoder().decode([QuickAction].self, from: Data(stored.utf8))) ?? starters
    }

    public static func encode(_ actions: [QuickAction]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(actions)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
