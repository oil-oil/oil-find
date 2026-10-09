import AppKit
import SwiftUI
import XCTest
@testable import OilFindApp

final class ApplicationMenuTests: XCTestCase {
    private final class Extension: ApplicationExtension {
        var chinese = true
        var visible = true
        var clicks = 0
        var onSettingsMenuItemChange: (() -> Void)?
        var settingsMenuItem: ApplicationMenuItem? {
            ApplicationMenuItem(title: chinese ? "扩展设置…" : "Extension Settings…", isVisible: visible) { [weak self] in self?.clicks += 1 }
        }
        func start(chinese: Bool, showSettings: @escaping () -> Void) { self.chinese = chinese }
        func stop() { }
        func handle(_ url: URL) { }
        func languageDidChange(chinese: Bool) { self.chinese = chinese; onSettingsMenuItemChange?() }
        func settingsSection(window: @escaping () -> NSWindow?) -> AnyView { AnyView(EmptyView()) }
    }
    private final class EmptyExtension: ApplicationExtension {
        func start(chinese: Bool, showSettings: @escaping () -> Void) { }
        func stop() { }
        func handle(_ url: URL) { }
        func languageDidChange(chinese: Bool) { }
        func settingsSection(window: @escaping () -> NSWindow?) -> AnyView { AnyView(EmptyView()) }
    }

    func testDefaultExtensionLeavesMenuUnchanged() {
        _ = NSApplication.shared
        let plain = AppDelegate(), extended = AppDelegate(appExtension: EmptyExtension())
        let first = plain.makeMenu(), second = extended.makeMenu()
        XCTAssertEqual(first.items.map(\.title), second.items.map(\.title))
        XCTAssertEqual(first.items.map(\.isHidden), second.items.map(\.isHidden))
        let settings = first.items.firstIndex { $0.action == #selector(AppDelegate.showSettings) }!
        XCTAssertEqual(first.items[settings + 1].title, L10n.text("update.check"))
    }

    func testItemPlacementActionAndImmediateVisibilityUpdates() throws {
        _ = NSApplication.shared
        let ext = Extension(), delegate = AppDelegate(appExtension: ext)
        let menu = delegate.makeMenu()
        let settings = try XCTUnwrap(menu.items.firstIndex { $0.action == #selector(AppDelegate.showSettings) })
        let supplied = menu.items[settings + 1]
        XCTAssertEqual(supplied.title, "扩展设置…")
        menu.performActionForItem(at: settings + 1)
        XCTAssertEqual(ext.clicks, 1)
        ext.visible = false; ext.onSettingsMenuItemChange?()
        XCTAssertTrue(supplied.isHidden)
        ext.visible = true; ext.onSettingsMenuItemChange?()
        XCTAssertFalse(supplied.isHidden)
    }

    func testLanguageChangeRefreshesBothExistingMenuItems() throws {
        _ = NSApplication.shared
        let name = "ApplicationMenuTests-\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        let original = L10n.language, snapshot = L10n.snapshotChinese
        L10n.snapshotChinese = nil
        defer { L10n.setLanguage(original, in: defaults); L10n.snapshotChinese = snapshot; defaults.removePersistentDomain(forName: name) }
        L10n.setLanguage(.chinese, in: defaults)
        let ext = Extension(), delegate = AppDelegate(appExtension: ext), menu = delegate.makeMenu()
        let settings = try XCTUnwrap(menu.items.firstIndex { $0.action == #selector(AppDelegate.showSettings) })
        L10n.setLanguage(.english, in: defaults)
        XCTAssertEqual(menu.items[settings].title, "Settings…")
        XCTAssertEqual(menu.items[settings + 1].title, "Extension Settings…")
        L10n.setLanguage(.chinese, in: defaults)
        XCTAssertEqual(menu.items[settings].title, "设置…")
        XCTAssertEqual(menu.items[settings + 1].title, "扩展设置…")
    }
}
