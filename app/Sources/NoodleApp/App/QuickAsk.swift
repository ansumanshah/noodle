import AppKit
import Carbon.HIToolbox

/// The global "open Models chat" shortcut. Carbon hot keys need no Accessibility permission.
@MainActor enum QuickAsk {
    static let defaultsKey = "quickAskHotKey"
    nonisolated static let focusArgument = "--focus-composer"
    /// Control-Option-Space.
    static let keyCode = UInt32(kVK_Space)
    static let modifiers = UInt32(controlKey | optionKey)

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?

    /// Registers or releases the hot key to match the setting. Safe to call repeatedly.
    static func apply(demo: Bool = AppEnvironment.shared.demo) {
        let want = isEnabled() && !demo
        if !want, let current = ref { UnregisterEventHotKey(current); ref = nil; return }
        guard want, ref == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickAsk.open() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x4E_44_4C_51, id: 1), GetApplicationEventTarget(), 0, &ref)
    }

    /// Shows the Models chat with the composer focused. In the menu bar copy this relaunches the full app.
    static func open() {
        ModelComposerFocus.pending = true
        AppEnvironment.shared.showMainWindow(.route(.chat), extraArguments: [focusArgument])
    }
}

/// A focus request the composer picks up when it is on screen, or when it appears.
@MainActor enum ModelComposerFocus {
    static let notification = Notification.Name("ModelComposerFocus")
    static var pending = false { didSet { if pending { NotificationCenter.default.post(name: notification, object: nil) } } }
}
