import Foundation

/// One piece of a prompt. `cacheBreakpoint` marks the end of a stretch the
/// provider should cache, because later requests start with the same text.
public struct PromptBlock: Sendable, Equatable {
    public var text: String
    public var cacheBreakpoint: Bool
    /// Keep the cache for an hour rather than five minutes, for text that
    /// stays the same all call (the files). Only with `cacheBreakpoint`.
    public var cachesForAnHour: Bool

    public init(text: String, cacheBreakpoint: Bool = false, cachesForAnHour: Bool = false) {
        self.text = text
        self.cacheBreakpoint = cacheBreakpoint
        self.cachesForAnHour = cachesForAnHour
    }
}

/// Everything one answer request carries: instructions (the base prompt, the
/// playbook, the call notes), the transcript so far, and what to answer.
public struct AnswerPrompt: Sendable, Equatable {
    public var system: [PromptBlock]
    /// Frozen chunks first, then the newest lines.
    public var transcript: [PromptBlock]
    public var question: String
    /// Tools to search and read the picked files, when they're too big to
    /// send whole.
    public var lookup: FileLookup?

    public init(system: [PromptBlock], transcript: [PromptBlock], question: String, lookup: FileLookup? = nil) {
        self.system = system
        self.transcript = transcript
        self.question = question
        self.lookup = lookup
    }
}

/// Token counts for one answer, as the API reports them.
public struct Usage: Sendable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    /// Adds another request's counts, for an answer that took several.
    public mutating func add(_ other: Usage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
    }
}

/// What an answer stream delivers, in order: pieces of text (and, while
/// Claude looks in the files, what it's looking up), then one ending.
public enum AnswerEvent: Sendable, Equatable {
    case text(String)
    /// Claude is searching or reading the picked files ("Reading …").
    case lookingUp(String)
    case finished(stopReason: String, usage: Usage)
    /// The model declined (`stop_reason: "refusal"`), with the API's category.
    case declined(category: String?)
}

public enum AnswerError: LocalizedError, Equatable {
    case noKey
    case keychainDenied
    case keychain(status: Int32)
    case keyRejected
    case rateLimited(retryAfter: Int?)
    case overloaded
    case http(status: Int, message: String)
    case network(String)
    case badStream(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: "No Claude API key in the Keychain. See the README to add one."
        case .keychainDenied: "Call Assistant isn't allowed to read the Claude API key. Allow it when macOS asks."
        case .keychain(let status): "Couldn't read the Claude API key from the Keychain (error \(status))."
        case .keyRejected: "Claude rejected the API key."
        case .rateLimited(let seconds?): "Claude is busy. Try again in \(seconds) s."
        case .rateLimited(nil), .overloaded: "Claude is busy. Try again in a moment."
        case .http(let status, let message): "Claude returned an error (\(status)): \(message)"
        case .network(let message): "Couldn't reach Claude: \(message)"
        case .badStream(let message): "Claude's reply couldn't be read: \(message)"
        }
    }
}

/// Something that answers a prompt as a stream: Claude today, other models
/// later. Cancelling the task that reads the stream cancels the request.
public protocol AnswerProvider: Sendable {
    func answer(_ prompt: AnswerPrompt) -> AsyncThrowingStream<AnswerEvent, Error>
    /// Caches the prompt's system text without answering, so the next answer
    /// starts sooner. Providers without a cache do nothing.
    func warm(_ prompt: AnswerPrompt) async throws -> Usage
}

extension AnswerProvider {
    public func warm(_ prompt: AnswerPrompt) async throws -> Usage { Usage() }
}
