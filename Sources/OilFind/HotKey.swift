import Carbon
import AppKit

enum SpotlightShortcut {
    static func isReserved(keyCode: UInt32, modifiers: UInt32, preferences: [String: Any]? = nil) -> Bool {
        let preferences = preferences ?? readPreferences()
        guard let keys = preferences["AppleSymbolicHotKeys"] as? [String: Any] else { return false }
        let flags = HotKey.modifierFlags(modifiers).rawValue
        return ["64", "65"].contains { identifier in
            guard let entry = keys[identifier] as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return false }
            return parameters[1].uint32Value == keyCode && parameters[2].uintValue == flags
        }
    }
    private static func readPreferences() -> [String: Any] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.symbolichotkeys.plist")
        guard let data = try? Data(contentsOf: url), let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return value
    }
}

final class HotKey {
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey)] {
            if flags.contains(flag) { mask |= UInt32(value) }
        }
        return mask
    }
    static func modifierFlags(_ mask: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey)] {
            if mask & UInt32(value) != 0 { flags.insert(flag) }
        }
        return flags
    }
    private var reference: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().handler()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { return nil }
        // Carbon requires a four-byte signature: "OILF".
        let id = EventHotKeyID(signature: 0x4F494C46, id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &reference) == noErr else {
            unregister(); return nil
        }
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }
    deinit { unregister() }
}
