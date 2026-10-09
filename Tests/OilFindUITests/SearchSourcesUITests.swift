import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SearchSourcesUITests: XCTestCase {
    private func store(_ root: URL, name: String) throws -> IndexStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("catalog".utf8).write(to: root.appendingPathComponent(name))
        let config = IndexConfig(rootPath: root.path)
        return IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
    }
    func testOfflineActionsCopyAndDrag() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindSourcesUI-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let startup = try store(root.appendingPathComponent("startup"), name: "startup.txt")
        let external = try store(root.appendingPathComponent("T7 Shield"), name: "external.txt")
        let source = SearchSource(id: "external", displayName: "T7 Shield", isOnline: false, store: external)
        let controller = SearchViewController(snapshot: true)
        let previousLanguage = L10n.snapshotChinese
        L10n.snapshotChinese = true
        defer { L10n.snapshotChinese = previousLanguage }
        try controller.prepareSnapshot(state: "results", query: "external", options: .init(), store: startup, selection: 0, additionalSources: [source])
        let item = try XCTUnwrap(controller.results.selectedItem)
        XCTAssertEqual(item.source.id, source.id)
        XCTAssertFalse(item.source.isOnline)
        let scroll = try XCTUnwrap(controller.results.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        XCTAssertNil(controller.results.tableView(table, pasteboardWriterForRow: 0))
        func key(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        for event in [key(36), key(36, flags: .command), key(16, characters: "y", flags: .command)] {
            XCTAssertTrue(controller.handleKey(event))
            XCTAssertEqual(controller.footer.text, "「T7 Shield」未连接，连接后才能打开。")
            XCTAssertFalse(controller.quickLook.isVisible)
        }
        XCTAssertTrue(controller.handleKey(key(8, characters: "c", flags: .command)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), item.path)
        XCTAssertTrue(controller.handleKey(key(8, characters: "c", flags: [.command, .option])))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), item.name)
        XCTAssertTrue(controller.handleKey(key(51, flags: .command)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }
    func testOldSnapshotCannotDragAfterCurrentStoreIsReplaced() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindSourceReplacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try store(root.appendingPathComponent("old"), name: "same.txt")
        let new = try store(root.appendingPathComponent("new"), name: "same.txt")
        let source = SearchSource(id: "disk", displayName: "Disk", isOnline: true, store: old)
        let found = try XCTUnwrap(MultiSearcher.search(Query.parse("same"), in: [source]))
        let view = ResultsView(frame: .zero)
        view.show(SearchPresentation(found))
        view.currentSource = { _ in SearchSource(id: "disk", displayName: "Disk", isOnline: true, store: new) }
        XCTAssertFalse(try XCTUnwrap(view.selectedItem).source.isOnline)
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        XCTAssertNil(view.tableView(table, pasteboardWriterForRow: 0))
    }
    func testSourceWithdrawalClearsResultsBeforeStartupHasLoaded() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindSourceWithdrawal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try store(root, name: "external.txt")
        let source = SearchSource(id: "external", displayName: "Archive", isOnline: false, store: index)
        let controller = SearchViewController(snapshot: true)
        controller.additionalSources = { [] }
        let found = try XCTUnwrap(MultiSearcher.search(Query.parse("external"), in: [source]))
        controller.present(SearchPresentation(found))
        XCTAssertEqual(controller.results.result?.total, 1)
        controller.sourcesChanged()
        XCTAssertNil(controller.results.result)
        XCTAssertNil(controller.results.selectedItem)
    }
    func testRefreshPreservesIdentityWhenSourcesReorderAndGoOffline() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindSourcesIdentity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try store(root.appendingPathComponent("a"), name: "same.txt")
        let b = try store(root.appendingPathComponent("b"), name: "same.txt")
        let sourceA = SearchSource(id: "a", displayName: "A", isOnline: true, store: a)
        let sourceB = SearchSource(id: "b", displayName: "B", isOnline: true, store: b)
        let query = Query.parse("same")
        let first = try XCTUnwrap(MultiSearcher.search(query, in: [sourceA, sourceB]))
        let view = ResultsView(frame: NSRect(origin: .zero, size: Theme.panelSize))
        view.show(SearchPresentation(first), selection: 1)
        XCTAssertEqual(view.selectedItem?.source.id, "b")
        let offlineB = SearchSource(id: "b", displayName: "B", isOnline: false, store: b)
        let next = try XCTUnwrap(MultiSearcher.search(query, in: [offlineB, sourceA]))
        view.refresh(SearchPresentation(next))
        XCTAssertEqual(view.selectedItem?.source.id, "b")
        XCTAssertFalse(try XCTUnwrap(view.selectedItem).source.isOnline)
    }
}
