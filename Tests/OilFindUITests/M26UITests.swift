import AppKit
import Quartz
import XCTest
import OilFindCore
@testable import OilFindApp

final class M26UITests: XCTestCase {
    private func fixture() throws -> (URL, IndexStore, IndexConfig) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindM26-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<100 { try Data().write(to: root.appendingPathComponent(String(format: "row%03d.txt", index))) }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        return (root, store, config)
    }
    func testPresentationWithoutResetKeepsPixelOffset() throws {
        let (root, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = SearchViewController(snapshot: true)
        controller.view.frame = NSRect(origin: .zero, size: Theme.panelSize)
        let found = try XCTUnwrap(Searcher.search(.parse("row"), options: .init(sort: .name, ascending: true), in: store))
        controller.present(found)
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(controller.results.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1234.5))
        let origin = scroll.contentView.bounds.origin
        let selected = controller.results.selectedID
        controller.present(found, resetScroll: false)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        XCTAssertEqual(controller.results.selectedID, selected)
    }
}

extension M26UITests {
    private func key(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func testRefreshKeepsPixelsIdentityAndNeighborDuringScrolling() throws {
        let (root, store, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let view = ResultsView(frame: NSRect(x: 0, y: 0, width: 760, height: 450))
        let query = Query.parse("row"), options = SearchOptions(sort: .name, ascending: true)
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(query, options: options, in: store)))
        view.show(base, selection: 2); view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1234.5))
        let origin = scroll.contentView.bounds.origin, selected = try XCTUnwrap(view.selectedItem)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        try Data().write(to: root.appendingPathComponent("row000-new.txt"))
        _ = IndexUpdater(config: config).apply([FSChange(path: root.appendingPathComponent("row000-new.txt").path)], to: store)
        let updated = SearchPresentation(try XCTUnwrap(Searcher.search(query, options: options, in: store)))
        view.refresh(updated)
        XCTAssertTrue(view.result === base)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        XCTAssertEqual(view.selectedItem?.path, selected.path)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        let row = view.selectedRow
        try FileManager.default.removeItem(atPath: selected.path)
        _ = IndexUpdater(config: config).apply([FSChange(path: selected.path)], to: store)
        view.refresh(try XCTUnwrap(Searcher.search(query, options: options, in: store)))
        XCTAssertEqual(view.selectedRow, row)
        XCTAssertNotEqual(view.selectedItem?.path, selected.path)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        let identity = view.selectedID
        let supplemented = try XCTUnwrap(view.result).supplement([.init(sourceID: "startup", entryID: 90, detail: "Late matching detail")], options: options)
        view.refresh(supplemented)
        XCTAssertEqual(view.selectedID, identity)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        let source = SearchSource(id: "startup", displayName: "Disk", isOnline: false, store: store)
        view.refresh(SearchPresentation(try XCTUnwrap(MultiSearcher.search(query, options: options, in: [source]))))
        XCTAssertEqual(view.selectedID, identity)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        view.select(0)
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, origin.y)
        view.select(99)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, origin.y)
    }
    func testSpaceInputBrowsingMarkedTextAndDisabledPreference() throws {
        let (root, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OilFindM26UI-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SearchViewController(snapshot: true, preferences: defaults)
        try controller.prepareSnapshot(state: "results", query: "row", options: .init(), store: store, selection: 0)
        let space = key(49, characters: " ")
        XCTAssertFalse(controller.browsingResults)
        XCTAssertFalse(controller.handleKey(space))
        XCTAssertEqual(controller.footer.previewKey, "⌘Y")
        for code: UInt16 in [126, 125, 116, 121, 115, 119] {
            XCTAssertTrue(controller.handleKey(key(code)))
            XCTAssertTrue(controller.browsingResults)
            XCTAssertEqual(controller.footer.previewKey, L10n.text("hint.space"))
            controller.searchField.onChange?()
            XCTAssertFalse(controller.browsingResults)
            XCTAssertFalse(controller.handleKey(space))
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller; window.delegate = controller
        defer { window.close() }
        controller.searchField.focus()
        let editor = try XCTUnwrap(controller.searchField.input.currentEditor() as? SearchEditor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: space)
        XCTAssertEqual(controller.searchField.text, "row ")
        XCTAssertFalse(controller.browsingResults)
        controller.results.onPointerSelection?()
        XCTAssertTrue(controller.browsingResults)
        controller.searchField.editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(controller.searchField.editor.hasMarkedText())
        XCTAssertFalse(controller.handleKey(space))
        controller.searchField.editor.unmarkText()
        defaults.set(false, forKey: "previewWithSpace")
        controller.results.onPointerSelection?()
        XCTAssertFalse(controller.handleKey(space))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: space)
        XCTAssertTrue(controller.searchField.text.hasSuffix(" "))
        controller.panelWillShow()
        XCTAssertFalse(controller.browsingResults)
        XCTAssertEqual(controller.footer.previewKey, "⌘Y")
    }
    func testQuickLookToggleNavigationAndEscapeKeepPanel() throws {
        let (root, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let panel = SearchPanel(snapshot: true)
        defer {
            panel.searchController.quickLook.close()
            // Tear down the process-wide native panel before the next controller test.
            QLPreviewPanel.shared().close()
            panel.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            QLPreviewPanel.shared().orderOut(nil)
        }
        let controller = panel.searchController
        try controller.prepareSnapshot(state: "results", query: "row", options: .init(sort: .name, ascending: true), store: store, selection: 0)
        panel.makeKeyAndOrderFront(nil)
        controller.quickLook.close()
        let space = key(49, characters: " ")
        XCTAssertTrue(controller.handleKey(key(125)))
        XCTAssertTrue(controller.handleKey(space))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(controller.quickLook.isVisible)
        let previous = controller.results.selectedID
        XCTAssertTrue(controller.quickLook.previewPanel(nil, handle: key(125)))
        XCTAssertNotEqual(controller.results.selectedID, previous)
        XCTAssertEqual(controller.quickLook.selectedURL?()?.path, controller.results.selectedItem?.path)
        XCTAssertTrue(controller.quickLook.previewPanel(nil, handle: space))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(controller.quickLook.isVisible)
        XCTAssertTrue(controller.handleKey(space))
        XCTAssertTrue(controller.quickLook.previewPanel(nil, handle: key(53)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(controller.quickLook.isVisible)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.handleKey(key(16, characters: "y", flags: .command)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.quickLook.isVisible)
        controller.quickLook.close()
    }
    func testExcludedTypesCommitNormalizationUndoRedoAndBlur() throws {
        _ = NSApplication.shared
        let suite = "OilFindM26Settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsModel(snapshot: true, preferences: defaults)
        let controller = SettingsWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        // A native field uses the same editor and delegate as the grouped settings form.
        let field = ExcludedExtensionsField(model: model)
        window.contentView?.addSubview(field); field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(" .LOG, js , .css log  ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(defaults.stringArray(forKey: "excludedExtensions"))
        editor.breakUndoCoalescing()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertTrue(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(field.stringValue, "log js css")
        XCTAssertEqual(defaults.stringArray(forKey: "excludedExtensions"), ["log", "js", "css"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertTrue(window.performKeyEquivalent(with: key(6, characters: "z", flags: .command)))
        XCTAssertEqual(editor.string, " .LOG, js , .css log  ")
        XCTAssertTrue(window.performKeyEquivalent(with: key(6, characters: "z", flags: [.command, .shift])))
        XCTAssertEqual(editor.string, "log js css")
        editor.insertText(" .INC", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertEqual(defaults.stringArray(forKey: "excludedExtensions"), ["log", "js", "css"])
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(field.stringValue, "log js css inc")
        XCTAssertEqual(defaults.stringArray(forKey: "excludedExtensions"), ["log", "js", "css", "inc"])
        let old = L10n.snapshotChinese; defer { L10n.snapshotChinese = old }
        L10n.snapshotChinese = true
        XCTAssertEqual(L10n.explanation(.fileType("log")), "它的扩展名（.log）在「排除的文件类型」里。")
        XCTAssertEqual(L10n.text("coverage.fileType", "3"), "排除的文件类型：3 个")
        L10n.snapshotChinese = false
        XCTAssertEqual(L10n.explanation(.fileType("log")), "Its extension (.log) is in Excluded File Types.")
        XCTAssertEqual(L10n.text("coverage.fileType", "3"), "Excluded file types: 3")
    }
}

extension M26UITests {
    func testShrinkingResultsNeverClampPassiveViewport() throws {
        let (root, store, config) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let view = ResultsView(frame: NSRect(x: 0, y: 0, width: 760, height: 450))
        let query = Query.parse("row"), options = SearchOptions(sort: .name, ascending: true)
        view.show(try XCTUnwrap(Searcher.search(query, options: options, in: store)))
        view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 4500.5))
        let origin = scroll.contentView.bounds.origin
        let paths = (5..<100).map { root.appendingPathComponent(String(format: "row%03d.txt", $0)).path }
        for path in paths { try FileManager.default.removeItem(atPath: path) }
        _ = IndexUpdater(config: config).apply(paths.map { FSChange(path: $0) }, to: store)
        let next = try XCTUnwrap(Searcher.search(query, options: options, in: store))
        view.refresh(next)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        view.show(next)
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, origin.y)
    }
}

extension M26UITests {
    func testWithdrawingAnotherSourceKeepsSurvivingSelectionAndPixels() throws {
        let (rootA, storeA, _) = try fixture(), (rootB, storeB, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let a = SearchSource(id: "a", displayName: "A", isOnline: true, store: storeA)
        let b = SearchSource(id: "b", displayName: "B", isOnline: true, store: storeB)
        var sources = [a, b]
        let controller = SearchViewController(snapshot: true)
        controller.view.frame = NSRect(origin: .zero, size: Theme.panelSize)
        controller.additionalSources = { sources }
        controller.searchField.text = "row"
        let first = SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("row"), in: sources)))
        let row = try XCTUnwrap((0..<first.count).first { first.row($0)?.source.id == "b" })
        controller.present(first, selection: row)
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(controller.results.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1234.5))
        let origin = scroll.contentView.bounds.origin, selected = controller.results.selectedItem?.path
        sources = [b]; controller.sourcesChanged()
        let deadline = Date().addingTimeInterval(3)
        while controller.results.result?.sources.count != 1 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(controller.results.result?.sources.count, 1)
        XCTAssertEqual(controller.results.selectedItem?.path, selected)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
    }
}

extension M26UITests {
    func testMomentumRefreshWaitsForEndAndKeepsExactPixels() throws {
        let (root, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let view = ResultsView(frame: NSRect(x: 0, y: 0, width: 760, height: 450))
        let first = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("row"), in: store)))
        view.show(first); view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1234.5))
        func wheel(momentum: Int64) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        let began = try wheel(momentum: 1)
        XCTAssertEqual(began.momentumPhase, .began)
        scroll.scrollWheel(with: began)
        let origin = scroll.contentView.bounds.origin
        let next = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("row"), in: store)))
        view.refresh(next)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(view.result === first)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        let ended = try wheel(momentum: 3)
        XCTAssertEqual(ended.momentumPhase, .ended)
        scroll.scrollWheel(with: ended)
        let deadline = Date().addingTimeInterval(3)
        while view.result !== next && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(view.result === next)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
    }
}

