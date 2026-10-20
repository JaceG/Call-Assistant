import CallCore
import Foundation
import Testing

struct PlaybooksTests {
    static func emptyFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybooksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to name: String, in folder: URL) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    @Test func aMissingFolderIsCreatedWithAStarterGeneralPlaybook() throws {
        let folder = try Self.emptyFolder().appendingPathComponent("Playbooks", isDirectory: true)
        let playbooks = try PlaybookLibrary(directory: folder).load()
        #expect(playbooks.map(\.name) == ["General"])
        #expect(!playbooks[0].instructions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("General.md").path))
    }

    @Test func noStarterIsAddedWhenPlaybooksExist() throws {
        let folder = try Self.emptyFolder()
        try Self.write("Answer as a senior iOS developer.", to: "Interview.md", in: folder)
        let playbooks = try PlaybookLibrary(directory: folder).load()
        #expect(playbooks.map(\.name) == ["Interview"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("General.md").path))
    }

    @Test func playbooksAreSortedByNameAndOnlyMarkdownFilesCount() throws {
        let folder = try Self.emptyFolder()
        try Self.write("b", to: "client check-in.md", in: folder)
        try Self.write("a", to: "Arkkhe call.md", in: folder)
        try Self.write("ignored", to: "notes.txt", in: folder)
        try Self.write("ignored", to: ".hidden.md", in: folder)
        let playbooks = try PlaybookLibrary(directory: folder).load()
        #expect(playbooks.map(\.name) == ["Arkkhe call", "client check-in"])
    }

    @Test func instructionsAreTrimmed() throws {
        let folder = try Self.emptyFolder()
        try Self.write("\n\n  Keep it short.  \n\n", to: "Short.md", in: folder)
        #expect(try PlaybookLibrary(directory: folder).load().first?.instructions == "Keep it short.")
    }

    @Test func aFileThatIsNotUTF8IsSkipped() throws {
        let folder = try Self.emptyFolder()
        try Data([0xFF, 0xFE, 0xFD, 0x00, 0xC3]).write(to: folder.appendingPathComponent("Broken.md"))
        try Self.write("Fine.", to: "Good.md", in: folder)
        #expect(try PlaybookLibrary(directory: folder).load().map(\.name) == ["Good"])
    }
}
