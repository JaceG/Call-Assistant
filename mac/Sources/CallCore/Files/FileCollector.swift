import Foundation

/// Reads the folders and files picked for a call into text.
///
/// - In a git work tree, a folder's files are the ones git lists (tracked or
///   new, minus .gitignore). Elsewhere they're found by walking the folder,
///   skipping hidden files and build or dependency folders.
/// - Secrets files are never read, even when picked by hand. Lockfiles,
///   minified files, source maps, binaries and very large files are skipped.
/// - PDFs and Word, RTF and OpenDocument files are read as their text.
public struct FileCollector: Sendable {
    public let maxFiles: Int
    public let maxTextBytes: Int

    public init(maxFiles: Int = 20_000, maxTextBytes: Int = 1_000_000) {
        self.maxFiles = maxFiles
        self.maxTextBytes = maxTextBytes
    }

    /// Reads `picks` (folders and files) off the main thread.
    public func collect(_ picks: [URL]) async -> CallFiles {
        let collector = self
        return await Task.detached(priority: .userInitiated) { collector.collectNow(picks) }.value
    }

    func collectNow(_ picks: [URL]) -> CallFiles {
        var files: [ContextFile] = []
        var skipped: [SkippedFile] = []
        var seen: Set<String> = []

        for pick in picks {
            let pick = pick.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: pick.path, isDirectory: &isDirectory) else {
                skipped.append(SkippedFile(path: pick.lastPathComponent, reason: .missing))
                continue
            }
            if isDirectory.boolValue {
                let (relativePaths, truncated) = listing(of: pick)
                if truncated { skipped.append(SkippedFile(path: pick.lastPathComponent, reason: .tooMany)) }
                for relative in relativePaths {
                    let url = pick.appendingPathComponent(relative)
                    guard seen.insert(url.path).inserted else { continue }
                    read(url, shownAs: "\(pick.lastPathComponent)/\(relative)", into: &files, skipped: &skipped)
                }
            } else {
                guard seen.insert(pick.path).inserted else { continue }
                read(pick, shownAs: pick.lastPathComponent, into: &files, skipped: &skipped)
            }
        }
        return CallFiles(files: files, skipped: skipped)
    }

    // MARK: Listing a folder

    /// The folder's files as paths relative to it, and whether the list was
    /// cut at `maxFiles`.
    func listing(of folder: URL) -> (paths: [String], truncated: Bool) {
        let paths = Self.gitListing(of: folder) ?? walk(folder)
        let kept = paths.filter { !Self.isInSkippedFolder($0) }
        return (Array(kept.prefix(maxFiles)), kept.count > maxFiles)
    }

    /// What git lists in the folder (tracked and new files, minus what
    /// .gitignore excludes), or nil when it isn't in a work tree or git
    /// can't run.
    static func gitListing(of folder: URL) -> [String]? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", folder.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let output = Pipe()
        git.standardOutput = output
        git.standardError = FileHandle.nullDevice
        do {
            try git.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    /// Walks the folder, skipping hidden files and skipped folders, stopping
    /// one past the limit.
    func walk(_ folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if Self.skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            // The enumerator's URLs can name the folder differently (/private/var
            // for /var), so the path inside it comes from the depth instead.
            paths.append(url.pathComponents.suffix(enumerator.level).joined(separator: "/"))
            if paths.count > maxFiles { break }
        }
        return paths
    }

    static let skippedFolders: Set<String> = [
        "node_modules", "build", "dist", ".build", "DerivedData", "Pods", ".next",
        "target", "out", "__pycache__", "venv", ".venv", "coverage", ".git",
    ]

    static func isInSkippedFolder(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").dropLast().contains { skippedFolders.contains(String($0)) }
    }

    // MARK: Reading a file

    private func read(_ url: URL, shownAs path: String, into files: inout [ContextFile], skipped: inout [SkippedFile]) {
        if let reason = Self.skipReason(forName: url.lastPathComponent) {
            skipped.append(SkippedFile(path: path, reason: reason))
            return
        }
        switch text(of: url) {
        case .text(let text):
            // Empty files carry nothing for Claude.
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                files.append(ContextFile(path: path, text: text))
            }
        case .skip(let reason):
            // git lists deleted files and submodules; those aren't worth reporting.
            if reason != .missing { skipped.append(SkippedFile(path: path, reason: reason)) }
        }
    }

    private enum Outcome {
        case text(String)
        case skip(SkippedFile.Reason)
    }

    private func text(of url: URL) -> Outcome {
        let fileExtension = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return .skip(.missing) }

        if DocumentText.handles(fileExtension) {
            guard let text = DocumentText.text(of: url) else { return .skip(.unreadable) }
            return text.utf8.count > maxTextBytes ? .skip(.tooBig) : .text(text)
        }
        if Self.binaryExtensions.contains(fileExtension) { return .skip(.notText) }
        if let size = values?.fileSize, size > maxTextBytes { return .skip(.tooBig) }

        guard let data = try? Data(contentsOf: url) else { return .skip(.unreadable) }
        if data.prefix(8192).contains(0) { return .skip(.notText) }
        guard let text = String(data: data, encoding: .utf8) else { return .skip(.notText) }
        if Self.looksMinified(data) { return .skip(.generated) }
        return .text(text)
    }

    /// Bundled or minified output (hashed build assets, one-line data): a
    /// file of some size whose lines run very long on average.
    static func looksMinified(_ data: Data) -> Bool {
        guard data.count > 20_000 else { return false }
        let lines = data.reduce(into: 1) { count, byte in if byte == 0x0A { count += 1 } }
        return data.count / lines > 500
    }

    /// Why a file is skipped by its name alone, or nil to read it.
    static func skipReason(forName name: String) -> SkippedFile.Reason? {
        let lower = name.lowercased()
        let fileExtension = (lower as NSString).pathExtension
        if lower.hasPrefix(".env") || secretNames.contains(lower) || secretExtensions.contains(fileExtension)
            || secretPrefixes.contains(where: lower.hasPrefix) {
            return .secret
        }
        if lockfiles.contains(lower) || lower.hasSuffix(".min.js") || lower.hasSuffix(".min.css") || fileExtension == "map" {
            return .generated
        }
        return nil
    }

    static let secretNames: Set<String> = [".npmrc", ".netrc", ".pypirc"]
    static let secretExtensions: Set<String> = ["pem", "key", "p12", "p8", "pfx", "jks", "keystore", "mobileprovision"]
    static let secretPrefixes = ["id_rsa", "id_ecdsa", "id_ed25519"]
    static let lockfiles: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "podfile.lock",
        "package.resolved", "cargo.lock", "gemfile.lock", "composer.lock", "poetry.lock", "pipfile.lock",
    ]
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "icns", "bmp", "tif", "tiff", "psd", "ai", "sketch", "fig",
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "caf", "aiff", "mp4", "mov", "m4v", "avi", "mkv", "webm",
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso",
        "exe", "dll", "so", "dylib", "a", "o", "class", "jar", "war", "pyc",
        "woff", "woff2", "ttf", "otf", "eot", "sqlite", "db", "realm", "ipa", "apk", "car", "nib", "bin", "dat",
        "xlsx", "xls", "pptx", "ppt", "numbers", "pages",
    ]
}
