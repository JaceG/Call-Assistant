import CallCore
import SwiftUI

/// The Files button's popover: the folders and files picked for calls, how
/// Claude will use them, and what was skipped.
struct FilesPopover: View {
    let picks: [URL]
    let files: CallFiles
    let isReading: Bool
    let add: () -> Void
    let remove: (URL) -> Void

    /// The popover's width, as wide as Call Notes' editor (points).
    static let width: CGFloat = 320
    /// The most the picks and skipped lists grow before they scroll (points).
    private static let listHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading) {
            if picks.isEmpty {
                Text("No files yet. Add a project folder, or a document such as your resume.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(picks, id: \.self) { pick in
                            PickRow(pick: pick, remove: { remove(pick) })
                        }
                    }
                }
                .frame(maxHeight: Self.listHeight)
                .fixedSize(horizontal: false, vertical: true)

                Divider()
                summary
            }

            Button("Add Folders or Files…", action: add)
        }
        .padding()
        .frame(width: Self.width)
    }

    @ViewBuilder private var summary: some View {
        if isReading {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Reading files…")
            }
            .font(.callout)
        } else {
            Text(Self.summary(of: files))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !files.skipped.isEmpty {
                DisclosureGroup("\(files.skipped.count) skipped") {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(files.skipped, id: \.path) { skipped in
                                Text("\(skipped.path): \(skipped.reason.label)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Self.listHeight)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// How many files Claude has and how it will use them.
    static func summary(of files: CallFiles) -> String {
        let count = files.files.count
        guard count > 0 else { return "Nothing readable in these picks." }
        let counted = count == 1 ? "1 file" : "\(count.formatted()) files"
        switch files.mode {
        case .whole:
            return "\(counted) · Claude reads all of \(count == 1 ? "it" : "them") with each answer."
        case .lookUp:
            return "\(counted) · Too much to read whole, so Claude searches them when a question needs it."
        }
    }
}

/// One picked folder or file: its name and where it is, with a remove button.
private struct PickRow: View {
    let pick: URL
    let remove: () -> Void

    /// The folder it's in, with the home folder as "~": "~/Codebases/Personal".
    static func folder(of pick: URL) -> String {
        let path = pick.deletingLastPathComponent().standardizedFileURL.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        HStack {
            Image(systemName: pick.hasDirectoryPath ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(pick.lastPathComponent)
                Text(Self.folder(of: pick))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Label("Remove \(pick.lastPathComponent)", systemImage: "minus.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove \(pick.lastPathComponent)")
        }
    }
}
