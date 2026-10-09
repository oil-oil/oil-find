import AppKit
import XCTest
import OilFindCore
@testable import OilFind

final class LanguageTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "OilFindLanguageTests-\(UUID().uuidString)"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testDefaultAndExplicitLanguagesResolveIndependentlyOfSystem() {
        let store = defaults()
        XCTAssertEqual(AppLanguage.load(from: store), .system)
        store.set("unsupported", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.load(from: store), .system)
        XCTAssertTrue(AppLanguage.system.usesChinese(systemLanguages: ["zh-Hans", "en"]))
        XCTAssertTrue(AppLanguage.system.usesChinese(systemLanguages: ["zh-Hant"]))
        XCTAssertFalse(AppLanguage.system.usesChinese(systemLanguages: ["en", "zh-Hans"]))
        XCTAssertFalse(AppLanguage.system.usesChinese(systemLanguages: []))
        XCTAssertTrue(AppLanguage.chinese.usesChinese(systemLanguages: ["en"]))
        XCTAssertFalse(AppLanguage.english.usesChinese(systemLanguages: ["zh-Hans"]))
    }

    func testSettingsPickerPersistsAndUpdatesAnExistingWindow() throws {
        _ = NSApplication.shared
        let store = defaults(), original = L10n.language, snapshot = L10n.snapshotChinese
        L10n.snapshotChinese = nil
        defer { L10n.setLanguage(original, in: store); L10n.snapshotChinese = snapshot }
        L10n.setLanguage(.chinese, in: store)
        let model = SettingsModel(snapshot: true, languageDefaults: store)
        let controller = SettingsWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        settle(window)
        let view = try XCTUnwrap(window.contentView)
        let picker = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("English")
        })
        let menu = try XCTUnwrap(picker.menu)
        let english = try XCTUnwrap(menu.items.firstIndex { $0.title == "English" })
        menu.performActionForItem(at: english)
        settle(window)
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(AppLanguage.load(from: store), .english)
        XCTAssertEqual(window.title, "Oil Find Settings")
        XCTAssertTrue(picker.itemTitles.contains("Follow System"))
        model.setLanguage(.system)
        XCTAssertEqual(AppLanguage.load(from: store), .system)
        XCTAssertEqual(L10n.chinese, AppLanguage.system.usesChinese())
    }

    func testSwitchUpdatesExistingSearchViewsAndKeepsQueryFilterSelectionAndScroll() throws {
        _ = NSApplication.shared
        let preferences = defaults(), original = L10n.language, snapshot = L10n.snapshotChinese
        L10n.snapshotChinese = nil
        defer { L10n.setLanguage(original, in: preferences); L10n.snapshotChinese = snapshot }
        L10n.setLanguage(.chinese, in: preferences)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindLanguage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<30 { try Data().write(to: root.appendingPathComponent("row\(index).txt")) }
        let config = IndexConfig(rootPath: root.path)
        let index = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let search = SearchViewController(snapshot: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = search
        defer { window.close() }
        try search.prepareSnapshot(state: "results", query: "row", options: .init(sort: .name), store: index, selection: 10)
        search.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(search.results.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200)); scroll.reflectScrolledClipView(scroll.contentView)
        let selection = search.results.selectedID, origin = scroll.contentView.bounds.origin
        search.filters.options.kind = 3
        search.toggleSyntax(true)
        L10n.setLanguage(.english, in: preferences)
        search.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(search.searchField.text, "row")
        XCTAssertEqual(search.filters.options.kind, 3)
        XCTAssertEqual(search.filters.options.sort, .name)
        XCTAssertEqual(search.results.selectedID, selection)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        XCTAssertEqual(table.numberOfRows, 30)
        XCTAssertTrue(search.syntaxVisible)
        XCTAssertEqual(search.searchField.input.placeholderAttributedString?.string, "Search apps, files, settings or calculate")
        XCTAssertTrue(descendants(search.filters).compactMap { $0 as? NSButton }.contains { $0.title == "Documents" })
        XCTAssertTrue(descendants(search.syntax).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Pinyin initials, finds 文档" })
        XCTAssertTrue(search.footer.text.contains("items"))
        L10n.setLanguage(.chinese, in: preferences)
        XCTAssertEqual(search.searchField.text, "row")
    }

    func testSearchAndUpdateWindowChangeLanguageWithoutRestrictingSearch() throws {
        _ = NSApplication.shared
        let store = defaults(), original = L10n.language, snapshot = L10n.snapshotChinese
        L10n.snapshotChinese = nil
        defer { L10n.setLanguage(original, in: store); L10n.snapshotChinese = snapshot }
        L10n.setLanguage(.chinese, in: store)
        let search = SearchViewController(snapshot: true)
        _ = search.view
        let update = UpdateManager(snapshot: true)
        update.prepareSnapshot(.latest, manifest: nil)
        let controller = UpdateWindowController(model: update)
        defer { controller.window?.close() }
        L10n.setLanguage(.english, in: store)
        XCTAssertTrue(search.searchField.input.isEnabled)
        XCTAssertEqual(search.searchField.input.placeholderAttributedString?.string, "Search apps, files, settings or calculate")
        XCTAssertFalse(descendants(search.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.localizedCaseInsensitiveContains("license") })
        XCTAssertEqual(controller.window?.title, "Check for Updates…")
        XCTAssertEqual(update.state, .latest)
    }

    func testLegacyAuthorizationCleanupRemovesOldLocalRecords() throws {
        let store = defaults()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OilFind-license-\(UUID().uuidString).json")
        try Data("legacy".utf8).write(to: path)
        store.set(1.0, forKey: "trialStartedAt")
        store.set(2.0, forKey: "trialLastSeenAt")
        store.set("https://example.com", forKey: "licenseAPI")
        store.set("old-device", forKey: "deviceFallbackID")
        store.set("legacy-key", forKey: "licenseKeyCache")
        store.set(true, forKey: "pinyinEnabled")
        store.set("en", forKey: AppLanguage.preferenceKey)
        var deletedKeychain = false

        LegacyAuthorizationCleanup.run(licenseFile: path, defaults: store) { deletedKeychain = true }

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertNil(store.object(forKey: "trialStartedAt"))
        XCTAssertNil(store.object(forKey: "trialLastSeenAt"))
        XCTAssertNil(store.object(forKey: "licenseAPI"))
        XCTAssertNil(store.object(forKey: "deviceFallbackID"))
        XCTAssertNil(store.object(forKey: "licenseKeyCache"))
        XCTAssertEqual(store.object(forKey: "pinyinEnabled") as? Bool, true)
        XCTAssertEqual(store.string(forKey: AppLanguage.preferenceKey), "en")
        XCTAssertTrue(deletedKeychain)
    }
}
