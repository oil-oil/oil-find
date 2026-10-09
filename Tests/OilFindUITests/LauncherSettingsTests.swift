import AppKit
import XCTest
import OilFindCore
@testable import OilFind

final class LauncherSettingsTests: XCTestCase {
    func testSnapshotSettingsDoNotPersistLauncherOrIndexChoices() throws {
        let keys = ["calculatorEnabled", "webSearchEnabled", "webSearchEngine", "pinyinEnabled",
                    "indexDependencyDirs", "indexPackageContents", "indexUserLibrary", "indexSystemDirs"]
        let defaults = UserDefaults.standard
        let before = keys.map { defaults.object(forKey: $0) as? NSObject }
        let model = SettingsModel(snapshot: true)
        XCTAssertTrue(model.calculatorEnabled)
        XCTAssertTrue(model.webSearchEnabled)
        XCTAssertEqual(model.webSearchEngine, .duckDuckGo)
        XCTAssertEqual(model.keyCode, Shortcut.defaultCmdSpace.keyCode)
        XCTAssertEqual(model.modifiers, Shortcut.defaultCmdSpace.modifiers)
        model.setCalculator(false)
        model.setWebSearch(false)
        let engine = try XCTUnwrap(WebSearchEngine.allCases.first { $0 != .duckDuckGo })
        model.setWebSearchEngine(engine)
        var pinyinChanges = 0, configChanges = 0
        model.onPinyinChange = { pinyinChanges += 1 }
        model.onConfigChange = { configChanges += 1 }
        model.setPinyin(false)
        for key in keys.filter({ $0.hasPrefix("index") }) { model.setScope(key, true) }
        XCTAssertFalse(model.calculatorEnabled)
        XCTAssertFalse(model.webSearchEnabled)
        XCTAssertEqual(model.webSearchEngine, engine)
        XCTAssertEqual(pinyinChanges, 1)
        XCTAssertEqual(configChanges, 4)
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, before[index], key)
        }
    }

    func testClipboardSettingsUseSuppliedHistoryAndSnapshotsOwnSeparateHistory() {
        let clipboard = ClipboardHistory(snapshot: true)
        let model = SettingsModel(snapshot: true, clipboard: clipboard)
        XCTAssertTrue(model.clipboard === clipboard)
        clipboard.setEnabled(true)
        clipboard.setPaused(true)
        clipboard.setRetention(days: 365, items: 10_000)
        clipboard.setExcludedApplications(["com.apple.safari", "com.apple.textedit"])
        model.removeExcludedApplication("com.apple.safari")
        XCTAssertTrue(model.clipboard.enabled)
        XCTAssertTrue(model.clipboard.paused)
        XCTAssertEqual(model.clipboard.retentionDays, 365)
        XCTAssertEqual(model.clipboard.maxItems, 10_000)
        XCTAssertEqual(model.clipboard.excludedAppIDs, ["com.apple.textedit"])
        clipboard.setRetention(days: 1, items: 1)
        XCTAssertEqual(model.clipboard.retentionDays, 1)
        XCTAssertEqual(model.clipboard.maxItems, 1)
        let other = SettingsModel(snapshot: true)
        XCTAssertFalse(other.clipboard === model.clipboard)
        XCTAssertFalse(other.clipboard.paused)
        XCTAssertEqual(other.clipboard.excludedAppIDs, ClipboardHistoryStore.defaultExcludedAppIDs)
    }

    func testChangingSectionCancelsRecordingAndRestoresDesiredShortcut() throws {
        _ = NSApplication.shared
        let model = SettingsModel(snapshot: true)
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var suspensions = 0
        var restored: [(UInt32, UInt32)] = []
        model.suspendHotKey = { suspensions += 1 }
        model.registerHotKey = { code, modifiers in restored.append((code, modifiers)); return true }
        model.actualShortcut = Shortcut.symbols(keyCode: Shortcut.fallbackKeyCode, modifiers: Shortcut.fallbackModifiers)
        model.beginRecording(in: window)
        XCTAssertTrue(model.recording)
        model.section = .search
        XCTAssertFalse(model.recording)
        XCTAssertEqual(suspensions, 1)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.0, model.keyCode)
        XCTAssertEqual(restored.first?.1, model.modifiers)
        XCTAssertEqual(model.actualShortcut, "⇧⌘F")
        XCTAssertNil(model.shortcutError)
    }

    func testReturningToSettingsRefreshesHotKeyWithoutChangingPreference() throws {
        _ = NSApplication.shared
        let model = SettingsModel(snapshot: true)
        let controller = SettingsWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        var retries = 0
        model.onRetryHotKey = {
            retries += 1
            model.actualShortcut = Shortcut.symbols(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers)
        }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(model.actualShortcut, "⌘␣")
        XCTAssertEqual(model.keyCode, Shortcut.defaultCmdSpace.keyCode)
        XCTAssertEqual(model.modifiers, Shortcut.defaultCmdSpace.modifiers)
        model.recording = true
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        XCTAssertEqual(retries, 1)
        model.recording = false
    }

    func testAllSettingsSectionsRenderAtStableWindowSizeAndRetainState() throws {
        _ = NSApplication.shared
        let model = SettingsModel(snapshot: true)
        let controller = SettingsWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        model.expandedCoverage = ["noAccess", "scope"]
        model.explanation = "coverage explanation"
        model.clipboard.setExcludedApplications(["com.apple.safari"])
        let view = try XCTUnwrap(window.contentView)
        for section in SettingsSection.allCases {
            model.section = section
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.bounds.width, 540, accuracy: 1)
            XCTAssertEqual(view.bounds.height, 680, accuracy: 1)
        }
        XCTAssertEqual(model.expandedCoverage, ["noAccess", "scope"])
        XCTAssertEqual(model.explanation, "coverage explanation")
        XCTAssertEqual(model.clipboard.excludedAppIDs, ["com.apple.safari"])
        XCTAssertEqual(model.contentHeight, 680)
    }
}
