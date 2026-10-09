import Foundation
import XCTest
@testable import OilFind

final class LauncherCatalogTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LauncherCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeApp(at url: URL, name: String, bundleID: String, localizedNames: [String: [String: String]] = [:]) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleName": name, "CFBundleDisplayName": name,
                                    "CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL",
                                    "CFBundleLocalizations": Array(localizedNames.keys)]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("bundle executable must not be scanned".utf8).write(to: url.appendingPathComponent("Contents/MacOS/hidden-tool"))
        for (localization, strings) in localizedNames {
            let directory = url.appendingPathComponent("Contents/Resources/\(localization).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let localizedData = try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
            try localizedData.write(to: directory.appendingPathComponent("InfoPlist.strings"))
        }
    }

    func testSearchRankingNormalizationAndPinyinAliases() {
        XCTAssertEqual(LauncherMatch.rank("calc", in: ["Calculator"]), 1)
        XCTAssertEqual(LauncherMatch.rank("culator", in: ["Calculator"]), 2)
        XCTAssertEqual(LauncherMatch.rank("cafe", in: ["Café"]), 0)
        XCTAssertEqual(LauncherMatch.rank("CAFÉ notes", in: ["Café Notes"]), 0)
        XCTAssertNil(LauncherMatch.rank("notes missing", in: ["Café Notes"]))

        let catalog = ApplicationCatalog(snapshot: true)
        catalog.prepareSnapshot([LauncherApp(name: "计算器", path: "/tmp/Calculator.app")])
        XCTAssertEqual(catalog.search("jsq").map(\.name), ["计算器"])
        XCTAssertEqual(catalog.search("计算 qi").map(\.name), ["计算器"])
    }

    func testApplicationScanExcludesPathsAndNeverDescendsIntoBundles() throws {
        let root = try temporaryDirectory()
        let organizational = root.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: organizational, withIntermediateDirectories: true)
        let calculator = organizational.appendingPathComponent("Calculator.app", isDirectory: true)
        try makeApp(at: calculator, name: "Calculator", bundleID: "example.calculator")
        let excluded = root.appendingPathComponent("Blocked.app", isDirectory: true)
        try makeApp(at: excluded, name: "Blocked", bundleID: "example.blocked")
        let plainFolder = root.appendingPathComponent("NotAnApp", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        try Data("not a bundle".utf8).write(to: plainFolder.appendingPathComponent("inside-tool"))

        let found = ApplicationCatalog.scan(roots: [root], excludedPaths: [excluded.path])
        XCTAssertEqual(found.map(\.path), [calculator.standardizedFileURL.path])
        XCTAssertEqual(found.first?.bundleID, "example.calculator")
        XCTAssertFalse(found.first?.aliases.contains("hidden-tool") ?? true)
        XCTAssertEqual(found.first?.id, calculator.standardizedFileURL.path)
    }

    func testLocalizedChineseApplicationNameAndPinyinSearchIsLocaleIndependent() throws {
        let root = try temporaryDirectory()
        let appURL = root.appendingPathComponent("Example.app", isDirectory: true)
        try makeApp(at: appURL, name: "Example", bundleID: "example.localized",
                    localizedNames: ["en": ["CFBundleDisplayName": "Example", "CFBundleName": "Example"],
                                     "zh-Hans": ["CFBundleDisplayName": "中文工具", "CFBundleName": "中文工具"]])

        let scanned = ApplicationCatalog.scan(roots: [root])
        let catalog = ApplicationCatalog(snapshot: true)
        catalog.prepareSnapshot(scanned)

        XCTAssertEqual(catalog.search("中文").map(\.id), [appURL.standardizedFileURL.path])
        XCTAssertEqual(catalog.search("zwgj").map(\.id), [appURL.standardizedFileURL.path])
        XCTAssertTrue(scanned.first?.aliases.contains("中文工具") ?? false)
    }

    func testLaunchRecencyPersistsInIsolatedDefaultsAndChangesEmptySearchOrder() throws {
        let suite = "LauncherCatalogTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let catalog = ApplicationCatalog(snapshot: true, defaults: defaults)
        let alpha = LauncherApp(name: "Alpha", path: "/tmp/Alpha.app")
        let beta = LauncherApp(name: "Beta", path: "/tmp/Beta.app")
        catalog.prepareSnapshot([alpha, beta])
        XCTAssertEqual(catalog.search("").map(\.name), ["Alpha", "Beta"])

        catalog.recordLaunch(beta)

        XCTAssertEqual(catalog.search("").map(\.name), ["Beta", "Alpha"])
        let persisted = try XCTUnwrap(defaults.dictionary(forKey: "launcher.application.lastLaunched") as? [String: Date])
        XCTAssertNotNil(persisted[beta.id])
        XCTAssertEqual(catalog.revision, 2)
    }

    func testSystemSettingsHaveStableUniqueIDsAndSearchAliases() throws {
        let entries = SystemSettingsCatalog.entries
        XCTAssertGreaterThanOrEqual(entries.count, 26)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertTrue(["displays", "sound", "wifi", "bluetooth", "network", "keyboard", "keyshortcuts", "mouse", "trackpad",
                       "dock", "appearance", "wallpaper", "notifications", "focus", "battery", "accessibility", "privacysecurity",
                       "fulldiskaccess", "loginitems", "storage", "softwareupdate", "datetime", "language", "printers", "timemachine", "spotlight"]
            .allSatisfy { id in entries.contains(where: { $0.id == id }) })
        XCTAssertEqual(SystemSettingsCatalog.search("wireless").first?.id, "wifi")
        XCTAssertEqual(SystemSettingsCatalog.search("全磁盘").first?.id, "fulldiskaccess")

        let keyboard = try XCTUnwrap(entries.first(where: { $0.id == "keyshortcuts" }))
        XCTAssertEqual(keyboard.fallbackURL, URL(string: "x-apple.systempreferences:com.apple.preference.keyboard"))
        XCTAssertFalse(keyboard.breadcrumb.isEmpty)
    }

    func testSystemPreferenceURLsAndLegacyIDsUseInjectedOSVersion() {
        let old = OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)
        let os15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let os26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(SystemSettingsCatalog.preferenceURL("com.apple.Displays-Settings.extension", osVersion: old),
                       URL(string: "x-apple.systempreferences:com.apple.preference.displays"))
        XCTAssertEqual(SystemSettingsCatalog.preferenceURL("com.apple.Displays-Settings.extension", osVersion: os15),
                       URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"))
        XCTAssertEqual(SystemSettingsCatalog.preferenceURL("com.apple.Displays-Settings.extension", osVersion: os26),
                       URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"))
        XCTAssertEqual(SystemSettingsCatalog.legacyID(for: "com.apple.Displays-Settings.extension"), "displays")
        XCTAssertEqual(SystemSettingsCatalog.legacyID(for: "com.apple.BluetoothSettings"), "com.apple.preferences.Bluetooth")
        XCTAssertEqual(SystemSettingsCatalog.preferenceURL("com.apple.BluetoothSettings", osVersion: old),
                       URL(string: "x-apple.systempreferences:com.apple.preferences.Bluetooth"))
        XCTAssertEqual(SystemSettingsCatalog.legacyID(for: "com.apple.LoginItems-Settings.extension"), "com.apple.ExtensionsPreferences")
        XCTAssertEqual(SystemSettingsCatalog.preferenceURL("com.apple.LoginItems-Settings.extension", osVersion: old),
                       URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences"))
        XCTAssertEqual(SystemSettingsCatalog.legacyID(for: "com.apple.Date-Time-Settings.extension"), "datetime")
        XCTAssertEqual(SystemSettingsCatalog.legacyID(for: "com.apple.Software-Update-Settings.extension"), "softwareupdate")
        XCTAssertEqual(SystemSettingsCatalog.legacyID(for: "unknown.extension"), "unknown.extension")
    }

    func testPrivacyAndKeyboardDestinationsResolveForMacOS14And15And26() throws {
        let os15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let os26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let settings26 = SystemSettingsCatalog.makeEntries(osVersion: os26)
        func setting(_ id: String, in values: [SystemSetting]) throws -> SystemSetting {
            try XCTUnwrap(values.first { $0.id == id })
        }

        for version in [OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0), os15] {
            let entries = SystemSettingsCatalog.makeEntries(osVersion: version)
            XCTAssertEqual(entries.count, 26)
            XCTAssertEqual(Set(entries.map(\.id)).count, 26)
            let keyboard = try setting("keyshortcuts", in: entries)
            XCTAssertEqual(keyboard.url, URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
            XCTAssertEqual(keyboard.fallbackURL, URL(string: "x-apple.systempreferences:com.apple.preference.keyboard"))
            let fullDisk = try setting("fulldiskaccess", in: entries)
            XCTAssertEqual(fullDisk.url, URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"))
            XCTAssertEqual(fullDisk.fallbackURL, URL(string: "x-apple.systempreferences:com.apple.preference.security"))
            XCTAssertTrue(fullDisk.breadcrumb.contains("Full Disk Access"))
            let privacy = try setting("privacysecurity", in: entries)
            XCTAssertEqual(privacy.url, URL(string: "x-apple.systempreferences:com.apple.preference.security"))
            XCTAssertEqual(privacy.fallbackURL, privacy.url)
        }

        let keyboard26 = try setting("keyshortcuts", in: settings26)
        XCTAssertEqual(keyboard26.url, URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
        XCTAssertEqual(keyboard26.fallbackURL, URL(string: "x-apple.systempreferences:com.apple.preference.keyboard"))
        XCTAssertTrue(keyboard26.breadcrumb.contains("Keyboard Shortcuts"))

        let fullDisk26 = try setting("fulldiskaccess", in: settings26)
        XCTAssertEqual(fullDisk26.url, URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"))
        XCTAssertEqual(fullDisk26.fallbackURL, URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"))
        XCTAssertTrue(fullDisk26.breadcrumb.contains("Full Disk Access"))
        let privacy26 = try setting("privacysecurity", in: settings26)
        XCTAssertEqual(privacy26.url, URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"))
        XCTAssertEqual(privacy26.fallbackURL, URL(string: "x-apple.systempreferences:com.apple.preference.security"))
    }
}
