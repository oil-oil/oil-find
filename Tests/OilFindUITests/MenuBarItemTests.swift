import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class MenuBarItemTests: XCTestCase {
    func testVisibilityDefaultsToShownAndPreservesSavedPreference() throws {
        let suite = "MenuBarItemTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsPreferences.register(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "showMenuBarItem"))
        defaults.set(false, forKey: "showMenuBarItem")
        SettingsPreferences.register(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: "showMenuBarItem"))
    }

    func testSettingsPersistsVisibilityAndNotifiesImmediately() throws {
        let suite = "MenuBarItemTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsModel(snapshot: true, preferences: defaults)
        XCTAssertTrue(model.showMenuBarItem)
        var changes: [Bool] = []
        model.onMenuBarItemChange = { changes.append($0) }
        model.setShowMenuBarItem(false)
        XCTAssertFalse(model.showMenuBarItem)
        XCTAssertFalse(defaults.bool(forKey: "showMenuBarItem"))
        XCTAssertFalse(SettingsModel(snapshot: true, preferences: defaults).showMenuBarItem)
        model.setShowMenuBarItem(true)
        model.setShowMenuBarItem(false)
        model.setShowMenuBarItem(true)
        XCTAssertTrue(model.showMenuBarItem)
        XCTAssertTrue(SettingsModel(snapshot: true, preferences: defaults).showMenuBarItem)
        XCTAssertEqual(changes, [false, true, false, true])
    }

    func testHiddenStartupAndRepeatedTogglesKeepTheSameMenu() throws {
        _ = NSApplication.shared
        let suite = "MenuBarItemTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "showMenuBarItem")
        let delegate = AppDelegate()
        delegate.buildMenu(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers, preferences: defaults)
        let item = try XCTUnwrap(delegate.statusItem)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let menu = try XCTUnwrap(item.menu)
        XCTAssertFalse(item.isVisible)
        let model = SettingsModel(snapshot: true, preferences: defaults)
        model.onMenuBarItemChange = { delegate.setMenuBarItemVisible($0) }
        for visible in [true, false, true] {
            model.setShowMenuBarItem(visible)
            XCTAssertEqual(item.isVisible, visible)
            XCTAssertTrue(delegate.statusItem === item)
            XCTAssertTrue(item.menu === menu)
            XCTAssertTrue(menu.items.contains { $0.action == #selector(AppDelegate.showSettings) })
        }
    }
}
