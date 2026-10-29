import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class ResultRefreshTests: XCTestCase {
    func testIndexNotificationDuringPendingAdditionalOnlyQueryKeepsViewport() throws {
        _ = NSApplication.shared
        final class Provider: AdditionalSearchProvider {
            var isEnabled = true
            let title = "AI Topics"
            var onChange: (() -> Void)?
            var blockNext = false
            var searches = 0
            let gate = DispatchSemaphore(value: 0)
            func prepareSearch(_ query: Query, isCancelled: @escaping () -> Bool) -> () throws -> [AdditionalSearchItem] {
                searches += 1
                let blocked = blockNext; blockNext = false
                return { [gate] in
                    if blocked { gate.wait() }
                    guard !isCancelled() else { return [] }
                    return (0..<150).map { index in
                        AdditionalSearchItem(id: String(index), title: "row topic \(index)", detail: query.raw, location: "Claude", modified: Date(timeIntervalSince1970: Double(index)), icon: NSImage(), actions: [])
                    }
                }
            }
            func visibilityChanged(_ visible: Bool) { }
        }
        let provider = Provider(), controller = SearchViewController(snapshot: true)
        controller.additionalSearchProvider = provider
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 800, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.close() }
        window.orderFrontRegardless()
        try controller.prepareSnapshot(state: "results", query: "row", options: .init(), store: nil, selection: 0, additionalOnly: true)
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(controller.results.subviews.compactMap { $0 as? NSScrollView }.first)
        controller.results.select(30)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000)); scroll.reflectScrolledClipView(scroll.contentView)
        let initial = controller.results.result, selection = controller.results.selectedAdditional?.id
        provider.blockNext = true
        defer { provider.gate.signal() }
        func awaitRefresh(_ previous: SearchPresentation?) {
            let deadline = Date().addingTimeInterval(3)
            while controller.results.result === previous && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertFalse(controller.results.result === previous, "searches \(provider.searches), query \(controller.searchField.text)")
        }
        controller.startSearch()
        controller.indexChanged()
        provider.gate.signal()
        awaitRefresh(initial)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1000)
        XCTAssertEqual(controller.results.selectedAdditional?.id, selection)

        controller.searchField.text = "new"
        var previous = controller.results.result
        controller.startSearch(); awaitRefresh(previous)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, -6)
        XCTAssertEqual(controller.results.selectedRow, 0)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
        previous = controller.results.result
        controller.filters.options.sort = .name
        controller.startSearch(); awaitRefresh(previous)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, -6)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
        previous = controller.results.result
        controller.filters.select(0); awaitRefresh(previous)
        XCTAssertEqual(controller.results.result?.count, 150)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, -6)
    }

    func testIndexNotificationDuringPendingFileQueryKeepsViewport() throws {
        _ = NSApplication.shared
        final class Provider: SupplementarySearchProvider {
            var isEnabled = true
            var blockNext = false
            let gate = DispatchSemaphore(value: 0)
            func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
                let blocked = blockNext; blockNext = false
                return { [gate] in
                    if blocked { gate.wait() }
                    guard !isCancelled() else { return [] }
                    return [.init(sourceID: "startup", entryID: 1, detail: "Generated content")]
                }
            }
            func sourcesDidChange(_ sources: [SearchSource]) { }
            func userActivity(visible: Bool, typing: Bool) { }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindViewport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<100 { try Data().write(to: root.appendingPathComponent(String(format: "row%03d.txt", index))) }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let provider = Provider(), controller = SearchViewController(snapshot: true)
        controller.additionalSources = { [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] }
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 800, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.close() }
        window.orderFrontRegardless()
        try controller.prepareSnapshot(state: "results", query: "row", options: .init(sort: .name), store: store, selection: 0)
        controller.supplementaryProvider = provider
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(controller.results.subviews.compactMap { $0 as? NSScrollView }.first)
        controller.results.select(30)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000)); scroll.reflectScrolledClipView(scroll.contentView)
        let initial = controller.results.result, selection = controller.results.selectedItem?.path
        provider.blockNext = true
        defer { provider.gate.signal() }
        controller.startSearch()
        controller.indexChanged()
        provider.gate.signal()
        let deadline = Date().addingTimeInterval(3)
        while controller.results.result === initial && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(controller.results.result === initial)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1000)
        XCTAssertEqual(controller.results.selectedItem?.path, selection)
    }

    func testIdenticalItemsKeepSelectionAndViewport() {
        XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: [7, 9, 12], sameStore: true,
                                           sameVersion: true, scrolling: false, dragging: false), .replaceResult)
        XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: [7, 9, 12], sameStore: true,
                                           sameVersion: false, scrolling: false, dragging: false), .reloadVisibleRows)
        XCTAssertEqual(resultRefreshAction(oldItems: [], newItems: [], sameStore: true,
                                           sameVersion: false, scrolling: false, dragging: false), .reloadVisibleRows)
    }
    func testChangedItemsRestoreSelectionAndViewport() {
        let variants: [[UInt32]] = [[7, 12], [12, 9, 7], [7, 9, 12, 15], []]
        for items in variants {
            XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: items, sameStore: true,
                                               sameVersion: false, scrolling: false, dragging: false), .reloadPreservingViewport)
        }
        // IDs in a replacement store do not identify the same files.
        XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: [7, 9, 12], sameStore: false,
                                           sameVersion: true, scrolling: false, dragging: false), .reloadPreservingViewport)
    }
    func testScrollingAndDraggingDeferEveryRefresh() {
        let variants: [[UInt32]] = [[7, 9, 12], [7, 12]]
        for (scrolling, dragging) in [(true, false), (false, true), (true, true)] {
            for items in variants {
                XCTAssertEqual(resultRefreshAction(oldItems: [7, 9, 12], newItems: items, sameStore: true,
                                                   sameVersion: false, scrolling: scrolling, dragging: dragging), .deferRefresh)
            }
            XCTAssertEqual(resultRefreshAction(oldItems: [7], newItems: [7], sameStore: true,
                                               sameVersion: true, scrolling: scrolling, dragging: dragging), .deferRefresh)
        }
    }
}