extension M26UITests {
    func testSpaceOnOfflineResultKeepsUnavailableMessage() throws {
        let (root, store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = SearchSource(id: "archive", displayName: "Archive", isOnline: false, store: store)
        let controller = SearchViewController(snapshot: true)
        // The native preview panel is process-wide and can still be on screen from an earlier test,
        // so check that the key press leaves it as it was.
        let previewVisible = controller.quickLook.isVisible
        controller.present(SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("row"), in: [source]))))
        controller.results.onPointerSelection?()
        XCTAssertTrue(controller.handleKey(key(49, characters: " ")))
        XCTAssertEqual(controller.footer.text, L10n.text("source.unavailable", "Archive"))
        XCTAssertEqual(controller.quickLook.isVisible, previewVisible)
    }
    func testFileTypeCoverageIncludesAdditionalSources() throws {
        let (rootA, storeA, _) = try fixture(), (rootB, storeB, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        storeA.coverage.buckets[.fileType] = CoverageBucket(count: 2, examples: ["/a/file.log"])
        storeB.coverage.buckets[.fileType] = CoverageBucket(count: 3, examples: ["/b/file.log"])
        let model = SettingsModel(snapshotStore: storeA, snapshot: true)
        model.additionalSources = { [SearchSource(id: "b", displayName: "B", isOnline: false, store: storeB)] }
        model.refresh()
        XCTAssertEqual(model.coverage[.fileType].count, 5)
        XCTAssertEqual(model.coverage[.fileType].examples, ["/a/file.log", "/b/file.log"])
    }
}
