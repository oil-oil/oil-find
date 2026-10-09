import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SupplementarySearchTests: XCTestCase {
    private func store() -> IndexStore {
        let names = ["", "发票.png", "older.png", "newer.png"]
        var buffer = ScanBuffer(); buffer.ids = [0,1,2,3]; buffer.parents = [0,0,0,0]; buffer.sizes = [0,100,200,300]; buffer.mtimes = [0,20,10,30]; buffer.flags = [1,128,128,128]; buffer.depths = [0,1,1,1]; buffer.kinds = [1,4,4,4]; buffer.nameLens = names.map { UInt32($0.utf8.count) }; buffer.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [buffer], count: 4, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/generated"))
    }
    func testDetailKeepsFolderAndOnlyFolderTruncates() throws {
        _ = NSApplication.shared
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store())
        let parent = NSHomeDirectory() + "/Desktop/截图/" + String(repeating: "很长的文件夹/", count: 12)
        let cell = ResultCell(frame: NSRect(x: 0, y: 0, width: 760, height: 50)), icons = IconProvider()
        func item(_ detail: SupplementaryHit?) -> ResultItem {
            ResultItem(detail: detail, id: 1, source: source, name: "发票.png", parentPath: parent, path: parent + "/发票.png", size: 100, modified: Date(), flags: 0, kind: 4)
        }
        for reason in ["图中文字：…开具发票的日期…", "图中有：猫", "Text in image: …Invoice date…", "Contains: cat"] {
            cell.configure(item(.init(sourceID: "startup", entryID: 1, detail: reason, highlights: [NSRange(location: 0, length: 2)])), query: .parse("发票"), icons: icons)
            cell.layoutSubtreeIfNeeded()
            let labels = cell.subviews.compactMap { $0 as? NSTextField }
            let detail = try XCTUnwrap(labels.first { $0.stringValue == reason + " · " })
            let path = try XCTUnwrap(labels.first { $0.stringValue == Presentation.abbreviate(path: parent, home: NSHomeDirectory()) })
            XCTAssertFalse(detail.isHidden)
            XCTAssertGreaterThanOrEqual(detail.frame.width, detail.attributedStringValue.size().width)
            XCTAssertEqual(path.frame.minX, detail.frame.maxX)
            XCTAssertEqual(path.lineBreakMode, .byTruncatingMiddle)
            XCTAssertLessThan(path.frame.width, path.attributedStringValue.size().width)
            XCTAssertNotNil(detail.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        }
        cell.configure(item(nil), query: .parse("发票"), icons: icons)
        cell.layoutSubtreeIfNeeded()
        let path = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("~/Desktop/") })
        XCTAssertEqual(path.frame.minX, 70)
        XCTAssertEqual(path.frame.width, 760 - 236)
    }
    func testThumbnailFitsSquareAndReusedCellKeepsFileIcon() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("M22-thumbnail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let file = dir.appendingPathComponent("wide.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store())
        func item(_ thumbnail: Bool) -> ResultItem {
            ResultItem(detail: thumbnail ? .init(sourceID: "startup", entryID: 1, detail: "Generated text", thumbnail: true) : nil, id: 1, source: source, name: "wide.png", parentPath: dir.path, path: file.path, size: 100, modified: Date(timeIntervalSince1970: 1), flags: 0, kind: 4)
        }
        let cell = ResultCell(frame: NSRect(x: 0, y: 0, width: 760, height: 50)), icons = IconProvider()
        cell.configure(item(true), query: .parse("text"), icons: icons)
        cell.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(icon.layer?.borderWidth, 0)
        let deadline = Date().addingTimeInterval(3)
        while !icons.isIdle && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(icons.isIdle)
        XCTAssertEqual(icon.frame.size, NSSize(width: 32, height: 32))
        XCTAssertEqual(icon.imageScaling, .scaleProportionallyUpOrDown)
        let thumbnail = try XCTUnwrap(icon.image)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 4, accuracy: 0.01)
        XCTAssertEqual(icon.layer?.borderWidth, 0.5)
        XCTAssertEqual(icon.layer?.cornerRadius, 3)
        XCTAssertNotNil(icon.layer?.backgroundColor)
        let pendingIcons = IconProvider()
        cell.configure(item(true), query: .parse("text"), icons: pendingIcons)
        cell.configure(item(false), query: .parse("text"), icons: pendingIcons)
        let fileIcon = icon.image
        while !pendingIcons.isIdle && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(icon.image === fileIcon)
        XCTAssertEqual(icon.layer?.borderWidth, 0)
        XCTAssertEqual(icon.layer?.cornerRadius, 0)
    }
    func testDedupOrderDetailAndLateSelection() throws {
        _ = NSApplication.shared
        let store = store(), query = Query.parse("发票"), base = SearchPresentation(try XCTUnwrap(Searcher.search(query, in: store)))
        let hits = [1,2,3].map { SupplementaryHit(sourceID: "startup", entryID: UInt32($0), detail: "Additional matching text", highlights: [NSRange(location: 0, length: 10)], thumbnail: true) }
        let view = ResultsView(frame: NSRect(x: 0,y: 0,width: 760,height: 500)); view.show(base)
        let combined = base.supplement(hits, options: .init())
        XCTAssertEqual((0..<combined.count).compactMap { combined.row($0)?.id }, [1,3,2])
        XCTAssertEqual(combined.count, 3); XCTAssertNotNil(combined.detail(at: 0))
        view.refresh(combined); XCTAssertEqual(view.selectedID, 1)
        view.select(1)
        view.refresh(base.supplement(hits + [hits[0]], options: .init()))
        XCTAssertEqual(view.selectedID, 3)
        for options in [SearchOptions(sort: .modified, ascending: true), SearchOptions(sort: .size, ascending: true)] {
            let result = base.supplement(hits, options: options)
            let expected: [UInt32] = options.sort == .size ? [1,2,3] : [2,1,3]
            XCTAssertEqual((0..<result.count).compactMap { result.row($0)?.id }, expected)
        }
        let byName = base.supplement(hits, options: .init(sort: .name, ascending: true))
        XCTAssertEqual((0..<byName.count).compactMap { byName.row($0)?.id }, [3,2,1])
    }
    private final class Provider: SupplementarySearchProvider {
        var isEnabled = true
        let gate = DispatchSemaphore(value: 0)
        var delay = false
        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
            let delayed = delay, enabled = isEnabled
            return { [self] in
                if delayed { gate.wait() }
                guard enabled, !isCancelled() else { return [] }
                return [.init(sourceID: "startup", entryID: 3, detail: "Generated additional text")]
            }
        }
        func sourcesDidChange(_ sources: [SearchSource]) { }
        func userActivity(visible: Bool, typing: Bool) { }
    }
    func testBackgroundPublicationKeepsContentSelectionUntilCompletion() throws {
        _ = NSApplication.shared
        let store = store(), provider = Provider(), controller = SearchViewController(snapshot: true)
        _ = controller.view
        // A generated name index is loaded through the existing offline path.
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("M22-selection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: db) }
        try store.save(to: db.path)
        let indexManager = IndexManager(config: IndexConfig(rootPath: "/generated"), dbURL: db)
        defer { indexManager.stop() }
        indexManager.startOffline()
        let deadline = Date().addingTimeInterval(3)
        while indexManager.store == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let loaded = try XCTUnwrap(indexManager.store)
        controller.manager = indexManager; controller.supplementaryProvider = provider
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(Query.parse("发票"), in: loaded)))
        controller.searchField.text = "发票"
        controller.present(base.supplement([.init(sourceID: "startup", entryID: 3, detail: "Generated additional text")], options: .init()), selection: 1)
        XCTAssertEqual(controller.results.selectedID, 3)
        provider.delay = true; controller.sourcesChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(controller.results.selectedID, 3)
        provider.gate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(controller.results.selectedID, 3)
        provider.isEnabled = false; provider.delay = false; controller.sourcesChanged()
        XCTAssertEqual(controller.results.result?.count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(controller.results.result?.count, 1)
    }
    func testStaleAndUnknownMatchesAreIgnored() throws {
        let store = store(), base = SearchPresentation(try XCTUnwrap(Searcher.search(Query.parse("发票"), in: store)))
        let result = base.supplement([.init(sourceID: "absent", entryID: 1, detail: "x"), .init(sourceID: "startup", entryID: 99, detail: "x")], options: .init())
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.isCurrent([SearchSource(id: "startup", displayName: "", isOnline: true, store: store)]))
        store.write { store.version += 1 }
        XCTAssertFalse(result.isCurrent([SearchSource(id: "startup", displayName: "", isOnline: true, store: store)]))
    }
}
