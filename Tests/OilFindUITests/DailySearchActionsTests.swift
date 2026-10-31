import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class DailySearchActionsTests: XCTestCase {
    func testRecentQueriesAreLocalBoundedAndClearable() throws {
        _ = NSApplication.shared
        let suite = "OilFindRecent-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentQueries(defaults: defaults)
        recent.add("  first  ")
        for number in 0..<11 { recent.add("query \(number)") }
        XCTAssertEqual(recent.entries.count, 10)
        XCTAssertFalse(recent.entries.contains("first"))
        recent.add("query 5")
        XCTAssertEqual(recent.entries.first, "query 5")
        XCTAssertEqual(recent.entries.filter { $0 == "query 5" }.count, 1)
        recent.add("   ")
        XCTAssertEqual(recent.entries.count, 10)
        recent.clear()
        XCTAssertTrue(recent.entries.isEmpty)

        let controller = SearchViewController(snapshot: false, preferences: defaults)
        _ = controller.view
        controller.searchField.text = "  report  "
        controller.searchField.clearText()
        XCTAssertEqual(recent.entries, ["report"])
        XCTAssertTrue(controller.searchField.hasRecentQueries)
        XCTAssertEqual(controller.searchField.text, "")
        let menu = controller.recentMenu()
        let reuse = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(reuse.title, "report")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reuse.action), to: reuse.target, from: reuse))
        XCTAssertEqual(controller.searchField.text, "report")
        let clear = try XCTUnwrap(menu.items.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear))
        XCTAssertTrue(recent.entries.isEmpty)
        XCTAssertFalse(controller.searchField.hasRecentQueries)
    }

    func testFolderContextActionScopesTheNextSearch() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindFolderAction-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("my folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: folder.appendingPathComponent("report.txt"))
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let controller = SearchViewController(snapshot: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.close() }
        try controller.prepareSnapshot(state: "results", query: "my folder", options: .init(), store: store, selection: 0)
        let menu = try XCTUnwrap(controller.results.onContextMenu?(0))
        let action = try XCTUnwrap(menu.items.first { $0.title == L10n.text("ctx.searchInFolder") })
        XCTAssertTrue(action.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(action.action), to: action.target, from: action))
        XCTAssertEqual(controller.searchField.text, "path:\"\(folder.path)/\"")
    }
}
