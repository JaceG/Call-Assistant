import Observation

/// What the menu bar asks the call window to do: show a popover or sheet,
/// start or stop the call, or put the cursor in Ask Claude.
@MainActor
@Observable
final class WindowControls {
    var showingNotes = false
    var showingFiles = false
    var editingAlways = false
    var reviewing = false
    /// Counts the menu's Start/Stop Call; the window acts on each change.
    var startStopRequests = 0
    /// Counts the menu's Ask Claude…; the answers pane focuses its field.
    var askRequests = 0
}
