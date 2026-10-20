import AppKit
import CallCore
import Foundation
import Testing

struct FileCollectorTests {
    static func folder(_ name: String = "Project") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileCollectorTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(_ text: String, to path: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    static func git(_ arguments: String..., in folder: URL) throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", folder.path] + arguments
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
    }

    static func skips(_ files: CallFiles) -> [String: SkippedFile.Reason] {
        Dictionary(uniqueKeysWithValues: files.skipped.map { ($0.path, $0.reason) })
    }

    // MARK: Folders

    @Test func aFolderIsReadSortedAndShownUnderItsName() async throws {
        let folder = try Self.folder()
        try Self.write("struct B {}", to: "Sources/B.swift", in: folder)
        try Self.write("struct A {}", to: "Sources/A.swift", in: folder)
        try Self.write("# Readme", to: "README.md", in: folder)
        let files = await FileCollector().collect([folder])
        #expect(files.files.map(\.path) == ["Project/README.md", "Project/Sources/A.swift", "Project/Sources/B.swift"])
        #expect(files.files[1].text == "struct A {}")
        #expect(files.skipped.isEmpty)
    }

    @Test func outsideGitHiddenFilesAndBuildFoldersAreLeftOut() async throws {
        let folder = try Self.folder()
        try Self.write("code", to: "app.js", in: folder)
        try Self.write("dependency", to: "node_modules/left-pad/index.js", in: folder)
        try Self.write("output", to: "build/app.js", in: folder)
        try Self.write("hidden", to: ".cache/x.txt", in: folder)
        try Self.write("SECRET=1", to: ".env", in: folder)
        let files = await FileCollector().collect([folder])
        #expect(files.files.map(\.path) == ["Project/app.js"])
        #expect(files.skipped.isEmpty)
    }

    @Test func inAGitWorkTreeGitDecidesWhatCounts() async throws {
        let folder = try Self.folder()
        try Self.git("init", "-q", in: folder)
        try Self.write("ignored.txt\n", to: ".gitignore", in: folder)
        try Self.write("kept", to: "kept.txt", in: folder)
        try Self.write("ignored", to: "ignored.txt", in: folder)
        try Self.write("name: ci", to: ".github/ci.yml", in: folder)
        let files = await FileCollector().collect([folder])
        #expect(files.files.map(\.path) == ["Project/.github/ci.yml", "Project/.gitignore", "Project/kept.txt"])
    }

    @Test func tooManyFilesStopsAtTheLimitAndSaysSo() async throws {
        let folder = try Self.folder()
        for name in ["a", "b", "c"] { try Self.write(name, to: "\(name).txt", in: folder) }
        let files = await FileCollector(maxFiles: 2).collect([folder])
        #expect(files.files.count == 2)
        #expect(Self.skips(files)["Project"] == .tooMany)
    }

    // MARK: Skip rules

