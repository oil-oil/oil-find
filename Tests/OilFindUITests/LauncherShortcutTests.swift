import AppKit
import Carbon
import XCTest
import OilFindCore
@testable import OilFind

final class LauncherShortcutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        let keys = ["hotKeyCode", "hotKeyModifiers"]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        addTeardownBlock {
            for (index, key) in keys.enumerated() {
                XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? NSObject, before[index], key)
            }
        }
    }

    private func preferences(identifier: String = "64", enabled: Bool, code: UInt32 = 49,
                             flags: NSEvent.ModifierFlags = .command) -> [String: Any] {
        let entry: [String: Any] = [
            "enabled": NSNumber(value: enabled),
            "value": ["parameters": [NSNumber(value: 32), NSNumber(value: code), NSNumber(value: flags.rawValue)]]
        ]
        return ["AppleSymbolicHotKeys": [identifier: entry]]
    }

    private func event(_ code: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(code)))
    }

    func testSpotlightReservationRequiresEnabledMatchingShortcut() {
        let shortcut = Shortcut.defaultCmdSpace
        for identifier in ["64", "65"] {
            XCTAssertTrue(SpotlightShortcut.isReserved(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                preferences: preferences(identifier: identifier, enabled: true)))
            XCTAssertFalse(SpotlightShortcut.isReserved(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                preferences: preferences(identifier: identifier, enabled: false)))
        }
        XCTAssertFalse(SpotlightShortcut.isReserved(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
            preferences: preferences(identifier: "99", enabled: true)))
        XCTAssertFalse(SpotlightShortcut.isReserved(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, preferences: [:]))
    }

    func testSpotlightCustomKeyAndModifierMaskDoNotReserveCommandSpace() {
        let code = UInt32(kVK_ANSI_F)
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift]
        let plist = preferences(enabled: true, code: code, flags: flags)
        XCTAssertTrue(SpotlightShortcut.isReserved(keyCode: code, modifiers: UInt32(controlKey | optionKey | shiftKey), preferences: plist))
        XCTAssertFalse(SpotlightShortcut.isReserved(keyCode: code, modifiers: UInt32(controlKey | optionKey), preferences: plist))
        XCTAssertFalse(SpotlightShortcut.isReserved(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers, preferences: plist))
        XCTAssertFalse(SpotlightShortcut.isReserved(keyCode: code, modifiers: UInt32(cmdKey), preferences: plist))
    }

    func testResetConflictKeepsDefaultDesiredAndRegisteredFallback() throws {
        for resetKey in [kVK_Delete, kVK_ForwardDelete] {
            let model = SettingsModel(snapshot: true)
            model.keyCode = UInt32(kVK_ANSI_Q); model.modifiers = UInt32(controlKey | optionKey)
            model.recording = true
            var requests: [(UInt32, UInt32)] = []
            model.registerHotKey = { [weak model] code, modifiers in
                requests.append((code, modifiers))
                model?.actualShortcut = Shortcut.symbols(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers)
                return false
            }
            model.record(try event(resetKey))
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.0, Shortcut.defaultKeyCode)
            XCTAssertEqual(requests.first?.1, Shortcut.defaultModifiers)
            XCTAssertEqual(model.keyCode, Shortcut.defaultKeyCode)
            XCTAssertEqual(model.modifiers, Shortcut.defaultModifiers)
            XCTAssertEqual(model.actualShortcut, Shortcut.symbols(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers))
            XCTAssertEqual(model.shortcutError, L10n.text("settings.shortcutConflict"))
            XCTAssertFalse(model.recording)
        }
    }

    func testResetSuccessAdoptsDefaultAndClearsPreviousError() throws {
        let model = SettingsModel(snapshot: true)
        model.keyCode = UInt32(kVK_ANSI_Q); model.modifiers = UInt32(controlKey | optionKey)
        model.shortcutError = L10n.text("settings.shortcutConflict"); model.recording = true
        var requests = 0
        model.registerHotKey = { [weak model] code, modifiers in
            requests += 1
            model?.actualShortcut = Shortcut.symbols(keyCode: code, modifiers: modifiers)
            return true
        }
        model.record(try event(kVK_Delete))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.keyCode, Shortcut.defaultKeyCode)
        XCTAssertEqual(model.modifiers, Shortcut.defaultModifiers)
        XCTAssertEqual(model.actualShortcut, Shortcut.symbols(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers))
        XCTAssertNil(model.shortcutError)
        XCTAssertFalse(model.recording)
    }

    func testRejectedCustomShortcutRestoresOriginalDesiredAndActual() throws {
        let model = SettingsModel(snapshot: true)
        let originalCode = UInt32(kVK_ANSI_Q), originalMask = UInt32(controlKey | optionKey)
        model.keyCode = originalCode; model.modifiers = originalMask; model.recording = true
        var requests: [(UInt32, UInt32)] = []
        model.registerHotKey = { [weak model] code, modifiers in
            requests.append((code, modifiers))
            guard code == originalCode && modifiers == originalMask else { model?.actualShortcut = nil; return false }
            model?.actualShortcut = Shortcut.symbols(keyCode: code, modifiers: modifiers)
            return true
        }
        model.record(try event(kVK_ANSI_F, flags: .command))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.0, UInt32(kVK_ANSI_F))
        XCTAssertEqual(requests.first?.1, UInt32(cmdKey))
        XCTAssertEqual(requests.last?.0, originalCode)
        XCTAssertEqual(requests.last?.1, originalMask)
        XCTAssertEqual(model.keyCode, originalCode)
        XCTAssertEqual(model.modifiers, originalMask)
        XCTAssertEqual(model.actualShortcut, Shortcut.symbols(keyCode: originalCode, modifiers: originalMask))
        XCTAssertEqual(model.shortcutError, L10n.text("settings.shortcutConflict"))
        XCTAssertFalse(model.recording)
    }

    func testAcceptedCustomShortcutUpdatesSnapshotWithoutPersisting() throws {
        let model = SettingsModel(snapshot: true)
        model.recording = true
        var requests = 0
        model.registerHotKey = { [weak model] code, modifiers in
            requests += 1; model?.actualShortcut = Shortcut.symbols(keyCode: code, modifiers: modifiers)
            return true
        }
        model.record(try event(kVK_ANSI_Q, flags: [.control, .option]))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.keyCode, UInt32(kVK_ANSI_Q))
        XCTAssertEqual(model.modifiers, UInt32(controlKey | optionKey))
        XCTAssertNil(model.shortcutError)
        XCTAssertFalse(model.recording)
    }

    func testEscapeRestoresDesiredAndModifierOnlyRejectionKeepsRecording() throws {
        let model = SettingsModel(snapshot: true)
        model.recording = true
        var requests: [(UInt32, UInt32)] = []
        model.registerHotKey = { code, modifiers in requests.append((code, modifiers)); return true }
        model.record(try event(kVK_ANSI_F, flags: .shift))
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(model.recording)
        XCTAssertEqual(model.shortcutError, L10n.text("settings.shortcutModifier"))
        model.record(try event(kVK_Escape))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, Shortcut.defaultKeyCode)
        XCTAssertEqual(requests.first?.1, Shortcut.defaultModifiers)
        XCTAssertNil(model.shortcutError)
        XCTAssertFalse(model.recording)
    }

    func testRetryAfterResetConflictUsesDefaultDesiredAndUpdatesActual() throws {
        let model = SettingsModel(snapshot: true)
        model.keyCode = UInt32(kVK_ANSI_Q); model.modifiers = UInt32(controlKey | optionKey)
        model.recording = true
        var available = false, requests: [(UInt32, UInt32)] = []
        model.registerHotKey = { [weak model] code, modifiers in
            requests.append((code, modifiers))
            model?.updateShortcutStatus(keyCode: available ? code : Shortcut.fallbackKeyCode,
                                       modifiers: available ? modifiers : Shortcut.fallbackModifiers)
            return available
        }
        model.record(try event(kVK_Delete))
        model.onRetryHotKey = { [weak model] in
            guard let model else { return }
            _ = model.registerHotKey?(model.keyCode, model.modifiers)
        }
        available = true
        model.onRetryHotKey?()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.0, Shortcut.defaultKeyCode)
            XCTAssertEqual(request.1, Shortcut.defaultModifiers)
        }
        XCTAssertEqual(model.actualShortcut, Shortcut.symbols(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers))
        XCTAssertEqual(model.keyCode, Shortcut.defaultKeyCode)
        XCTAssertEqual(model.modifiers, Shortcut.defaultModifiers)
        XCTAssertNil(model.shortcutError)
    }

    func testActualShortcutStatusReportsInitialConflictAndClearsAfterRetry() {
        let model = SettingsModel(snapshot: true)
        model.updateShortcutStatus(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers)
        XCTAssertEqual(model.shortcutError, L10n.text("settings.shortcutConflict"))
        XCTAssertEqual(model.actualShortcut, Shortcut.symbols(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers))
        model.recording = true
        model.shortcutError = nil
        model.updateShortcutStatus(keyCode: nil, modifiers: nil)
        XCTAssertNil(model.actualShortcut)
        XCTAssertNil(model.shortcutError)
        model.recording = false
        model.updateShortcutStatus(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers)
        XCTAssertNil(model.shortcutError)
        // A rejected recording restores the old binding but must retain its error.
        model.shortcutError = L10n.text("settings.shortcutConflict")
        model.updateShortcutStatus(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers, clearErrorWhenBound: false)
        XCTAssertEqual(model.shortcutError, L10n.text("settings.shortcutConflict"))
        model.updateShortcutStatus(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers)
        XCTAssertNil(model.shortcutError)
    }
}
