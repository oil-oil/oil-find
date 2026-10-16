import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class AdditionalSearchTests: XCTestCase {
    private final class Provider: AdditionalSearchProvider {
        var isEnabled = true
        var title = "AI Topics"
        var onChange: (() -> Void)?
        var opened = 0, copied = 0
        var delay = false
        let gate = DispatchSemaphore(value: 0)
        func prepareSearch(_ query: Query, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem] {
            let delayed = delay
            return { [self] in
                if delayed { gate.wait() }
                guard !isCancelled(), query.raw != "missing" else { return [] }
                return (0..<150).map { i in
                    AdditionalSearchItem(id: String(i), title: "shared topic \(i)", detail: query.raw, location: "Claude", modified: Date(timeIntervalSince1970: Double(i)), icon: NSImage(), relevance: 1200,
                        actions: [.init(kind: .open, title: "Open Conversation") { done in self.opened += 1; done(true) }, .init(kind: .copy, title: "Copy Resume") { done in self.copied += 1; done(true) }])
                }
            }
        }
        func visibilityChanged(_ visible: Bool) { }
    }
    private final class ScopedProvider: AdditionalSearchProvider {
        private enum Failure: Error { case refresh }
        private enum NextSearch { case success, blockedFailure }
        var isEnabled = true
        let title = "AI Topics"
        var onChange: (() -> Void)?
        var enabledScopes: Set<String> = ["claude", "codex"]
        private var nextSearch: NextSearch = .success
        let gate = DispatchSemaphore(value: 0)
        private let items: [AdditionalSearchItem] = ["claude", "codex"].flatMap { scope in
            (0..<10).map { index in
                AdditionalSearchItem(id: "\(scope)-\(index)", title: "\(scope) shared topic \(index)", detail: "\(scope) excerpt", location: scope.capitalized,
                    modified: Date(timeIntervalSince1970: Double(index)), icon: NSImage(), availabilityScope: scope, actions: [])
            }
        }
        func availableItems(from items: [AdditionalSearchItem]) -> [AdditionalSearchItem] {
            let scopes = enabledScopes
            return items.filter { $0.availabilityScope.map(scopes.contains) ?? false }
        }
        func blockAndFailNextSearch() { nextSearch = .blockedFailure }
        func prepareSearch(_ query: Query, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem] {
            let found = availableItems(from: items), outcome = nextSearch
            nextSearch = .success
            return { [gate] in
                if case .blockedFailure = outcome { gate.wait(); throw Failure.refresh }
                return isCancelled() ? [] : found
            }
        }
        func visibilityChanged(_ visible: Bool) { }
    }
    private func eventually(_ body: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !body(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return body()
    }
    private func source() -> SearchSource {
        let names = ["", "shared.swift"]
        var b = ScanBuffer(); b.ids = [0,1]; b.parents = [0,0]; b.sizes = [0,100]; b.mtimes = [0,10]; b.flags = [1,128]; b.depths = [0,1]; b.kinds = [1,7]
        b.nameLens = names.map { UInt32($0.utf8.count) }; b.nameBytes = Array(names.joined().utf8)
        let store = IndexStore(scan: ScanOutput(buffers: [b], count: 2, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/generated"))
        return SearchSource(id: "fixture", displayName: "", isOnline: true, store: store)
    }
    func testAllAndCategoryTabsShareOneCompleteResultListAndRevocationRemovesTopics() throws {
        _ = NSApplication.shared
        let provider = Provider(), controller = SearchViewController(snapshot: true), source = source()
        _ = controller.view; controller.additionalSources = { [source] }; controller.additionalSearchProvider = provider
        controller.searchField.text = "shared"; controller.startSearch()
        XCTAssertTrue(eventually { controller.results.result?.count == 151 })
        XCTAssertEqual(controller.results.result?.total, 151)
        let tab = try XCTUnwrap(controller.filters.subviews.compactMap { $0 as? NSButton }.first { $0.title == provider.title })
        XCTAssertTrue(tab.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.stringValue == provider.title })
        XCTAssertNotNil(controller.results.result?.additional(at: 0))
        controller.filters.select(FilterBar.names.count)
        XCTAssertTrue(eventually { controller.results.result?.count == 150 })
        XCTAssertTrue(controller.footer.text.contains("150"))
        XCTAssertTrue((0..<150).allSatisfy { controller.results.result?.additional(at: $0) != nil })
        controller.results.select(149)
        XCTAssertEqual(controller.results.selectedAdditional?.id, "0")
        XCTAssertNil(controller.results.selectedItem)
        controller.filters.select(7)
        XCTAssertTrue(eventually { controller.results.result?.count == 1 && controller.results.result?.hasAdditional == false })
        controller.filters.select(0)
        XCTAssertTrue(eventually { controller.results.result?.count == 151 })
        provider.isEnabled = false; provider.onChange?()
        XCTAssertNil(controller.filters.additionalTitle)
        XCTAssertFalse(controller.results.result?.hasAdditional == true)
        XCTAssertEqual(controller.results.result?.count, 1)
    }
    func testNewQuerySuppressesStaleTopicsAndTopicKeysNeverInvokeFileActions() {
        _ = NSApplication.shared
        let provider = Provider(), controller = SearchViewController(snapshot: true)
        _ = controller.view; controller.additionalSearchProvider = provider
        provider.delay = true; controller.searchField.text = "old"; controller.startSearch()
        provider.delay = false; controller.searchField.text = "new"; controller.startSearch(); provider.gate.signal()
        XCTAssertTrue(eventually { controller.results.result?.additional(at: 0)?.detail == "new" })
        controller.results.select(149)
        XCTAssertEqual(controller.results.selectedAdditional?.id, "0")
        controller.searchField.text = "another"; controller.startSearch()
        XCTAssertTrue(eventually { controller.results.result?.additional(at: 0)?.detail == "another" })
        XCTAssertEqual(controller.results.selectedRow, 0)
        func key(_ code: UInt16, _ text: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(controller.handleKey(key(51, "", .command)))
        XCTAssertEqual(provider.opened, 0)
        XCTAssertTrue(controller.handleKey(key(8, "c", .command)))
        XCTAssertEqual(provider.copied, 1)
        var dismissed = 0; controller.hidePanel = { dismissed += 1 }
        XCTAssertTrue(controller.handleKey(key(36)))
        XCTAssertTrue(eventually { dismissed == 1 }); XCTAssertEqual(provider.opened, 1)
        XCTAssertFalse(controller.handleKey(key(29, "0", .command)))
        controller.filters.select(7)
        XCTAssertEqual(controller.results.result?.count ?? 0, 0)
        XCTAssertFalse(controller.results.result?.hasAdditional == true)
        controller.filters.select(FilterBar.names.count)
        XCTAssertTrue(eventually { controller.results.result?.count == 150 })
        let manager = IndexManager(config: IndexConfig(rootPath: "/generated"), dbURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        controller.manager = manager; controller.managerStateChanged(.loading)
        XCTAssertFalse(controller.results.isHidden)
        XCTAssertTrue(controller.footer.text.contains("150"))
        manager.stop()
    }
    func testTopicSelectionSurvivesRefreshAndFileRowsRemainFiles() throws {
        _ = NSApplication.shared
        let provider = Provider(), source = source(), query = Query.parse("shared")
        let base = SearchPresentation(try XCTUnwrap(MultiSearcher.search(query, options: .init(sort: .modified), in: [source])))
        let extras = try provider.prepareSearch(query, isCancelled: { false })()
        let merged = base.including(extras, options: .init(sort: .modified))
        let results = ResultsView(frame: NSRect(x: 0, y: 0, width: 760, height: 300)); results.show(merged)
        results.select(try XCTUnwrap(merged.index(additionalID: "12")))
        let next = base.including(Array(extras.dropFirst(10)), options: .init(sort: .modified))
        results.refresh(next); XCTAssertEqual(results.selectedAdditional?.id, "12")
        results.select(try XCTUnwrap(next.index(sourceID: source.id, store: source.store, id: 1, path: "/generated/shared.swift")))
        XCTAssertNil(results.selectedAdditional); XCTAssertEqual(results.selectedItem?.path, "/generated/shared.swift")
    }
    func testPartialDisablePrunesBeforeBlockedFailureAndKeepsEnabledTopicAndFileSelection() throws {
        _ = NSApplication.shared
        let panel = SearchPanel(snapshot: true), controller = panel.searchController, provider = ScopedProvider(), source = source()
        defer { provider.gate.signal(); controller.panelDidHide(); panel.orderOut(nil); panel.close() }
        _ = controller.view; controller.additionalSources = { [source] }; controller.additionalSearchProvider = provider
        controller.searchField.text = "shared"; controller.startSearch()
        XCTAssertTrue(eventually { controller.results.result?.count == 21 && !controller.searchField.indexing })
        panel.makeKeyAndOrderFront(nil); controller.panelWillShow()
        XCTAssertTrue(eventually { controller.results.result?.count == 21 && !controller.searchField.indexing })

        let initial = try XCTUnwrap(controller.results.result)
        let selectedCodexRow = try XCTUnwrap(initial.index(additionalID: "codex-0"))
        controller.results.select(selectedCodexRow)
        XCTAssertEqual(controller.results.selectedAdditional?.id, "codex-0")
        let scroll = try XCTUnwrap(controller.results.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100)); scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(origin.y, 0)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)

        provider.enabledScopes = ["codex"]
        provider.blockAndFailNextSearch()
        provider.onChange?()

        let pruned = try XCTUnwrap(controller.results.result)
        XCTAssertEqual(pruned.count, 11, "the disabled provider rows should disappear before refresh completes")
        XCTAssertNil(pruned.index(additionalID: "claude-0"))
        XCTAssertNotNil(pruned.index(additionalID: "codex-0"))
        XCTAssertEqual((0..<pruned.count).filter { pruned.row($0) != nil }.count, 1)
        XCTAssertEqual(controller.results.selectedAdditional?.id, "codex-0")
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)

        provider.gate.signal()
        XCTAssertTrue(eventually { controller.footer.warning && controller.results.result?.count == 11 })
        XCTAssertNil(controller.results.result?.index(additionalID: "claude-0"))
        XCTAssertNotNil(controller.results.result?.index(additionalID: "codex-0"))
        XCTAssertEqual(controller.results.selectedAdditional?.id, "codex-0")
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)

        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(controller.results.result?.count, 11)
        XCTAssertNil(controller.results.result?.index(additionalID: "claude-0"))
        XCTAssertEqual(controller.results.selectedAdditional?.id, "codex-0")
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
    }
    func testHiddenPanelPartialDisablePrunesOnlyUnavailableItems() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true), provider = ScopedProvider(), source = source()
        _ = controller.view; controller.additionalSources = { [source] }; controller.additionalSearchProvider = provider
        controller.searchField.text = "shared"; controller.startSearch()
        XCTAssertTrue(eventually { controller.results.result?.count == 21 && !controller.searchField.indexing })
        let initial = try XCTUnwrap(controller.results.result)
        let fileRow = try XCTUnwrap((0..<initial.count).first { initial.row($0) != nil })
        controller.results.select(fileRow)
        let selectedPath = try XCTUnwrap(controller.results.selectedItem?.path)

        provider.enabledScopes = ["codex"]
        provider.onChange?()
        let pruned = try XCTUnwrap(controller.results.result)
        XCTAssertEqual(pruned.count, 11)
        XCTAssertNil(pruned.index(additionalID: "claude-0"))
        XCTAssertNotNil(pruned.index(additionalID: "codex-0"))
        XCTAssertEqual(controller.results.selectedItem?.path, selectedPath)
        XCTAssertEqual(controller.filters.additionalTitle, provider.title)

        provider.onChange?() // A sync-progress notification with unchanged availability must not replace the displayed snapshot.
        XCTAssertTrue(controller.results.result === pruned)
        XCTAssertEqual(controller.results.selectedItem?.path, selectedPath)
    }
    func testReopeningAfterHiddenAdditionalOnlyDisableSearchesAvailableFiles() throws {
        _ = NSApplication.shared
        let panel = SearchPanel(snapshot: true), controller = panel.searchController, provider = ScopedProvider(), source = source()
        defer { controller.panelDidHide(); panel.orderOut(nil); panel.close() }
        _ = controller.view; controller.additionalSources = { [source] }; controller.additionalSearchProvider = provider
        controller.searchField.text = "shared"; controller.filters.select(FilterBar.names.count, notify: false); controller.startSearch()
        XCTAssertTrue(eventually { controller.results.result?.count == 20 && !controller.searchField.indexing })
        XCTAssertNil(controller.results.result?.single); XCTAssertNil(controller.results.result?.multiple)

        provider.enabledScopes = []; provider.isEnabled = false; provider.onChange?()
        XCTAssertNil(controller.filters.additionalTitle)
        XCTAssertEqual(controller.results.result?.count, 0)
        panel.makeKeyAndOrderFront(nil); controller.panelWillShow()
        XCTAssertTrue(eventually { controller.results.result?.count == 1 && controller.results.result?.row(0) != nil })
        XCTAssertEqual(controller.results.result?.row(0)?.source.id, source.id)
    }
}
