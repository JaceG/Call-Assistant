@testable import CallCore
import Foundation
import Testing

/// search_files and read_file over files already read into memory.
struct FileLookupTests {
    static let lookup = FileLookup(files: CallFiles(files: [
        ContextFile(path: "Site/src/terminal/index.js", text: """
            export function Terminal() {
              const history = useHistory()
              // Opens with the backtick key
              return <Prompt history={history} />
            }

            """),
        ContextFile(path: "Site/README.md", text: "# Site\nThe terminal opens with the backtick key."),
    ], skipped: []))

    // MARK: Search

    @Test func searchListsPathMatchesThenNumberedLines() {
        let result = Self.lookup.search("Terminal")
        #expect(!result.isError)
        #expect(result.text == """
            Files whose path matches:
              Site/src/terminal/index.js
            Matching lines:
            Site/README.md:2: The terminal opens with the backtick key.
            Site/src/terminal/index.js:1: export function Terminal() {
            """)
    }

    @Test func everyWordMustBeOnTheLineInAnyOrder() {
        let text = Self.lookup.search("key backtick opens").text
        #expect(text.contains("Site/README.md:2:"))
        #expect(text.contains("Site/src/terminal/index.js:3: // Opens with the backtick key"))
        #expect(!text.contains("index.js:1:"))
    }

    @Test func noMatchesSaysSoAndAnEmptyQueryIsAnError() {
        #expect(Self.lookup.search("websocket") == ("No matches for \u{201C}websocket\u{201D}.", false))
        #expect(Self.lookup.search("   ").isError)
    }

    @Test func searchStopsAtTheLimitAndCountsTheRest() {
        let many = (1...45).map { "match \($0)" }.joined(separator: "\n")
        let lookup = FileLookup(files: CallFiles(files: [ContextFile(path: "f.txt", text: many)], skipped: []))
        let lines = lookup.search("match").text.components(separatedBy: "\n")
        #expect(lines.filter { $0.hasPrefix("f.txt:") }.count == FileLookup.searchLimit)
        #expect(lines.last == "…and 5 more matching lines. Search for something more specific to narrow them.")
    }

    // MARK: Read

    @Test func readNumbersTheLinesAndSaysWhichPartItIs() {
        let result = Self.lookup.read("Site/src/terminal/index.js", from: 2, to: 3)
        #expect(!result.isError)
        #expect(result.text == """
            Site/src/terminal/index.js, lines 2–3 of 5:
            2\t  const history = useHistory()
            3\t  // Opens with the backtick key
            (2 more lines; read from line 4 for more.)
            """)
    }

    @Test func readFindsAFileByTheEndOfItsPath() {
        #expect(Self.lookup.read("README.md", from: nil, to: nil).text.hasPrefix("Site/README.md, lines 1–2 of 2:"))
    }

    @Test func readReportsUnknownPathsAndLinesPastTheEnd() {
        #expect(Self.lookup.read("Site/missing.js", from: nil, to: nil).isError)
        #expect(Self.lookup.read("Site/README.md", from: 9, to: nil) == ("Site/README.md has 2 lines.", true))
    }

    @Test func readStopsAtTheLineLimit() {
        let long = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let lookup = FileLookup(files: CallFiles(files: [ContextFile(path: "long.txt", text: long)], skipped: []))
        let text = lookup.read("long.txt", from: nil, to: nil).text
        #expect(text.hasPrefix("long.txt, lines 1–800 of 1000:"))
        #expect(text.hasSuffix("800\tline 800\n(200 more lines; read from line 801 for more.)"))
    }

    // MARK: Calls

    @Test func runDispatchesByToolNameAndRejectsBadInput() {
        #expect(Self.lookup.run(name: "read_file", input: ["path": "Site/README.md"]).text.hasPrefix("Site/README.md, lines"))
        #expect(Self.lookup.run(name: "search_files", input: [:]).isError)
        #expect(Self.lookup.run(name: "delete_file", input: [:]).isError)
    }

    @Test func activitiesSayWhatClaudeIsDoing() {
        #expect(FileLookup.activity(name: "search_files", input: ["query": "terminal"]) == "Searching the files for \u{201C}terminal\u{201D}…")
        #expect(FileLookup.activity(name: "read_file", input: ["path": "Site/README.md"]) == "Reading Site/README.md…")
    }

    @Test func toolDefinitionsNameBothTools() {
        #expect(FileLookup.definitions.map { $0["name"] as? String } == ["search_files", "read_file"])
    }
}
