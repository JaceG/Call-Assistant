import SwiftUI

/// The editor for the Always instructions: what Claude follows on every
/// call, whatever the playbook. Suggestions accepted after a call are added
/// here too.
struct AlwaysEditor: View {
    @State var text: String
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The editor's size (points).
    private static let size = CGSize(width: 480, height: 300)

    var body: some View {
        VStack(alignment: .leading) {
            Text("Always Instructions")
                .font(.headline)
            Text("Claude follows these on every call, whatever playbook you pick. Accepted suggestions from the review after a call are added here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .accessibilityLabel("Always instructions")
                .frame(width: Self.size.width, height: Self.size.height)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}
