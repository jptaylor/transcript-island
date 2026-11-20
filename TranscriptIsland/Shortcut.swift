import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    /// ⌥⇧Space: not used by macOS by default.
    static let defaultShortcut = Shortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey | shiftKey),
        keyLabel: "Space"
    )

    var displayString: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// From a key press in the recorder. Needs ⌘, ⌥ or ⌃ (F-keys may stand alone)
    /// so the shortcut doesn't swallow normal typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        let keyCode = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys[keyCode] != nil
        guard isFunctionKey || modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(keyCode), carbonModifiers: modifiers, keyLabel: Self.label(for: event))
    }

    private static func label(for event: NSEvent) -> String {
        let keyCode = Int(event.keyCode)
        if let name = functionKeys[keyCode] ?? namedKeys[keyCode] { return name }
        let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return characters.isEmpty ? "Key \(keyCode)" : characters
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19",
    ]
}
