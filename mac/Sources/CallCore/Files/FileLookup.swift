import Foundation

/// Claude's two tools for files too big to send whole: search them, and read
/// one. Both work on the text already read into memory, so a lookup takes
/// milliseconds; the time goes to the extra request.
public struct FileLookup: Sendable, Equatable {
    public let files: CallFiles

    static let searchLimit = 40
    static let lineLimit = 200
    static let readLineLimit = 800
    static let readCharacterLimit = 40_000

    public init(files: CallFiles) {
        self.files = files
    }

    /// The tools as the Messages API defines them. Their inputs are a few
    /// words, so streaming them eagerly would gain nothing.
    static var definitions: [[String: Any]] {
        [
            [
                "name": "search_files",
                "description": "Searches the text of the files Jace picked for this call. Returns the files whose path matches, then up to \(searchLimit) matching lines as path:line: text. Use a few distinctive words, such as a name from the code or a term from the question.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Words that must all appear on a line, in any order. Case doesn't matter."],
                    ],
                    "required": ["query"],
                ],
            ],
            [
                "name": "read_file",
                "description": "Reads one of the picked files with line numbers, up to \(readLineLimit) lines at a time.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "The file's path exactly as listed."],
                        "start_line": ["type": "integer", "description": "The first line to read (from 1). Defaults to 1."],
                        "end_line": ["type": "integer", "description": "The last line to read. Defaults to \(readLineLimit) lines after start_line."],
                    ],
                    "required": ["path"],
                ],
            ],
        ]
    }

    /// Runs a tool call, returning the text to send back and whether it failed.
    func run(name: String, input: [String: Any]) -> (text: String, isError: Bool) {
        switch name {
        case "search_files":
            guard let query = input["query"] as? String else { return ("search_files needs a query.", true) }
            return search(query)
        case "read_file":
            guard let path = input["path"] as? String else { return ("read_file needs a path.", true) }
            return read(path, from: input["start_line"] as? Int, to: input["end_line"] as? Int)
        default:
            return ("There's no tool named \(name).", true)
        }
    }

    /// What the answer shows while a tool runs.
    static func activity(name: String, input: [String: Any]) -> String {
        switch name {
        case "search_files": "Searching the files for \u{201C}\(input["query"] as? String ?? "")\u{201D}…"
        case "read_file": "Reading \(input["path"] as? String ?? "a file")…"
        default: "Looking in the files…"
        }
    }

    // MARK: Search

    func search(_ query: String) -> (text: String, isError: Bool) {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return ("Give a word or phrase to search for.", true) }
        func matches(_ text: String) -> Bool {
            let lower = text.lowercased()
            return words.allSatisfy(lower.contains)
        }

        var out: [String] = []
        let paths = files.files.map(\.path).filter(matches)
        if !paths.isEmpty {
            out.append("Files whose path matches:")
            out += paths.prefix(Self.searchLimit).map { "  \($0)" }
        }

        var shown = 0
        var more = 0
        for file in files.files {
            var number = 0
            file.text.enumerateLines { line, _ in
                number += 1
                guard matches(line) else { return }
                if shown < Self.searchLimit {
                    if shown == 0 { out.append("Matching lines:") }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let clipped = trimmed.count > Self.lineLimit ? String(trimmed.prefix(Self.lineLimit)) + "…" : trimmed
                    out.append("\(file.path):\(number): \(clipped)")
                    shown += 1
                } else {
                    more += 1
                }
            }
        }
        if more > 0 { out.append("…and \(more) more matching lines. Search for something more specific to narrow them.") }
        return out.isEmpty ? ("No matches for \u{201C}\(query)\u{201D}.", false) : (out.joined(separator: "\n"), false)
    }

    // MARK: Read

    func read(_ path: String, from start: Int?, to end: Int?) -> (text: String, isError: Bool) {
        guard let file = file(at: path) else {
            return ("No picked file at \(path). Use a path exactly as listed, or search_files to find it.", true)
        }
        let lines = file.text.components(separatedBy: "\n")
        let total = file.text.hasSuffix("\n") ? lines.count - 1 : lines.count
        let first = max(start ?? 1, 1)
        guard first <= total else { return ("\(file.path) has \(total) lines.", true) }
        let last = min(end ?? (first + Self.readLineLimit - 1), first + Self.readLineLimit - 1, total)
        guard last >= first else { return ("end_line comes before start_line.", true) }

        var out = ["\(file.path), lines \(first)–\(last) of \(total):"]
        var characters = 0
        for number in first...last {
            let line = "\(number)\t\(lines[number - 1])"
            characters += line.count + 1
            if characters > Self.readCharacterLimit {
                out.append("(Stopped at line \(number - 1) to stay short; read from line \(number) for more.)")
                break
            }
            out.append(line)
        }
        if last < total, characters <= Self.readCharacterLimit {
            out.append("(\(total - last) more lines; read from line \(last + 1) for more.)")
        }
        return (out.joined(separator: "\n"), false)
    }

    /// The file at `path` as listed, or the only one whose path ends with it.
    private func file(at path: String) -> ContextFile? {
        if let exact = files.files.first(where: { $0.path == path }) { return exact }
        let endings = files.files.filter { $0.path.hasSuffix("/" + path) }
        return endings.count == 1 ? endings[0] : nil
    }
}
