import CallCore
import SwiftUI

/// A row of buttons above Ask Claude, each sending a saved prompt in one
/// click ("Shorter", "Recap"), and a button to edit them.
struct QuickActionsBar: View {
    @Binding var actions: [QuickAction]
    let run: (QuickAction) -> Void

    /// Where the buttons are kept, as JSON (see QuickAction.decode).
    static let storageKey = QuickAction.storageKey

    @State private var editing = false

    var body: some View {
        HStack {
            // Scrolls sideways when there are more buttons than fit.
            ScrollView(.horizontal) {
                HStack {
                    ForEach(actions.filter(\.isComplete)) { action in
                        Button(action.name) { run(action) }
                            .help(Self.help(for: action))
                    }
                }
            }
            .scrollIndicators(.never)
            .controlSize(.small)

            Button {
                editing.toggle()
            } label: {
                Label("Edit Buttons", systemImage: "slider.horizontal.3")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Add, change or remove these buttons")
            .popover(isPresented: $editing) {
                QuickActionsEditor(actions: $actions)
            }
        }
    }

    /// "Ask Claude: Make that shorter", without the prompt's closing period,
    /// like the window's other help.
    static func help(for action: QuickAction) -> String {
        var prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.hasSuffix(".") { prompt.removeLast() }
        return "Ask Claude: \(prompt)"
    }
}

/// The quick-action buttons' editor: a name and a prompt for each, in the
/// order they appear (drag to reorder).
private struct QuickActionsEditor: View {
    @Binding var actions: [QuickAction]
    /// The name field to type in: a new button's, once it's added.
    @FocusState private var focusedName: UUID?
    /// The button just added, to scroll to.
    @State private var added: UUID?

    /// The list's height (points); longer lists scroll.
    private static let listHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading) {
            if actions.isEmpty {
                Text("No buttons yet. Add one, or restore the starters.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollViewReader { list in
                    List {
                        ForEach($actions) { $action in
                            ActionRow(action: $action, focusedName: $focusedName) {
                                actions.removeAll { $0.id == action.id }
                            }
                            .id(action.id)
                        }
                        .onMove { actions.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(height: Self.listHeight)
                    // A new button scrolls into view, ready for its name.
                    .onChange(of: added) {
                        guard let added else { return }
                        list.scrollTo(added)
                        focusedName = added
                    }
                }
            }

            HStack {
                Button("Add Button") {
                    let new = QuickAction(name: "", prompt: "")
                    actions.append(new)
                    added = new.id
                }
                Spacer(minLength: 0)
                Button("Restore Starters") {
                    actions = QuickAction.starters
                }
                .help("Put back Shorter, Simpler, Example, Ask them and Recap")
            }
        }
        .frame(width: TranscriptWindow.notesSize.width)
        .padding()
        // Rows left with neither a name nor a prompt aren't kept.
        .onDisappear {
            actions.removeAll { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}

/// One button's name and prompt, with a remove button.
private struct ActionRow: View {
    @Binding var action: QuickAction
    var focusedName: FocusState<UUID?>.Binding
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                TextField("Name", text: $action.name)
                    .focused(focusedName, equals: action.id)
                TextField("Prompt", text: $action.prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) {
                Label("Remove \(action.name.isEmpty ? "this button" : action.name)", systemImage: "minus.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove \(action.name.isEmpty ? "this button" : action.name)")
        }
    }
}
