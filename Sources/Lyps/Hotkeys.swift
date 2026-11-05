import AppKit
import Carbon.HIToolbox

/// Global shortcuts. Carbon's hot keys are still the API for this, and they need no permissions.
@MainActor
final class Hotkeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private var refs: [UInt32: EventHotKeyRef] = [:]

    init() {
        guard !Self.handlerInstalled else { return }
        Self.handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let action = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.actions[action]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// False when another app already owns the combination.
    @discardableResult
    func register(id: UInt32, _ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        Self.actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C595053), id: id) // "LYPS"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }
}

extension Shortcut {
    /// The shortcut in the form menu items want, so macOS draws it in the usual right-hand column.
    var menuKey: String {
        let name = String(display.drop { "⌃⌥⇧⌘".contains($0) })
        switch name {
        case "Space": return " "
        case "↩": return "\r"
        case "⇥": return "\t"
        case "←": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "→": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "↑": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "↓": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default: return name.lowercased()
        }
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Nil unless the keypress has ⌃, ⌥ or ⌘. Shift alone would make a key unusable for typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }

        var modifiers = 0
        var symbols = ""
        if flags.contains(.control) { modifiers |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { modifiers |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { modifiers |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { modifiers |= cmdKey; symbols += "⌘" }

        let name: String
        switch Int(event.keyCode) {
        case kVK_Space: name = "Space"
        case kVK_Return: name = "↩"
        case kVK_Tab: name = "⇥"
        case kVK_LeftArrow: name = "←"
        case kVK_RightArrow: name = "→"
        case kVK_UpArrow: name = "↑"
        case kVK_DownArrow: name = "↓"
        default: name = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), display: symbols + name)
    }
}
