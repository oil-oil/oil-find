import Foundation
import Carbon

public enum Shortcut {
    public static let defaultCmdSpace = (keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
    public static let oldShiftCmdF = (keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey))
    public static let defaultKeyCode = defaultCmdSpace.keyCode
    public static let defaultModifiers = defaultCmdSpace.modifiers
    public static let fallbackKeyCode = oldShiftCmdF.keyCode
    public static let fallbackModifiers = oldShiftCmdF.modifiers

    public static func symbols(keyCode: UInt32, modifiers: UInt32) -> String {
        let prefix = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined()
        return prefix + keyName(keyCode)
    }
    public static func keyName(_ code: UInt32) -> String {
        if let name = fixedNames[code] { return name }
        return translatedKey(code).uppercased()
    }
    public static func keyEquivalent(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Space: return " "
        case kVK_Delete: return "\u{8}"
        case kVK_ForwardDelete: return "\u{f728}"
        case kVK_Escape: return "\u{1b}"
        case kVK_ANSI_KeypadEnter: return "\u{3}"
        case kVK_LeftArrow: return "\u{f702}"
        case kVK_RightArrow: return "\u{f703}"
        case kVK_UpArrow: return "\u{f700}"
        case kVK_DownArrow: return "\u{f701}"
        case kVK_Help: return "\u{f746}"
        case kVK_Home: return "\u{f729}"
        case kVK_End: return "\u{f72b}"
        case kVK_PageUp: return "\u{f72c}"
        case kVK_PageDown: return "\u{f72d}"
        case kVK_ANSI_KeypadClear: return "\u{f739}"
        default:
            if let index = functionKeys.firstIndex(of: code), let scalar = UnicodeScalar(0xf704 + index) { return String(scalar) }
            return translatedKey(code).lowercased()
        }
    }
    private static func translatedKey(_ code: UInt32) -> String {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var state: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(clamping: code), UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &state, 8, &length, &characters)
        return status == noErr ? String(utf16CodeUnits: characters, count: length) : ""
    }
    private static let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    private static let fixedNames: [UInt32: String] = {
        var names: [UInt32: String] = [36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌤", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        for (i, code) in functionKeys.enumerated() { names[code] = "F\(i + 1)" }
        return names
    }()
}
