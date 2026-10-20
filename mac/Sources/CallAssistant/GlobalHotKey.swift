import Carbon.HIToolbox

/// A keyboard shortcut that works while another app is in front: ⌃⌥A for
/// Answer Now. Uses Carbon's hot-key API, which needs no Accessibility
/// permission. It stays registered for the life of the app.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Registers ⌃⌥A (by default). Returns nil if macOS refuses it, for
    /// example when another app already holds the same shortcut.
    init?(keyCode: Int = kVK_ANSI_A, modifiers: Int = controlKey | optionKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)

        // "CAas": Call Assistant, Answer Now.
        let id = EventHotKeyID(signature: OSType(0x4341_6173), id: 1)
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
        guard installed == noErr, registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }
}
