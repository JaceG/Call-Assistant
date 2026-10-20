import Foundation

/// One file Claude can use on a call, as text.
public struct ContextFile: Sendable, Equatable {
    /// As shown to Claude and in the window: the picked folder's name and the
    /// path inside it ("cluely-alternative/mac/Package.swift"), or the picked
    /// file's name.
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// A file that was left out, and why.
public struct SkippedFile: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Keys, passwords and the like (.env, .pem…). Never sent, even when picked.
        case secret
        /// Images, audio, archives, or bytes that aren't UTF-8 text.
        case notText
        /// More text than one file should carry (likely generated data).
        case tooBig
        /// Lockfiles, minified files and source maps.
        case generated
        case unreadable
        case missing
        /// A folder with more files than the limit; the rest weren't read.
        case tooMany

        public var label: String {
            switch self {
            case .secret: "secrets file, never sent"
            case .notText: "not text"
            case .tooBig: "over 1 MB of text"
            case .generated: "generated"
            case .unreadable: "couldn't be read"
            case .missing: "not found"
            case .tooMany: "too many files; the rest weren't read"
            }
        }
    }

    public let path: String
    public let reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }
}

/// The folders and files picked for a call, read as text.
public struct CallFiles: Sendable, Equatable {
    /// How Claude gets them: all of the text with every answer, or a list it
    /// searches and reads from while answering.
    public enum Mode: Sendable, Equatable {
        case whole
        case lookUp
    }

    /// The most estimated tokens sent whole with every answer.
    public static let wholeBudget = 150_000
    /// Tokens per byte of text, for the estimate: measured 2026-10-20, this
    /// repository's 355 KB of code and Markdown came to 143,219 tokens, about
    /// 2.5 bytes per token.
    static let tokensPerByte = 0.4

    public static let none = CallFiles(files: [], skipped: [])

    /// Sorted by path, so the same picks always give the same prompt.
    public let files: [ContextFile]
    public let skipped: [SkippedFile]
    public let byteCount: Int

    public init(files: [ContextFile], skipped: [SkippedFile]) {
        self.files = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        self.skipped = skipped.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        byteCount = files.reduce(0) { $0 + $1.text.utf8.count }
    }

    public var isEmpty: Bool { files.isEmpty }

    public var estimatedTokens: Int { Int(Double(byteCount) * Self.tokensPerByte) }

    public var mode: Mode { estimatedTokens <= Self.wholeBudget ? .whole : .lookUp }
}