    @Test func secretsAreNeverReadEvenWhenPickedByHand() async throws {
        let folder = try Self.folder()
        try Self.write("-----BEGIN PRIVATE KEY-----", to: "certs/server.pem", in: folder)
        try Self.write("key", to: "id_ed25519", in: folder)
        let env = try Self.write("API_KEY=abc", to: ".env.local", in: folder)
        let files = await FileCollector().collect([folder, env])
        #expect(files.files.isEmpty)
        #expect(Self.skips(files) == [
            "Project/certs/server.pem": .secret,
            "Project/id_ed25519": .secret,
            ".env.local": .secret,
        ])
        #expect(!files.files.contains { $0.text.contains("abc") })
    }

    @Test func lockfilesMinifiedFilesAndMapsAreGenerated() async throws {
        let folder = try Self.folder()
        try Self.write("{}", to: "package-lock.json", in: folder)
        try Self.write("x", to: "app.min.js", in: folder)
        try Self.write("{}", to: "app.js.map", in: folder)
        try Self.write("real", to: "app.js", in: folder)
        let files = await FileCollector().collect([folder])
        #expect(files.files.map(\.path) == ["Project/app.js"])
        #expect(Set(files.skipped.map(\.reason)) == [.generated])
        #expect(files.skipped.count == 3)
    }

    @Test func bundledOutputWithVeryLongLinesIsGenerated() async throws {
        let folder = try Self.folder()
        try Self.write(String(repeating: "var a=1;", count: 4_000), to: "assets/gallery.f59fb107.js", in: folder)
        try Self.write(String(repeating: "let a = 1\n", count: 4_000), to: "app.js", in: folder)
        let files = await FileCollector().collect([folder])
        #expect(files.files.map(\.path) == ["Project/app.js"])
        #expect(Self.skips(files) == ["Project/assets/gallery.f59fb107.js": .generated])
    }

    @Test func binariesAndNonUTF8AreNotText() async throws {
        let folder = try Self.folder()
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent("logo.png"))
        try Data([0x41, 0x00, 0x42]).write(to: folder.appendingPathComponent("data.txt"))
        try Data([0xFF, 0xFE, 0xC3]).write(to: folder.appendingPathComponent("latin.txt"))
        let files = await FileCollector().collect([folder])
        #expect(files.files.isEmpty)
        #expect(Self.skips(files) == ["Project/data.txt": .notText, "Project/latin.txt": .notText, "Project/logo.png": .notText])
    }

    @Test func textOverTheLimitIsTooBig() async throws {
        let folder = try Self.folder()
        try Self.write(String(repeating: "x", count: 101), to: "big.txt", in: folder)
        try Self.write("small", to: "small.txt", in: folder)
        let files = await FileCollector(maxTextBytes: 100).collect([folder])
        #expect(files.files.map(\.path) == ["Project/small.txt"])
        #expect(Self.skips(files) == ["Project/big.txt": .tooBig])
    }

    @Test func emptyFilesAreLeftOutQuietly() async throws {
        let folder = try Self.folder()
        try Self.write("  \n", to: "empty.txt", in: folder)
        let files = await FileCollector().collect([folder])
        #expect(files.files.isEmpty && files.skipped.isEmpty)
    }

    // MARK: Picks

    @Test func aMissingPickIsReportedAndAFileInsideAPickedFolderCountsOnce() async throws {
        let folder = try Self.folder()
        let inside = try Self.write("once", to: "notes.md", in: folder)
        let gone = folder.deletingLastPathComponent().appendingPathComponent("Gone")
        let files = await FileCollector().collect([folder, inside, gone])
        #expect(files.files.map(\.path) == ["Project/notes.md"])
        #expect(Self.skips(files) == ["Gone": .missing])
    }

    @Test func wordAndRTFDocumentsAreReadAsText() async throws {
        let folder = try Self.folder()
        let text = NSAttributedString(string: "Eight years of Swift.")
        let range = NSRange(location: 0, length: text.length)
        try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            .write(to: folder.appendingPathComponent("Resume.docx"))
        try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            .write(to: folder.appendingPathComponent("Cover.rtf"))
        let files = await FileCollector().collect([folder])
        #expect(files.files.map(\.path) == ["Project/Cover.rtf", "Project/Resume.docx"])
        #expect(files.files.allSatisfy { $0.text.contains("Eight years of Swift.") })
    }

    // MARK: Size

    @Test func theModeFollowsTheEstimate() {
        let fits = CallFiles(files: [ContextFile(path: "a", text: String(repeating: "x", count: CallFiles.wholeBudget * 3))], skipped: [])
        #expect(fits.estimatedTokens == CallFiles.wholeBudget)
        #expect(fits.mode == .whole)
        let over = CallFiles(files: [ContextFile(path: "a", text: String(repeating: "x", count: CallFiles.wholeBudget * 3 + 3))], skipped: [])
        #expect(over.mode == .lookUp)
    }
}
